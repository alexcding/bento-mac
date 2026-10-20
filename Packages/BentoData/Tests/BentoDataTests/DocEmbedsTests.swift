import Foundation
import Testing

@testable import BentoData

@Suite struct DocEmbedsTests {
  @Test func togglesBecomeDirectivesWithTheirSummaryFirst() {
    let markdown = """
      <details><summary>What is entropy?</summary>

      Disorder, **measured**.
      </details>
      after
      """
    #expect(
      DocEmbeds.prepare(markdown) == """
        @Toggle {
        What is entropy?


        Disorder, **measured**.

        }
        after
        """
    )
    // Unclosed, it runs to the end.
    #expect(DocEmbeds.prepare("<details>\ninside").hasSuffix("inside\n}"))
  }

  @Test func postAndVideoLinksOnTheirOwnLineBecomeEmbeds() {
    let markdown = """
      https://x.com/jack/status/20
      <https://www.youtube.com/watch?v=abc>
      ![](https://a.com/clip.MP4)
      See https://x.com/jack/status/20 inline.
      https://x.com/jack
      https://youtube.com/
      ![](https://a.com/photo.jpg)
      """
    #expect(
      DocEmbeds.prepare(markdown).components(separatedBy: "\n") == [
        #"@Post(url: "https://x.com/jack/status/20")"#,
        #"@Post(url: "https://www.youtube.com/watch?v=abc")"#,
        #"@Video(url: "https://a.com/clip.MP4")"#,
        "See https://x.com/jack/status/20 inline.",
        #"@Link(url: "https://x.com/jack", style: "regular", title: "")"#,
        #"@Link(url: "https://youtube.com/", style: "regular", title: "")"#,
        "![](https://a.com/photo.jpg)",
      ]
    )
  }

  @Test func codeBlocksAreLeftAlone() {
    let markdown = "```\n<details>\nhttps://x.com/a/status/1\n```"
    #expect(DocEmbeds.prepare(markdown) == markdown)
  }

  @Test func textThatLooksLikeDirectiveSyntaxStaysText() {
    #expect(DocEmbeds.prepare("@alex said hi") == "\\@alex said hi")
    let toggled = DocEmbeds.prepare("<details><summary>Q</summary>\n} not\n</details>")
    #expect(toggled.contains("\\} not"))
  }

  @Test func githubTogglesWithTheirSummaryBelowOrTheEndInline() {
    let markdown = "<details>\n<summary>Click</summary>\n\nAnswer</details>\nafter"
    #expect(DocEmbeds.prepare(markdown) == "@Toggle {\nClick\n\n\nAnswer\n\n}\nafter")
  }

  @Test func linkLinesCarryTheirStyleInTheirTitle() {
    #expect(DocEmbeds.prepare("[Apple](https://apple.com \"card\")") == #"@Link(url: "https://apple.com", style: "card", title: "Apple")"#)
    #expect(DocEmbeds.prepare("[Apple](https://apple.com)") == #"@Link(url: "https://apple.com", style: "regular", title: "Apple")"#)
    #expect(DocEmbeds.prepare("[Apple](https://apple.com \"text\")") == #"@Link(url: "https://apple.com", style: "text", title: "Apple")"#)
    let body = "intro\n  https://apple.com\n[Apple](https://apple.com \"card\")\nsee https://apple.com"
    #expect(
      DocEmbeds.restyleLinks(body, url: "https://apple.com", style: .card)
        == "intro\n  [](https://apple.com \"card\")\n[Apple](https://apple.com \"card\")\nsee https://apple.com"
    )
    #expect(DocEmbeds.restyleLinks("[Apple](https://apple.com \"card\")", url: "https://apple.com", style: .regular) == "[Apple](https://apple.com)")
  }

  @Test func aPlainLinkWithoutTextShowsItsAddress() {
    #expect(DocEmbeds.restyleLinks("https://apple.com", url: "https://apple.com", style: .text) == "[https://apple.com](https://apple.com \"text\")")
    #expect(DocEmbeds.prepare("[](https://apple.com \"text\")") == #"@Link(url: "https://apple.com", style: "text", title: "")"#)
  }

  @Test func restylingLeavesCodeBlocksAlone() {
    let body = "https://a.com\n```\nhttps://a.com\n```"
    #expect(DocEmbeds.restyleLinks(body, url: "https://a.com", style: .card) == "[](https://a.com \"card\")\n```\nhttps://a.com\n```")
  }

  @Test func longDocsSplitAtHeadingsOutsideCodeAndToggles() {
    let part = String(repeating: "word ", count: 50)
    let markdown = ["# One", part, "```", "# not a heading", "```", "# Two", part, "<details><summary>S</summary>", "# inside", "</details>", "# Three", part].joined(separator: "\n")
    let sections = DocEmbeds.sections(markdown, minLength: 100)
    #expect(sections.map { $0.components(separatedBy: "\n").first } == ["# One", "# Two", "# Three"])
    #expect(sections.joined(separator: "\n") == markdown)
    // Short docs stay whole, and so do docs with reference links.
    #expect(DocEmbeds.sections(markdown).count == 1)
    #expect(DocEmbeds.sections(markdown + "\n[1]: https://a.com", minLength: 100).count == 1)
  }
}
