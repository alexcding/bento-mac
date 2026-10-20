import BentoData
import Foundation
import Observation
import SQLiteData

public enum SidebarDestination: Hashable, Sendable {
  case all
  case bookmarks
  case channel(Channel.ID)
  case allDocs
  case starredDocs
  case docFolder(DocFolder.ID)

  var channelID: Channel.ID? {
    if case .channel(let id) = self { id } else { nil }
  }

  /// Destinations that list docs rather than feed items.
  public var isDocs: Bool {
    switch self {
    case .allDocs, .starredDocs, .docFolder: true
    case .all, .bookmarks, .channel: false
    }
  }
}

@MainActor
@Observable
public final class SidebarViewModel {
  public enum Action: Equatable {
    case selected(SidebarDestination)
    case openChannelSettings(Channel.ID)
    case newChannel
  }

  public var selection: SidebarDestination = .all {
    didSet { if selection != oldValue { onAction(.selected(selection)) } }
  }
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored
  @FetchAll(
    Channel
      .group(by: \.id)
      .order(by: \.position)
      .leftJoin(ChannelSource.all) { $0.id.eq($1.channelID) }
      .leftJoin(FeedItem.all) { $1.sourceID.eq($2.sourceID) }
      .leftJoin(ReadState.all) { $2.id.eq($3.feedItemID) }
      .select {
        ChannelRow.Columns(
          channel: $0,
          sourceCount: $1.id.count(distinct: true),
          unreadCount: $2.id.count(distinct: true, filter: $3.feedItemID.is(nil))
        )
      },
    animation: .default
  )
  var rows: [ChannelRow]

  @ObservationIgnored
  @FetchOne(
    FeedItem.where { !$0.id.in(ReadState.select(\.feedItemID)) && $0.sourceID.in(Source.select(\.id)) }.count()
  )
  var unreadTotal = 0

  @ObservationIgnored
  @FetchOne(Bookmark.count())
  var bookmarkCount = 0

  @ObservationIgnored
  @FetchAll(
    DocFolder
      .group(by: \.id)
      .order(by: \.position)
      .leftJoin(Doc.all) { $1.folderID.eq($0.id) }
      .select { DocFolderRow.Columns(folder: $0, docCount: $1.id.count()) },
    animation: .default
  )
  var folderRows: [DocFolderRow]

  @ObservationIgnored
  @FetchOne(Doc.count())
  var docCount = 0

  /// The folder whose name is being edited in place.
  var renamingFolderID: DocFolder.ID?

  /// The folder whose delete is waiting for confirmation.
  var folderToDelete: DocFolderRow?

  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let docs: any DocsStoring

  init(store: any LibraryStoring, docs: any DocsStoring) {
    self.store = store
    self.docs = docs
  }

  /// Folders nested under their parents, each level in position order.
  var folderTree: [DocFolderNode] {
    let children = Dictionary(grouping: folderRows, by: \.folder.parentID)
    let ids = Set(folderRows.map(\.id))
    func nodes(_ parentID: DocFolder.ID?) -> [DocFolderNode] {
      (children[parentID] ?? []).map { row in
        let nested = nodes(row.id)
        return DocFolderNode(row: row, children: nested.isEmpty ? nil : nested)
      }
    }
    // A folder whose parent has not synced yet shows at the top level until it arrives.
    let orphans = folderRows.filter { $0.folder.parentID.map { !ids.contains($0) } ?? false }
    return nodes(nil) + orphans.map { DocFolderNode(row: $0, children: nodes($0.id).nilIfEmpty) }
  }

  func addFolder(parentID: DocFolder.ID? = nil) {
    withErrorReporting {
      let id = try docs.addFolder(name: "New folder", parentID: parentID)
      selection = .docFolder(id)
      renamingFolderID = id
    }
  }

  func renameFolder(_ id: DocFolder.ID, to name: String) {
    renamingFolderID = nil
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty else { return }
    withErrorReporting { try docs.renameFolder(id, name: name) }
  }

  /// Docs dropped on a folder (nil: All docs, the top level) move into it.
  func dropDocs(_ items: [String], into folderID: DocFolder.ID?) -> Bool {
    let ids = DocDrag.docIDs(items)
    guard !ids.isEmpty else { return false }
    withErrorReporting {
      for id in ids { try docs.moveDoc(id, folderID: folderID) }
    }
    return true
  }

  func deleteFolder(_ id: DocFolder.ID) {
    if case .docFolder(let selected) = selection, isInside(selected, id) { selection = .allDocs }
    withErrorReporting { try docs.deleteFolder(id) }
  }

  /// Whether `folderID` is `ancestorID` or nested anywhere below it.
  private func isInside(_ folderID: DocFolder.ID, _ ancestorID: DocFolder.ID) -> Bool {
    let parents = Dictionary(folderRows.map { ($0.id, $0.folder.parentID) }, uniquingKeysWith: { first, _ in first })
    var current: DocFolder.ID? = folderID
    var seen: Set<DocFolder.ID> = []
    while let id = current, seen.insert(id).inserted {
      if id == ancestorID { return true }
      current = parents[id] ?? nil
    }
    return false
  }

  /// Opens settings for a channel that is saved only when the user creates it.
  func addChannel() {
    onAction(.newChannel)
  }

  func openSettings(_ channel: Channel) {
    onAction(.openChannelSettings(channel.id))
  }

  func toggleEnabled(_ channel: Channel) {
    var channel = channel
    channel.isEnabled.toggle()
    withErrorReporting { try store.updateChannel(channel) }
  }

  /// The channel the user asked to delete, waiting for confirmation.
  var channelToDelete: Channel?

  func delete(_ channel: Channel) {
    channelToDelete = nil
    if selection == .channel(channel.id) { selection = .all }
    withErrorReporting { try store.deleteChannel(channel.id) }
  }
}

@Selection
struct ChannelRow: Identifiable {
  let channel: Channel
  let sourceCount: Int
  let unreadCount: Int
  var id: Channel.ID { channel.id }
}

@Selection
struct DocFolderRow: Identifiable {
  let folder: DocFolder
  let docCount: Int
  var id: DocFolder.ID { folder.id }
}

struct DocFolderNode: Identifiable {
  let row: DocFolderRow
  let children: [DocFolderNode]?
  var id: DocFolder.ID { row.id }
}

extension Array {
  fileprivate var nilIfEmpty: Self? { isEmpty ? nil : self }
}
