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
func makeTestDocEditor(
  title: String = "", _ blocks: [DocContent], previewer: any LinkPreviewing = FakeLinkPreviewer()
) async throws -> (model: DocEditorViewModel, docID: Doc.ID) {
  @Dependency(\.defaultDatabase) var database
  let docID = try await database.write { try Mutations.addDoc($0, folderID: nil, title: title, blocks: blocks) }
  let model = DocEditorViewModel(docID: docID, store: NativeDocsStore(database: database), linkPreviewer: previewer)
  await model.load()
  return (model, docID)
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

/// A paragraph for `block`, as the text view reads it back; `text` is what the paragraph now holds.
func para(_ block: DocBlock, _ text: String? = nil) -> DocParagraphState {
  DocParagraphState(blockID: block.id, block: block, isTitle: false, markdown: text ?? block.text)
}

func titleParagraph(_ text: String) -> DocParagraphState {
  DocParagraphState(blockID: nil, block: nil, isTitle: true, markdown: text)
}

/// The paragraphs of the blocks on screen as they are now, with some texts (by index) replaced.
@MainActor
func paragraphs(_ model: DocEditorViewModel, _ edits: [Int: String] = [:]) -> [DocParagraphState] {
  model.visibleBlocks.enumerated().map { para($1, edits[$0]) }
}

@MainActor
func focus(_ model: DocEditorViewModel, _ ids: DocBlock.ID...) {
  model.selectionChanged(focused: ids.first, selected: ids.count > 1 ? ids : [])
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocParagraphTests {
  func texts(_ model: DocEditorViewModel) -> [String] { model.blocks.map(\.text) }

  @Test func aChangedTextUpdatesItsBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    let ids = model.blocks.map(\.id)

    let assigned = model.applyParagraphs(paragraphs(model, [0: "a2"]))

    #expect(texts(model) == ["a2", "b"])
    #expect(model.blocks.map(\.id) == ids)
    #expect(assigned.isEmpty)
  }

  @Test func nothingChangedMakesNoUndoStep() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.applyParagraphs(paragraphs(model))

    #expect(!model.canUndo)
  }

  @Test func aDuplicatedBlockBecomesANewBlockPlacedAfter() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    let (a, b) = (model.blocks[0], model.blocks[1])

    let assigned = model.applyParagraphs([para(a), para(a, ""), para(b)])

    #expect(texts(model) == ["a", "", "b"])
    #expect(model.blocks[0].id == a.id)
    #expect(model.blocks[2].id == b.id)
    #expect(model.blocks[1].id != a.id)
    #expect(assigned == [1: model.blocks[1].id])
  }

  @Test func theParagraphStillHoldingTheTextKeepsTheBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "hello")])
    let a = model.blocks[0]

    let assigned = model.applyParagraphs([para(a, ""), para(a, "hello")])

    #expect(texts(model) == ["", "hello"])
    #expect(model.blocks[1].id == a.id)
    #expect(assigned == [0: model.blocks[0].id])
  }

  @Test func aBlockUnknownToTheDocIsAddedAsNew() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    let pasted = DocBlock(docID: model.docID, text: "pasted")

    let assigned = model.applyParagraphs([para(model.blocks[0]), para(pasted), para(model.blocks[1])])

    #expect(texts(model) == ["a", "pasted", "b"])
    #expect(assigned[1] == model.blocks[1].id)
    #expect(model.blocks[1].id != pasted.id)
  }

  @Test func aMissingParagraphDeletesItsBlock() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, docID) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])

    model.applyParagraphs([para(model.blocks[0])])

    #expect(texts(model) == ["a"])
    let stored = try await database.read { try Mutations.docBlocks($0, docID: docID) }
    #expect(stored.map(\.text) == ["a"])
  }

  @Test func aDeletedCollapsedToggleTakesItsChildrenWithIt() async throws {
    let (model, _) = try await makeTestDocEditor([
      DocContent(kind: .toggle, text: "t"), DocContent(text: "child", indent: 1), DocContent(text: "after"),
    ])
    model.toggleCollapsed(model.blocks[0].id)

    model.applyParagraphs(paragraphs(model).filter { $0.markdown != "t" })

    #expect(texts(model) == ["after"])
  }

  @Test func reorderedParagraphsMoveTheirBlocks() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")])
    let (a, b, c) = (model.blocks[0], model.blocks[1], model.blocks[2])

    model.applyParagraphs([para(c), para(a), para(b)])

    #expect(texts(model) == ["c", "a", "b"])
    #expect(model.blocks.map(\.id) == [c.id, a.id, b.id])
  }

  @Test(arguments: [("# ", DocBlock.Kind.title), ("- ", .bullet), ("[] ", .todo)])
  func aTypedPrefixOnTheCaretBlockChangesItsKind(prefix: String, kind: DocBlock.Kind) async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let block = model.blocks[0]

    model.applyParagraphs([para(block, prefix)], caretBlockID: block.id)

    #expect(model.blocks.count == 1)
    #expect(model.blocks[0].kind == kind)
    #expect(model.blocks[0].text == "")
  }

  @Test func aPrefixInABlockTheCaretIsNotInStaysText() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let block = model.blocks[0]

    model.applyParagraphs([para(block, "# ")])

    #expect(model.blocks[0].kind == .text)
    #expect(model.blocks[0].text == "# ")
  }

  @Test func anEmptyDuplicateAfterATitleIsBodyText() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .title, text: "Head")])
    let head = model.blocks[0]

    model.applyParagraphs([para(head), para(head, "")])

    #expect(model.blocks.map(\.kind) == [.title, .text])
    #expect(texts(model) == ["Head", ""])
  }

  @Test func anEmptyDuplicateAfterAnOpenToggleIsItsFirstNestedLine() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .toggle, text: "t")])
    let toggle = model.blocks[0]

    model.applyParagraphs([para(toggle), para(toggle, "")])

    #expect(model.blocks.map(\.kind) == [.toggle, .text])
    #expect(model.blocks.map(\.indent) == [0, 1])
  }

  @Test func anEmptyDuplicateAfterAnItemContinuesTheListUnchecked() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .todo, text: "a", isChecked: true), DocContent(kind: .bullet, text: "b")])
    let (todo, bullet) = (model.blocks[0], model.blocks[1])

    model.applyParagraphs([para(todo), para(todo, ""), para(bullet), para(bullet, "")])

    #expect(model.blocks.map(\.kind) == [.todo, .todo, .bullet, .bullet])
    #expect(model.blocks.map(\.isChecked) == [true, false, false, false])
  }

  @Test func theTitleParagraphChangesTheDocTitle() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, docID) = try await makeTestDocEditor(title: "Old", [DocContent(text: "a")])

    let assigned = model.applyParagraphs([titleParagraph("New")] + paragraphs(model))

    #expect(model.title == "New")
    #expect(assigned.isEmpty)
    let stored = try await database.read { try Doc.find(docID).fetchOne($0) }
    #expect(stored?.title == "New")
    #expect(texts(model) == ["a"])
  }

  @Test func aSecondTitleParagraphIsTheFirstLineOfTheDoc() async throws {
    let (model, _) = try await makeTestDocEditor(title: "Title", [DocContent(text: "a")])

    let assigned = model.applyParagraphs([titleParagraph("Tit"), titleParagraph("le")] + paragraphs(model))

    #expect(model.title == "Tit")
    #expect(texts(model) == ["le", "a"])
    #expect(assigned[1] == model.blocks[0].id)
  }

  @Test func editsAreWrittenToTheDatabase() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, docID) = try await makeTestDocEditor([DocContent()])

    model.applyParagraphs(paragraphs(model, [0: "typed"]))

    let stored = try await database.read { try Mutations.docBlocks($0, docID: docID) }
    #expect(stored.map(\.text) == ["typed"])
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocLineCommandTests {
  @Test func returnOnAnEmptyTopLevelItemMakesItBodyText() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .bullet)])
    let id = model.blocks[0].id

    #expect(model.endList(id))

    #expect(model.blocks.map(\.kind) == [.text])
  }

  @Test func returnOnAnEmptyNestedItemMovesItOutALevel() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .bullet, indent: 2)])
    let id = model.blocks[0].id

    #expect(model.endList(id))
    #expect(model.blocks[0].kind == .bullet)
    #expect(model.blocks[0].indent == 1)
    #expect(model.endList(id))
    #expect(model.endList(id))

    #expect(model.blocks[0].kind == .text)
    #expect(model.blocks[0].indent == 0)
  }

  @Test func returnOnAnItemWithTextOrOnBodyTextEndsNothing() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .bullet, text: "a"), DocContent(text: "")])

    #expect(!model.endList(model.blocks[0].id))
    #expect(!model.endList(model.blocks[1].id))
    #expect(model.blocks.map(\.kind) == [.bullet, .text])
    #expect(!model.canUndo)
  }

  @Test func deleteAtTheStartOfAnIndentedItemGoesOutAThenLosesTheStyle() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .bullet, text: "a", indent: 1)])
    let id = model.blocks[0].id

    #expect(model.unstyle(id))
    #expect(model.blocks[0].kind == .bullet)
    #expect(model.blocks[0].indent == 0)
    #expect(model.unstyle(id))

    #expect(model.blocks[0].kind == .text)
    #expect(model.blocks[0].text == "a")
    #expect(!model.unstyle(id))
  }

  @Test func unstyleClearsTheDecorationAndTheCheck() async throws {
    let (model, _) = try await makeTestDocEditor([
      DocContent(kind: .todo, text: "a", isChecked: true), DocContent(text: "q", decoration: .focus), DocContent(kind: .title, text: "t"),
    ])

    for block in model.blocks { #expect(model.unstyle(block.id)) }

    #expect(model.blocks.map(\.kind) == [.text, .text, .text])
    #expect(model.blocks.map(\.isChecked) == [false, false, false])
    #expect(model.blocks.map(\.decoration) == [.none, .none, .none])
  }

  @Test func unstyleLeavesEmbeddedBlocksAndPlainTextAlone() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .divider), DocContent(text: "plain")])

    #expect(!model.unstyle(model.blocks[0].id))
    #expect(!model.unstyle(model.blocks[1].id))
    #expect(!model.canUndo)
  }

  @Test func indentNestsTheBlocksAndStopsAtTheMargins() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .bullet, text: "a"), DocContent(text: "t")])
    let (bullet, text) = (model.blocks[0].id, model.blocks[1].id)

    model.indent([bullet, text], by: 1)
    #expect(model.blocks.map(\.indent) == [1, 1])
    model.indent([bullet], by: -1)
    #expect(model.blocks.map(\.indent) == [0, 1])
    for _ in 0..<8 { model.indent([text], by: 1) }
    #expect(model.blocks[1].indent == 6)
    for _ in 0..<8 { model.indent([text], by: -1) }
    #expect(model.blocks[1].indent == 0)
  }

  @Test func indentingAtTheMarginMakesNoUndoStep() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.indent([model.blocks[0].id], by: -1)

    #expect(!model.canUndo)
  }

  @Test func indentIsOneUndoStepForAllTheBlocks() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])

    model.indent(model.blocks.map(\.id), by: 1)
    model.undo()

    #expect(model.blocks.map(\.indent) == [0, 0])
    #expect(!model.canUndo)
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocFormatTests {
  @Test func settingAKindChangesTheFocusedBlockOnly() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    focus(model, model.blocks[0].id)

    model.setKind(.title)

    #expect(model.blocks.map(\.kind) == [.title, .text])
  }

  @Test func settingAKindChangesEverySelectedBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")])
    focus(model, model.blocks[0].id, model.blocks[1].id)

    model.setKind(.heading)

    #expect(model.blocks.map(\.kind) == [.heading, .heading, .text])
    #expect(model.blocks.map(\.text) == ["a", "b", "c"])
  }

  @Test func settingAListKindTwiceGoesBackToText() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    focus(model, model.blocks[0].id)

    model.setKind(.bullet)
    #expect(model.blocks[0].kind == .bullet)
    model.setKind(.bullet)

    #expect(model.blocks[0].kind == .text)
  }

  @Test func formatDoesNothingWithoutAFocusedBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.setKind(.title)
    model.setColor(.red)

    #expect(model.blocks[0].kind == .text)
    #expect(model.blocks[0].color == .standard)
    #expect(!model.canUndo)
  }

  @Test func focusDecorationTogglesOnAndOff() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    focus(model, model.blocks[0].id)

    model.toggleDecoration(.focus)
    #expect(model.blocks[0].decoration == .focus)
    model.toggleDecoration(.block)
    #expect(model.blocks[0].decoration == .block)
    model.toggleDecoration(.block)

    #expect(model.blocks[0].decoration == .none)
  }

  @Test func colorFontAndAlignmentChangeTheFocusedBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    focus(model, model.blocks[0].id)

    model.setColor(.red)
    model.setFont(.serif)
    model.setAlignment(.center)

    #expect(model.blocks[0].color == .red)
    #expect(model.blocks[0].font == .serif)
    #expect(model.blocks[0].alignment == .center)
    #expect(model.blocks[1].color == .standard)
  }

  @Test func checkingATodoAndCollapsingAToggle() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .todo, text: "t"), DocContent(kind: .toggle, text: "g")])

    model.toggleChecked(model.blocks[0].id)
    model.toggleCollapsed(model.blocks[1].id)

    #expect(model.blocks.map(\.isChecked) == [true, false])
    #expect(model.blocks.map(\.isCollapsed) == [false, true])
  }

  @Test func collapsingAToggleHidesItsChildren() async throws {
    let (model, _) = try await makeTestDocEditor([
      DocContent(kind: .toggle, text: "t"), DocContent(text: "child", indent: 1), DocContent(text: "after"),
    ])

    model.toggleCollapsed(model.blocks[0].id)

    #expect(model.visibleBlocks.map(\.text) == ["t", "after"])
    #expect(model.blocks.map(\.text) == ["t", "child", "after"])
  }

  @Test func insertingOnAnEmptyBodyLineTurnsItIntoTheBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id
    focus(model, id)

    model.insert(.block(.bullet))

    #expect(model.blocks.map(\.kind) == [.bullet])
    #expect(model.blocks[0].id == id)
  }

  @Test func insertingAfterTheFocusedBlockAddsOneAndFocusesIt() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    focus(model, model.blocks[0].id)

    model.insert(.block(.bullet))

    #expect(model.blocks.map(\.kind) == [.text, .bullet, .text])
    #expect(model.focusRequest?.id == model.blocks[1].id)
  }

  @Test func insertingATableAddsALineAfterIt() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.insert(.block(.table))

    #expect(model.blocks.map(\.kind) == [.text, .table, .text])
  }

  @Test func tableEditing() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.insert(.block(.table))
    let id = try #require(model.blocks.first { $0.kind == .table }?.id)
    #expect(model.table(id).rows.count == 3)
    #expect(model.table(id).columnCount == 3)

    model.addRow(id)
    #expect(model.table(id).rows.count == 4)
    model.addColumn(id)
    #expect(model.table(id).columnCount == 4)

    model.setCell(id, row: 0, column: 0, "a")
    #expect(model.table(id).rows[0][0] == "a")
    #expect(model.markdown.contains("| a |"))

    model.removeRow(id, 3)
    #expect(model.table(id).rows.count == 3)
    model.removeColumn(id, 3)
    #expect(model.table(id).columnCount == 3)
  }

  @Test func insertingAPageAddsABlockWithAnUntitledDoc() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.insert(.block(.page))

    let id = try #require(model.blocks.first { $0.kind == .page }?.id)
    #expect(model.pageTitle(id) == "Untitled")
  }

  @Test func insertingASeparatorAddsADividerWithItsWeight() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])

    model.insert(.separator(.light))

    let divider = try #require(model.blocks.first { $0.kind == .divider })
    #expect(divider.lineWeight == .light)
  }

  @Test func markdownExportIncludesTitleAndBlocks() async throws {
    let (model, _) = try await makeTestDocEditor(
      title: "T", [DocContent(kind: .title, text: "H"), DocContent(kind: .todo, text: "x", isChecked: true)]
    )

    #expect(model.markdown.contains("# T"))
    #expect(model.markdown.contains("# H"))
    #expect(model.markdown.contains("- [x] x"))
  }

  @Test func countsIgnoreInlineSyntax() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "hello world"), DocContent(text: "**bold** x")])

    #expect(model.counts.words == 4)
    #expect(model.counts.characters == "hello world\nbold x".count)
  }
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

  @Test func openingAPageShowsItAndGoingBackReturnsToTheParent() async throws {
    @Dependency(\.defaultDatabase) var database
    let (docID, blockID, pageID) = try await database.write { db -> (Doc.ID, DocBlock.ID, Doc.ID) in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "Parent")
      let (block, pageID) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "Child")
      return (doc, block.id, pageID)
    }
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.sidebar.selection = .allDocs
    coordinator.docList?.selectedDocID = docID
    let parent = try #require(coordinator.docEditor)
    await parent.load()

    parent.open(blockID)

    let page = try #require(coordinator.docEditor)
    #expect(page.docID == pageID)
    #expect(page.parentTitle == "Parent")

    page.goBack()

    #expect(coordinator.docEditor?.docID == docID)
  }

  @Test func followingADocLinkOpensItAndGoingBackReturns() async throws {
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

    let linked = try #require(coordinator.docEditor)
    #expect(linked.docID == otherID)
    #expect(linked.parentTitle == "Parent")

    linked.goBack()

    #expect(coordinator.docEditor?.docID == parentID)
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
    let blocks = try await database.read { try Mutations.docBlocks($0, docID: docs[0].id) }
    #expect(blocks.map(\.kind).prefix(2) == [.link, .text])
    #expect(blocks[1].decoration == .focus)
    #expect(blocks.first?.text == "https://example.com/a")
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct LinkPreviewTests {
  @Test func aFetchCutShortSavesNoPreview() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .link, text: "https://example.com/a")], previewer: SlowLinkPreviewer())
    let id = model.blocks[0].id

    let fetch = Task { await model.loadPreview(id) }
    try await Task.sleep(for: .milliseconds(50))
    fetch.cancel()
    await fetch.value
    await model.load()

    #expect(model.linkPreview(id) == nil)
  }

  @Test func makingALinkTurnsAnEmptyBlockIntoALinkBlock() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id

    model.makeLink(id, url: "https://example.com/a")

    #expect(model.blocks[0].id == id)
    #expect(model.blocks[0].kind == .link)
    #expect(model.blocks[0].text == "https://example.com/a")
    #expect(model.blocks.map(\.kind) == [.link, .text])
    #expect(model.focusRequest?.id == model.blocks[1].id)
  }

  @Test func loadingAPreviewSavesIt() async throws {
    let previewer = FakeLinkPreviewer()
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .link, text: "https://example.com/a")], previewer: previewer)
    let id = model.blocks[0].id
    #expect(model.linkPreview(id) == nil)

    await model.loadPreview(id)
    await model.load()

    #expect(model.linkPreview(id)?.title == "Fake title")
    #expect(previewer.calls == 1)
  }

  @Test func aSecondLoadDoesNotFetchAgainUnlessForced() async throws {
    let previewer = FakeLinkPreviewer()
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .link, text: "https://example.com/a")], previewer: previewer)
    let id = model.blocks[0].id
    await model.loadPreview(id)
    await model.load()

    await model.loadPreview(id)
    #expect(previewer.calls == 1)

    await model.loadPreview(id, force: true)
    #expect(previewer.calls == 2)
  }

  @Test func changingTheLinkDropsItsPreview() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(kind: .link, text: "https://example.com/a")])
    let id = model.blocks[0].id
    await model.loadPreview(id)
    await model.load()
    #expect(model.linkPreview(id) != nil)

    model.setLink(id, "https://example.com/b")

    #expect(model.linkPreview(id) == nil)
  }

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
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocUndoTests {
  func texts(_ model: DocEditorViewModel) -> [String] { model.blocks.map(\.text) }

  @Test func typingAcrossSeveralEditsIsOneUndoStepAndRedoReappliesIt() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])

    for text in ["h", "he", "hel"] { model.applyParagraphs(paragraphs(model, [0: text])) }
    #expect(texts(model) == ["hel"])
    #expect(model.canUndo)

    model.undo()
    #expect(texts(model) == [""])
    #expect(!model.canUndo)

    model.redo()
    #expect(texts(model) == ["hel"])
  }

  @Test func typingInAnotherBlockStartsAnotherStep() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    model.applyParagraphs(paragraphs(model, [0: "a1"]))
    model.applyParagraphs(paragraphs(model, [1: "b1"]))

    model.undo()
    #expect(texts(model) == ["a1", "b"])
    model.undo()
    #expect(texts(model) == ["a", "b"])
  }

  @Test func undoingASplitRemovesTheNewBlockAndRestoresTheText() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, docID) = try await makeTestDocEditor([DocContent(text: "hello")])
    let a = model.blocks[0]
    model.applyParagraphs([para(a, "he"), para(a, "llo")])
    #expect(texts(model) == ["he", "llo"])

    model.undo()

    #expect(texts(model) == ["hello"])
    let stored = try await database.read { try Mutations.docBlocks($0, docID: docID) }
    #expect(stored.map(\.text) == ["hello"])
  }

  @Test func undoingARemovedPageBringsBackItsDocAndRedoDeletesItAgain() async throws {
    @Dependency(\.defaultDatabase) var database
    let (docID, blockID) = try await database.write { db -> (Doc.ID, DocBlock.ID) in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "Parent")
      let (block, _) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "Child")
      return (doc, block.id)
    }
    let model = DocEditorViewModel(docID: docID, store: NativeDocsStore(database: database))
    await model.load()
    func inside() async throws -> [Doc] {
      try await database.read { try Doc.where { $0.parentBlockID.eq(blockID) }.fetchAll($0) }
    }
    #expect(try await inside().count == 1)

    model.remove(blockID)
    #expect(try await inside().isEmpty)
    #expect(!model.blocks.contains { $0.id == blockID })

    model.undo()
    #expect(try await inside().count == 1)
    #expect(model.blocks.contains { $0.id == blockID })

    model.redo()
    #expect(try await inside().isEmpty)
    #expect(!model.blocks.contains { $0.id == blockID })
  }

  @Test func undoingAKindChange() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    focus(model, model.blocks[0].id)

    model.setKind(.title)
    #expect(model.blocks[0].kind == .title)
    model.undo()
    #expect(model.blocks[0].kind == .text)

    model.redo()
    #expect(model.blocks[0].kind == .title)
  }

  @Test func undoingAColorChange() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    focus(model, model.blocks[0].id)

    model.setColor(.red)
    #expect(model.blocks[0].color == .red)
    model.undo()
    #expect(model.blocks[0].color == .standard)

    model.redo()
    #expect(model.blocks[0].color == .red)
  }

  @Test func undoingAMoveRestoresTheOrder() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")])

    model.move(model.blocks[2].id, after: nil)
    #expect(texts(model) == ["c", "a", "b"])
    model.undo()

    #expect(texts(model) == ["a", "b", "c"])
  }

  @Test func theFlagsFollowTheStacks() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    #expect(!model.canUndo)
    #expect(!model.canRedo)

    focus(model, model.blocks[0].id)
    model.setColor(.red)
    #expect(model.canUndo)
    #expect(!model.canRedo)

    model.undo()
    #expect(!model.canUndo)
    #expect(model.canRedo)

    model.redo()
    #expect(model.canUndo)
    #expect(!model.canRedo)
  }

  @Test func aNewEditAfterUndoClearsRedo() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    focus(model, model.blocks[0].id)
    model.setColor(.red)
    model.undo()
    #expect(model.canRedo)

    model.setFont(.serif)

    #expect(!model.canRedo)
    model.redo()
    #expect(model.blocks[0].color == .standard)
    #expect(model.blocks[0].font == .serif)
  }

  @Test func undoLeavesABlockAnotherDeviceChangedMeanwhileAlone() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    model.applyParagraphs(paragraphs(model, [0: "a1"]))
    var other = model.blocks[1]
    other.text = "b from elsewhere"
    let synced = other
    try await database.write { try Mutations.updateDocBlock($0, synced) }
    await model.load()
    #expect(texts(model) == ["a1", "b from elsewhere"])

    model.undo()

    #expect(texts(model) == ["a", "b from elsewhere"])
    let docID = model.docID
    let stored = try await database.read { try Mutations.docBlocks($0, docID: docID) }
    #expect(stored.map(\.text) == ["a", "b from elsewhere"])
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocMovingTests {
  func texts(_ model: DocEditorViewModel) -> [String] { model.blocks.map(\.text) }

  func nested() async throws -> DocEditorViewModel {
    let (model, _) = try await makeTestDocEditor([
      DocContent(kind: .toggle, text: "t"), DocContent(text: "c1", indent: 1), DocContent(text: "c2", indent: 1),
      DocContent(text: "x"), DocContent(text: "y"),
    ])
    return model
  }

  @Test func movingAToggleMovesItsNestedChildrenInOrder() async throws {
    let model = try await nested()

    model.move(model.blocks[0].id, after: model.blocks[4].id)

    #expect(texts(model) == ["x", "y", "t", "c1", "c2"])
    #expect(model.blocks.map(\.indent) == [0, 0, 0, 1, 1])
  }

  @Test func movingIntoItsOwnSubtreeIsIgnored() async throws {
    let model = try await nested()

    model.move(model.blocks[0].id, after: model.blocks[1].id)

    #expect(texts(model) == ["t", "c1", "c2", "x", "y"])
    #expect(!model.canUndo)
  }

  @Test func movingAfterACollapsedToggleLandsAfterItsHiddenChildren() async throws {
    let model = try await nested()
    model.toggleCollapsed(model.blocks[0].id)

    model.move(model.blocks[4].id, after: model.blocks[0].id)

    #expect(texts(model) == ["t", "c1", "c2", "y", "x"])
  }

  @Test func moveByMinusOneSwapsWithThePreviousSibling() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")])

    model.move(model.blocks[2].id, by: -1)

    #expect(texts(model) == ["a", "c", "b"])
  }

  @Test func moveByOneSwapsWithTheNextSibling() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")])

    model.move(model.blocks[0].id, by: 1)

    #expect(texts(model) == ["b", "a", "c"])
  }

  @Test func movingUpSkipsOverTheNeighboursNestedChildren() async throws {
    let (model, _) = try await makeTestDocEditor([
      DocContent(text: "a"), DocContent(kind: .toggle, text: "b"), DocContent(text: "b1", indent: 1), DocContent(text: "c"),
    ])

    model.move(model.blocks[3].id, by: -1)

    #expect(texts(model) == ["a", "c", "b", "b1"])
  }

  @Test func movingDownSkipsOverTheNeighboursNestedChildren() async throws {
    let (model, _) = try await makeTestDocEditor([
      DocContent(text: "a"), DocContent(kind: .toggle, text: "b"), DocContent(text: "b1", indent: 1), DocContent(text: "c"),
    ])

    model.move(model.blocks[0].id, by: 1)

    #expect(texts(model) == ["b", "b1", "a", "c"])
  }

  @Test func droppingABlockPayloadMovesIt() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")])

    let handled = model.drop(DocBlockDrag.payload(model.blocks[0].id), after: model.blocks[2].id)

    #expect(handled)
    #expect(texts(model) == ["b", "c", "a"])
  }

  @Test func droppingAWebLinkInsertsALinkBlockAfterTheTarget() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])

    let handled = model.drop("https://example.com", after: model.blocks[0].id)

    #expect(handled)
    #expect(model.blocks.map(\.kind) == [.text, .link, .text])
    #expect(model.blocks[1].text == "https://example.com")
  }

  @Test func droppingMarkdownInsertsItsBlocksAfterTheTarget() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "z")])

    let handled = model.drop("# H\nbody", after: model.blocks[0].id)

    #expect(handled)
    #expect(model.blocks.map(\.kind) == [.text, .title, .text, .text])
    #expect(texts(model) == ["a", "H", "body", "z"])
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocLinkEditingTests {
  func doc(_ title: String, blocks: [DocContent] = []) async throws -> Doc.ID {
    @Dependency(\.defaultDatabase) var database
    return try await database.write { try Mutations.addDoc($0, folderID: nil, title: title, blocks: blocks) }
  }

  func linkedDocs(_ model: DocEditorViewModel) -> [Doc.ID] {
    model.linkChoices.compactMap { choice -> Doc.ID? in
      if case .doc(let doc) = choice { return doc.id }
      return nil
    }
  }

  @Test func aQueryOffersMatchingDocsAndCreate() async throws {
    let physics = try await doc("Physics")
    let (model, _) = try await makeTestDocEditor([DocContent()])

    model.linkQueryChanged(.init(blockID: model.blocks[0].id, query: "phy"))

    #expect(model.linkQuery?.query == "phy")
    #expect(await eventually { linkedDocs(model).contains(physics) })
    #expect(model.linkChoices.contains(.create("phy")))
  }

  @Test func clearingTheQueryClosesTheList() async throws {
    _ = try await doc("Physics")
    let (model, _) = try await makeTestDocEditor([DocContent()])
    model.linkQueryChanged(.init(blockID: model.blocks[0].id, query: "phy"))
    #expect(await eventually { !model.linkSuggestions.isEmpty })

    model.linkQueryChanged(nil)

    #expect(model.linkQuery == nil)
    #expect(model.linkSuggestions.isEmpty)
  }

  @Test func choosingADocAsksTheTextViewToLinkIt() async throws {
    let physics = try await doc("Physics")
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id
    var inserted: [(query: String, doc: Doc.ID, title: String)] = []
    model.linkInserter = { query, doc, title in inserted.append((query.query, doc, title)) }
    model.linkQueryChanged(.init(blockID: id, query: "phy"))
    #expect(await eventually { linkedDocs(model).contains(physics) })
    let choice = try #require(model.linkChoices.first { if case .doc(let doc) = $0 { doc.id == physics } else { false } })

    model.chooseLink(choice)

    #expect(inserted.count == 1)
    #expect(inserted.first?.query == "phy")
    #expect(inserted.first?.doc == physics)
    #expect(inserted.first?.title == "Physics")
    #expect(model.linkQuery == nil)
  }

  @Test func choosingCreateMakesANewDocAndLinksIt() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, _) = try await makeTestDocEditor([DocContent()])
    var inserted: [(doc: Doc.ID, title: String)] = []
    model.linkInserter = { _, doc, title in inserted.append((doc, title)) }
    model.linkQueryChanged(.init(blockID: model.blocks[0].id, query: "Chem"))

    model.chooseLink(.create("Chem"))

    let created = try await database.read { try Doc.where { $0.title.eq("Chem") }.fetchAll($0) }
    let chem = try #require(created.first)
    #expect(created.count == 1)
    #expect(inserted.count == 1)
    #expect(inserted.first?.doc == chem.id)
    #expect(inserted.first?.title == "Chem")
    #expect(model.linkQuery == nil)
  }

  @Test func undoingTheLinkDeletesTheDocItMade() async throws {
    @Dependency(\.defaultDatabase) var database
    let (model, _) = try await makeTestDocEditor([DocContent()])
    model.linkQueryChanged(.init(blockID: model.blocks[0].id, query: "Geology"))
    model.chooseLink(.create("Geology"))
    func geology() async throws -> [Doc] {
      try await database.read { try Doc.where { $0.title.eq("Geology") }.fetchAll($0) }
    }
    #expect(try await geology().count == 1)
    #expect(model.canUndo)

    model.undo()
    #expect(try await geology().isEmpty)

    model.redo()
    #expect(try await geology().count == 1)
  }

  @Test func dismissingTheQueryKeepsItClosedForTheSameText() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id
    let query = DocEditorViewModel.CaretQuery(blockID: id, query: "phy")
    model.linkQueryChanged(query)
    #expect(model.linkQuery != nil)

    #expect(model.dismissPopup())
    #expect(model.linkQuery == nil)
    #expect(!model.dismissPopup())

    model.linkQueryChanged(query)
    #expect(model.linkQuery == nil)

    model.linkQueryChanged(.init(blockID: id, query: "phyx"))
    #expect(model.linkQuery?.query == "phyx")
  }

  @Test func theQueryOpensAgainOnceItWasClearedInBetween() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let query = DocEditorViewModel.CaretQuery(blockID: model.blocks[0].id, query: "phy")
    model.linkQueryChanged(query)
    #expect(model.dismissPopup())

    model.linkQueryChanged(nil)
    model.linkQueryChanged(query)

    #expect(model.linkQuery?.query == "phy")
  }

  @Test func theArrowsWrapAroundASingleChoice() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    model.linkQueryChanged(.init(blockID: model.blocks[0].id, query: "zzz-none"))
    #expect(model.linkChoices == [.create("zzz-none")])

    #expect(model.movePopupSelection(by: 1))
    #expect(model.linkQuery?.selected == 0)
    #expect(model.movePopupSelection(by: -1))
    #expect(model.linkQuery?.selected == 0)
  }

  @Test func displayTextShowsTheLinkedDocsCurrentTitle() async throws {
    @Dependency(\.defaultDatabase) var database
    let target = try await doc("Optics")
    let (model, _) = try await makeTestDocEditor([DocContent(text: "see " + DocLink.markdown(title: "Optics", id: target))])
    #expect(await eventually { model.linkedTitles[target] == "Optics" })

    try await database.write { try Mutations.renameDoc($0, id: target, title: "Light") }
    await model.load()
    model.refreshLinks()

    #expect(await eventually { model.displayText(model.blocks[0]) == "see " + DocLink.markdown(title: "Light", id: target) })
    #expect(model.blocks[0].text.contains("[Optics]"))
  }

  @Test func openingALinkURLSendsOpenDoc() async throws {
    let target = UUID()
    let (model, _) = try await makeTestDocEditor([DocContent()])
    var received: [DocEditorViewModel.Action] = []
    model.onAction = { received.append($0) }

    #expect(model.openLink(DocLink.url(target)))
    #expect(!model.openLink(URL(string: "https://example.com")!))

    #expect(received == [.openDoc(target)])
  }

  @Test func aDocListsTheDocsThatLinkToIt() async throws {
    @Dependency(\.defaultDatabase) var database
    let target = try await doc("Target")
    let source = try await doc("Source", blocks: [DocContent(text: "see " + DocLink.markdown(title: "Target", id: target))])
    let other = try await doc("Other")
    let model = DocEditorViewModel(docID: target, store: NativeDocsStore(database: database))

    await model.load()

    #expect(model.backlinks.map(\.id) == [source])
    #expect(!model.backlinks.map(\.id).contains(other))
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocSlashTests {
  @Test func aQueryNarrowsTheMenu() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id

    model.slashQueryChanged(.init(blockID: id, query: ""))
    #expect(model.slashChoices.count == DocEditorViewModel.insertSections.flatMap(\.1).count)

    model.slashQueryChanged(.init(blockID: id, query: "tab"))
    #expect(model.slashChoices.map(\.name).contains("Table"))
    #expect(!model.slashChoices.map(\.name).contains("Toggle"))

    model.slashQueryChanged(nil)
    #expect(model.slashChoices.isEmpty)
  }

  @Test func keywordsMatchToo() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])

    model.slashQueryChanged(.init(blockID: model.blocks[0].id, query: "todo"))

    #expect(model.slashChoices.map(\.name) == ["Task List"])
  }

  @Test func choosingTableOnAnEmptyFocusedLineConvertsIt() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id
    focus(model, id)
    model.slashQueryChanged(.init(blockID: id, query: "tab"))
    let table = try #require(model.slashChoices.first { $0.name == "Table" })

    model.chooseSlash(table)

    #expect(model.slashQuery == nil)
    #expect(model.blocks[0].id == id)
    #expect(model.blocks.map(\.kind) == [.table, .text])
  }

  @Test func choosingAListOnAnEmptyFocusedLineConvertsItWithoutAddingOne() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id
    focus(model, id)
    model.slashQueryChanged(.init(blockID: id, query: "bull"))

    model.chooseSlash(try #require(model.slashChoices.first))

    #expect(model.blocks.map(\.kind) == [.bullet])
    #expect(model.blocks[0].id == id)
  }

  @Test func theTextViewIsAskedToRemoveTheTypedQuery() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    let id = model.blocks[0].id
    focus(model, id)
    var removed: [String] = []
    model.slashRemover = { removed.append($0.query) }
    model.slashQueryChanged(.init(blockID: id, query: "bull"))

    model.chooseSlash(try #require(model.slashChoices.first))

    #expect(removed == ["bull"])
  }

  @Test func escapeClosesTheMenu() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent()])
    model.slashQueryChanged(.init(blockID: model.blocks[0].id, query: "a"))

    #expect(model.dismissPopup())

    #expect(model.slashQuery == nil)
    #expect(!model.dismissPopup())
  }
}

