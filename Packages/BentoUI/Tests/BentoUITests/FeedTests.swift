import BentoData
import DependenciesTestSupport
import Foundation
import SQLiteData
import Testing

@testable import BentoUI

@Suite struct FeedQueryTests {
  let database: any DatabaseWriter

  init() throws {
    database = try makeDatabase()
  }

  func rows(_ channelID: Channel.ID? = nil, search: String = "", unreadOnly: Bool = false) throws -> [FeedRow] {
    try database.read { try FeedQuery.items(channelID: channelID, search: search, unreadOnly: unreadOnly).fetchAll($0) }
  }

  @Test func filtersByChannelSearchAndUnread() throws {
    let (news, newsItem, otherItem) = try database.write { db in
      let news = try Mutations.addChannel(db, name: "News")
      let source = try Mutations.addSource(db, channelID: news, pluginID: "rss", name: "n", query: "n")
      let newsItem = item(sourceID: source, title: "Rust 2.0 released", publishedAt: Date(timeIntervalSince1970: 2))
      let otherItem = item(title: "Über Wetter", summary: "Sunny", publishedAt: Date(timeIntervalSince1970: 1))
      try FeedItem.insert { newsItem; otherItem }.execute(db)
      return (news, newsItem, otherItem)
    }

    #expect(try rows().map(\.id) == [newsItem.id, otherItem.id], "newest first")
    #expect(try rows(news).map(\.id) == [newsItem.id])
    #expect(try rows(search: "RUST").map(\.id) == [newsItem.id])
    #expect(try rows(search: "sunny").map(\.id) == [otherItem.id], "searches the summary")
    #expect(try rows(search: "über").map(\.id) == [otherItem.id], "case-insensitive beyond ASCII")

    try database.write { try Mutations.setRead($0, itemIDs: [newsItem.id], true) }
    #expect(try rows(unreadOnly: true).map(\.id) == [otherItem.id])
    #expect(try rows().first?.isRead == true)
  }

  @Test func bookmarksListTheSavedCopyEvenAfterTheItemIsGone() throws {
    let saved = item(title: "Keep me")
    try database.write { db in
      try FeedItem.insert { saved }.execute(db)
      try Mutations.setBookmarked(db, itemID: saved.id, true)
    }
    #expect(try rows().first?.isBookmarked == true)
    try database.write { try FeedItem.find(saved.id).delete().execute($0) }

    let bookmarks = try database.read { try FeedQuery.bookmarks(search: "keep", unreadOnly: false).fetchAll($0) }

    #expect(bookmarks.map(\.feedRow.item.title) == ["Keep me"])
    #expect(bookmarks[0].feedRow.isBookmarked)
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct FeedViewModelTests {
  let store = FakeLibraryStore()

  @Test func keyboardMovesSelectionWithinBounds() async throws {
    @Dependency(\.defaultDatabase) var database
    try await database.write { db in
      try FeedItem.insert {
        item(publishedAt: Date(timeIntervalSince1970: 3))
        item(publishedAt: Date(timeIntervalSince1970: 2))
        item(publishedAt: Date(timeIntervalSince1970: 1))
      }
      .execute(db)
    }
    let model = FeedViewModel(destination: .all, store: store)
    await model.reload()
    let ids = model.rows.map(\.id)

    model.moveSelection(by: 1)
    #expect(model.selectedItemID == ids[0])
    model.moveSelection(by: 1)
    model.moveSelection(by: 1)
    model.moveSelection(by: 1)
    #expect(model.selectedItemID == ids[2])
    model.moveSelection(by: -1)
    #expect(model.selectedItemID == ids[1])
  }

  @Test func markAllReadInBookmarksMarksOnlyBookmarks() async throws {
    @Dependency(\.defaultDatabase) var database
    let saved = item()
    try await database.write { db in
      try FeedItem.insert { saved; item() }.execute(db)
      try Mutations.setBookmarked(db, itemID: saved.id, true)
    }
    let model = FeedViewModel(destination: .bookmarks, store: store)
    await model.reload()

    model.markAllRead()

    #expect(store.calls == ["setRead(1,true)"])
  }

  @Test func actionsGoThroughTheStore() {
    let channel = UUID()
    let model = FeedViewModel(destination: .channel(channel), store: store)
    let row = FeedRow(item: item(), isRead: false, isBookmarked: true)

    model.toggleRead(row)
    model.toggleBookmark(row)
    model.markAllRead()

    #expect(store.calls == ["setRead(1,true)", "setBookmarked(false)", "markAllRead(channel)"])
  }

  @Test func groupsRowsByDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let day = 86_400.0
    let rows = [3.5 * day, 3.2 * day, 1.1 * day].map {
      FeedRow(item: item(publishedAt: Date(timeIntervalSince1970: $0)), isRead: false, isBookmarked: false)
    }

    let days = FeedDay.group(rows, calendar: calendar)

    #expect(days.map(\.rows.count) == [2, 1])
    #expect(days.map(\.day) == [Date(timeIntervalSince1970: 3 * day), Date(timeIntervalSince1970: day)])
  }
}

@Suite struct FeedCardModelTests {
  @Test func prefersTranslatedTitleThenTitleThenFirstLine() {
    #expect(FeedCardModel(item(title: "T", translatedTitle: "译")).title == "译")
    #expect(FeedCardModel(item(title: "T")).title == "T")
    #expect(FeedCardModel(item(title: nil, text: "First\nSecond")).title == "First")
  }

  @Test func bodyIsSummaryOrTextButNeverRepeatsTheTitle() {
    #expect(FeedCardModel(item(title: "T", text: "Body", summary: "Sum")).body == "Sum")
    #expect(FeedCardModel(item(title: "T", text: "Body")).body == "Body")
    #expect(FeedCardModel(item(title: nil, text: "Tweet text")).body == nil)
  }
}

@Suite struct ChannelSettingsTests {
  @Test func acceptsOnlyHTTPFeedURLs() {
    #expect(ChannelSettingsViewModel.feedURL(" https://example.com/feed.xml ") != nil)
    #expect(ChannelSettingsViewModel.feedURL("http://example.com") != nil)
    #expect(ChannelSettingsViewModel.feedURL("ftp://example.com") == nil)
    #expect(ChannelSettingsViewModel.feedURL("example.com/feed") == nil)
    #expect(ChannelSettingsViewModel.feedURL("") == nil)
  }
}
