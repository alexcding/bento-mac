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

  @ObservationIgnored @FetchAll var docs: [Doc]
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
  func reload() async {
    _ = await withErrorReporting {
      if let folderID { try await $folder.load(DocFolder.find(folderID)) }
      try await $docs.load(DocQuery.docs(folderID: folderID, starredOnly: destination == .starredDocs, search: search))
    }
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
  func addDoc(from template: DocTemplate? = nil) {
    withErrorReporting {
      let id = try store.addDoc(folderID: folderID, title: "", blocks: template?.blocks ?? [])
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

  func toggleStarred(_ doc: Doc) {
    withErrorReporting { try store.setStarred(doc.id, !doc.isStarred) }
  }

  func move(_ doc: Doc, to folderID: DocFolder.ID?) {
    withErrorReporting { try store.moveDoc(doc.id, folderID: folderID) }
  }

  func delete(_ doc: Doc) {
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
  /// Each doc's first lines of text, plain, cut to a preview's length.
  static func snippets(_ db: Database, docIDs: [Doc.ID]) throws -> [Doc.ID: String] {
    let textKinds: [DocBlock.Kind] = [.text, .bullet, .numbered, .todo, .toggle]
    let blocks = try DocBlock
      .where { $0.docID.in(docIDs) && $0.kind.in(textKinds) && $0.text.neq("") }
      .order { ($0.docID, $0.position) }
      .fetchAll(db)
    var snippets: [Doc.ID: String] = [:]
    for block in blocks {
      let current = snippets[block.docID] ?? ""
      guard current.count < 160 else { continue }
      let line = DocInline.plainText(DocLink.retitle(block.text, titles: [:]) { title, _ in title })
      snippets[block.docID] = current.isEmpty ? line : current + " " + line
    }
    return snippets.mapValues { String($0.prefix(160)) }
  }

  /// Docs whose title or any block contains `search`, most recently edited first.
  static func docs(folderID: DocFolder.ID?, starredOnly: Bool, search: String) -> some Statement<Doc> {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    return Doc
      .where {
        if let folderID { $0.folderID.eq(folderID) }
      }
      .where {
        // Pages inside other docs show in their parent, unless searched for.
        if needle.isEmpty { $0.parentBlockID.is(nil) }
      }
      .where {
        if starredOnly { $0.isStarred }
      }
      .where { doc in
        if !needle.isEmpty {
          #sql(
            """
            (instr(bentoLower(\(doc.title)), \(bind: needle)) > 0 OR \(doc.id) IN \
            (SELECT "docID" FROM "docBlocks" WHERE instr(bentoLower("text"), \(bind: needle)) > 0))
            """,
            as: Bool.self
          )
        }
      }
      .order { $0.updatedAt.desc() }
      .select { $0 }
  }
}