@MainActor
@Suite(
  .dependency(\.defaultDatabase, try makeDatabase()),
  .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
)
struct DocTextFormatTests {
  @Test func numberedItemsCountPerLevelAndRestartAfterBodyText() async throws {
    let (model, _) = try await makeTestDocEditor([
      DocContent(kind: .numbered, text: "a"), DocContent(kind: .numbered, text: "a1", indent: 1),
      DocContent(kind: .numbered, text: "a2", indent: 1), DocContent(kind: .numbered, text: "b"),
      DocContent(text: "break"), DocContent(kind: .numbered, text: "c"),
    ])

    let numbers = DocTextRenderer.listNumbers(model.blocks)

    #expect(model.blocks.map { numbers[$0.id] ?? 0 } == [1, 1, 2, 2, 0, 1])
  }

  @Test func renderedTextReadsBackAsTheSameParagraphs() async throws {
    let (model, _) = try await makeTestDocEditor(
      title: "Cell biology",
      [
        DocContent(kind: .subtitle, text: "Mitochondria"),
        DocContent(text: "The **powerhouse** of _DNA_ and `ATP`"),
        DocContent(kind: .bullet, text: "Outer membrane", indent: 1),
        DocContent(kind: .todo, text: "Review", isChecked: true),
        DocContent(text: ""),
        DocContent(kind: .code, text: "let atp = adp + phosphate", language: "swift"),
        DocContent(kind: .divider),
        DocContent(text: "See " + DocLink.markdown(title: "Physics", id: UUID())),
      ]
    )

    let text = DocTextRenderer.render(title: model.title, blocks: model.blocks, host: nil) { $0.text }
    let states = DocTextReader.paragraphs(text)

    #expect(states.count == model.blocks.count + 1)
    #expect(states[0].isTitle)
    #expect(states[0].markdown == "Cell biology")
    for (state, block) in zip(states.dropFirst(), model.blocks) {
      #expect(state.blockID == block.id)
      #expect(state.markdown == (block.kind.isAttachment ? "" : block.text))
      #expect(state.attachmentID == (block.kind.isAttachment ? block.id : nil))
    }
  }

