import BentoData
import Observation

/// Root coordinator: sidebar selection, the feed or doc list for it, the selected item or doc,
/// and the channel settings sheet. Screens have no navigation of their own yet, so it is the only
/// coordinator.
@MainActor
@Observable
public final class AppCoordinator: Coordinatable {
  /// The middle column: feed items, or docs.
  public enum Content {
    case feed(FeedViewModel)
    case docs(DocListViewModel)

    var destination: SidebarDestination {
      switch self {
      case .feed(let feed): feed.destination
      case .docs(let docs): docs.destination
      }
    }
  }

  public let sidebar: SidebarViewModel
  public private(set) var content: Content
  public private(set) var itemDetail: ItemDetailViewModel?
  public private(set) var docEditor: DocEditorViewModel?
  public var channelSettings: ChannelSettingsViewModel?

  @ObservationIgnored private let container: AppContainer
  /// The docs a page was opened through, outermost first, for the back button.
  @ObservationIgnored private var docTrail: [DocEditorViewModel] = []

  public var feed: FeedViewModel? {
    if case .feed(let feed) = content { feed } else { nil }
  }

  public var docList: DocListViewModel? {
    if case .docs(let docs) = content { docs } else { nil }
  }

  public init(container: AppContainer) {
    self.container = container
    sidebar = container.sidebar.makeSidebar()
    content = .feed(container.feed.makeFeed(destination: sidebar.selection))
    sidebar.onAction = { [weak self] in self?.handle(.sidebar($0)) }
    wire(content)
  }

  public func handle(_ action: Action) {
    switch action {
    case .sidebar(.selected(let destination)):
      guard destination != content.destination else { return }
      itemDetail = nil
      docEditor = nil
      docTrail = []
      content = destination.isDocs
        ? .docs(container.docList.makeDocList(destination: destination))
        : .feed(container.feed.makeFeed(destination: destination))
      wire(content)
    case .sidebar(.openDoc(let id)):
      docList?.selectedDocID = id
    case .sidebar(.openChannelSettings(let id)), .feed(.openChannelSettings(let id)):
      let model = container.channelSettings.makeChannelSettings(channelID: id)
      model.onAction = { [weak self] in self?.handle(.channelSettings($0)) }
      channelSettings = model
    case .feed(.selectedItem(let id)):
      guard id != itemDetail?.itemID else { return }
      itemDetail = id.map(container.itemDetail.makeItemDetail(itemID:))
    case .channelSettings(.dismiss):
      channelSettings = nil
    case .docList(.selectedDoc(let id)):
      guard id != docEditor?.docID else { return }
      docTrail = []
      docEditor = id.map(makeDocEditor)
    case .docEditor(.openDoc(let id)):
      guard let current = docEditor else { return }
      docTrail.append(current)
      let page = makeDocEditor(id)
      page.parentTitle = current.title
      docEditor = page
    case .docEditor(.back):
      docEditor = docTrail.popLast()
    }
  }

  private func makeDocEditor(_ id: Doc.ID) -> DocEditorViewModel {
    let editor = container.docEditor.makeDocEditor(docID: id)
    editor.onAction = { [weak self] in self?.handle(.docEditor($0)) }
    return editor
  }

  private func wire(_ content: Content) {
    switch content {
    case .feed(let feed): feed.onAction = { [weak self] in self?.handle(.feed($0)) }
    case .docs(let docs): docs.onAction = { [weak self] in self?.handle(.docList($0)) }
    }
  }
}
