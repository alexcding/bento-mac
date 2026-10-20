import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct LinkMetadataTests {
  let page = URL(string: "https://www.example.com/post/1")!

  func parse(_ head: String, body: String = "") -> LinkMetadata {
    LinkMetadata.parse(html: "<html><head>\(head)</head><body>\(body)</body></html>", url: page)
  }

  @Test func openGraphTagsWinOverTitleAndDescription() {
    let metadata = parse(
      """
      <title>Page title</title>
      <meta name="description" content="Plain description">
      <meta property="og:title" content="OG title">
      <meta property="og:description" content="OG description">
      """
    )

    #expect(metadata.title == "OG title")
    #expect(metadata.summary == "OG description")
  }

  @Test func twitterTagsAreUsedWhenOpenGraphIsMissing() {
    let metadata = parse(
      """
      <title>Page title</title>
      <meta name="twitter:title" content="Tweet title">
      <meta name="twitter:description" content="Tweet description">
      <meta name="twitter:image" content="https://cdn.example.com/t.png">
      """
    )

    #expect(metadata.title == "Tweet title")
    #expect(metadata.summary == "Tweet description")
    #expect(metadata.imageURL == URL(string: "https://cdn.example.com/t.png"))
  }

  @Test func titleAndDescriptionAreTheFallback() {
    let metadata = parse(#"<title> Just   a title </title><meta name="description" content="About it">"#)

    #expect(metadata.title == "Just a title")
    #expect(metadata.summary == "About it")
  }

  @Test func attributesMayUseEitherQuoteAndEitherOrder() {
    let metadata = parse(
      """
      <meta content='Single quoted' property='og:title'>
      <meta content="Content first" property="og:description" />
      """
    )

    #expect(metadata.title == "Single quoted")
    #expect(metadata.summary == "Content first")
  }

  @Test func htmlEntitiesAreDecoded() {
    let metadata = parse(
      #"<meta property="og:title" content="Tom &amp; Jerry &quot;live&quot; it&#39;s &#x2019;""#
        + #"><meta property="og:description" content="&amp;lt; stays">"#
    )

    #expect(metadata.title == "Tom & Jerry \"live\" it's \u{2019}")
    #expect(metadata.summary == "&lt; stays")
  }

  @Test func aRelativeImageIsResolvedAgainstThePage() {
    let metadata = parse(#"<meta property="og:image" content="/img/a.png">"#)

    #expect(metadata.imageURL == URL(string: "https://www.example.com/img/a.png"))
  }

  @Test func siteNameFallsBackToTheHostWithoutWww() {
    #expect(parse("").siteName == "example.com")
    #expect(parse(#"<meta property="og:site_name" content="Example Site">"#).siteName == "Example Site")
  }

  @Test func aLongFirstParagraphStandsInForTheDescription() {
    let short = "Too short to describe anything."
    let long =
      "This paragraph is long enough to describe the page well[1], so it is used[23] as the summary of the preview card."
    let metadata = parse("", body: "<p>\(short)</p><p>\(long)</p>")

    #expect(metadata.summary == "This paragraph is long enough to describe the page well, so it is used as the summary of the preview card.")
  }

  @Test func shortParagraphsAreSkipped() {
    #expect(parse("", body: "<p>Short one.</p><p>Another short one.</p>").summary == "")
    #expect(LinkMetadata.firstParagraph("<p>tiny</p>") == nil)
  }

  @Test func anOEmbedLinkIsFound() {
    let metadata = parse(
      #"<link rel="alternate" type="application/json+oembed" href="/oembed?u=1&amp;format=json" title="x">"#
    )

    #expect(metadata.oEmbedURL == URL(string: "https://www.example.com/oembed?u=1&format=json"))
    #expect(parse("").oEmbedURL == nil)
  }

  @Test func oEmbedFillsInTitleSiteImageAndAuthorSummary() {
    var metadata = LinkMetadata()
    let json = #"{"title":"T","author_name":"A","provider_name":"YouTube","thumbnail_url":"https://i/x.jpg"}"#

    metadata.merge(oEmbed: Data(json.utf8))

    #expect(metadata.title == "T")
    #expect(metadata.siteName == "YouTube")
    #expect(metadata.imageURL == URL(string: "https://i/x.jpg"))
    #expect(metadata.summary == "By A")
  }

  @Test func oEmbedKeepsAnExistingSummary() {
    var metadata = LinkMetadata(summary: "Already here")

    metadata.merge(oEmbed: Data(#"{"title":"T","author_name":"A"}"#.utf8))

    #expect(metadata.summary == "Already here")
  }

  @Test func oEmbedWithoutATitleUsesTheAuthorAndPostText() {
    var metadata = LinkMetadata()
    let json = #"{"author_name":"jack","html":"<blockquote><p>just setting up</p></blockquote>","provider_name":"X"}"#

    metadata.merge(oEmbed: Data(json.utf8))

    #expect(metadata.title == "jack")
    #expect(metadata.summary == "just setting up")
    #expect(metadata.siteName == "X")
  }
}
