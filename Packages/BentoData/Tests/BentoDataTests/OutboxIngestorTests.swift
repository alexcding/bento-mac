import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct OutboxIngestorTests {
  let directory: URL
  let collectorURL: URL
  let database: any DatabaseWriter

  init() throws {
    directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    collectorURL = directory.appending(path: "collector.sqlite")
    database = try BentoDatabase.open(at: directory.appending(path: "bento.sqlite"), iCloudContainer: nil)
  }

  /// Creates `collector.sqlite` from the Rust schema, so the contract cannot drift silently.
  func makeCollector() throws -> DatabaseQueue {
    try? FileManager.default.removeItem(at: collectorURL)
    let schema = try String(
      contentsOf: testdata.appending(path: "../crates/bento-store-sqlite/src/schema.sql").standardized,
      encoding: .utf8
    )
    let collector = try DatabaseQueue(path: collectorURL.path)
    try collector.write { try $0.execute(sql: schema) }
    return collector
  }

  func appendFixture(_ collector: DatabaseQueue, externalID: String? = nil) throws {
    var payload = try String(contentsOf: testdata.appending(path: "outbox-item.json"), encoding: .utf8)
    if let externalID {
      let id = StableID.feedItem(
        sourceID: UUID(uuidString: "6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10")!,
        externalID: externalID
      )
      payload = payload
        .replacingOccurrences(of: "45494751-1472-5c8f-9c00-76446f6c1b1f", with: id.uuidString.lowercased())
        .replacingOccurrences(of: "1834567890123456789\",", with: "\(externalID)\",")
    }
    let detail = try Data(base64Encoded: Vectors.load().details[0].encoded_base64)
    try collector.write {
      try $0.execute(
        sql: "INSERT INTO outbox (item_id, payload, detail) VALUES (?, ?, ?)",
        arguments: ["unused", payload, detail]
      )
    }
  }

  func counts() throws -> (items: Int, details: Int) {
    try database.read { db in
      (try FeedItem.count().fetchOne(db) ?? 0, try FeedItemDetail.count().fetchOne(db) ?? 0)
    }
  }

  @Test func missingCollectorIsANoOp() throws {
    let ingestor = OutboxIngestor(collectorURL: collectorURL, database: database)
    #expect(try ingestor.ingestPending() == 0)
  }

  @Test func savesItemsAndDetails() throws {
    try appendFixture(makeCollector())

    let saved = try OutboxIngestor(collectorURL: collectorURL, database: database).ingestPending()

    #expect(saved == 1)
    let item = try #require(try database.read { try FeedItem.all.fetchOne($0) })
    #expect(item.media.count == 2)
    #expect(item.translatedTitle == "翻译标题")
    let detail = try #require(try database.read { try FeedItemDetail.all.fetchOne($0) })
    #expect(try DetailCodec.decode(detail.markdown).hasPrefix("# 标题"))
  }

  @Test func readsOnlyNewRows() throws {
    let collector = try makeCollector()
    let ingestor = OutboxIngestor(collectorURL: collectorURL, database: database)
    try appendFixture(collector)
    try ingestor.ingestPending()

    #expect(try ingestor.ingestPending() == 0)
    try appendFixture(collector, externalID: "2")
    #expect(try ingestor.ingestPending() == 1)
    #expect(try counts().items == 2)
  }

  @Test func paginatesAcrossBatches() throws {
    let collector = try makeCollector()
    for n in 0..<5 { try appendFixture(collector, externalID: "n\(n)") }

    let saved = try OutboxIngestor(collectorURL: collectorURL, database: database).ingestPending(batchSize: 2)

    #expect(saved == 5)
    #expect(try counts().items == 5)
  }

  @Test func duplicateRowsAreIdempotent() throws {
    let collector = try makeCollector()
    try appendFixture(collector)
    try appendFixture(collector)

    try OutboxIngestor(collectorURL: collectorURL, database: database).ingestPending()

    #expect(try counts() == (1, 1))
  }

  @Test func recreatedCollectorIsReadFromStart() throws {
    let ingestor = OutboxIngestor(collectorURL: collectorURL, database: database)
    let first = try makeCollector()
    try appendFixture(first)
    try appendFixture(first, externalID: "2")
    try ingestor.ingestPending()

    // New instance: seq restarts at 1, below the old cursor of 2.
    try appendFixture(makeCollector(), externalID: "3")

    #expect(try ingestor.ingestPending() == 1)
    #expect(try counts().items == 3)
  }
}

/// Runs the real `bento-collector` binary, so Rust's actual output is what Swift ingests.
/// Build it first: `cargo build -p bento-collector` in `services/`.
@Suite struct CollectorIntegrationTests {
  static let binary = testdata.appending(path: "../target/debug/bento-collector").standardized

  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: binary.path)))
  func ingestsRealCollectorOutput() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let process = Process()
    process.executableURL = Self.binary
    process.arguments = ["--data-dir", directory.path, "emit-test-item", "--title", "集成测试"]
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)

    let database = try BentoDatabase.open(at: directory.appending(path: "bento.sqlite"), iCloudContainer: nil)
    let saved = try OutboxIngestor(collectorURL: directory.appending(path: "collector.sqlite"), database: database)
      .ingestPending()

    #expect(saved == 1)
    let item = try #require(try database.read { try FeedItem.all.fetchOne($0) })
    #expect(item.title == "集成测试")
    #expect(item.id == StableID.feedItem(sourceID: item.sourceID, externalID: item.externalID))
    #expect(item.isPublishedAtEstimated)
    let detail = try #require(try database.read { try FeedItemDetail.all.fetchOne($0) })
    #expect(try DetailCodec.decode(detail.markdown).hasPrefix("# Test item"))
  }
}
