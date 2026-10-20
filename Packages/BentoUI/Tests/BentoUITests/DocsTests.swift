@testable import BentoData
import Dependencies
import DependenciesTestSupport
import Foundation
import SQLiteData
import SwiftUI
import Testing

@testable import BentoUI

final class FakeLinkPreviewer: LinkPreviewing, @unchecked Sendable {
  private let lock = NSLock()
  private var fetched = 0
  let metadata: LinkMetadata

  init(metadata: LinkMetadata = LinkMetadata(title: "Fake title", summary: "Fake summary", siteName: "example.com")) {
    self.metadata = metadata
  }

  var calls: Int { lock.withLock { fetched } }

  func preview(for url: URL) async throws -> LinkMetadata {
    lock.withLock { fetched += 1 }
    return metadata
  }
}

/// Never answers before it is cancelled, as a slow page would when the doc is closed.
struct SlowLinkPreviewer: LinkPreviewing {
  func preview(for url: URL) async throws -> LinkMetadata {
    try await Task.sleep(for: .seconds(30))
    return LinkMetadata(title: "Too late")
  }
}
@MainActor
func eventually(timeout: Duration = .seconds(10), _ condition: () -> Bool) async -> Bool {
  let clock = ContinuousClock()
  let deadline = clock.now + timeout
  while !condition() {
    if clock.now > deadline { return false }
    try? await Task.sleep(for: .milliseconds(25))
  }
  return true
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocListTests {
  @Test func addingInAFolderCreatesAndSelectsADocThere() async throws {
    @Dependency(\.defaultDatabase) var database
    let folder = try await database.write { try Mutations.addDocFolder($0, name: "F", parentID: nil) }
    let model = DocListViewModel(destination: .docFolder(folder), store: NativeDocsStore(database: database))

    model.addDoc()

    let id = try #require(model.selectedDocID)
    let doc = try await database.read { try Doc.find(id).fetchOne($0) }
    #expect(doc?.folderID == folder)
  }

  @Test func addingInStarredCreatesAStarredDoc() async throws {
    @Dependency(\.defaultDatabase) var database
    let model = DocListViewModel(destination: .starredDocs, store: NativeDocsStore(database: database))

    model.addDoc()

    let id = try #require(model.selectedDocID)
    let doc = try await database.read { try Doc.find(id).fetchOne($0) }
    #expect(doc?.isStarred == true)
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocsCoordinatorTests {
  let store = FakeLibraryStore()

  @Test func selectingAllDocsShowsTheDocListInsteadOfTheFeed() {
    let coordinator = AppCoordinator(container: .test(store: store))

    coordinator.sidebar.selection = .allDocs

    #expect(coordinator.docList != nil)
    #expect(coordinator.feed == nil)
  }

  @Test func selectingADocOpensTheEditor() {
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.sidebar.selection = .allDocs
    let id = UUID()

    coordinator.docList?.selectedDocID = id

    #expect(coordinator.docEditor?.docID == id)
  }

  @Test func goingBackToTheFeedClearsTheEditor() {
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.sidebar.selection = .allDocs
    coordinator.docList?.selectedDocID = UUID()

    coordinator.sidebar.selection = .all

    #expect(coordinator.docEditor == nil)
    #expect(coordinator.feed?.destination == .all)
  }

  @Test func typingBeforeTheLoadFinishesIsKept() async throws {
    @Dependency(\.defaultDatabase) var database
    let docID = try await database.write { try Mutations.addDoc($0, folderID: nil, title: "") }
    let page = DocPageViewModel(docID: docID, store: NativeDocsStore(database: database))
    #expect(page.isEditing)

    page.body = "typed"
    page.edited()
    await page.load()
    page.flush()

    #expect(page.body == "typed")
    #expect(try await database.read { try Doc.find(docID).fetchOne($0)?.body } == "typed")
  }

  @Test func aNewDocOpensForEditingAndSavesItsMarkdown() async throws {
    @Dependency(\.defaultDatabase) var database
    let docID = try await database.write { try Mutations.addDoc($0, folderID: nil, title: "") }
    let page = DocPageViewModel(docID: docID, store: NativeDocsStore(database: database))
    await page.load()
    #expect(page.isEditing)

    page.title = "Notes"
    page.body = "## Ideas\n- one"
    page.edited()
    page.flush()

    let stored = try #require(try await database.read { try Doc.find(docID).fetchOne($0) })
    #expect(stored.title == "Notes")
    #expect(stored.body == "## Ideas\n- one")
    #expect(page.markdown == "# Notes\n\n## Ideas\n- one\n")
  }

  @Test func aLinkToADocThatIsGoneStaysALinkButOpensNothing() async throws {
    @Dependency(\.defaultDatabase) var database
    let gone = UUID()
    let (pageID, otherID) = try await database.write { db -> (Doc.ID, Doc.ID) in
      let other = try Mutations.addDoc(db, folderID: nil, title: "Physics")
      let body = "\(DocLink.markdown(title: "Old", id: gone)) and \(DocLink.markdown(title: "Stale", id: other))"
      return (try Mutations.addDoc(db, folderID: nil, title: "Notes", body: body), other)
    }
    let page = DocPageViewModel(docID: pageID, store: NativeDocsStore(database: database))
    var opened: [Doc.ID] = []
    page.onAction = { if case .openDoc(let id) = $0 { opened.append(id) } }
    await page.load()

    #expect(page.preview == "\(DocLink.markdown(title: "Old", id: gone)) and \(DocLink.markdown(title: "Physics", id: otherID))")
    #expect(!page.docExists(gone) && page.docExists(otherID))
    page.openDoc(gone)
    page.openDoc(otherID)
    #expect(opened == [otherID])
  }

  @Test func imagesTheTextNoLongerLinksGoWhenEditingEnds() async throws {
    @Dependency(\.defaultDatabase) var database
    let docID = try await database.write { try Mutations.addDoc($0, folderID: nil, title: "D") }
    let asset = try await database.write {
      try Mutations.addDocAsset($0, docID: docID, name: "a.png", contentType: "public.png", data: Data([1]), now: Date.now.addingTimeInterval(-3600))
    }
    try await database.write {
      try Mutations.setDocBody($0, id: docID, body: DocAsset.markdown(id: asset, name: "a.png", isImage: true))
    }
    let page = DocPageViewModel(docID: docID, store: NativeDocsStore(database: database))
    await page.load()
    page.isEditing = true

    page.body = "no image now"
    page.edited()
    page.toggleEditing()

    #expect(await eventually { (try? database.read { try DocAsset.count().fetchOne($0) }) == 0 })
  }

  @Test func aLinkToADocTheListDoesNotShowOpensItUnderAllDocs() async throws {
    @Dependency(\.defaultDatabase) var database
    let (starred, other) = try await database.write { db -> (Doc.ID, Doc.ID) in
      let starred = try Mutations.addDoc(db, folderID: nil, title: "Starred")
      try Mutations.setDocStarred(db, id: starred, true)
      return (starred, try Mutations.addDoc(db, folderID: nil, title: "Other"))
    }
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.sidebar.selection = .starredDocs
    await coordinator.docList?.reload()
    coordinator.docList?.selectedDocID = starred
    let page = try #require(coordinator.docEditor)
    await page.load()

    page.openDoc(other)

    #expect(coordinator.sidebar.selection == .allDocs)
    #expect(coordinator.docList?.selectedDocID == other)
    #expect(coordinator.docEditor?.docID == other)
  }

  @Test func followingADocLinkGoesStraightToIt() async throws {
    @Dependency(\.defaultDatabase) var database
    let (parentID, otherID) = try await database.write { db -> (Doc.ID, Doc.ID) in
      (try Mutations.addDoc(db, folderID: nil, title: "Parent"), try Mutations.addDoc(db, folderID: nil, title: "Other"))
    }
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.sidebar.selection = .allDocs
    coordinator.docList?.selectedDocID = parentID
    let parent = try #require(coordinator.docEditor)
    await parent.load()

    parent.openDoc(otherID)

    #expect(coordinator.docEditor?.docID == otherID)
    // Selected in the list too, as if chosen there.
    #expect(coordinator.docList?.selectedDocID == otherID)
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct SaveToDocsTests {
  let store = FakeLibraryStore()

  @Test func savingAnItemCreatesOneDocWithItsLinkAndSummary() async throws {
    @Dependency(\.defaultDatabase) var database
    var saved = item(title: "Worth reading", summary: "The gist")
    saved.url = "https://example.com/a"
    let feedItem = saved
    try await database.write { try FeedItem.insert { feedItem }.execute($0) }
    let model = ItemDetailViewModel(itemID: feedItem.id, store: store, docs: NativeDocsStore(database: database))
    await model.load()

    model.saveToDocs()
    model.saveToDocs()

    let docs = try await database.read { try Doc.fetchAll($0) }
    #expect(docs.map(\.title) == ["Worth reading"])
    #expect(docs[0].body.hasPrefix("https://example.com/a\n\n> The gist"))
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct LinkPreviewTests {
  @Test func knownOEmbedPointsYouTubeLinksAtItsEndpoint() throws {
    let endpoint = try #require(NativeLinkPreviewer.knownOEmbed(for: URL(string: "https://youtu.be/x")!))
    let components = try #require(URLComponents(url: endpoint, resolvingAgainstBaseURL: false))

    #expect(components.host == "www.youtube.com")
    #expect(components.path == "/oembed")
    #expect(components.queryItems?.first { $0.name == "url" }?.value == "https://youtu.be/x")
    #expect(components.queryItems?.first { $0.name == "format" }?.value == "json")
    #expect(NativeLinkPreviewer.knownOEmbed(for: URL(string: "https://example.com")!) == nil)
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct DocDragToFolderTests {
  @Test func docsDroppedOnAFolderMoveIntoIt() async throws {
    @Dependency(\.defaultDatabase) var database
    let (folder, doc) = try await database.write { db in
      (try Mutations.addDocFolder(db, name: "F", parentID: nil), try Mutations.addDoc(db, folderID: nil, title: "D"))
    }
    let sidebar = SidebarViewModel(store: FakeLibraryStore(), docs: NativeDocsStore(database: database))

    #expect(sidebar.dropDocs([DocDrag.payload(doc), "not a doc"], into: folder))
    #expect(try await database.read { try Doc.find(doc).fetchOne($0)?.folderID } == folder)
    #expect(!sidebar.dropDocs(["plain text"], into: folder))
    #expect(sidebar.dropDocs([DocDrag.payload(doc)], into: nil))
    #expect(try await database.read { try Doc.find(doc).fetchOne($0)?.folderID } == nil)
  }
}

@Suite struct PublicWebTests {
  @Test func onlyPublicWebAddressesAreFetched() {
    for allowed in [
      "https://example.com/a", "http://93.184.216.34/x", "https://[2606:2800:220:1:248:1893:25c8:1946]/",
      "https://example.com./a", "http://[::ffff:93.184.216.34]/",
    ] {
      #expect(NativeLinkPreviewer.isPublicWeb(URL(string: allowed)), "\(allowed)")
    }
    for refused in [
      "file:///etc/hosts", "ftp://example.com/x", "http://localhost:8080", "http://router.local/", "http://127.0.0.1/",
      "http://10.0.0.1/", "http://192.168.1.1/", "http://172.20.0.1/", "http://169.254.169.254/latest", "http://[::1]/",
      "http://[fd00::1]/", "http://[fe80::1]/", "http://0.0.0.0/",
      // Other spellings of local addresses, read as the network stack reads them.
      "http://127.1/", "http://0x7f000001/", "http://2130706433/", "http://0177.0.0.1/", "http://10.1/",
      "http://[::ffff:127.0.0.1]/", "http://[::ffff:a9fe:a9fe]/", "http://[64:ff9b::a00:1]/", "http://localhost./",
      "http://127.0.0.1./",
    ] {
      #expect(!NativeLinkPreviewer.isPublicWeb(URL(string: refused)), "\(refused)")
    }
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct OrphanAndFolderTests {
  @Test func deletingAFolderWaitsForConfirmation() async throws {
    @Dependency(\.defaultDatabase) var database
    let sidebar = SidebarViewModel(store: FakeLibraryStore(), docs: NativeDocsStore(database: database))
    sidebar.addFolder()
    try await Task.sleep(for: .milliseconds(200))
    let row = try #require(sidebar.folderRows.first)

    sidebar.folderToDelete = row
    #expect(try await database.read { try DocFolder.count().fetchOne($0) } == 1)
    sidebar.deleteFolder(row.id)
    #expect(try await database.read { try DocFolder.count().fetchOne($0) } == 0)
  }
}
