import BentoData
import Foundation
import SQLiteData

/// Contract: `services/crates/bento-store-sqlite/src/migrations/002_scheduling.sql`.
@Table("source_state")
nonisolated struct SourceStateRow {
  @Column("source_id", primaryKey: true)
  let sourceID: String
  @Column("last_run_at")
  var lastRunAt: Int?
  @Column("next_run_at")
  var nextRunAt: Int
  @Column("consecutive_failures")
  var consecutiveFailures: Int
  @Column("last_error")
  var lastError: String?
  @Column("last_new_items")
  var lastNewItems: Int
}

public enum CollectorStatusReader {
  /// Status per source ID. Empty when the collector has not created its database yet.
  public static func read(collectorURL: URL) throws -> [UUID: SourceStatus] {
    guard FileManager.default.fileExists(atPath: collectorURL.path) else { return [:] }
    let rows = try DatabaseQueue(path: collectorURL.path).read { db in
      try SourceStateRow.all.fetchAll(db)
    }
    func date(_ millis: Int) -> Date { Date(timeIntervalSince1970: Double(millis) / 1000) }
    return Dictionary(
      rows.compactMap { row in
        UUID(uuidString: row.sourceID).map { id in
          (
            id,
            SourceStatus(
              lastRunAt: row.lastRunAt.map(date),
              nextRunAt: date(row.nextRunAt),
              consecutiveFailures: row.consecutiveFailures,
              lastError: row.lastError,
              lastNewItems: row.lastNewItems
            )
          )
        }
      },
      uniquingKeysWith: { first, _ in first }
    )
  }
}
