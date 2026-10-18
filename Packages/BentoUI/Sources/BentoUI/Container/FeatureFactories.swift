import Foundation
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
  /// Settings for a channel not saved yet: name and switch, then Create.
  func makeNewChannel() -> ChannelSettingsViewModel
}

@MainActor
public protocol AddSourceFeatureFactory {
  func makeAddSource(channelID: Channel.ID) -> AddSourceViewModel
}

@MainActor
public protocol SourceEditorFeatureFactory {
  func makeSourceEditor(sourceID: Source.ID) -> SourceEditorViewModel
}

@MainActor
public protocol SettingsFeatureFactory {
  func makeSettings() -> SettingsViewModel
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
  let collector: (any CollectorControlling)?
  public func makeChannelSettings(channelID: Channel.ID) -> ChannelSettingsViewModel {
    make(channelID: channelID, isNew: false)
  }

  public func makeNewChannel() -> ChannelSettingsViewModel {
    make(channelID: UUID(), isNew: true)
  }

  private func make(channelID: Channel.ID, isNew: Bool) -> ChannelSettingsViewModel {
    ChannelSettingsViewModel(
      channelID: channelID,
      isNew: isNew,
      store: store,
      statuses: statuses,
      collector: collector,
      sourceEditors: NativeSourceEditorFeatureFactory(store: store, statuses: statuses, collector: collector),
      addSources: NativeAddSourceFeatureFactory(store: store, collector: collector)
    )
  }
}

public struct NativeAddSourceFeatureFactory: AddSourceFeatureFactory {
  let store: any LibraryStoring
  let collector: (any CollectorControlling)?

  public func makeAddSource(channelID: Channel.ID) -> AddSourceViewModel {
    AddSourceViewModel(channelID: channelID, store: store, collector: collector)
  }
}

public struct NativeSourceEditorFeatureFactory: SourceEditorFeatureFactory {
  let store: any LibraryStoring
  let statuses: any SourceStatusProviding
  let collector: (any CollectorControlling)?
  public func makeSourceEditor(sourceID: Source.ID) -> SourceEditorViewModel {
    SourceEditorViewModel(sourceID: sourceID, store: store, statuses: statuses, collector: collector)
  }
}

public struct NativeSettingsFeatureFactory: SettingsFeatureFactory {
  let store: any LibraryStoring
  let collector: (any CollectorControlling)?

  public init(store: any LibraryStoring, collector: (any CollectorControlling)?) {
    self.store = store
    self.collector = collector
  }

  public func makeSettings() -> SettingsViewModel {
    SettingsViewModel(store: store, collector: collector)
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

  /// `collector` is the Mac's connection to the collector daemon; nil on iOS.
  @MainActor
  public static func native(
    store: any LibraryStoring,
    statuses: any SourceStatusProviding,
    collector: (any CollectorControlling)? = nil
  ) -> AppContainer {
    AppContainer(
      sidebar: NativeSidebarFeatureFactory(store: store),
      feed: NativeFeedFeatureFactory(store: store),
      itemDetail: NativeItemDetailFeatureFactory(store: store),
      channelSettings: NativeChannelSettingsFeatureFactory(store: store, statuses: statuses, collector: collector)
    )
  }
}
