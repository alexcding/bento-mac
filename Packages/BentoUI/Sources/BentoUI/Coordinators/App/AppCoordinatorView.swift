import SwiftUI

/// Slack-style layout: channels, the selected channel's feed, then the selected item. Shared by
/// the Mac and iOS apps.
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
      FeedView(model: coordinator.feed)
        .id(coordinator.feed.destination)
        .navigationSplitViewColumnWidth(min: 320, ideal: 420)
    } detail: {
      if let detail = coordinator.itemDetail {
        ItemDetailView(model: detail)
          .id(detail.itemID)
      } else {
        ContentUnavailableView("Select an item", systemImage: "doc.text")
      }
    }
    .sheet(item: $coordinator.channelSettings) { model in
      ChannelSettingsView(model: model)
    }
    .providesSourceIcons()
  }
}

#if os(macOS)
  private let sidebarMaxWidth: CGFloat = 420
#else
  private let sidebarMaxWidth: CGFloat? = nil
#endif
