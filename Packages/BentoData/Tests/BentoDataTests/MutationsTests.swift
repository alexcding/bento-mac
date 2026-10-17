import Foundation
import SQLiteData
import Testing

@testable import BentoData

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

  func insertItem(_ db: Database, sourceID: UUID = UUID(), detail: String? = nil) throws -> FeedItem {
    let item = FeedItem(
      id: UUID(), sourceID: sourceID, externalID: UUID().uuidString, title: "T", publishedAt: .now, fetchedAt: .now
    )
    try FeedItem.insert { item }.execute(db)
    if let detail {
      let blob = try DetailCodec.encode(detail)
      try FeedItemDetail.insert { FeedItemDetail(feedItemID: item.id, markdown: blob) }.execute(db)
    }
    return item
  }

  @Test func bookmarkIsACopyThatSurvivesTheItem() throws {
    try database.write { db in
      let item = try insertItem(db, detail: "# Saved")

      try Mutations.setBookmarked(db, itemID: item.id, true)
      try Mutations.setBookmarked(db, itemID: item.id, true)
      try FeedItem.find(item.id).delete().execute(db)

      let bookmark = try #require(try Bookmark.find(item.id).fetchOne(db))
      #expect(try Bookmark.count().fetchOne(db) == 1)
      #expect(bookmark.title == "T")
      #expect(bookmark.asFeedItem.id == item.id)
      let detail = try #require(try BookmarkDetail.find(item.id).fetchOne(db))
      #expect(try DetailCodec.decode(detail.markdown) == "# Saved")

      try Mutations.setBookmarked(db, itemID: item.id, false)
      #expect(try Bookmark.count().fetchOne(db) == 0)
      #expect(try BookmarkDetail.count().fetchOne(db) == 0)
    }
  }

  @Test func setReadKeepsFirstReadTimeAndCanUnread() throws {
    try database.write { db in
      let item = try insertItem(db)

      try Mutations.setRead(db, itemIDs: [item.id], true, now: Date(timeIntervalSince1970: 1))
      try Mutations.setRead(db, itemIDs: [item.id], true, now: Date(timeIntervalSince1970: 2))
      #expect(try ReadState.find(item.id).fetchOne(db)?.readAt == Date(timeIntervalSince1970: 1))

      try Mutations.setRead(db, itemIDs: [item.id], false)
      #expect(try ReadState.count().fetchOne(db) == 0)

      try Mutations.setRead(db, itemIDs: [UUID()], true)
      #expect(try ReadState.count().fetchOne(db) == 0, "no feed item, no read state")
    }
  }

  @Test func markAllReadIsScopedToTheChannel() throws {
    try database.write { db in
      let news = try Mutations.addChannel(db, name: "News")
      let newsSource = try Mutations.addSource(db, channelID: news, pluginID: "rss", name: "n", query: "n")
      let inNews = try insertItem(db, sourceID: newsSource)
      let elsewhere = try insertItem(db)

      try Mutations.markAllRead(db, channelID: news)
      #expect(try ReadState.find(inNews.id).fetchOne(db) != nil)
      #expect(try ReadState.find(elsewhere.id).fetchOne(db) == nil)

      try Mutations.markAllRead(db, channelID: nil)
      #expect(try ReadState.count().fetchOne(db) == 2)
    }
  }

  @Test func deletingAProfileOrTaskCleansUpReferences() throws {
    try database.write { db in
      let main = AiProfile()
      let backup = AiProfile()
      try Mutations.saveAiProfile(db, main)
      try Mutations.saveAiProfile(db, backup)
      var task = AiTask()
      task.key = "keywords"
      task.profileID = main.id
      task.fallback = [backup.id, main.id]
      try Mutations.saveAiTask(db, task)
      let channel = try Mutations.addChannel(db, name: "C")
      let sourceID = try Mutations.addSource(db, channelID: channel, pluginID: "rss", name: "s", query: "q")
      var source = try #require(try Source.find(sourceID).fetchOne(db))
      source.aiTaskKeys = ["keywords", "other"]
      try Mutations.updateSource(db, source)

      try Mutations.deleteAiProfile(db, id: main.id)
      let updated = try #require(try AiTask.find(task.id).fetchOne(db))
      #expect(updated.profileID == nil)
      #expect(updated.fallback == [backup.id])

      try Mutations.deleteAiTask(db, id: task.id)
      #expect(try Source.find(sourceID).fetchOne(db)?.aiTaskKeys == ["other"])

      let unkeyed = AiTask()
      try Mutations.saveAiTask(db, unkeyed)
      var withUnkeyed = try #require(try Source.find(sourceID).fetchOne(db))
      withUnkeyed.aiTaskKeys = [unkeyed.sourceKey, "other"]
      try Mutations.updateSource(db, withUnkeyed)
      try Mutations.deleteAiTask(db, id: unkeyed.id)
      #expect(try Source.find(sourceID).fetchOne(db)?.aiTaskKeys == ["other"], "tasks without a key use their ID")
    }
  }

  @Test func settingsDefaultUntilSaved() throws {
    try database.write { db in
      #expect(try Mutations.settings(db).maxItemAgeHours == 72)
      var settings = try Mutations.settings(db)
      settings.skipWeekends = true
      try Mutations.saveSettings(db, settings)
      #expect(try Mutations.settings(db).skipWeekends)
    }
  }

  @Test func firstClaimWinsUnlessTakenOver() throws {
    let (first, second) = (UUID(), UUID())
    try database.write { db in
      #expect(try Mutations.claimCollector(db, deviceID: first, deviceName: "Studio", onlyIfUnset: true))
      #expect(try !Mutations.claimCollector(db, deviceID: second, deviceName: "Laptop", onlyIfUnset: true))
      #expect(try Mutations.settings(db).collectorDeviceName == "Studio")

      try Mutations.claimCollector(db, deviceID: second, deviceName: "Laptop")
      let settings = try Mutations.settings(db)
      #expect(settings.collectorDeviceID == second && settings.collectorDeviceName == "Laptop")
    }
  }

  @Test func feedItemIDsListsEveryItem() throws {
    try database.write { db in
      let items = try [insertItem(db), insertItem(db)]
      #expect(Set(try Mutations.feedItemIDs(db)) == Set(items.map(\.id)))
    }
  }

  @Test func sourceLimitLivesInSettingsJSON() {
    var source = Source(id: UUID())
    #expect(source.limit == nil)
    source.limit = 30
    #expect(source.settingsJSON == #"{"limit":30}"#)
    #expect(source.limit == 30)
  }
}

@Suite struct MigrationTests {
  /// A database created before the AI tables existed upgrades in place.
  @Test func upgradesADatabaseFromTheFirstMigration() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    let database = try DatabaseQueue(path: url.path)
    try BentoDatabase.migrator.migrate(database, upTo: "Create tables")
    try database.write { db in
      try #sql(#"INSERT INTO "sources" ("id", "pluginID", "name") VALUES ('6f1c2a52-1d0e-4c7a-9a52-2f7e1b1c9d10', 'rss', 'Old')"#)
        .execute(db)
    }

    try BentoDatabase.migrator.migrate(database)

    try database.write { db in
      let old = try #require(try Source.all.fetchOne(db))
      #expect(old.aiTaskKeys.isEmpty && !old.skipInitialBacklog, "existing rows get the defaults")
      try Mutations.saveAiProfile(db, AiProfile())
      #expect(try Mutations.settings(db).maxItemAgeHours == 72)
      #expect(try Mutations.settings(db).collectorDeviceID == nil)
    }
  }
}
