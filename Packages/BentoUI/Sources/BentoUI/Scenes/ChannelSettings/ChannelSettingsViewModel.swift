import BentoData
import Foundation
import Observation
import SQLiteData

/// Channel name and pause switch, its sources with collector status, and the destinations its
/// new items are posted to.
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
  /// Set on the new source before its first fetch, which can follow within seconds.
  var newSourceSkipsBacklog = false
  /// The source being edited, shown as a sheet over the channel settings.
  var sourceEditor: SourceEditorViewModel?
  var newDestinationKind: Destination.Kind = .discord
  var newDestinationName = ""
  /// The webhook URL or bot token, saved to the collector's Keychain.
  var newDestinationSecret = ""
  var newDestinationChatID = ""
  private(set) var destinationMessage: String?
  /// Plugin ID → which of its secrets are set, for plugins that need a sign-in.
  private(set) var secretStatus: [String: [String: Bool]] = [:]
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchOne var channel: Channel?
  @ObservationIgnored @FetchAll var sources: [Source]
  @ObservationIgnored @FetchAll var destinations: [Destination]
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let statuses: any SourceStatusProviding
  @ObservationIgnored let collector: (any CollectorControlling)?
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
      try await $destinations.load(Destination.where { $0.channelID.eq(channelID) }.order(by: \.name))
      name = channel?.name ?? ""
    }
    await refreshSignIns()
  }

  /// Reads which plugins are signed in, so only usable ones are offered as sources.
  func refreshSignIns() async {
    guard let collector else { return }
    for plugin in collector.plugins where plugin.authRequired && (plugin.hasInteractiveLogin || !plugin.secretFields.isEmpty) {
      if let status = try? await collector.secretStatus(pluginID: plugin.id) {
        secretStatus[plugin.id] = status
      }
    }
    // A plugin that is no longer offered (signed out meanwhile) must not stay selected.
    if !availablePlugins.contains(where: { $0.id == newSourcePluginID }) {
      newSourcePluginID = availablePlugins.first?.id ?? "rss"
    }
  }


  /// Source types that can be added, or RSS without a collector. On the collector Mac, which does
  /// the fetching, only plugins that are ready (programs installed, sign-in set if needed); another
  /// Mac cannot tell what the collector has, so it lists every source plugin.
  var availablePlugins: [PluginInfo] {
    let loaded = collector?.plugins.filter { $0.isSource && $0.loadError == nil } ?? []
    let offered = filtersByReadiness ? loaded.filter { $0.isReady(secretStatus: secretStatus[$0.id]) } : loaded
    return offered.isEmpty ? [.rss] : offered
  }

  /// Source plugins left out because they still need setting up on this, the collector, Mac.
  var pluginsNeedingSetup: [PluginInfo] {
    guard filtersByReadiness else { return [] }
    return (collector?.plugins ?? []).filter {
      $0.isSource && $0.loadError == nil && !$0.isReady(secretStatus: secretStatus[$0.id])
    }
  }

  private var filtersByReadiness: Bool { collector?.isThisMacCollector ?? false }

  /// The loaded plugins, to refresh sign-in status when the collector's catalog arrives.
  var pluginIDs: [String] { collector?.plugins.map(\.id) ?? [] }

  var newSourcePlugin: PluginInfo? {
    availablePlugins.first { $0.id == newSourcePluginID } ?? availablePlugins.first
  }

  var canAddSource: Bool { newSourcePlugin?.accepts(query: newSourceQuery) ?? false }

  func status(for source: Source) -> SourceStatus? {
    statuses.status(for: source.id)
  }

  func pluginName(for source: Source) -> String {
    (collector?.plugins ?? [.rss]).first { $0.id == source.pluginID }?.name ?? source.pluginID
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
      try store.addSource(
        channelID: channelID,
        pluginID: plugin.id,
        query: newSourceQuery,
        name: nil,
        skipInitialBacklog: newSourceSkipsBacklog
      )
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

  // MARK: Destinations

  /// Destinations are set up on the collector Mac, which posts with their secrets. With iCloud
  /// Keychain on, those secrets reach the user's other Macs for a later takeover; a Mac cannot
  /// tell whether iCloud Keychain is on, so entering them elsewhere is not offered.
  var canManageDestinations: Bool { collector?.isThisMacCollector ?? false }

  var canAddDestination: Bool {
    let filled = { (text: String) in !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let kind = newDestinationKind
    return canManageDestinations && (!kind.needsSecret || filled(newDestinationSecret))
      && (!kind.needsChat || filled(newDestinationChatID))
  }

  /// Saves the secret first, so a destination never exists without one.
  func addDestination() async {
    guard let collector, canAddDestination else { return }
    let id = UUID()
    let kind = newDestinationKind
    let name = newDestinationName.trimmingCharacters(in: .whitespacesAndNewlines)
    let chatID = newDestinationChatID.trimmingCharacters(in: .whitespacesAndNewlines)
    do {
      if kind.needsSecret {
        try await collector.setSecret(
          pluginID: Destination.secretNamespace,
          key: id.uuidString.lowercased(),
          value: newDestinationSecret.trimmingCharacters(in: .whitespacesAndNewlines)
        )
      }
      try store.addDestination(
        id: id,
        channelID: channelID,
        kind: kind,
        name: name.isEmpty ? kind.label : name,
        chatID: kind.needsChat ? chatID : nil
      )
      newDestinationName = ""
      newDestinationSecret = ""
      newDestinationChatID = ""
      destinationMessage = nil
    } catch {
      destinationMessage = error.localizedDescription
    }
  }

  func update(_ destination: Destination) {
    withErrorReporting { try store.updateDestination(destination) }
  }

  func replaceSecret(of destination: Destination, with value: String) async {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let collector, canManageDestinations, !value.isEmpty else { return }
    do {
      try await collector.setSecret(pluginID: Destination.secretNamespace, key: destination.secretKey, value: value)
      destinationMessage = nil
    } catch {
      destinationMessage = error.localizedDescription
    }
  }

  func delete(_ destination: Destination) async {
    withErrorReporting { try store.deleteDestination(destination.id) }
    guard destination.kind.needsSecret else { return }
    try? await collector?.deleteSecret(pluginID: Destination.secretNamespace, key: destination.secretKey)
  }

  func done() {
    saveName()
    onAction(.dismiss)
  }
}

extension Destination.Kind {
  static let addable: [Self] = [.discord, .telegramBot, .telegramAccount, .x]

  /// A webhook URL or bot token; posting as you uses the Telegram or X plugin's sign-in instead.
  var needsSecret: Bool { self == .discord || self == .telegramBot }
  var needsChat: Bool { self == .telegramBot || self == .telegramAccount }

  var label: String {
    switch self {
    case .discord: "Discord"
    case .telegramBot: "Telegram bot"
    case .telegramAccount: "Telegram (as you)"
    case .x: "X (as you)"
    }
  }

  /// What the secret field asks for.
  var secretPrompt: String {
    switch self {
    case .discord: "Webhook URL"
    case .telegramBot: "Bot token"
    case .telegramAccount, .x: ""
    }
  }

  var chatPrompt: String {
    self == .telegramAccount ? "me, @channel or t.me/c/<id>" : "Chat ID or @channel"
  }
}
