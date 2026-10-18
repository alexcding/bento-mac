import Testing

@testable import BentoData

@Suite struct DocMarkdownTests {
  func parse(_ markdown: String) -> [DocContent] {
    DocMarkdown.blocks(from: markdown)
  }

  @Test func headingsMapToFourStyles() {
    #expect(parse("# a\n## b\n### c\n#### d") == [
      DocContent(kind: .title, text: "a"),
      DocContent(kind: .subtitle, text: "b"),
      DocContent(kind: .heading, text: "c"),
      DocContent(kind: .strong, text: "d"),
    ])
  }

  @Test func tableBecomesOneTableBlock() throws {
    let blocks = parse("| a | b |\n| --- | --- |\n| 1 | 2 |")
    #expect(blocks.count == 1)
    #expect(blocks[0].kind == .table)
    #expect(DocTable(json: blocks[0].text).rows == [["a", "b"], ["1", "2"]])
  }

  @Test func fenceLanguageIsKept() {
    #expect(parse("```swift\nlet a = 1\n```") == [DocContent(kind: .code, text: "let a = 1", language: "swift")])
  }

  @Test func quoteIsFocusedText() {
    #expect(parse("> note") == [DocContent(text: "note", decoration: .focus)])
  }

  @Test func smallTagIsCaption() {
    #expect(parse("<small>c</small>") == [DocContent(kind: .caption, text: "c")])
  }

  @Test func triangleIsToggle() {
    #expect(parse("▸ t") == [DocContent(kind: .toggle, text: "t")])
  }

  @Test func bulletsAcceptEveryMarkerAndNestByTwoSpaces() {
    #expect(parse("- a\n* b\n+ c\n  - d") == [
      DocContent(kind: .bullet, text: "a"),
      DocContent(kind: .bullet, text: "b"),
      DocContent(kind: .bullet, text: "c"),
      DocContent(kind: .bullet, text: "d", indent: 1),
    ])
  }

  @Test func numberedLineKeepsOnlyItsText() {
    #expect(parse("12. x") == [DocContent(kind: .numbered, text: "x")])
  }

  @Test func todosCarryCheckedState() {
    #expect(parse("- [ ] a\n- [x] b\n[] c") == [
      DocContent(kind: .todo, text: "a"),
      DocContent(kind: .todo, text: "b", isChecked: true),
      DocContent(kind: .todo, text: "c"),
    ])
  }

  @Test func quoteAndDivider() {
    #expect(parse("> q\n---") == [DocContent(text: "q", decoration: .focus), DocContent(kind: .divider)])
  }

  @Test func fencedCodeIsOneBlock() {
    #expect(parse("```\nlet a = 1\nlet b = 2\n```") == [DocContent(kind: .code, text: "let a = 1\nlet b = 2")])
  }

  @Test func unterminatedFenceStillYieldsCode() {
    #expect(parse("```\nlet a = 1\nlet b = 2") == [DocContent(kind: .code, text: "let a = 1\nlet b = 2")])
  }

  @Test func blankLinesAreSkipped() {
    #expect(parse("a\n\n\n  \nb") == [DocContent(text: "a"), DocContent(text: "b")])
  }

  @Test func bareURLBecomesLink() {
    #expect(parse("https://example.com/a") == [DocContent(kind: .link, text: "https://example.com/a")])
  }

  @Test func decimalNumberStaysText() {
    #expect(parse("1.5 is a number") == [DocContent(text: "1.5 is a number")])
  }

  @Test func shortcutsTurnTypedPrefixesIntoBlocks() {
    #expect(DocMarkdown.shortcut("# ") == DocContent(kind: .title))
    #expect(DocMarkdown.shortcut("> ") == DocContent(decoration: .focus))
    #expect(DocMarkdown.shortcut("- ") == DocContent(kind: .bullet))
    #expect(DocMarkdown.shortcut("[] ") == DocContent(kind: .todo))
    #expect(DocMarkdown.shortcut("```") == DocContent(kind: .code))
    #expect(DocMarkdown.shortcut("---") == DocContent(kind: .divider))
    #expect(DocMarkdown.shortcut("hello") == nil)
    #expect(DocMarkdown.shortcut("https://a.com") == nil)
  }

  @Test func markdownRoundTripsWithoutTitle() {
    let blocks = [
      DocContent(kind: .title, text: "T"),
      DocContent(text: "para"),
      DocContent(kind: .bullet, text: "a"),
      DocContent(kind: .bullet, text: "b", indent: 1),
      DocContent(kind: .todo, text: "done", isChecked: true),
      DocContent(kind: .todo, text: "open"),
      DocContent(kind: .numbered, text: "one"),
      DocContent(kind: .numbered, text: "two"),
      DocContent(text: "q", decoration: .focus),
      DocContent(kind: .code, text: "x\ny"),
      DocContent(kind: .divider),
      DocContent(kind: .link, text: "https://example.com"),
    ]
    #expect(DocMarkdown.blocks(from: DocMarkdown.markdown(title: "", blocks: blocks)) == blocks)
  }

  @Test func markdownRoundTripsEveryStyle() {
    let blocks = [
      DocContent(kind: .title, text: "t"),
      DocContent(kind: .subtitle, text: "s"),
      DocContent(kind: .heading, text: "h"),
      DocContent(kind: .strong, text: "st"),
      DocContent(kind: .caption, text: "c"),
      DocContent(kind: .toggle, text: "tg"),
      DocContent(text: "focus", decoration: .focus),
      DocContent(kind: .table, text: DocTable(rows: [["a", "b"], ["1", "2"]]).json),
      DocContent(kind: .code, text: "print(1)", language: "py"),
    ]
    #expect(DocMarkdown.blocks(from: DocMarkdown.markdown(title: "", blocks: blocks)) == blocks)
  }

  @Test func numberingRestartsAfterANonNumberedBlock() {
    let markdown = DocMarkdown.markdown(title: "", blocks: [
      DocContent(kind: .numbered, text: "a"),
      DocContent(kind: .numbered, text: "b"),
      DocContent(text: "x"),
      DocContent(kind: .numbered, text: "c"),
    ])
    #expect(markdown.contains("1. a\n2. b"))
    #expect(markdown.contains("1. c"))
    #expect(!markdown.contains("3. c"))
  }
}
