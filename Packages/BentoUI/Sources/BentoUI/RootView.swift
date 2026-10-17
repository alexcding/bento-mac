import BentoData
import SwiftUI

/// Slack-style layout: channels in the sidebar, the selected channel's feed, then the selected
/// item. Shared by the Mac and iOS apps.
public struct RootView: View {
  @State private var selection: SidebarSelection? = .all
  @State private var selectedItemID: FeedItem.ID?

  public init() {}

  public var body: some View {
    NavigationSplitView {
      ChannelSidebar(selection: $selection)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } content: {
      FeedView(filter: selection ?? .all, selectedItemID: $selectedItemID)
        .id(selection)
        .navigationSplitViewColumnWidth(min: 320, ideal: 420)
    } detail: {
      if let selectedItemID {
        FeedItemDetailView(itemID: selectedItemID)
          .id(selectedItemID)
      } else {
        ContentUnavailableView("Select an item", systemImage: "doc.text")
      }
    }
    .onChange(of: selection) { selectedItemID = nil }
  }
}

enum SidebarSelection: Hashable {
  case all
  case bookmarks
  case channel(Channel.ID)
}

extension EnvironmentValues {
  /// Collector status per source, provided by the Mac app. Empty on iOS.
  @Entry public var sourceStatuses: [Source.ID: SourceStatus] = [:]
}
