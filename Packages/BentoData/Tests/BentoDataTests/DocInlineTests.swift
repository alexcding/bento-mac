import Foundation
import Testing

@testable import BentoData

@Suite struct DocInlineTests {
  func run(
    _ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, link: String? = nil
  ) -> DocInlineRun {
    DocInlineRun(text, bold: bold, italic: italic, strike: strike, code: code, link: link)
  }

  @Test func plainTextIsOneRun() {
    #expect(DocInline.parse("hello world") == [run("hello world")])
    #expect(DocInline.markdown([run("hello world")]) == "hello world")
  }

  @Test func emptyTextHasNoRuns() {
    #expect(DocInline.parse("").isEmpty)
    #expect(DocInline.markdown([]) == "")
    #expect(DocInline.markdown([run("")]) == "")
  }

  @Test func nestedBoldAndItalicShareRuns() {
    let runs = DocInline.parse("**bold _both_ bold**")

    #expect(runs == [run("bold ", bold: true), run("both", bold: true, italic: true), run(" bold", bold: true)])
  }

  @Test func italicInsideAWordUsesStars() {
    let runs = [run("un"), run("believ", italic: true), run("able")]

    #expect(DocInline.markdown(runs) == "un*believ*able")
    #expect(DocInline.parse("un*believ*able") == runs)
  }

  @Test func italicBetweenSpacesUsesUnderscores() {
    #expect(DocInline.markdown([run("a "), run("b", italic: true), run(" c")]) == "a _b_ c")
  }

  @Test func aLeadingUnderscoreIsEscaped() {
    let runs = [run("_private")]

    #expect(DocInline.markdown(runs) == "\\_private")
    #expect(DocInline.parse("\\_private") == runs)
    #expect(DocInline.parse("_private") == runs)
  }

  @Test func anUnderscoreInsideAWordIsLeftAlone() {
    let runs = [run("snake_case_name")]

    #expect(DocInline.markdown(runs) == "snake_case_name")
    #expect(DocInline.parse("snake_case_name") == runs)
  }

  @Test func aLinkCarriesItsBoldInside() {
    let runs = [run("a ", link: "https://x.com"), run("b", bold: true, link: "https://x.com"), run(" c", link: "https://x.com")]

    #expect(DocInline.parse("[a **b** c](https://x.com)") == runs)
    #expect(DocInline.markdown(runs) == "[a **b** c](https://x.com)")
  }

  @Test func aDocLinkIsALinkRun() {
    let id = UUID()
    let markdown = "see " + DocLink.markdown(title: "Physics", id: id) + " now"
    let runs = DocInline.parse(markdown)

    #expect(runs == [run("see "), run("Physics", link: DocLink.url(id).absoluteString), run(" now")])
    #expect(DocInline.markdown(runs) == markdown)
    #expect(DocLink.docIDs(in: markdown) == [id])
  }

  @Test func codeSpansKeepBackticksInside() {
    let runs = [run("a`b", code: true)]

    #expect(DocInline.markdown(runs) == "``a`b``")
    #expect(DocInline.parse("``a`b``") == runs)
  }

  @Test func codeSpansAtTheEdgeOfBackticksArePadded() {
    let runs = [run("`tick`", code: true)]

    #expect(DocInline.parse(DocInline.markdown(runs)) == runs)
  }

  @Test func codeIsNotParsedForStyles() {
    #expect(DocInline.parse("`**a**`") == [run("**a**", code: true)])
  }

  @Test func escapedStarsAreText() {
    #expect(DocInline.parse("a \\* b \\* c") == [run("a * b * c")])
    #expect(DocInline.markdown([run("a * b * c")]) == "a \\* b \\* c")
  }

  @Test func strikeIsTildes() {
    #expect(DocInline.parse("~~gone~~") == [run("gone", strike: true)])
    #expect(DocInline.markdown([run("gone", strike: true)]) == "~~gone~~")
  }

  @Test func plainTextDropsTheSyntax() {
    #expect(DocInline.plainText("The **powerhouse** of _DNA_ and `ATP` [here](https://x.com)") == "The powerhouse of DNA and ATP here")
  }

  @Test func adjacentRunsWithTheSameStyleMerge() {
    #expect(DocInline.markdown([run("a", bold: true), run("b", bold: true)]) == "**ab**")
  }

  @Test(arguments: [
    "plain",
    "**bold**",
    "*italic*",
    "_italic_",
    "un*believ*able",
    "**bold _both_ bold**",
    "**_both_**",
    "~~strike~~ and **bold**",
    "_private",
    "snake_case",
    "snake_case and _italic_",
    "[a **b** c](https://x.com)",
    "[Physics](bento-doc://5F0C8F0E-1111-2222-3333-444455556666)",
    "see [a](https://x.com) and [b](https://y.com/a%20b)",
    "``a`b``",
    "**bold** and `code`",
    "[`code` link](https://x.com)",
    "a \\* b \\* c",
    "\\*not italic\\*",
    "\\[not a link\\](x)",
    "tilde \\~~ text",
    "a ** b",
    "* alone",
    "2 \\* 3 \\* 4",
  ])
  func writingWhatWasReadParsesBackToTheSameRuns(markdown: String) {
    let runs = DocInline.parse(markdown)
    let written = DocInline.markdown(runs)

    #expect(DocInline.parse(written) == runs)
    #expect(DocInline.markdown(DocInline.parse(written)) == written)
  }
}
