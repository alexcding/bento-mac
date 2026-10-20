import Foundation
import SQLiteData
import Testing

@testable import BentoData

/// Cases found by review, kept so they stay fixed.
@Suite struct ReviewRegressionTests {
  @Test func codeInSavedHTMLKeepsItsText() {
    let markdown = DocHTML.markdown(from: "<p>Hi</p><pre>let a: Array&lt;Int&gt; = []\nx &amp;lt; y\n&lt;div&gt;hi&lt;/div&gt;</pre>")
    #expect(markdown.hasSuffix("```\nlet a: Array<Int> = []\nx &lt; y\n<div>hi</div>\n```"))
  }

  @Test func unclosedHTMLTagsStayFast() {
    let html = "<p>" + String(repeating: "<b>word ", count: 3_000) + "</p>"
    let elapsed = ContinuousClock().measure { _ = DocHTML.markdown(from: html) }
    #expect(elapsed < .seconds(1))
  }

  @Test func docLinksKeepTitlesWithSyntaxCharacters() {
    let id = UUID()
    for title in ["Notes [draft]", "C:\\", "a*b*c", "snake_case"] {
      let link = DocLink.markdown(title: title, id: id)
      #expect(DocLink.unescaped(DocLink.escaped(title)) == title, "\(title)")
      #expect(DocLink.retitle(link, titles: [:]) { stored, _ in stored } == title, "\(title)")
    }
  }
}

@Suite struct ArticleImageTests {
  @Test func relativeImagesAreReadAgainstTheirPage() {
    let base = URL(string: "https://a.com/post/1")
    #expect(DocMarkdown.absoluteImages("![x](img/a.png) ![](https://b.com/c.jpg) [l](rel)", baseURL: base)
      == "![x](https://a.com/post/img/a.png) ![](https://b.com/c.jpg) [l](rel)")
  }

  @Test func webImagesAreListedOnceAndVideosLeftOut() {
    let markdown = "![](https://a.com/1.png)\n![b](https://a.com/2.jpg)\n![](https://a.com/1.png)\n![](https://a.com/v.mp4)\n![](bento-asset://x)"
    #expect(DocMarkdown.webImageURLs(markdown) == ["https://a.com/1.png", "https://a.com/2.jpg"])
  }

  @Test func aLinkedImageKeepsItsLineAndTheLinkItsText() {
    let markdown = DocHTML.markdown(from: #"<p><a href="https://a.com/big.png"><img src="https://a.com/small.png"> Full size</a></p>"#)
    #expect(markdown == "![](https://a.com/small.png)\n[Full size](https://a.com/big.png)")
  }

  @Test func aFetchedImageLandsOnlyInADocStillShowingIt() throws {
    let database = try DatabaseQueue()
    try BentoDatabase.migrator.migrate(database)
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", body: "a ![](https://a.com/1.png) b ![](https://a.com/1.png)")
      #expect(try Mutations.attachWebImage(db, docID: doc, address: "https://a.com/1.png", name: "1.jxl", contentType: "public.jpeg-xl", data: Data([1])))
      let asset = try #require(try DocAsset.all.fetchOne(db))
      #expect(try Doc.find(doc).fetchOne(db)?.body == "a ![](bento-asset://\(asset.id.uuidString)) b ![](bento-asset://\(asset.id.uuidString))")
      // Only that exact image: a longer address and a plain link are left alone.
      try Mutations.setDocBody(db, id: doc, body: "![](https://a.com/2.png?s=l) [l](https://a.com/2.png) ![x](https://a.com/2.png \"t\")")
      #expect(try Mutations.attachWebImage(db, docID: doc, address: "https://a.com/2.png", name: "2.jxl", contentType: "public.jpeg-xl", data: Data([2])))
      let second = try #require(try DocAsset.where { $0.name.eq("2.jxl") }.fetchOne(db))
      #expect(try Doc.find(doc).fetchOne(db)?.body == "![](https://a.com/2.png?s=l) [l](https://a.com/2.png) ![x](bento-asset://\(second.id.uuidString) \"t\")")
      // Edited away meanwhile: the download is dropped.
      try Mutations.setDocBody(db, id: doc, body: "typed")
      #expect(try !Mutations.attachWebImage(db, docID: doc, address: "https://a.com/1.png", name: "1.jxl", contentType: "public.jpeg-xl", data: Data([1])))
      #expect(try DocAsset.count().fetchOne(db) == 2)
    }
  }
}
