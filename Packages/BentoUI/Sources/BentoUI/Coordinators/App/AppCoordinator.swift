import BentoData
import Observation

/// Root coordinator: the sidebar, what the middle column shows for its selection (a feed or a doc
/// list), what the detail column shows (the chosen item or doc), and the channel settings sheet.
/// Each column holds a `Destination`; the view only shows them. Screens have no navigation of
/// their own yet, so it is the only coordinator.
@MainActor
@Observable
public final class AppCoordinator: Coordinatable {
  public let sidebar: SidebarViewModel
  /// The middle column.
  private(set) var content: Destination
  /// The detail column.
  private(set) var detail: Destination
  public var channelSettings: ChannelSettingsViewModel?

  @ObservationIgnored private let container: AppContainer

  public var feed: FeedViewModel? {
    if case .feed(let model) = content { model } else { nil }
  }

  public var docList: DocListViewModel? {
    if case .docList(let model) = content { model } else { nil }
  }

  public var itemDetail: ItemDetailViewModel? {
    if case .itemDetail(let model) = detail { model } else { nil }
  }

  public var docEditor: DocPageViewModel? {
    if case .docPage(let model) = detail { model } else { nil }
  }

  /// The sidebar destination the middle column is showing.
  private var contentDestination: SidebarDestination? {
    feed?.destination ?? docList?.destination
  }

  public init(container: AppContainer) {
    self.container = container
    sidebar = container.sidebar.makeSidebar()
    content = .placeholder("", symbol: "")
    detail = Self.emptyDetail(docs: false)
    sidebar.onAction = { [weak self] in self?.handle(.sidebar($0)) }
    show(sidebar.selection)
  }

  public func handle(_ action: Action) {
    switch action {
    case .sidebar(.selected(let destination)):
      guard destination != contentDestination else { return }
      show(destination)
    case .sidebar(.openChannelSettings(let id)), .feed(.openChannelSettings(let id)):
      let model = container.channelSettings.makeChannelSettings(channelID: id)
      model.onAction = { [weak self] in self?.handle(.channelSettings($0)) }
      channelSettings = model
    case .sidebar(.newChannel):
      let model = container.channelSettings.makeNewChannel()
      model.onAction = { [weak self] in self?.handle(.channelSettings($0)) }
      channelSettings = model
    case .channelSettings(.created(let id)):
      sidebar.selection = .channel(id)
    case .feed(.selectedItem(let id)):
      guard id != itemDetail?.itemID else { return }
      detail = id.map { .itemDetail(container.itemDetail.makeItemDetail(itemID: $0)) } ?? Self.emptyDetail(docs: false)
    case .channelSettings(.dismiss):
      channelSettings = nil
    case .docList(.selectedDoc(let id)):
      guard id != docEditor?.docID else { return }
      detail = id.map { .docPage(makeDocEditor($0)) } ?? Self.emptyDetail(docs: true)
    case .docEditor(.openDoc(let id)):
      // A link goes straight to its doc, chosen in the list as if clicked there; a doc that list
      // does not show (another folder, not starred) is shown under All docs.
      if docList?.docs.contains(where: { $0.id == id }) != true, sidebar.selection != .allDocs {
        sidebar.selection = .allDocs
      }
      if let docList {
        docList.selectedDocID = id
      } else if id != docEditor?.docID {
        detail = .docPage(makeDocEditor(id))
      }
    }
  }

  private func makeDocEditor(_ id: Doc.ID) -> DocPageViewModel {
    let editor = container.docEditor.makeDocEditor(docID: id)
    editor.onAction = { [weak self] in self?.handle(.docEditor($0)) }
    return editor
  }

  /// The middle column for a sidebar destination, with nothing chosen in it yet.
  private func show(_ destination: SidebarDestination) {
    if destination.isDocs {
      let model = container.docList.makeDocList(destination: destination)
      model.onAction = { [weak self] in self?.handle(.docList($0)) }
      content = .docList(model)
    } else {
      let model = container.feed.makeFeed(destination: destination)
      model.onAction = { [weak self] in self?.handle(.feed($0)) }
      content = .feed(model)
    }
    detail = Self.emptyDetail(docs: destination.isDocs)
  }

  private static func emptyDetail(docs: Bool) -> Destination {
    .placeholder(docs ? "Select a doc" : "Select an item", symbol: "doc.text")
  }
}
