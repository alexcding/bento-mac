import Foundation
import SQLiteData

/// One collector run, for the history and performance view.
public struct CollectorRun: Hashable, Identifiable, Sendable {
  public let id: Int
  public let sourceID: UUID?
  public let startedAt: Date
  public let duration: Duration
  public let fetched: Int
  public let tooOld: Int
  public let newItems: Int
  public let error: String?
}

/// Run counts and timing for one source over the runs read.
public struct SourcePerformance: Hashable, Sendable {
  public let runs: Int
  public let failures: Int
  public let averageDuration: Duration
  public let slowestDuration: Duration
  public let newItems: Int
}

/// Contract: `services/crates/bento-store-sqlite/src/migrations/003_run_log.sql`.
@Table("run_log")
nonisolated struct RunLogRow {
  let id: Int
  @Column("source_id")
  var sourceID: String
  @Column("started_at")
  var startedAt: Int
  @Column("duration_ms")
  var durationMS: Int
  var fetched: Int
  @Column("too_old")
  var tooOld: Int
  @Column("new_items")
  var newItems: Int
  var error: String?
}

public enum CollectorDiagnostics {
  /// The newest runs, newest first.
  public static func recentRuns(collectorURL: URL, limit: Int = 500) throws -> [CollectorRun] {
    guard FileManager.default.fileExists(atPath: collectorURL.path) else { return [] }
    let rows = try DatabaseQueue(path: collectorURL.path).read { db in
      try RunLogRow.order { $0.id.desc() }.limit(limit).fetchAll(db)
    }
    return rows.map { row in
      CollectorRun(
        id: row.id,
        sourceID: UUID(uuidString: row.sourceID),
        startedAt: Date(timeIntervalSince1970: Double(row.startedAt) / 1000),
        duration: .milliseconds(row.durationMS),
        fetched: row.fetched,
        tooOld: row.tooOld,
        newItems: row.newItems,
        error: row.error
      )
    }
  }

  public static func performance(_ runs: [CollectorRun]) -> [UUID: SourcePerformance] {
    Dictionary(grouping: runs.filter { $0.sourceID != nil }, by: { $0.sourceID! }).mapValues { runs in
      let total = runs.reduce(Duration.zero) { $0 + $1.duration }
      return SourcePerformance(
        runs: runs.count,
        failures: runs.count { $0.error != nil },
        averageDuration: total / runs.count,
        slowestDuration: runs.map(\.duration).max() ?? .zero,
        newItems: runs.reduce(0) { $0 + $1.newItems }
      )
    }
  }

  /// The last `maxLines` lines of `collector.log`, reading at most the final `maxBytes`.
  public static func logTail(url: URL, maxLines: Int = 1_000, maxBytes: Int = 512 * 1024) throws -> [String] {
    guard FileManager.default.fileExists(atPath: url.path) else { return [] }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let size = try handle.seekToEnd()
    let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
    try handle.seek(toOffset: start)
    let text = String(decoding: try handle.readToEnd() ?? Data(), as: UTF8.self)
    var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    if start > 0, !lines.isEmpty { lines.removeFirst() }  // likely cut mid-line
    return Array(lines.suffix(maxLines))
  }
}

/// One row of the collector's `plugins` table.
public struct PluginCatalogEntry: Hashable, Sendable {
  public let id: String
  public let name: String
  public let version: String
  /// `plugin.json` as JSON (`{}` when the plugin failed to load).
  public let manifest: Data
  /// JSON array of `{name, installed, detail, install}`.
  public let requirements: Data
  public let error: String?
}

/// Contract: `services/crates/bento-store-sqlite/src/migrations/004_plugins.sql`.
@Table("plugins")
nonisolated struct PluginRow {
  @Column(primaryKey: true)
  let id: String
  var name: String
  var version: String
  var directory: String
  var manifest: String
  var requirements: String
  var error: String?
}

extension CollectorDiagnostics {
  /// Every plugin the collector loaded or failed to load, sorted by name as people read it.
  public static func plugins(collectorURL: URL) throws -> [PluginCatalogEntry] {
    guard FileManager.default.fileExists(atPath: collectorURL.path) else { return [] }
    let rows = try DatabaseQueue(path: collectorURL.path).read { db in
      try PluginRow.all.fetchAll(db)
    }
    return rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map {
      PluginCatalogEntry(
        id: $0.id, name: $0.name, version: $0.version, manifest: Data($0.manifest.utf8),
        requirements: Data($0.requirements.utf8), error: $0.error
      )
    }
  }
}
