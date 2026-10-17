import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct CollectorConfigTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  func exported(maxItemAgeHours: Int = 72) throws -> [String: Any] {
    let data = try database.read { try CollectorConfigExporter.json($0, maxItemAgeHours: maxItemAgeHours) }
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

    let config = try exported(maxItemAgeHours: 48)

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

@Suite struct MutationsTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  @Test func deletingChannelDeletesItsOwnSources() throws {
    try database.write { db in
      let keep = try Mutations.addChannel(db, name: "Keep")
      let drop = try Mutations.addChannel(db, name: "Drop")
      try Mutations.addSource(db, channelID: keep, pluginID: "rss", name: "K", query: "k")
      let shared = try Mutations.addSource(db, channelID: drop, pluginID: "rss", name: "S", query: "s")
      try ChannelSource.insert { ChannelSource(id: UUID(), channelID: keep, sourceID: shared, position: 1) }
        .execute(db)
      try Mutations.addSource(db, channelID: drop, pluginID: "rss", name: "D", query: "d")

      try Mutations.deleteChannel(db, id: drop)

      #expect(try Channel.count().fetchOne(db) == 1)
      #expect(Set(try Source.all.fetchAll(db).map(\.name)) == ["K", "S"])
      #expect(try ChannelSource.count().fetchOne(db) == 2)
    }
  }

  @Test func bookmarkTogglesAndReadIsIdempotent() throws {
    let item = FeedItem(
      id: UUID(), sourceID: UUID(), externalID: "1", publishedAt: .now, fetchedAt: .now
    )
    try database.write { db in
      try FeedItem.insert { item }.execute(db)

      try Mutations.setBookmarked(db, itemID: item.id, true)
      try Mutations.setBookmarked(db, itemID: item.id, true)
      #expect(try Bookmark.count().fetchOne(db) == 1)
      try Mutations.setBookmarked(db, itemID: item.id, false)
      #expect(try Bookmark.count().fetchOne(db) == 0)

      try Mutations.markRead(db, itemID: item.id, now: Date(timeIntervalSince1970: 1))
      try Mutations.markRead(db, itemID: item.id, now: Date(timeIntervalSince1970: 2))
      #expect(try ReadState.find(item.id).fetchOne(db)?.readAt == Date(timeIntervalSince1970: 1))
    }
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
