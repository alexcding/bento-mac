import BentoData
import SQLiteData
import SwiftUI

/// Cards for one channel, or for every channel when `channelID` is nil. Newest first.
struct FeedView: View {
  let channelID: Channel.ID?

  @FetchAll private var items: [FeedItem]

  var body: some View {
    Group {
      if items.isEmpty {
        ContentUnavailableView(
          "No items yet",
          systemImage: "tray",
          description: Text("Items appear here as the collector fetches them.")
        )
      } else {
        List(items) { item in
          FeedCard(item: item)
            .listRowSeparator(.hidden)
        }
        .listStyle(.plain)
      }
    }
    .task(id: channelID) {
      _ = await withErrorReporting {
        try await $items.load(Self.query(channelID: channelID), animation: .default)
      }
    }
  }

  static let pageSize = 200

  static func query(channelID: Channel.ID?) -> some Statement<FeedItem> {
    FeedItem
      .where {
        if let channelID {
          $0.sourceID.in(
            ChannelSource.where { $0.channelID.eq(channelID) }.select(\.sourceID)
          )
        }
      }
      .order { $0.publishedAt.desc() }
      .limit(pageSize)
      .select { $0 }
  }
}
