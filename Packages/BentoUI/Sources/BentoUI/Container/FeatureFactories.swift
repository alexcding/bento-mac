import BentoData

// One factory per feature. Tests substitute these; production uses the `Native*` versions.

@MainActor
public protocol SidebarFeatureFactory {
  func makeSidebar() -> SidebarViewModel
}

@MainActor
public protocol FeedFeatureFactory {
  func makeFeed(destination: SidebarDestination) -> FeedViewModel
}

@MainActor
public protocol ItemDetailFeatureFactory {
  func makeItemDetail(itemID: FeedItem.ID) -> ItemDetailViewModel
}

@MainActor
public protocol ChannelSettingsFeatureFactory {
  func makeChannelSettings(channelID: Channel.ID) -> ChannelSettingsViewModel
}

public struct NativeSidebarFeatureFactory: SidebarFeatureFactory {
  let store: any LibraryStoring
  public func makeSidebar() -> SidebarViewModel { SidebarViewModel(store: store) }
}

public struct NativeFeedFeatureFactory: FeedFeatureFactory {
  let store: any LibraryStoring
  public func makeFeed(destination: SidebarDestination) -> FeedViewModel {
    FeedViewModel(destination: destination, store: store)
  }
}

public struct NativeItemDetailFeatureFactory: ItemDetailFeatureFactory {
  let store: any LibraryStoring
  public func makeItemDetail(itemID: FeedItem.ID) -> ItemDetailViewModel {
    ItemDetailViewModel(itemID: itemID, store: store)
  }
}

public struct NativeChannelSettingsFeatureFactory: ChannelSettingsFeatureFactory {
  let store: any LibraryStoring
  let statuses: any SourceStatusProviding
  public func makeChannelSettings(channelID: Channel.ID) -> ChannelSettingsViewModel {
    ChannelSettingsViewModel(channelID: channelID, store: store, statuses: statuses)
  }
}

/// Every factory the app coordinator needs.
public struct AppContainer {
  public var sidebar: any SidebarFeatureFactory
  public var feed: any FeedFeatureFactory
  public var itemDetail: any ItemDetailFeatureFactory
  public var channelSettings: any ChannelSettingsFeatureFactory

  public init(
    sidebar: any SidebarFeatureFactory,
    feed: any FeedFeatureFactory,
    itemDetail: any ItemDetailFeatureFactory,
    channelSettings: any ChannelSettingsFeatureFactory
  ) {
    self.sidebar = sidebar
    self.feed = feed
    self.itemDetail = itemDetail
    self.channelSettings = channelSettings
  }

  @MainActor
  public static func native(store: any LibraryStoring, statuses: any SourceStatusProviding) -> AppContainer {
    AppContainer(
      sidebar: NativeSidebarFeatureFactory(store: store),
      feed: NativeFeedFeatureFactory(store: store),
      itemDetail: NativeItemDetailFeatureFactory(store: store),
      channelSettings: NativeChannelSettingsFeatureFactory(store: store, statuses: statuses)
    )
  }
}
