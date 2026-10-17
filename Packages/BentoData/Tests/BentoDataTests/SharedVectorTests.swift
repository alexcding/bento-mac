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
      #expect(try DetailCodec.decode(blob) == c.markdown)
    }
  }

  @Test func roundTrips() throws {
    let text = "# 标题\n\nbody **bold**"
    #expect(try DetailCodec.decode(DetailCodec.encode(text)) == text)
  }

  @Test func rejectsBadBlobs() {
    #expect(throws: DetailCodec.Error.empty) { try DetailCodec.decode(Data()) }
    #expect(throws: DetailCodec.Error.unknownCodec(0x7f)) { try DetailCodec.decode(Data([0x7f, 1])) }
  }
}
