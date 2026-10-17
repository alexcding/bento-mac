@testable import BentoData
import DependenciesTestSupport
import Foundation
import Testing

@testable import BentoUI

@MainActor
@Suite(.dependency(\.defaultDatabase, try makeDatabase()))
struct AppCoordinatorTests {
  let store = FakeLibraryStore()

  @Test func selectingADestinationReplacesTheFeedAndClearsTheItem() {
    let coordinator = AppCoordinator(container: .test(store: store))
    coordinator.feed.selectedItemID = UUID()
    #expect(coordinator.itemDetail != nil)

    coordinator.sidebar.selection = .bookmarks

    #expect(coordinator.feed.destination == .bookmarks)
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

    coordinator.feed.selectedItemID = id
    #expect(coordinator.itemDetail?.itemID == id)

    coordinator.feed.selectedItemID = nil
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
    coordinator.feed.openChannelSettings()
    #expect(coordinator.channelSettings?.channelID == channel)
  }

  @Test func addingAChannelSelectsItAndOpensItsSettings() {
    let coordinator = AppCoordinator(container: .test(store: store))

    coordinator.sidebar.addChannel()

    #expect(store.calls == ["addChannel(New channel)"])
    #expect(coordinator.feed.destination == .channel(store.newChannelID))
    #expect(coordinator.channelSettings?.channelID == store.newChannelID)
  }

  @Test func deletingTheSelectedChannelFallsBackToAllItems() {
    let coordinator = AppCoordinator(container: .test(store: store))
    let channel = channelRow(UUID())
    coordinator.sidebar.selection = .channel(channel.id)

    coordinator.sidebar.delete(channel)

    #expect(coordinator.feed.destination == .all)
    #expect(store.calls == ["deleteChannel"])
  }
}
