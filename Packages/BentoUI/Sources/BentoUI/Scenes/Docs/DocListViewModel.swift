import BentoData
import Dependencies
import Foundation
import Observation
import SQLiteData

/// The docs in a folder, all docs, or the starred ones, most recently edited first.
@MainActor
@Observable
public final class DocListViewModel {
  public enum Action: Equatable {
    case selectedDoc(Doc.ID?)
  }

  public let destination: SidebarDestination
  public var search = ""
  public var selectedDocID: Doc.ID? {
    didSet { if selectedDocID != oldValue { onAction(.selectedDoc(selectedDocID)) } }
  }
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchAll var docs: [DocListRow]
  @ObservationIgnored @FetchOne var folder: DocFolder?
  @ObservationIgnored @FetchAll(DocFolder.order(by: \.name)) var folders: [DocFolder]
  @ObservationIgnored private let store: any DocsStoring

  init(destination: SidebarDestination, store: any DocsStoring) {
    self.destination = destination
    self.store = store
  }

  var folderID: DocFolder.ID? {
    if case .docFolder(let id) = destination { id } else { nil }
  }

  var title: String {
    switch destination {
    case .starredDocs: "Starred"
    case .docFolder: folder?.name ?? "Folder"
    default: "All docs"
    }
  }

  /// Reloads for the current search. Called by the view when it changes.
  /// Set once the first load is done, so the view shows nothing for that moment rather than its
  /// empty state flashing up before the content.
  private(set) var hasLoaded = false

  func reload() async {
    _ = await withErrorReporting {
      if let folderID { try await $folder.load(DocFolder.find(folderID)) }
      try await $docs.load(DocQuery.docs(folderID: folderID, starredOnly: destination == .starredDocs, search: search))
    }
    // The rows show with their titles; their snippets fill in after.
    hasLoaded = true
    await loadSnippets()
  }

  /// The start of each listed doc's text, shown under its title as in Craft.
  private(set) var snippets: [Doc.ID: String] = [:]
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database

  /// Reads the snippets again for docs edited since; called when the list changes.
  func refreshSnippets() async {
    let edited = Set(docs.filter { snippetDates[$0.id] != $0.updatedAt }.map(\.id))
    for id in edited { snippets[id] = nil }
    await loadSnippets()
    for doc in docs { snippetDates[doc.id] = doc.updatedAt }
  }

  @ObservationIgnored private var snippetDates: [Doc.ID: Date] = [:]

  /// Reads the first lines of text of the listed docs that have none yet.
  func loadSnippets() async {
    let ids = docs.map(\.id).filter { snippets[$0] == nil }
    guard !ids.isEmpty else { return }
    let found = await withErrorReporting {
      try await database.read { db in
        try DocQuery.snippets(db, docIDs: ids)
      }
    }
    if let found { snippets.merge(found) { _, new in new } }
  }

  /// A new, empty doc here, selected so it opens for typing.
  func addDoc() {
    withErrorReporting {
      let id = try store.addDoc(folderID: folderID, title: "", body: "")
      if destination == .starredDocs { try store.setStarred(id, true) }
      selectedDocID = id
    }
  }

  /// Imports files as new docs here and selects the last one.
  func importFiles(_ urls: [URL]) async {
    for url in urls {
      await withErrorReporting {
        let id = try await store.importFile(url, folderID: folderID)
        if destination == .starredDocs { try store.setStarred(id, true) }
        selectedDocID = id
      }
    }
  }

  func toggleStarred(_ doc: DocListRow) {
    withErrorReporting { try store.setStarred(doc.id, !doc.isStarred) }
  }

  func move(_ doc: DocListRow, to folderID: DocFolder.ID?) {
    withErrorReporting { try store.moveDoc(doc.id, folderID: folderID) }
  }

  func delete(_ doc: DocListRow) {
    if selectedDocID == doc.id { selectedDocID = nil }
    withErrorReporting { try store.deleteDoc(doc.id) }
  }
}

/// A doc dragged from the list to a folder travels as text with this prefix.
enum DocDrag {
  static let prefix = "bento-doc-move:"

  static func payload(_ id: Doc.ID) -> String { prefix + id.uuidString }

  static func docIDs(_ items: [String]) -> [Doc.ID] {
    items.compactMap { $0.hasPrefix(prefix) ? UUID(uuidString: String($0.dropFirst(prefix.count))) : nil }
  }
}

enum DocQuery {
  /// Each doc's opening text, plain, cut to a preview's length. Only the start of each body is
  /// read.
  static func snippets(_ db: Database, docIDs: [Doc.ID]) throws -> [Doc.ID: String] {
    let rows = try Doc
      .where { $0.id.in(docIDs) }
      .select { ($0.id, #sql("substr(\($0.body), 1, 800)", as: String.self)) }
      .fetchAll(db)
    var snippets: [Doc.ID: String] = [:]
    for (id, start) in rows {
      let text = plainText(start)
      if !text.isEmpty { snippets[id] = String(text.prefix(160)) }
    }
    return snippets
  }

  /// Markdown as the words it shows: markers, link addresses, images and code fences left out.
  static func plainText(_ markdown: String) -> String {
    var lines: [String] = []
    var inCode = false
    for line in markdown.split(separator: "\n") {
      var line = line.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") || line.hasPrefix("~~~") {
        inCode.toggle()
        continue
      }
      if inCode || line.hasPrefix("|") || line.hasPrefix("<") || line.hasPrefix("![") || line.allSatisfy({ "-*_=".contains($0) }) {
        continue
      }
      line = line.replacingOccurrences(of: #"^(#{1,6}|>|[-*+]( \[[ xX]\])?|\d+\.)\s+"#, with: "", options: .regularExpression)
      line = line.replacingOccurrences(of: #"!?\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
      line = line.replacingOccurrences(of: #"(\*\*|__|~~|`|\*|_)"#, with: "", options: .regularExpression)
      if !line.isEmpty { lines.append(line) }
    }
    return lines.joined(separator: " ")
  }

  /// Docs whose title or text contains `search`, most recently edited first.
  static func docs(folderID: DocFolder.ID?, starredOnly: Bool, search: String) -> some Statement<DocListRow> {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    return Doc
      .where {
        if let folderID { $0.folderID.eq(folderID) }
      }
      .where {
        if starredOnly { $0.isStarred }
      }
      .where { doc in
        if !needle.isEmpty {
          #sql(
            "(instr(bentoLower(\(doc.title)), \(bind: needle)) > 0 OR instr(bentoLower(\(doc.body)), \(bind: needle)) > 0)",
            as: Bool.self
          )
        }
      }
      .order { $0.updatedAt.desc() }
      .select {
        DocListRow.Columns(id: $0.id, folderID: $0.folderID, title: $0.title, isStarred: $0.isStarred, updatedAt: $0.updatedAt)
      }
  }
}

/// What a list of docs shows of each: never its text, which can be a long saved article and is
/// read only up to a snippet's length.
@Selection
struct DocListRow: Identifiable, Hashable {
  let id: Doc.ID
  let folderID: DocFolder.ID?
  let title: String
  let isStarred: Bool
  let updatedAt: Date
}
