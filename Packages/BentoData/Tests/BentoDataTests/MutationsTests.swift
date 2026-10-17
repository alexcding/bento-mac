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
}
