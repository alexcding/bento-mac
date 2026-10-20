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
      coordinator.content.view()
        // A new screen replaces the last at once; nothing animates in from the one before.
        .transaction(value: coordinator.content) { $0.animation = nil }
        .navigationSplitViewColumnWidth(min: 320, ideal: 420)
    } detail: {
      coordinator.detail.view()
        .transaction(value: coordinator.detail) { $0.animation = nil }
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
