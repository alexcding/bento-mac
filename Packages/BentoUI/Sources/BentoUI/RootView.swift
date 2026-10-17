import BentoData
import SwiftUI

/// Slack-style layout: channels in the sidebar, the selected channel's feed in the main area.
public struct RootView: View {
  @State private var selection: SidebarSelection? = .all

  public init() {}

  public var body: some View {
    NavigationSplitView {
      ChannelSidebar(selection: $selection)
        .navigationSplitViewColumnWidth(min: 200, ideal: 240)
    } detail: {
      FeedView(channelID: selection?.channelID)
        .id(selection)
    }
  }
}

enum SidebarSelection: Hashable {
  case all
  case channel(Channel.ID)

  var channelID: Channel.ID? {
    if case .channel(let id) = self { id } else { nil }
  }
}
