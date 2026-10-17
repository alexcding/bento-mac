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

@Suite struct PluginInfoTests {
  @Test func rssNeedsAWebURLOtherPluginsAcceptAnyQuery() {
    #expect(PluginInfo.rss.accepts(query: " https://example.com/feed.xml "))
    #expect(!PluginInfo.rss.accepts(query: "ftp://example.com"))
    #expect(!PluginInfo.rss.accepts(query: "example.com/feed"))
    let x = plugin("x", manifest: #"{"id":"x","capabilities":["source"],"source":{"default_interval_minutes":15}}"#)
    #expect(x.accepts(query: ""))
    #expect(x.accepts(query: "@rustlang"))
  }

  @Test func decodesAuthKindsHintsAndRequirements() {
    let x = plugin(
      "x",
      manifest: #"{"id":"x","description":"X posts","capabilities":["source"],"auth":{"kind":"secrets","fields":[{"key":"auth_token","label":"auth_token cookie","help":"From your browser"}]},"source":{"default_interval_minutes":15,"query_hint":"@handle"}}"#,
      requirements: #"[{"name":"twitter-cli","installed":false,"detail":"`twitter` not found","install":"pipx install twitter-cli"}]"#
    )
    #expect(x.isSource && x.queryHint == "@handle" && x.defaultIntervalMinutes == 15)
    #expect(x.secretFields.map(\.key) == ["auth_token"])
    #expect(!x.hasInteractiveLogin)
    #expect(x.requirements.first?.install == "pipx install twitter-cli")

    let bilibili = plugin("bilibili", manifest: #"{"id":"bilibili","capabilities":["source","auth"],"auth":{"kind":"interactive","secrets":["sessdata"]},"source":{"default_interval_minutes":30}}"#)
    #expect(bilibili.hasInteractiveLogin && bilibili.interactiveSecretKeys == ["sessdata"])
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct SettingsTests {
  let store = FakeLibraryStore()

  @Test func pluginsTabOnlyWithACollector() {
    #expect(SettingsViewModel(store: store, collector: nil).tabs == [.general, .ai])
    #expect(SettingsViewModel(store: store, collector: FakeCollector(plugins: [])).tabs == [.general, .plugins, .ai])
  }

  @Test func savesSettingsSecretsAndHttpKeys() async {
    let collector = FakeCollector(plugins: [])
    let model = SettingsViewModel(store: store, collector: collector)
    let x = plugin("x", manifest: #"{"id":"x","auth":{"kind":"secrets","fields":[{"key":"auth_token","label":"a"},{"key":"ct0","label":"c"}]}}"#)

    model.updateSettings { $0.skipWeekends = true }
    await model.saveSecret("tok", key: "auth_token", plugin: x)
    await model.refreshSecrets(for: x)
    var profile = AiProfile()
    profile.name = "DeepSeek"
    profile.kind = .http
    model.save(profile, apiKey: "sk-1")
    try? await Task.sleep(for: .milliseconds(50))

    #expect(store.calls == ["saveSettings(true)", "saveAiProfile(DeepSeek)"])
    #expect(collector.calls == ["set(x.auth_token)", "set(ai.\(profile.id.uuidString.lowercased()))"])
    #expect(!model.isSignedIn(x), "ct0 is still missing")
  }

  @Test func collectOnThisMacTakesOver() async {
    let collector = FakeCollector(plugins: [])
    collector.isThisMacCollector = false
    let model = SettingsViewModel(store: store, collector: collector)

    await model.becomeCollector()

    #expect(collector.calls == ["becomeCollector"])
    #expect(collector.isThisMacCollector && !model.isTakingOver)
  }

  @Test func presetsStartFromTheBuiltInText() {
    let model = SettingsViewModel(store: store, collector: nil)
    model.editPreset("translate")
    #expect(model.editingTask?.key == "translate")
    #expect(model.editingTask?.outputs.map(\.target) == ["translated_title", "detail"])
  }

  @Test func loginShowsPromptsAndFinishes() async {
    let collector = FakeCollector(plugins: [])
    collector.events = [.prompt(kind: .qr, message: "Scan", qr: "https://qr"), .done]
    let model = SettingsViewModel(store: store, collector: collector)
    model.signIn(plugin("bilibili", manifest: #"{"id":"bilibili","auth":{"kind":"interactive","secrets":["sessdata"]}}"#))
    let login = model.login!

    login.start()
    try? await Task.sleep(for: .milliseconds(50))

    #expect(login.isDone)
    login.close()
    #expect(model.login == nil)
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct SourceEditorTests {
  let store = FakeLibraryStore()

  @Test func fetchNowReportsTheSummary() async {
    let model = SourceEditorViewModel(sourceID: UUID(), store: store, statuses: NoSourceStatus(), collector: FakeCollector(plugins: []))

    await model.fetchNow()

    #expect(model.runMessage == "Fetched 3 · 2 new")
  }

  @Test func describesBacklogAndFailures() {
    let summary = RunSummary(fetched: 5, new: 0, backlogSkipped: 5, aiFailures: ["translate: down"])
    #expect(SourceEditorViewModel.describe(summary) == "Fetched 5 · 0 new · 5 existing posts skipped · AI: translate: down")
    #expect(SourceEditorViewModel.describe(RunSummary(error: "no plugin")) == "no plugin")
  }
}

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct DestinationSettingsTests {
  let store = FakeLibraryStore()

  func model(_ collector: FakeCollector) -> ChannelSettingsViewModel {
    NativeChannelSettingsFeatureFactory(store: store, statuses: NoSourceStatus(), collector: collector)
      .makeChannelSettings(channelID: UUID())
  }

  @Test func addsATelegramBotWithItsTokenSavedFirst() async {
    let collector = FakeCollector(plugins: [])
    let model = model(collector)
    model.newDestinationKind = .telegramBot
    model.newDestinationSecret = " 123:abc "
    #expect(!model.canAddDestination, "a Telegram bot needs a chat")
    model.newDestinationChatID = "@news"

    await model.addDestination()

    #expect(collector.calls.count == 1 && collector.calls[0].hasPrefix("set(destination."))
    #expect(store.calls == ["addDestination(telegramBot,Telegram bot,@news)"])
    #expect(model.newDestinationSecret.isEmpty && model.newDestinationChatID.isEmpty)
  }

  @Test func onlyTheCollectorMacSetsUpDestinations() async {
    let collector = FakeCollector(plugins: [])
    collector.isThisMacCollector = false
    let model = model(collector)
    model.newDestinationSecret = "https://discord.com/api/webhooks/1/x"

    await model.addDestination()

    #expect(!model.canManageDestinations && collector.calls.isEmpty && store.calls.isEmpty)
  }
}
