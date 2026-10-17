import BentoData
import Observation

/// Root coordinator: sidebar selection, the feed for it, the selected item, and the channel
/// settings sheet. Screens have no navigation of their own yet, so it is the only coordinator.
@MainActor
@Observable
public final class AppCoordinator: Coordinatable {
  public let sidebar: SidebarViewModel
  public private(set) var feed: FeedViewModel
  public private(set) var itemDetail: ItemDetailViewModel?
  public var channelSettings: ChannelSettingsViewModel?

  @ObservationIgnored private let container: AppContainer

  public init(container: AppContainer) {
    self.container = container
    sidebar = container.sidebar.makeSidebar()
    feed = container.feed.makeFeed(destination: sidebar.selection)
    sidebar.onAction = { [weak self] in self?.handle(.sidebar($0)) }
    wire(feed)
  }

  public func handle(_ action: Action) {
    switch action {
    case .sidebar(.selected(let destination)):
      guard destination != feed.destination else { return }
      itemDetail = nil
      feed = container.feed.makeFeed(destination: destination)
      wire(feed)
    case .sidebar(.openChannelSettings(let id)), .feed(.openChannelSettings(let id)):
      let model = container.channelSettings.makeChannelSettings(channelID: id)
      model.onAction = { [weak self] in self?.handle(.channelSettings($0)) }
      channelSettings = model
    case .feed(.selectedItem(let id)):
      guard id != itemDetail?.itemID else { return }
      itemDetail = id.map(container.itemDetail.makeItemDetail(itemID:))
    case .channelSettings(.dismiss):
      channelSettings = nil
    }
  }

  private func wire(_ feed: FeedViewModel) {
    feed.onAction = { [weak self] in self?.handle(.feed($0)) }
  }
}
