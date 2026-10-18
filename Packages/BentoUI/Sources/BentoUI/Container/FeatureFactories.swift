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
public protocol DocListFeatureFactory {
  func makeDocList(destination: SidebarDestination) -> DocListViewModel
}

@MainActor
public protocol DocEditorFeatureFactory {
  func makeDocEditor(docID: Doc.ID) -> DocEditorViewModel
}

@MainActor
public protocol ItemDetailFeatureFactory {
  func makeItemDetail(itemID: FeedItem.ID) -> ItemDetailViewModel
}

@MainActor
public protocol ChannelSettingsFeatureFactory {
  func makeChannelSettings(channelID: Channel.ID) -> ChannelSettingsViewModel
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
  let docs: any DocsStoring
  public func makeSidebar() -> SidebarViewModel { SidebarViewModel(store: store, docs: docs) }
}

public struct NativeDocListFeatureFactory: DocListFeatureFactory {
  let docs: any DocsStoring
  public func makeDocList(destination: SidebarDestination) -> DocListViewModel {
    DocListViewModel(destination: destination, store: docs)
  }
}

public struct NativeDocEditorFeatureFactory: DocEditorFeatureFactory {
  let docs: any DocsStoring
  let linkPreviewer: any LinkPreviewing
  public func makeDocEditor(docID: Doc.ID) -> DocEditorViewModel {
    DocEditorViewModel(docID: docID, store: docs, linkPreviewer: linkPreviewer)
  }
}

public struct NativeFeedFeatureFactory: FeedFeatureFactory {
  let store: any LibraryStoring
  public func makeFeed(destination: SidebarDestination) -> FeedViewModel {
    FeedViewModel(destination: destination, store: store)
  }
}

public struct NativeItemDetailFeatureFactory: ItemDetailFeatureFactory {
  let store: any LibraryStoring
  let docs: any DocsStoring
  public func makeItemDetail(itemID: FeedItem.ID) -> ItemDetailViewModel {
    ItemDetailViewModel(itemID: itemID, store: store, docs: docs)
  }
}

public struct NativeChannelSettingsFeatureFactory: ChannelSettingsFeatureFactory {
  let store: any LibraryStoring
  let statuses: any SourceStatusProviding
  let collector: (any CollectorControlling)?
  public func makeChannelSettings(channelID: Channel.ID) -> ChannelSettingsViewModel {
    ChannelSettingsViewModel(
      channelID: channelID,
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
  public var docList: any DocListFeatureFactory
  public var docEditor: any DocEditorFeatureFactory

  public init(
    sidebar: any SidebarFeatureFactory,
    feed: any FeedFeatureFactory,
    itemDetail: any ItemDetailFeatureFactory,
    channelSettings: any ChannelSettingsFeatureFactory,
    docList: any DocListFeatureFactory,
    docEditor: any DocEditorFeatureFactory
  ) {
    self.sidebar = sidebar
    self.feed = feed
    self.itemDetail = itemDetail
    self.channelSettings = channelSettings
    self.docList = docList
    self.docEditor = docEditor
  }

  /// `collector` is the Mac's connection to the collector daemon; nil on iOS.
  @MainActor
  public static func native(
    store: any LibraryStoring,
    docs: any DocsStoring,
    statuses: any SourceStatusProviding,
    collector: (any CollectorControlling)? = nil,
    linkPreviewer: any LinkPreviewing = NativeLinkPreviewer()
  ) -> AppContainer {
    AppContainer(
      sidebar: NativeSidebarFeatureFactory(store: store, docs: docs),
      feed: NativeFeedFeatureFactory(store: store),
      itemDetail: NativeItemDetailFeatureFactory(store: store, docs: docs),
      channelSettings: NativeChannelSettingsFeatureFactory(store: store, statuses: statuses, collector: collector),
      docList: NativeDocListFeatureFactory(docs: docs),
      docEditor: NativeDocEditorFeatureFactory(docs: docs, linkPreviewer: linkPreviewer)
    )
  }
}
