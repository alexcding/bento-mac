import Foundation
import SQLiteData
import Testing

@testable import BentoCollectorClient
@testable import BentoData

@Suite struct CollectorConfigTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  func exported() throws -> [String: Any] {
    let data = try database.read { try CollectorConfigExporter.json($0, utcOffsetMinutes: 480) }
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
  }

  /// Builds the same sources as `services/testdata/collector-config.json` and expects identical
  /// JSON, so the Rust decoder's fixture is exactly what the app writes.
  @Test func matchesRustFixture() throws {
    try database.write { db in
      let channel = try Mutations.addChannel(db, name: "News")
      try Source.insert {
        Source(
          id: UUID(uuidString: "6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10")!, pluginID: "rss", name: "Example Feed",
          query: "https://example.com/feed.xml", settingsJSON: "{}", intervalMinutes: 30,
          translate: true, summarize: false, fetchDetail: true, isEnabled: true
        )
        Source(
          id: UUID(uuidString: "0b8e4d1a-7a35-4d0b-8f2e-5c9d3e6a1b24")!, pluginID: "rss", name: "Paused Feed",
          query: "https://example.org/atom.xml", settingsJSON: "{}", intervalMinutes: 60,
          translate: false, summarize: false, fetchDetail: false, isEnabled: false
        )
      }
      .execute(db)
      for id in ["6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10", "0b8e4d1a-7a35-4d0b-8f2e-5c9d3e6a1b24"] {
        try ChannelSource.insert {
          ChannelSource(id: UUID(), channelID: channel, sourceID: UUID(uuidString: id)!, position: 0)
        }
        .execute(db)
      }
    }
    let fixture = try JSONSerialization.jsonObject(
      with: Data(contentsOf: testdata.appending(path: "collector-config.json"))
    )

    try database.write { db in
      var settings = AppSettings()
      settings.maxItemAgeHours = 48
      settings.skipWeekends = true
      try Mutations.saveSettings(db, settings)
      var deepseek = AiProfile(id: UUID(uuidString: "8a5b9c1e-2f3d-4e6a-9b7c-1d2e3f4a5b6c")!)
      deepseek.name = "DeepSeek"
      deepseek.kind = .http
      deepseek.baseURL = "https://api.deepseek.com"
      deepseek.model = "deepseek-chat"
      deepseek.timeoutSeconds = 120
      var claude = AiProfile(id: UUID(uuidString: "9b6c0d2f-3a4e-4f7b-8c8d-2e3f4a5b6c7d")!)
      claude.name = "Claude CLI"
      claude.position = 1
      try Mutations.saveAiProfile(db, deepseek)
      try Mutations.saveAiProfile(db, claude)
      var task = AiTask()
      task.key = "keywords"
      task.name = "Keywords"
      task.profileID = deepseek.id
      task.fallback = [claude.id]
      task.instructions = "List three keywords."
      task.outputs = [.init(name: "keywords", target: "summary", description: "Three comma-separated keywords.")]
      task.maxInputChars = 4000
      task.batchSize = 3
      try Mutations.saveAiTask(db, task)
      var source = try #require(try Source.find(UUID(uuidString: "6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10")!).fetchOne(db))
      source.aiTaskKeys = ["keywords"]
      try Mutations.updateSource(db, source)
    }

    let config = try exported()

    // Compare sources by ID: the exporter orders them by ID, the fixture by hand.
    func byID(_ object: Any) -> [String: NSDictionary] {
      let sources = (object as? [String: Any])?["sources"] as? [[String: Any]] ?? []
      return Dictionary(uniqueKeysWithValues: sources.map { ($0["id"] as! String, $0 as NSDictionary) })
    }
    #expect(byID(config) == byID(fixture))
    var withoutSources = config
    var fixtureWithoutSources = try #require(fixture as? [String: Any])
    withoutSources["sources"] = nil
    fixtureWithoutSources["sources"] = nil
    #expect(NSDictionary(dictionary: withoutSources).isEqual(fixtureWithoutSources))
  }

  @Test func sourcesInPausedChannelsAreDisabled() throws {
    try database.write { db in
      let paused = try Mutations.addChannel(db, name: "Paused")
      var channel = try #require(try Channel.find(paused).fetchOne(db))
      channel.isEnabled = false
      try Mutations.updateChannel(db, channel)
      try Mutations.addSource(db, channelID: paused, pluginID: "rss", name: "A", query: "https://a")
    }

    let sources = try #require(try exported()["sources"] as? [[String: Any]])

    #expect(sources.count == 1)
    #expect(sources[0]["enabled"] as? Bool == false)
  }

  @Test func writesOnlyWhenChanged() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).json")
    let data = try database.read { try CollectorConfigExporter.json($0) }

    #expect(try CollectorConfigExporter.write(data, to: url))
    #expect(try !CollectorConfigExporter.write(data, to: url))
  }
}

@Suite struct CollectorStatusTests {
  @Test func readsSourceStateFromCollectorDatabase() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    let collector = try DatabaseQueue(path: url.path)
    try collector.write { db in
      for migration in try collectorMigrations() { try db.execute(sql: migration) }
      try db.execute(
        sql: """
          INSERT INTO source_state VALUES
            ('6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10', 1792141200000, 1792143000000, 2, 'timeout', 5)
          """
      )
    }

    let statuses = try CollectorStatusReader.read(collectorURL: url)

    let status = try #require(statuses[UUID(uuidString: "6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10")!])
    #expect(status.lastRunAt == Date(timeIntervalSince1970: 1_792_141_200))
    #expect(status.nextRunAt == Date(timeIntervalSince1970: 1_792_143_000))
    #expect(status.consecutiveFailures == 2)
    #expect(status.lastError == "timeout")
    #expect(status.lastNewItems == 5)
  }

  @Test func missingDatabaseIsEmpty() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "missing.sqlite")
    #expect(try CollectorStatusReader.read(collectorURL: url).isEmpty)
  }
}
