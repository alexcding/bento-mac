@testable import BentoData
import DependenciesTestSupport
import Foundation
import Testing

@testable import BentoUI

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct AppCoordinatorTests {
  let store = FakeLibraryStore()

  @Test func eachColumnHoldsTheDestinationForTheSelection() {
    let coordinator = AppCoordinator(container: .test(store: store))
    let feed = coordinator.content
    #expect(coordinator.detail == .placeholder("Select an item", symbol: "doc.text"))

    coordinator.feed?.selectedItemID = UUID()
    guard case .itemDetail = coordinator.detail else {
      Issue.record("no item detail")
      return
    }

    coordinator.sidebar.selection = .allDocs
    guard case .docList = coordinator.content else {
      Issue.record("no doc list")
      return
    }
    #expect(coordinator.content != feed)
    #expect(coordinator.detail == .placeholder("Select a doc", symbol: "doc.text"))
  }

  @Test func selectingADestinationReplacesTheFeedAndClearsTheItem() {
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.feed?.selectedItemID = UUID()
    #expect(coordinator.itemDetail != nil)

    coordinator.sidebar.selection = .bookmarks

    #expect(coordinator.feed?.destination == .bookmarks)
    #expect(coordinator.itemDetail == nil)
  }

  @Test func reselectingTheSameDestinationKeepsTheFeed() {
    let coordinator = AppCoordinator(container: .test(store: store))
    let feed = coordinator.feed

    coordinator.handle(.sidebar(.selected(.all)))

    #expect(coordinator.feed === feed)
  }

  @Test func feedSelectionDrivesTheDetail() {
    let coordinator = AppCoordinator(container: .test(store: store))
    let id = UUID()

    coordinator.feed?.selectedItemID = id
    #expect(coordinator.itemDetail?.itemID == id)

    coordinator.feed?.selectedItemID = nil
    #expect(coordinator.itemDetail == nil)
  }

  @Test func channelSettingsOpenFromSidebarOrFeedAndDismiss() {
    let coordinator = AppCoordinator(container: .test(store: store))
    let channel = UUID()

    coordinator.sidebar.openSettings(channelRow(channel))
    #expect(coordinator.channelSettings?.channelID == channel)
    coordinator.channelSettings?.done()
    #expect(coordinator.channelSettings == nil)

    coordinator.sidebar.selection = .channel(channel)
    coordinator.feed?.openChannelSettings()
    #expect(coordinator.channelSettings?.channelID == channel)
  }

  @Test func aNewChannelIsSavedOnlyWhenCreated() async throws {
    let coordinator = AppCoordinator(container: .test(store: store))

    coordinator.sidebar.addChannel()
    let settings = try #require(coordinator.channelSettings)
    #expect(settings.isNew)
    #expect(store.calls.isEmpty, "nothing saved while it is being named")

    settings.cancel()
    #expect(coordinator.channelSettings == nil)
    #expect(store.calls.isEmpty, "cancelling leaves nothing behind")

    coordinator.sidebar.addChannel()
    let created = try #require(coordinator.channelSettings)
    created.name = "  News "
    created.newIsEnabled = false
    created.showAddSource()
    let addSource = try #require(created.addSource)
    addSource.choose(.rss)
    addSource.query = "https://example.com/feed.xml"
    addSource.add()
    #expect(created.shownSources.map(\.name) == ["example.com"])
    #expect(store.calls.isEmpty, "a source added to a new channel is not saved yet")

    await created.create()

    #expect(store.calls == ["createChannel(News,false,[\"rss\"],[])"])
    #expect(!created.isNew)
    #expect(coordinator.feed?.destination == .channel(created.channelID))
    #expect(coordinator.channelSettings == nil, "the sheet closes once the channel is saved")
  }

  @Test func deletingTheSelectedChannelFallsBackToAllItems() {
    let coordinator = AppCoordinator(container: .test(store: store))
    let channel = channelRow(UUID())
    coordinator.sidebar.selection = .channel(channel.id)

    coordinator.sidebar.delete(channel)

    #expect(coordinator.feed?.destination == .all)
    #expect(store.calls == ["deleteChannel"])
  }
}
