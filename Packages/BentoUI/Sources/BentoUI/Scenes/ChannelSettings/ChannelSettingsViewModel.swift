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
  var newSourcePluginID = "rss"
  var newSourceQuery = ""
  /// The source being edited, shown as a sheet over the channel settings.
  var sourceEditor: SourceEditorViewModel?
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchOne var channel: Channel?
  @ObservationIgnored @FetchAll var sources: [Source]
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let statuses: any SourceStatusProviding
  @ObservationIgnored private let collector: (any CollectorControlling)?
  @ObservationIgnored private let sourceEditors: any SourceEditorFeatureFactory

  init(
    channelID: Channel.ID,
    store: any LibraryStoring,
    statuses: any SourceStatusProviding,
    collector: (any CollectorControlling)?,
    sourceEditors: any SourceEditorFeatureFactory
  ) {
    self.channelID = channelID
    self.store = store
    self.statuses = statuses
    self.collector = collector
    self.sourceEditors = sourceEditors
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

  /// Source types that can be added: the collector's loaded source plugins, or RSS without one.
  var availablePlugins: [PluginInfo] {
    let loaded = collector?.plugins.filter { $0.isSource && $0.loadError == nil } ?? []
    return loaded.isEmpty ? [.rss] : loaded
  }

  var newSourcePlugin: PluginInfo? {
    availablePlugins.first { $0.id == newSourcePluginID } ?? availablePlugins.first
  }

  var canAddSource: Bool { newSourcePlugin?.accepts(query: newSourceQuery) ?? false }

  func status(for source: Source) -> SourceStatus? {
    statuses.status(for: source.id)
  }

  func pluginName(for source: Source) -> String {
    availablePlugins.first { $0.id == source.pluginID }?.name ?? source.pluginID
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

  func addSource() {
    guard let plugin = newSourcePlugin, plugin.accepts(query: newSourceQuery) else { return }
    withErrorReporting {
      try store.addSource(channelID: channelID, pluginID: plugin.id, query: newSourceQuery, name: nil)
    }
    newSourceQuery = ""
  }

  func update(_ source: Source) {
    withErrorReporting { try store.updateSource(source) }
  }

  func delete(_ source: Source) {
    withErrorReporting { try store.deleteSource(source.id) }
  }

  func edit(_ source: Source) {
    let editor = sourceEditors.makeSourceEditor(sourceID: source.id)
    editor.onAction = { [weak self] action in
      switch action {
      case .dismiss: self?.sourceEditor = nil
      }
    }
    sourceEditor = editor
  }

  func done() {
    saveName()
    onAction(.dismiss)
  }
}