  @Test func theTitleParagraphHasNoBlock() async throws {
    let (model, _) = try await makeTestDocEditor(title: "T", [DocContent(text: "a")])

    let text = DocTextRenderer.render(title: model.title, blocks: model.blocks, host: nil) { $0.text }

    #expect(text.string == "T\na\n")
    #expect(DocTextReader.paragraphs(text).first?.blockID == nil)
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

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()), .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000)))
struct DocLinkDropTests {
  @Test func docsDroppedOnADocBecomeLinksAfterTheTarget() async throws {
    @Dependency(\.defaultDatabase) var database
    let (target, other) = try await database.write { db in
      (try Mutations.addDoc(db, folderID: nil, title: "Here", blocks: [DocContent(text: "a")]), try Mutations.addDoc(db, folderID: nil, title: "Physics"))
    }
    let model = DocEditorViewModel(docID: target, store: NativeDocsStore(database: database))
    await model.load()

    model.insertDocLinks([other, target], after: model.blocks[0].id)

    #expect(model.blocks.map(\.text) == ["a", DocLink.markdown(title: "Physics", id: other)])
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()), .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000)))
struct DailyNoteFlowTests {
  @Test func todayOpensTheDailyNoteInItsFolder() async throws {
    let coordinator = AppCoordinator(container: .test(store: FakeLibraryStore()))

    coordinator.sidebar.openToday()

    guard case .docFolder = coordinator.sidebar.selection else {
      Issue.record("Today did not select the Daily Notes folder")
      return
    }
    #expect(coordinator.docList != nil)
    #expect(coordinator.docEditor != nil)
    let opened = coordinator.docEditor?.docID
    coordinator.sidebar.selection = .allDocs
    coordinator.sidebar.openToday()
    #expect(coordinator.docEditor?.docID == opened)
  }

