import Foundation
import Testing

@testable import BentoData

@Suite struct DocHTMLTests {
  @Test func articleHTMLBecomesMarkdown() {
    let markdown = DocHTML.markdown(
      from: """
        <html><head><style>p{}</style></head><body><h2>Title &amp; more</h2>
        <p>Some <b>bold</b>, <em>italic</em> and <a href="https://a.com/x">a link</a>.</p>
        <ul><li>One</li><li>Two</li></ul><blockquote>Quoted</blockquote>
        <img src="/pic.png"><pre><code>let x = 1</code></pre><script>alert(1)</script></body></html>
        """,
      baseURL: URL(string: "https://a.com/post/1")
    )
    #expect(
      markdown == """
        ## Title & more

        Some **bold**, _italic_ and [a link](https://a.com/x).

        - One

        - Two

        > Quoted

        ![](https://a.com/pic.png)

        ```
        let x = 1
        ```
        """
    )
  }

  @Test func codeKeepsItsIndentationAndBlankLines() {
    let markdown = DocHTML.markdown(from: "<pre>def f():\n    return 1\n\n\n\nx = 2</pre>")
    #expect(markdown == "```\ndef f():\n    return 1\n\n\n\nx = 2\n```")
  }

  @Test func emphasisKeepsItsSpacesOutsideTheMarkers() {
    #expect(DocHTML.markdown(from: "<p><strong>Note: </strong>text and <em> this</em>.<b></b></p>") == "**Note:** text and _this_.")
  }
}
