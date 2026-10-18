import SwiftUI

/// Slack-style layout: channels and doc folders, the selected channel's feed or folder's docs,
/// then the selected item or doc. Shared by the Mac and iOS apps.
public struct AppCoordinatorView: View {
  @Bindable var coordinator: AppCoordinator

  public init(coordinator: AppCoordinator) {
    self.coordinator = coordinator
  }

  public var body: some View {
    NavigationSplitView {
      SidebarView(model: coordinator.sidebar)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: sidebarMaxWidth)
    } content: {
      Group {
        switch coordinator.content {
        case .feed(let feed): FeedView(model: feed)
        case .docs(let docs): DocListView(model: docs)
        }
      }
      .id(coordinator.content.destination)
      .navigationSplitViewColumnWidth(min: 320, ideal: 420)
    } detail: {
      if coordinator.content.destination.isDocs {
        if let editor = coordinator.docEditor {
          DocEditorView(model: editor)
            .id(editor.docID)
        } else {
          ContentUnavailableView("Select a doc", systemImage: "doc.text")
        }
      } else if let detail = coordinator.itemDetail {
        ItemDetailView(model: detail)
          .id(detail.itemID)
      } else {
        ContentUnavailableView("Select an item", systemImage: "doc.text")
      }
    }
    .sheet(item: $coordinator.channelSettings) { model in
      ChannelSettingsView(model: model)
    }
  }
}

#if os(macOS)
  private let sidebarMaxWidth: CGFloat = 420
#else
  private let sidebarMaxWidth: CGFloat? = nil
#endif
