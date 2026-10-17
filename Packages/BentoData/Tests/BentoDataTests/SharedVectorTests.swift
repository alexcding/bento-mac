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

@Suite struct OutboxPayloadTests {
  @Test func decodesRustFixture() throws {
    let data = try Data(contentsOf: testdata.appending(path: "outbox-item.json"))
    let item = try OutboxPayload.decode(data).feedItem
    #expect(item.id == UUID(uuidString: "45494751-1472-5c8f-9c00-76446f6c1b1f"))
    #expect(item.publishedAt == Date(timeIntervalSince1970: 1_792_141_200))
    #expect(item.translatedTitle == "翻译标题")
    #expect(item.media[1].kind == .video)
    #expect(item.media[1].embedURL == "https://www.youtube.com/embed/x")
    #expect(item.referenceItemID == UUID(uuidString: "6c33f2ab-add7-5b3d-885f-1cfc1056988c"))
    #expect(item.title == nil)
  }
}
