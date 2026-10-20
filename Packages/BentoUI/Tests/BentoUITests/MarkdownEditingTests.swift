import Foundation
import Testing

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

@testable import BentoUI

@Suite struct MarkdownEditingTests {
  @Test func returnContinuesListsAndEndsThemWhenEmpty() {
    #expect(MarkdownEditing.onReturn(after: "- milk") == .continueWith("- "))
    #expect(MarkdownEditing.onReturn(after: "  9. nine") == .continueWith("  10. "))
    #expect(MarkdownEditing.onReturn(after: "- [x] done") == .continueWith("- [ ] "))
    #expect(MarkdownEditing.onReturn(after: "> quoted") == .continueWith("> "))
    #expect(MarkdownEditing.onReturn(after: "- ") == .endList)
    #expect(MarkdownEditing.onReturn(after: "plain") == nil)
    #expect(MarkdownEditing.onReturn(after: "2024. was a year") == .continueWith("2025. "))
  }

  @Test func tabNestsUnderTheItemAboveAndShiftTabComesBack() {
    #expect(MarkdownEditing.indented("- b", linesAbove: ["- a"]) == "  - b")
    #expect(MarkdownEditing.indented("- b", linesAbove: ["1. a"]) == "   - b")
    #expect(MarkdownEditing.indented("text", linesAbove: []) == "  text")
    #expect(MarkdownEditing.outdented("   - b", linesAbove: ["1. a"]) == "- b")
    #expect(MarkdownEditing.outdented("    - c", linesAbove: ["- a", "  - b"]) == "  - c")
  }

  @Test func slashAndDoubleBracketOpenMenus() {
    let slash = MarkdownEditing.trigger(in: "Hello /hea", cursor: 10)
    #expect(slash == .init(kind: .insert, query: "hea", range: NSRange(location: 6, length: 4)))
    #expect(MarkdownEditing.trigger(in: "a/b", cursor: 3) == nil)
    #expect(MarkdownEditing.trigger(in: "/two words", cursor: 10) == nil)
    let link = MarkdownEditing.trigger(in: "see [[phy", cursor: 9)
    #expect(link == .init(kind: .docLink, query: "phy", range: NSRange(location: 4, length: 5)))
    #expect(MarkdownEditing.trigger(in: "[[done]]", cursor: 8) == nil)
  }

  @Test func breakingAFenceRecoloursEverything() {
    let text = "x\n```\ncode\n```\ny"
    #expect(MarkdownHighlighter.touchesFence(text, NSRange(location: 2, length: 1)))
    #expect(!MarkdownHighlighter.touchesFence(text, NSRange(location: 0, length: 1)))
  }

  @Test func insertItemsMatchByNameAndKeyword() {
    #expect(MarkdownInsert.all.filter { $0.matches("todo") }.map(\.name) == ["Task List"])
    #expect(MarkdownInsert.all.filter { $0.matches("h2") }.map(\.name) == ["Heading 2"])
  }

  @Test func stylesRestyleTheLineAndToggleOff() {
    #expect(MarkdownEditing.restyled("Ideas", with: "# ") == "# Ideas")
    #expect(MarkdownEditing.restyled("## Ideas", with: "# ") == "# Ideas")
    #expect(MarkdownEditing.restyled("# Ideas", with: "# ") == "Ideas")
    #expect(MarkdownEditing.restyled("  - milk", with: "- [ ] ") == "  - [ ] milk")
    #expect(MarkdownEditing.restyled("  3. milk", with: "1. ") == "  milk")
    #expect(MarkdownEditing.restyled("> quote", with: "") == "quote")
  }

  @Test func colouringJustTheEditedLinesMatchesColouringEverything() {
    let start = "# Title\nplain **bold**\n```\nlet x = 1\n```\n- item"
    for (offset, insert) in [(9, "more "), (31, "y"), (0, "#")] {
      let storage = NSTextStorage(string: start)
      MarkdownHighlighter.apply(to: storage)
      storage.replaceCharacters(in: NSRange(location: offset, length: 0), with: insert)
      MarkdownHighlighter.apply(to: storage, editedRange: NSRange(location: offset, length: (insert as NSString).length))
      let fresh = NSTextStorage(string: storage.string)
      MarkdownHighlighter.apply(to: fresh)
      #expect(storage.isEqual(to: fresh), "insert \(insert) at \(offset)")
    }
  }
}
