import BentoData
import Foundation
import Observation
import SQLiteData

/// Channel name and pause switch, and its sources with collector status.
@MainActor
@Observable
public final class ChannelSettingsViewModel: Identifiable {
  public enum Action: Equatable {
    case dismiss
  }

  public let channelID: Channel.ID
  public nonisolated var id: Channel.ID { channelID }
  var name = ""
  var newFeedURL = ""
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchOne var channel: Channel?
  @ObservationIgnored @FetchAll var sources: [Source]
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let statuses: any SourceStatusProviding

  static let intervals = [10, 15, 30, 60, 120, 360]

  init(channelID: Channel.ID, store: any LibraryStoring, statuses: any SourceStatusProviding) {
    self.channelID = channelID
    self.store = store
    self.statuses = statuses
  }

  func load() async {
    _ = await withErrorReporting {
      try await $channel.load(Channel.find(channelID))
      try await $sources.load(
        Source
          .where { $0.id.in(ChannelSource.where { $0.channelID.eq(channelID) }.select(\.sourceID)) }
          .order(by: \.name)
          .select { $0 }
      )
      name = channel?.name ?? ""
    }
  }

  var canAddFeed: Bool { Self.feedURL(newFeedURL) != nil }

  func status(for source: Source) -> SourceStatus? {
    statuses.status(for: source.id)
  }

  func saveName() {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard var channel, !trimmed.isEmpty, trimmed != channel.name else { return }
    channel.name = trimmed
    withErrorReporting { try store.updateChannel(channel) }
  }

  func setEnabled(_ enabled: Bool) {
    guard var channel else { return }
    channel.isEnabled = enabled
    withErrorReporting { try store.updateChannel(channel) }
  }

  func addFeed() {
    guard let url = Self.feedURL(newFeedURL) else { return }
    withErrorReporting { try store.addFeed(channelID: channelID, url: url) }
    newFeedURL = ""
  }

  func update(_ source: Source) {
    withErrorReporting { try store.updateSource(source) }
  }

  func delete(_ source: Source) {
    withErrorReporting { try store.deleteSource(source.id) }
  }

  func done() {
    saveName()
    onAction(.dismiss)
  }

  nonisolated static func feedURL(_ text: String) -> URL? {
    guard let url = URL(string: text.trimmingCharacters(in: .whitespaces)),
      ["http", "https"].contains(url.scheme?.lowercased()), url.host() != nil
    else { return nil }
    return url
  }
}
