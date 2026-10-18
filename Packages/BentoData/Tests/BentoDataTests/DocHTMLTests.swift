import Testing

@testable import BentoData

@Suite struct DocHTMLTests {
  @Test func articleHTMLBecomesBlocks() {
    let blocks = DocHTML.blocks(
      from: """
        <html><head><style>p{}</style></head><body><h2>Title &amp; more</h2>
        <p>Some <b>bold</b>, <em>italic</em> and <a href="https://a.com/x">a link</a>.</p>
        <ul><li>One</li><li>Two</li></ul><blockquote>Quoted</blockquote>
        <pre><code>let x = 1</code></pre><script>alert(1)</script></body></html>
        """
    )
    #expect(blocks.map(\.kind) == [.subtitle, .text, .bullet, .bullet, .text, .code])
    #expect(blocks[0].text == "Title & more")
    #expect(blocks[1].text == "Some **bold**, _italic_ and [a link](https://a.com/x).")
    #expect(blocks[4].decoration == .focus)
    #expect(blocks[5].text == "let x = 1")
    #expect(!blocks.contains { $0.text.contains("alert") })
  }
}