  @Test func aTemplateFillsTheNewDoc() async throws {
    @Dependency(\.defaultDatabase) var database
    let list = DocListViewModel(destination: .allDocs, store: NativeDocsStore(database: database))

    list.addDoc(from: .lecture)

    let id = try #require(list.selectedDocID)
    let kinds = try await database.read { try Mutations.docBlocks($0, docID: id).map(\.kind) }
    #expect(kinds.contains(.subtitle))
    #expect(kinds.contains(.todo))
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()), .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000)))
struct TypingSaveTests {
  func stored(_ id: DocBlock.ID) async throws -> String? {
    @Dependency(\.defaultDatabase) var database
    return try await database.read { try DocBlock.find(id).fetchOne($0)?.text }
  }

  @Test func typingIsSavedWhenItPauses() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    let block = model.blocks[0]

    #expect(model.applyParagraph(para(block, "ab"), caretBlockID: block.id))
    #expect(model.blocks[0].text == "ab")
    #expect(try await stored(block.id) == "a")

    try await Task.sleep(for: .milliseconds(700))
    #expect(try await stored(block.id) == "ab")
  }

  @Test func anyOtherEditSavesTypingFirst() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a"), DocContent(text: "b")])
    let (first, second) = (model.blocks[0], model.blocks[1])

    _ = model.applyParagraph(para(first, "a1"), caretBlockID: first.id)
    _ = model.applyParagraph(para(second, "b1"), caretBlockID: second.id)

    #expect(try await stored(first.id) == "a1")
    model.flushTyping()
    #expect(try await stored(second.id) == "b1")
  }

  @Test func undoAfterTypingRestoresTheStoredText() async throws {
    let (model, _) = try await makeTestDocEditor([DocContent(text: "a")])
    let block = model.blocks[0]

    _ = model.applyParagraph(para(block, "ab"), caretBlockID: block.id)
    model.undo()

    #expect(model.blocks[0].text == "a")
    #expect(try await stored(block.id) == "a")
  }
}
