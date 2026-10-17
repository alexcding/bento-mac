import BentoData
import Foundation
import Observation
import SQLiteData

public enum SidebarDestination: Hashable, Sendable {
  case all
  case bookmarks
  case channel(Channel.ID)

  var channelID: Channel.ID? {
    if case .channel(let id) = self { id } else { nil }
  }
}

@MainActor
@Observable
public final class SidebarViewModel {
  public enum Action: Equatable {
    case selected(SidebarDestination)
    case openChannelSettings(Channel.ID)
  }

  public var selection: SidebarDestination = .all {
    didSet { if selection != oldValue { onAction(.selected(selection)) } }
  }
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored
  @FetchAll(
    Channel
      .group(by: \.id)
      .order(by: \.position)
      .leftJoin(ChannelSource.all) { $0.id.eq($1.channelID) }
      .leftJoin(FeedItem.all) { $1.sourceID.eq($2.sourceID) }
      .leftJoin(ReadState.all) { $2.id.eq($3.feedItemID) }
      .select {
        ChannelRow.Columns(
          channel: $0,
          sourceCount: $1.id.count(distinct: true),
          unreadCount: $2.id.count(distinct: true, filter: $3.feedItemID.is(nil))
        )
      },
    animation: .default
  )
  var rows: [ChannelRow]

  @ObservationIgnored
  @FetchOne(FeedItem.where { !$0.id.in(ReadState.select(\.feedItemID)) }.count())
  var unreadTotal = 0

  @ObservationIgnored
  @FetchOne(Bookmark.count())
  var bookmarkCount = 0

  @ObservationIgnored private let store: any LibraryStoring

  init(store: any LibraryStoring) {
    self.store = store
  }

  func addChannel() {
    withErrorReporting {
      let id = try store.addChannel(name: "New channel")
      selection = .channel(id)
      onAction(.openChannelSettings(id))
    }
  }

  func openSettings(_ channel: Channel) {
    onAction(.openChannelSettings(channel.id))
  }

  func toggleEnabled(_ channel: Channel) {
    var channel = channel
    channel.isEnabled.toggle()
    withErrorReporting { try store.updateChannel(channel) }
  }

  func delete(_ channel: Channel) {
    if selection == .channel(channel.id) { selection = .all }
    withErrorReporting { try store.deleteChannel(channel.id) }
  }
}

@Selection
struct ChannelRow: Identifiable {
  let channel: Channel
  let sourceCount: Int
  let unreadCount: Int
  var id: Channel.ID { channel.id }
}
