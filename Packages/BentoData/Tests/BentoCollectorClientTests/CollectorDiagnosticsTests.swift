import Foundation
import SQLiteData
import Testing

@testable import BentoCollectorClient

@Suite struct CollectorDiagnosticsTests {
  let source = UUID(uuidString: "6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10")!

  func collector(runs: [(startedAt: Int, ms: Int, new: Int, error: String?)]) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    try DatabaseQueue(path: url.path).write { db in
      for migration in try collectorMigrations() { try db.execute(sql: migration) }
      for run in runs {
        try db.execute(
          sql: """
            INSERT INTO run_log (source_id, started_at, duration_ms, fetched, too_old, new_items, error)
            VALUES (?, ?, ?, 20, 0, ?, ?)
            """,
          arguments: [source.uuidString.lowercased(), run.startedAt, run.ms, run.new, run.error]
        )
      }
    }
    return url
  }

  @Test func readsRunsNewestFirst() throws {
    let url = try collector(runs: [(1_000, 100, 2, nil), (2_000, 300, 0, "timeout")])

    let runs = try CollectorDiagnostics.recentRuns(collectorURL: url)

    #expect(runs.map(\.startedAt) == [Date(timeIntervalSince1970: 2), Date(timeIntervalSince1970: 1)])
    #expect(runs[0].error == "timeout")
    #expect(runs[0].duration == .milliseconds(300))
    #expect(runs[0].sourceID == source)
  }

  @Test func summarizesPerformancePerSource() throws {
    let url = try collector(runs: [(1, 100, 2, nil), (2, 300, 1, nil), (3, 200, 0, "x")])

    let performance = try #require(
      CollectorDiagnostics.performance(try CollectorDiagnostics.recentRuns(collectorURL: url))[source]
    )

    #expect(performance.runs == 3)
    #expect(performance.failures == 1)
    #expect(performance.averageDuration == .milliseconds(200))
    #expect(performance.slowestDuration == .milliseconds(300))
    #expect(performance.newItems == 3)
  }

  @Test func tailsLogAndDropsPartialFirstLine() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).log")
    try (1...100).map { "line \($0)" }.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)

    #expect(try CollectorDiagnostics.logTail(url: url, maxLines: 3) == ["line 98", "line 99", "line 100"])
    let tail = try CollectorDiagnostics.logTail(url: url, maxBytes: 20)
    #expect(tail.last == "line 100")
    #expect(tail.allSatisfy { $0.hasPrefix("line ") })
  }

  @Test func missingFilesAreEmpty() throws {
    let missing = FileManager.default.temporaryDirectory.appending(path: "missing-\(UUID())")
    #expect(try CollectorDiagnostics.recentRuns(collectorURL: missing).isEmpty)
    #expect(try CollectorDiagnostics.logTail(url: missing).isEmpty)
  }
}

@Suite struct PluginCatalogTests {
  @Test func readsTheCatalogByName() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    try DatabaseQueue(path: url.path).write { db in
      for migration in try collectorMigrations() { try db.execute(sql: migration) }
      try db.execute(
        sql: """
          INSERT INTO plugins VALUES
            ('x', 'X (Twitter)', '0.1.0', '/p/x', '{"id":"x"}', '[{"name":"twitter-cli","installed":false}]', NULL, 1),
            ('error:/p/bad', 'bad', '', '/p/bad', '{}', '[]', 'protocol 9 is not supported', 1)
          """
      )
    }

    let plugins = try CollectorDiagnostics.plugins(collectorURL: url)

    #expect(plugins.map(\.id) == ["error:/p/bad", "x"])
    #expect(plugins[0].error == "protocol 9 is not supported")
    #expect(String(decoding: plugins[1].requirements, as: UTF8.self).contains("twitter-cli"))
  }
}
