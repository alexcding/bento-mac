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
