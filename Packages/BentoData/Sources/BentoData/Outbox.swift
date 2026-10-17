import Foundation
import SQLiteData

/// Moves processed items from `collector.sqlite` (written by `bento-collector`) into the synced
/// database. Only the app writes the synced database, so sync triggers see every change.
///
/// Contract with `services/crates/bento-store-sqlite/src/schema.sql`: table `outbox(seq,
/// payload, detail)` and `meta('instance_id')`. Payload JSON is `bento_domain::FeedItem`.
public struct OutboxIngestor: Sendable {
  let collectorURL: URL
  let database: any DatabaseWriter

  public init(collectorURL: URL, database: any DatabaseWriter) {
    self.collectorURL = collectorURL
    self.database = database
  }

  /// Saves every outbox row past the stored cursor. Safe to call repeatedly: item IDs are
  /// deterministic, so a row saved twice changes nothing.
  /// - Returns: The number of rows saved.
  @discardableResult
  public func ingestPending(batchSize: Int = 200) throws -> Int {
    guard FileManager.default.fileExists(atPath: collectorURL.path) else { return 0 }
    let collector = try DatabaseQueue(path: collectorURL.path)
    let instanceID = try collector.read { db in
      try CollectorMeta.where { $0.key.eq("instance_id") }.select(\.value).fetchOne(db)
    }
    guard let instanceID else { return 0 }

    var total = 0
    while true {
      let cursor = try database.read { db in
        try OutboxCursor.find(instanceID).fetchOne(db)?.seq ?? 0
      }
      let rows = try collector.read { db in
        try OutboxRow.where { $0.seq > cursor }.order(by: \.seq).limit(batchSize).fetchAll(db)
      }
      guard let last = rows.last else { break }
      let entries = try rows.map { row in
        (item: try OutboxPayload.decode(Data(row.payload.utf8)).feedItem, detail: row.detail)
      }
      try database.write { db in
        for entry in entries {
          try FeedItem.upsert { FeedItem.Draft(entry.item) }.execute(db)
          if let detail = entry.detail {
            try FeedItemDetail.upsert {
              FeedItemDetail.Draft(feedItemID: entry.item.id, markdown: detail)
            }
            .execute(db)
          }
        }
        // Concurrent runs must never move the cursor backwards.
        let stored = try OutboxCursor.find(instanceID).fetchOne(db)?.seq ?? 0
        if last.seq > stored {
          try OutboxCursor.upsert { OutboxCursor(instanceID: instanceID, seq: last.seq) }
            .execute(db)
        }
      }
      total += rows.count
      if rows.count < batchSize { break }
    }
    return total
  }
}

@Table("meta")
nonisolated struct CollectorMeta {
  @Column(primaryKey: true)
  let key: String
  var value: String
}

@Table("outbox")
nonisolated struct OutboxRow {
  @Column(primaryKey: true)
  let seq: Int
  var payload: String
  var detail: Data?
}

/// `bento_domain::FeedItem` as JSON: snake_case keys, dates in Unix milliseconds.
struct OutboxPayload: Decodable {
  let feedItem: FeedItem

  static func decode(_ data: Data) throws -> OutboxPayload {
    try JSONDecoder().decode(OutboxPayload.self, from: data)
  }

  private enum CodingKeys: String, CodingKey {
    case id, url, title, text, summary, media, language
    case sourceID = "source_id"
    case externalID = "external_id"
    case translatedTitle = "translated_title"
    case authorName = "author_name"
    case authorHandle = "author_handle"
    case authorAvatarURL = "author_avatar_url"
    case referenceItemID = "reference_item_id"
    case publishedAt = "published_at"
    case isPublishedAtEstimated = "is_published_at_estimated"
    case fetchedAt = "fetched_at"
  }

  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func date(_ key: CodingKeys) throws -> Date {
      Date(timeIntervalSince1970: Double(try c.decode(Int64.self, forKey: key)) / 1000)
    }
    feedItem = FeedItem(
      id: try c.decode(UUID.self, forKey: .id),
      sourceID: try c.decode(UUID.self, forKey: .sourceID),
      externalID: try c.decode(String.self, forKey: .externalID),
      url: try c.decodeIfPresent(String.self, forKey: .url),
      title: try c.decodeIfPresent(String.self, forKey: .title),
      text: try c.decode(String.self, forKey: .text),
      translatedTitle: try c.decodeIfPresent(String.self, forKey: .translatedTitle),
      summary: try c.decodeIfPresent(String.self, forKey: .summary),
      authorName: try c.decodeIfPresent(String.self, forKey: .authorName),
      authorHandle: try c.decodeIfPresent(String.self, forKey: .authorHandle),
      authorAvatarURL: try c.decodeIfPresent(String.self, forKey: .authorAvatarURL),
      media: try c.decode([Media].self, forKey: .media),
      referenceItemID: try c.decodeIfPresent(UUID.self, forKey: .referenceItemID),
      publishedAt: try date(.publishedAt),
      isPublishedAtEstimated: try c.decode(Bool.self, forKey: .isPublishedAtEstimated),
      language: try c.decodeIfPresent(String.self, forKey: .language),
      fetchedAt: try date(.fetchedAt)
    )
  }
}
