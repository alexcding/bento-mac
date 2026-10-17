import Foundation
import Testing

@testable import BentoCollectorClient

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
