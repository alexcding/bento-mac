import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct DocLinkTests {
  @Test func markdownIDAndURLRoundTrip() {
    let id = UUID()

    let markdown = DocLink.markdown(title: "Physics", id: id)

    #expect(markdown == "[Physics](bento-doc://\(id.uuidString))")
    #expect(DocLink.docID(DocLink.url(id)) == id)
    #expect(DocLink.docID(URL(string: "https://example.com")!) == nil)
  }

  @Test func aTitleWithABracketSurvivesTheRoundTrip() {
    let id = UUID()

    let markdown = DocLink.markdown(title: "a]b", id: id)

    #expect(markdown == "[a\\]b](bento-doc://\(id.uuidString))")
    #expect(DocLink.retitle(markdown, titles: [:]) { DocLink.markdown(title: $0, id: $1) } == markdown)
  }

  @Test func retitleReplacesKnownTitlesAndLeavesOtherLinksAlone() {
    let (first, second) = (UUID(), UUID())
    let text = "x \(DocLink.markdown(title: "Old", id: first)) y \(DocLink.markdown(title: "Keep", id: second))"

    let result = DocLink.retitle(text, titles: [first: "New"]) { DocLink.markdown(title: $0, id: $1) }

    #expect(result == "x \(DocLink.markdown(title: "New", id: first)) y \(DocLink.markdown(title: "Keep", id: second))")
  }
}
