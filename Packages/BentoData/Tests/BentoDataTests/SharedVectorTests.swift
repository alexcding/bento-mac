import Foundation
import Testing

@testable import BentoData

/// `services/testdata`, shared with the Rust tests.
let testdata = URL(filePath: #filePath)
  .deletingLastPathComponent()
  .appending(path: "../../../../services/testdata")
  .standardized

struct Vectors: Decodable {
  struct StableIDCase: Decodable {
    let source_id: UUID
    let external_id: String
    let expected: UUID
  }
  struct DetailCase: Decodable {
    var format: String?
    let markdown: String
    let encoded_base64: String
  }
  let namespace: UUID
  let stable_ids: [StableIDCase]
  let details: [DetailCase]

  static func load() throws -> Vectors {
    try JSONDecoder().decode(Vectors.self, from: Data(contentsOf: testdata.appending(path: "vectors.json")))
  }
}

@Suite struct StableIDTests {
  @Test func namespaceMatchesRust() throws {
    #expect(try Vectors.load().namespace == StableID.feedItemNamespace)
  }

  @Test func idsMatchRust() throws {
    for c in try Vectors.load().stable_ids {
      #expect(StableID.feedItem(sourceID: c.source_id, externalID: c.external_id) == c.expected)
    }
  }
}

@Suite struct DetailCodecTests {
  @Test func decodesRustVectors() throws {
    for c in try Vectors.load().details {
      let blob = try #require(Data(base64Encoded: c.encoded_base64))
      let format: DetailContent.Format = c.format == "html" ? .html : .markdown
      #expect(try DetailCodec.decode(blob) == DetailContent(format: format, body: c.markdown))
    }
  }

  @Test func roundTrips() throws {
    let text = "# 标题\n\nbody **bold**"
    #expect(try DetailCodec.decode(DetailCodec.encode(text)).body == text)
    let html = DetailContent(format: .html, body: "<p>\(text)</p>")
    #expect(try DetailCodec.decode(DetailCodec.encode(html)) == html)

  }

  @Test func rejectsBadBlobs() {
    #expect(throws: DetailCodec.Error.empty) { try DetailCodec.decode(Data()) }
    #expect(throws: DetailCodec.Error.unknownCodec(0x7f)) { try DetailCodec.decode(Data([0x7f, 1])) }
    #expect(throws: DetailCodec.Error.unknownFormat(9)) { try DetailCodec.decode(Data([0x02, 9, 1])) }
  }
}
