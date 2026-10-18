#if os(macOS)
  import AppKit
  @testable import BentoData
  import Dependencies
  import DependenciesTestSupport
  import Foundation
  import SwiftUI
  import Testing

  @testable import BentoUI

  /// The real text view, hosted in an offscreen window and driven the way the keyboard drives it.
  @MainActor
  final class EditorRig {
    let model: DocEditorViewModel
    let window: NSWindow
    let host: NSHostingView<AnyView>
    let textView: DocNSTextView
    let controller: DocTextController

    private init(
      model: DocEditorViewModel, window: NSWindow, host: NSHostingView<AnyView>, textView: DocNSTextView, controller: DocTextController
    ) {
      self.model = model
      self.window = window
      self.host = host
      self.textView = textView
      self.controller = controller
    }

    static func make(title: String = "Doc", _ blocks: [DocContent]) async throws -> EditorRig {
      let (model, _) = try await makeTestDocEditor(title: title, blocks)
      let host = NSHostingView(rootView: AnyView(DocTextEditor(model: model).frame(width: 820, height: 800)))
      host.frame = CGRect(x: 0, y: 0, width: 820, height: 800)
      let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      var found: DocNSTextView?
      for _ in 0..<60 {
        pump(0.05)
        found = find(DocNSTextView.self, in: host)
        if let found, !found.string.isEmpty { break }
      }
      let textView = try #require(found)
      let controller = try #require(textView.controller)
      window.makeFirstResponder(textView)
      pump(0.1)
      return EditorRig(model: model, window: window, host: host, textView: textView, controller: controller)
    }

    func close() {
      window.orderOut(nil)
      window.contentView = nil
    }

    static func pump(_ seconds: Double = 0.1) {
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
      if let match = view as? T { return match }
      for sub in view.subviews { if let match = find(type, in: sub) { return match } }
      return nil
    }

    /// Lets SwiftUI and the controller catch up after a step.
    func settle() {
      Self.pump(0.1)
    }

    /// Runs the loop until `condition` holds.
    func wait(timeout: Double = 3, _ condition: () -> Bool) -> Bool {
      let deadline = Date().addingTimeInterval(timeout)
      while !condition() {
        if Date() > deadline { return false }
        Self.pump(0.02)
      }
      return true
    }

    func type(_ text: String) {
      textView.insertText(text, replacementRange: textView.selectedRange())
      settle()
    }

    func command(_ selector: Selector) {
      textView.doCommand(by: selector)
      settle()
    }

    func caretAtStart(of id: DocBlock.ID) {
      guard let range = controller.range(of: id) else {
        Issue.record("No paragraph for the block")
        return
      }
      textView.setSelectedRange(NSRange(location: range.location, length: 0))
    }

    func caretAtEnd(of id: DocBlock.ID) {
      guard let range = controller.range(of: id) else {
        Issue.record("No paragraph for the block")
        return
      }
      var end = NSMaxRange(range)
      if end > range.location, (textView.string as NSString).character(at: end - 1) == 0x0A { end -= 1 }
      textView.setSelectedRange(NSRange(location: end, length: 0))
    }

    func select(_ range: Range<Int>, in id: DocBlock.ID) {
      guard let paragraph = controller.range(of: id) else {
        Issue.record("No paragraph for the block")
        return
      }
      textView.setSelectedRange(NSRange(location: paragraph.location + range.lowerBound, length: range.count))
    }

    /// The block the paragraph at `id` is drawn as.
    func drawnBlock(_ id: DocBlock.ID) -> DocBlock? {
      guard let range = controller.range(of: id) else { return nil }
      return (textView.textStorage?.attribute(.docParagraph, at: range.location, effectiveRange: nil) as? DocParagraph)?.block
    }
  }

  @MainActor
  // One at a time: each test runs the main run loop to let the text view lay out.
  @Suite(
    .serialized,
    .dependency(\.defaultDatabase, try makeDatabase()),
    .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
  )
  struct DocTextEditorTests {
    let newline = #selector(NSTextView.insertNewline(_:))
    let tab = #selector(NSTextView.insertTab(_:))
    let backtab = #selector(NSTextView.insertBacktab(_:))
    let backspace = #selector(NSTextView.deleteBackward(_:))

    @Test func theTextIsTheTitleThenEachBlocksPlainText() async throws {
      let rig = try await EditorRig.make(
        title: "Cell biology",
        [
          DocContent(kind: .subtitle, text: "Mitochondria"),
          DocContent(text: "The **powerhouse** of _DNA_, `ATP` and [a site](https://example.com)."),
          DocContent(kind: .bullet, text: "Outer **membrane**", indent: 1),
          DocContent(kind: .numbered, text: "Glycolysis"),
          DocContent(kind: .todo, text: "Review", isChecked: true),
          DocContent(kind: .heading, text: "Energy"),
          DocContent(kind: .caption, text: "A caption"),
          DocContent(text: ""),
          DocContent(kind: .toggle, text: "Exam notes"),
          DocContent(kind: .code, text: "let atp = adp + phosphate"),
        ]
      )
      defer { rig.close() }

      let expected = "Cell biology\n" + rig.model.blocks.map { DocInline.plainText($0.text) + "\n" }.joined()

      #expect(rig.wait { rig.textView.string == expected })
      #expect(expected.contains("The powerhouse of DNA, ATP and a site.\n"))
    }

    @Test func typingAtTheEndOfABodyLineUpdatesItsBlock() async throws {
      let rig = try await EditorRig.make([DocContent(text: "Hello"), DocContent(text: "Other")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtEnd(of: id)
      rig.type(" world")

      #expect(rig.model.block(id)?.text == "Hello world")
      #expect(rig.model.blocks.map(\.text) == ["Hello world", "Other"])
      #expect(rig.textView.string == "Doc\nHello world\nOther\n")
    }

    @Test func typingInTheTitleChangesTheDocTitle() async throws {
      let rig = try await EditorRig.make(title: "Doc", [DocContent(text: "Hello")])
      defer { rig.close() }

      rig.textView.setSelectedRange(NSRange(location: 3, length: 0))
      rig.type("s")

      #expect(rig.model.title == "Docs")
      #expect(rig.model.blocks.map(\.text) == ["Hello"])
    }

    @Test func returnThenADashAndTextMakesANewBulletAfterIt() async throws {
      let rig = try await EditorRig.make([DocContent(text: "Hello")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtEnd(of: id)
      rig.command(newline)
      rig.type("- ")
      rig.type("new bullet")

      #expect(rig.model.blocks.map(\.kind) == [.text, .bullet])
      #expect(rig.model.blocks.map(\.text) == ["Hello", "new bullet"])
      #expect(rig.model.blocks[0].id == id)
    }

    @Test func returnOnAnEmptyBulletMakesItBodyTextWithoutANewBlock() async throws {
      let rig = try await EditorRig.make([DocContent(kind: .bullet, text: "a"), DocContent(kind: .bullet)])
      defer { rig.close() }
      let empty = rig.model.blocks[1].id

      rig.caretAtStart(of: empty)
      rig.command(newline)

      #expect(rig.model.blocks.map(\.kind) == [.bullet, .text])
      #expect(rig.model.blocks.count == 2)
      #expect(rig.model.blocks[1].id == empty)
    }

    @Test func returnInTheMiddleSplitsTheLine() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.select(2..<2, in: id)
      rig.command(newline)

      #expect(rig.model.blocks.map(\.text) == ["he", "llo"])
      #expect(rig.model.blocks[0].id == id)
    }

    @Test func tabIndentsAndDeleteAtTheLineStartOutdents() async throws {
      let rig = try await EditorRig.make([DocContent(text: "Body")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtStart(of: id)
      rig.command(tab)
      #expect(rig.model.block(id)?.indent == 1)

      rig.caretAtStart(of: id)
      rig.command(tab)
      #expect(rig.model.block(id)?.indent == 2)

      rig.caretAtStart(of: id)
      rig.command(backtab)
      #expect(rig.model.block(id)?.indent == 1)

      rig.caretAtStart(of: id)
      rig.command(backspace)
      #expect(rig.model.block(id)?.indent == 0)
      #expect(rig.model.block(id)?.text == "Body")
    }

    @Test func deleteAtTheStartOfABulletMakesItBodyText() async throws {
      let rig = try await EditorRig.make([DocContent(kind: .bullet, text: "a")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtStart(of: id)
      rig.command(backspace)

      #expect(rig.model.blocks.map(\.kind) == [.text])
      #expect(rig.model.blocks[0].text == "a")
    }

    @Test func deleteAtTheStartOfTheFirstLineDoesNotMergeIntoTheTitle() async throws {
      let rig = try await EditorRig.make(title: "Doc", [DocContent(text: "Body")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtStart(of: id)
      rig.command(backspace)

      #expect(rig.model.title == "Doc")
      #expect(rig.model.block(id)?.text == "Body")
    }

    @Test func deleteAtTheStartOfALineMergesItIntoTheOneAbove() async throws {
      let rig = try await EditorRig.make([DocContent(text: "a"), DocContent(text: "b")])
      defer { rig.close() }
      let second = rig.model.blocks[1].id

      rig.caretAtStart(of: second)
      rig.command(backspace)

      #expect(rig.model.blocks.map(\.text) == ["ab"])
    }

    @Test func aBracketPairAndASpaceMakeATodo() async throws {
      let rig = try await EditorRig.make([DocContent()])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtStart(of: id)
      rig.type("[] ")

      #expect(rig.model.blocks.count == 1)
      #expect(rig.model.blocks[0].kind == .todo)
      #expect(rig.model.blocks[0].text == "")
      #expect(rig.model.blocks[0].id == id)
    }

    @Test func boldOnASelectionStoresStarsAndTogglesBack() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.select(0..<3, in: id)
      rig.model.toggleInline(.bold)
      rig.settle()
      #expect(rig.model.block(id)?.text == "**hel**lo")
      #expect(rig.textView.string == "Doc\nhello\n")

      rig.model.toggleInline(.bold)
      rig.settle()
      #expect(rig.model.block(id)?.text == "hello")
    }

    @Test func italicAndCodeStoreTheirMarkers() async throws {
      let rig = try await EditorRig.make([DocContent(text: "one two")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.select(0..<3, in: id)
      rig.model.toggleInline(.italic)
      rig.settle()
      rig.select(4..<7, in: id)
      rig.model.toggleInline(.code)
      rig.settle()

      #expect(rig.model.block(id)?.text == "_one_ `two`")
    }

    @Test func undoAfterTypingRestoresTheTextInTheModelAndInTheView() async throws {
      let rig = try await EditorRig.make([DocContent(text: "Hello")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtEnd(of: id)
      rig.type(" world")
      #expect(rig.textView.string == "Doc\nHello world\n")

      rig.model.undo()

      #expect(rig.model.block(id)?.text == "Hello")
      #expect(rig.wait { rig.textView.string == "Doc\nHello\n" })

      rig.model.redo()

      #expect(rig.model.block(id)?.text == "Hello world")
      #expect(rig.wait { rig.textView.string == "Doc\nHello world\n" })
    }

    @Test func aKindChangedInTheModelIsRedrawnWithTheTextIntact() async throws {
      let rig = try await EditorRig.make([DocContent(text: "Hello"), DocContent(text: "Other")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtEnd(of: id)
      rig.model.selectionChanged(focused: id, selected: [])
      rig.model.setKind(.heading)

      #expect(rig.wait { rig.drawnBlock(id)?.kind == .heading })
      #expect(rig.textView.string == "Doc\nHello\nOther\n")
      #expect(rig.model.block(id)?.text == "Hello")
      #expect(rig.controller.blockID(at: rig.textView.selectedRange().location) == id)
    }

    @Test func aColorChangedInTheModelIsRedrawn() async throws {
      let rig = try await EditorRig.make([DocContent(text: "Hello")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtEnd(of: id)
      rig.model.selectionChanged(focused: id, selected: [])
      rig.model.setColor(.red)

      #expect(rig.wait { rig.drawnBlock(id)?.color == .red })
      #expect(rig.textView.string == "Doc\nHello\n")
    }

    @Test func collapsingAToggleTakesItsChildLineOutOfTheText() async throws {
      let rig = try await EditorRig.make([
        DocContent(kind: .toggle, text: "T"), DocContent(text: "child", indent: 1), DocContent(text: "after"),
      ])
      defer { rig.close() }
      let toggle = rig.model.blocks[0].id
      #expect(rig.textView.string == "Doc\nT\nchild\nafter\n")

      rig.model.toggleCollapsed(toggle)

      #expect(rig.wait { rig.textView.string == "Doc\nT\nafter\n" })
      #expect(rig.model.blocks.map(\.text) == ["T", "child", "after"])

      rig.model.toggleCollapsed(toggle)

      #expect(rig.wait { rig.textView.string == "Doc\nT\nchild\nafter\n" })
    }

    @Test func pastingTwoLinesCreatesTwoBlocks() async throws {
      let rig = try await EditorRig.make([DocContent(text: "x")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.caretAtEnd(of: id)
      rig.controller.paste("a\nb")
      rig.settle()

      #expect(rig.model.blocks.map(\.text) == ["x", "a", "b"])
      #expect(rig.model.blocks[0].id == id)
      #expect(rig.wait { rig.textView.string == "Doc\nx\na\nb\n" })
    }

    @Test func pastingOneLineKeepsItsInlineStylesInTheCurrentBlock() async throws {
      let rig = try await EditorRig.make([DocContent(text: "ab")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.select(1..<1, in: id)
      rig.controller.paste("**x**")
      rig.settle()

      #expect(rig.model.blocks.count == 1)
      #expect(rig.model.block(id)?.text == "a**x**b")
    }

    @Test func typingBracketsOpensTheLinkQueryAndTheSlashOpensTheMenu() async throws {
      let rig = try await EditorRig.make([DocContent(text: "see "), DocContent()])
      defer { rig.close() }
      let (first, second) = (rig.model.blocks[0].id, rig.model.blocks[1].id)

      rig.caretAtEnd(of: first)
      rig.type("[[phy")
      #expect(rig.model.linkQuery?.query == "phy")
      #expect(rig.model.linkQuery?.blockID == first)

      rig.caretAtStart(of: second)
      rig.type("/tab")
      #expect(rig.model.linkQuery == nil)
      #expect(rig.model.slashQuery?.query == "tab")
      #expect(rig.model.slashChoices.map(\.name).contains("Table"))
    }

    // Next to an embedded block (a link card here).

    @Test func deleteAfterALinkCardDeletesTheCardAndUndoBringsItBack() async throws {
      let rig = try await EditorRig.make([DocContent(text: "a"), DocContent(kind: .link, text: "https://example.com"), DocContent(text: "b")])
      defer { rig.close() }
      let link = rig.model.blocks[1].id

      rig.caretAtEnd(of: link)
      rig.command(backspace)

      #expect(rig.model.blocks.map(\.text) == ["a", "b"])
      rig.model.undo()
      #expect(rig.wait { rig.model.block(link)?.text == "https://example.com" })
    }

    @Test func typingAfterALinkCardMakesOneLineAfterItAndKeepsTheLink() async throws {
      let rig = try await EditorRig.make([DocContent(text: "a"), DocContent(kind: .link, text: "https://example.com"), DocContent(text: "b")])
      defer { rig.close() }
      let link = rig.model.blocks[1].id

      rig.caretAtEnd(of: link)
      rig.type("x")
      rig.type("y")
      rig.type("z")

      #expect(rig.model.block(link)?.text == "https://example.com")
      #expect(rig.model.blocks.map(\.text) == ["a", "https://example.com", "xyz", "b"])
    }

    @Test func typingBeforeALinkCardMakesALineBeforeItAndKeepsTheLink() async throws {
      let rig = try await EditorRig.make([DocContent(text: "a"), DocContent(kind: .link, text: "https://example.com"), DocContent(text: "b")])
      defer { rig.close() }
      let link = rig.model.blocks[1].id

      rig.caretAtStart(of: link)
      rig.type("x")

      #expect(rig.model.block(link)?.text == "https://example.com")
      #expect(rig.model.blocks.map(\.text) == ["a", "x", "https://example.com", "b"])
    }

    @Test func returnAfterALinkCardKeepsTheLink() async throws {
      let rig = try await EditorRig.make([DocContent(kind: .link, text: "https://example.com"), DocContent(text: "b")])
      defer { rig.close() }
      let link = rig.model.blocks[0].id

      rig.caretAtEnd(of: link)
      rig.command(newline)
      rig.type("c")

      #expect(rig.model.block(link)?.text == "https://example.com")
      #expect(rig.model.blocks.map(\.text) == ["https://example.com", "c", "b"])
    }

    @Test func pastingBlocksKeepsEmbeddedOnes() async throws {
      let rig = try await EditorRig.make([DocContent(text: "x")])
      defer { rig.close() }
      let first = rig.model.blocks[0].id

      rig.caretAtEnd(of: first)
      rig.controller.paste("a\n---\nhttps://example.com\nb")

      #expect(rig.model.blocks.map(\.kind) == [.text, .text, .divider, .link, .text])
      #expect(rig.model.blocks.map(\.text) == ["x", "a", "", "https://example.com", "b"])
    }

    @Test func pastingBlocksInTheMiddleOfALineSplitsIt() async throws {
      let rig = try await EditorRig.make([DocContent(text: "start end")])
      defer { rig.close() }
      let first = rig.model.blocks[0].id

      rig.select(5..<5, in: first)
      rig.controller.paste("one\ntwo")

      #expect(rig.model.blocks.map(\.text) == ["start", "one", "two", " end"])
    }

    @Test func typingInALongDocStaysFast() async throws {
      let rig = try await EditorRig.make((0..<2_000).map { DocContent(text: "Paragraph \($0) with some **bold** words in it.") })
      defer { rig.close() }
      let target = rig.model.blocks[1_000].id
      rig.caretAtEnd(of: target)

      let clock = ContinuousClock()
      let elapsed = clock.measure {
        for _ in 0..<20 { rig.textView.insertText("x", replacementRange: rig.textView.selectedRange()) }
      }

      #expect(rig.model.block(target)?.text.hasSuffix("xxxxxxxxxxxxxxxxxxxx") == true)
      print("TIMING 20 keystrokes in a 2,000-block doc: \(elapsed)")
      // Debug build; the whole-doc path took about 300 ms a keystroke.
      #expect(elapsed < .milliseconds(20 * 60))
    }

    @Test func pastingFromTheTitlePutsBlocksFirst() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello"), DocContent(text: "world")])
      defer { rig.close() }

      rig.textView.setSelectedRange(NSRange(location: 3, length: 0))
      rig.controller.paste("a\nb")

      #expect(rig.model.blocks.map(\.text) == ["a", "b", "hello", "world"])
    }

    @Test func pastingAtTheStartOfALinePutsBlocksBeforeIt() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello"), DocContent(text: "world")])
      defer { rig.close() }

      rig.caretAtStart(of: rig.model.blocks[0].id)
      rig.controller.paste("a\nb")

      #expect(rig.model.blocks.map(\.text) == ["a", "b", "hello", "world"])
    }

    @Test func aPasteThatSplitsALineIsOneUndoStep() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello"), DocContent(text: "world")])
      defer { rig.close() }

      rig.select(2..<2, in: rig.model.blocks[0].id)
      rig.controller.paste("a\nb")
      #expect(rig.model.blocks.map(\.text) == ["he", "a", "b", "llo", "world"])

      rig.model.undo()

      #expect(rig.wait { rig.model.blocks.map(\.text) == ["hello", "world"] })
    }

    @Test func undoPutsTheCursorBackWhereTheEditStarted() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello world"), DocContent(text: "other")])
      defer { rig.close() }
      let first = rig.model.blocks[0].id
      rig.select(5..<5, in: first)
      let start = rig.textView.selectedRange().location

      rig.type(" big")
      rig.caretAtEnd(of: rig.model.blocks[1].id)
      rig.model.undo()

      #expect(rig.wait { rig.model.block(first)?.text == "hello world" })
      #expect(rig.wait { rig.textView.selectedRange() == NSRange(location: start, length: 0) })
    }

    @Test func embeddedBlocksNearTheTopShow() async throws {
      let rig = try await EditorRig.make([
        DocContent(text: "Above"), DocContent(kind: .divider),
        DocContent(kind: .table, text: DocTable(rows: [["a", "b"]]).json), DocContent(text: "Below"),
      ])
      defer { rig.close() }
      rig.textView.display()

      let embedded = rig.textView.subviews.filter { String(describing: type(of: $0)).contains("Hosting") }
      #expect(embedded.count == 2)
      #expect(embedded.allSatisfy { !$0.isHidden && $0.frame.height > 0 })
    }

    @Test func aLinkOnSelectedTextIsStoredAsMarkdown() async throws {
      let rig = try await EditorRig.make([DocContent(text: "see the site")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.select(8..<12, in: id)
      rig.model.setLinkOnSelection("example.com")

      #expect(rig.model.block(id)?.text == "see the [site](https://example.com)")
    }

    @Test func pastingFromTheMiddleOfTheTitleLeavesTheTitleWhole() async throws {
      let rig = try await EditorRig.make([DocContent(text: "hello")])
      defer { rig.close() }

      rig.textView.setSelectedRange(NSRange(location: 1, length: 0))
      rig.controller.paste("a\nb")

      #expect(rig.model.title == "Doc")
      #expect(rig.model.blocks.map(\.text) == ["a", "b", "hello"])
    }

    @Test func pastingAtTheStartOfALinkCardPutsBlocksBeforeIt() async throws {
      let rig = try await EditorRig.make([DocContent(kind: .link, text: "https://example.com"), DocContent(text: "w")])
      defer { rig.close() }

      rig.caretAtStart(of: rig.model.blocks[0].id)
      rig.controller.paste("a\nb")

      #expect(rig.model.blocks.map(\.text) == ["a", "b", "https://example.com", "w"])
    }

    @Test func thePlusOnAnEmptyLineOpensTheBlockMenu() async throws {
      let rig = try await EditorRig.make([DocContent(text: "a"), DocContent(text: "")])
      defer { rig.close() }
      let empty = rig.model.blocks[1].id

      rig.controller.startSlash(in: empty)

      #expect(rig.model.slashQuery?.blockID == empty)
      #expect(rig.model.slashQuery?.query == "")
      #expect(!rig.model.slashChoices.isEmpty)
    }

    @Test func pastingABareMarkerInsertsTheCharacter() async throws {
      let rig = try await EditorRig.make([DocContent(text: "a b")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id

      rig.select(1..<1, in: id)
      rig.controller.paste("-")

      #expect(rig.model.blocks.map(\.text) == ["a- b"])
    }

    @Test func pastingADividerMidLineStillMakesADivider() async throws {
      let rig = try await EditorRig.make([DocContent(text: "ab")])
      defer { rig.close() }

      rig.select(1..<1, in: rig.model.blocks[0].id)
      rig.controller.paste("---")

      #expect(rig.model.blocks.map(\.kind) == [.text, .divider, .text])
    }

    @Test func boldRightAfterTypingIsNotUndoneByTheDelayedSave() async throws {
      let rig = try await EditorRig.make([DocContent(text: "abc")])
      defer { rig.close() }
      let id = rig.model.blocks[0].id
      @Dependency(\.defaultDatabase) var database

      rig.caretAtEnd(of: id)
      rig.type("d")
      rig.select(0..<4, in: id)
      rig.model.toggleInline(.bold)
      try await Task.sleep(for: .milliseconds(1_200))

      let stored = try await database.read { try DocBlock.find(id).fetchOne($0)?.text }
      #expect(stored == "**abcd**")
      #expect(rig.model.block(id)?.text == "**abcd**")
    }

    @Test func movingTheFocusedBlockKeepsTheCursorInIt() async throws {
      let rig = try await EditorRig.make([DocContent(text: "one"), DocContent(text: "two")])
      defer { rig.close() }
      let two = rig.model.blocks[1].id

      rig.select(1..<1, in: two)
      rig.model.moveFocusedBlock(by: -1)

      #expect(rig.wait { rig.model.blocks.map(\.text) == ["two", "one"] })
      #expect(rig.wait { rig.controller.blockID(at: rig.textView.selectedRange().location) == two })
    }
  }
#endif
