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
    /// A new channel was saved.
    case created(Channel.ID)
  }

  public let channelID: Channel.ID
  public nonisolated var id: Channel.ID { channelID }
  var name = ""
  /// Not saved yet: sources and destinations are kept here, and nothing is written until
  /// `create()`.
  private(set) var isNew: Bool
  /// The switch while the channel is new.
  var newIsEnabled = true
  /// A create is running, so a second Return or click does nothing.
  private(set) var isCreating = false
  private(set) var draftSources: [Source] = []
  private(set) var draftDestinations: [Destination] = []
  /// New destinations' webhook URLs or bot tokens, saved to the Keychain on `create()`.
  @ObservationIgnored private var draftSecrets: [Destination.ID: String] = [:]

  var shownSources: [Source] { isNew ? draftSources : sources }
  var shownDestinations: [Destination] { isNew ? draftDestinations : destinations }
  /// The source being edited, shown as a sheet over the channel settings.
  var sourceEditor: SourceEditorViewModel?
  var newDestinationKind: Destination.Kind = .discord
  var newDestinationName = ""
  /// The webhook URL or bot token, saved to the collector's Keychain.
  var newDestinationSecret = ""
  var newDestinationChatID = ""
  private(set) var destinationMessage: String?
  /// Adding a source, shown as a sheet over the channel settings.
  var addSource: AddSourceViewModel?
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchOne var channel: Channel?
  @ObservationIgnored @FetchAll var sources: [Source]
  @ObservationIgnored @FetchAll var destinations: [Destination]
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let statuses: any SourceStatusProviding
  @ObservationIgnored let collector: (any CollectorControlling)?
  @ObservationIgnored private let sourceEditors: any SourceEditorFeatureFactory
  @ObservationIgnored private let addSources: any AddSourceFeatureFactory

  init(
    channelID: Channel.ID,
    isNew: Bool = false,
    store: any LibraryStoring,
    statuses: any SourceStatusProviding,
    collector: (any CollectorControlling)?,
    sourceEditors: any SourceEditorFeatureFactory,
    addSources: any AddSourceFeatureFactory
  ) {
    self.channelID = channelID
    self.isNew = isNew
    self.store = store
    self.statuses = statuses
    self.collector = collector
    self.sourceEditors = sourceEditors
    self.addSources = addSources
  }

  func load() async {
    guard !isNew else { return }
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
  }

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

  func showAddSource() {
    let model = addSources.makeAddSource(channelID: channelID)
    if isNew {
      model.onDraft = { [weak self] in self?.draftSources.append($0) }
    }
    model.onAction = { [weak self] action in
      switch action {
      case .dismiss: self?.addSource = nil
      }
    }
    addSource = model
  }

  func update(_ source: Source) {
    if isNew {
      if let index = draftSources.firstIndex(where: { $0.id == source.id }) { draftSources[index] = source }
      return
    }
    withErrorReporting { try store.updateSource(source) }
  }

  func delete(_ source: Source) {
    if isNew {
      draftSources.removeAll { $0.id == source.id }
      return
    }
    withErrorReporting { try store.deleteSource(source.id) }
  }

  /// Opens the full source editor, which works on saved sources.
  func edit(_ source: Source) {
    guard !isNew else { return }
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
    if isNew {
      draftDestinations.append(
        Destination(id: id, channelID: channelID, kind: kind, name: name.isEmpty ? kind.label : name,
                    chatID: kind.needsChat ? chatID : nil)
      )
      if kind.needsSecret { draftSecrets[id] = newDestinationSecret.trimmingCharacters(in: .whitespacesAndNewlines) }
      newDestinationName = ""
      newDestinationSecret = ""
      newDestinationChatID = ""
      return
    }
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
    if isNew {
      if let index = draftDestinations.firstIndex(where: { $0.id == destination.id }) {
        draftDestinations[index] = destination
      }
      return
    }
    withErrorReporting { try store.updateDestination(destination) }
  }

  func replaceSecret(of destination: Destination, with value: String) async {
    let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let collector, canManageDestinations, !value.isEmpty else { return }
    if isNew {
      draftSecrets[destination.id] = value
      return
    }
    do {
      try await collector.setSecret(pluginID: Destination.secretNamespace, key: destination.secretKey, value: value)
      destinationMessage = nil
    } catch {
      destinationMessage = error.localizedDescription
    }
  }

  func delete(_ destination: Destination) async {
    if isNew {
      draftDestinations.removeAll { $0.id == destination.id }
      draftSecrets[destination.id] = nil
      return
    }
    withErrorReporting { try store.deleteDestination(destination.id) }
    guard destination.kind.needsSecret else { return }
    try? await collector?.deleteSecret(pluginID: Destination.secretNamespace, key: destination.secretKey)
  }

  func done() {
    saveName()
    onAction(.dismiss)
  }

  var canCreate: Bool { !isCreating && !name.trimmingCharacters(in: .whitespaces).isEmpty }

  /// Saves the new channel with everything set up so far, in one write, closes the sheet, and
  /// fetches its sources on the collector Mac.
  func create() async {
    guard isNew, canCreate else { return }
    isCreating = true
    defer { isCreating = false }
    // Secrets first, so a destination never exists without one.
    do {
      for destination in draftDestinations where destination.kind.needsSecret {
        try await collector?.setSecret(
          pluginID: Destination.secretNamespace, key: destination.secretKey, value: draftSecrets[destination.id] ?? ""
        )
      }
    } catch {
      destinationMessage = error.localizedDescription
      return
    }
    let channel = Channel(id: channelID, name: name.trimmingCharacters(in: .whitespaces), isEnabled: newIsEnabled)
    let saved: Bool? = withErrorReporting {
      try store.createChannel(channel, sources: draftSources, destinations: draftDestinations)
      return true
    }
    guard saved == true else { return }
    let created = draftSources
    isNew = false
    draftSecrets = [:]
    onAction(.created(channelID))
    onAction(.dismiss)
    if let collector, collector.isThisMacCollector {
      for source in created {
        Task { _ = try? await collector.fetchNow(sourceID: source.id) }
      }
    }
  }

  /// Closes without saving anything when the channel is new.
  func cancel() {
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
