import BentoData
import Foundation
import Observation
import SQLiteData

/// Adding a source in three steps: choose a plugin; set it up when it still misses a program or a
/// sign-in; enter the query. A plugin that is ready skips the setup.
@MainActor
@Observable
public final class AddSourceViewModel: Identifiable {
  public enum Action: Equatable {
    case dismiss
  }

  enum Step: Equatable {
    case choose
    case setup(pluginID: String)
    case details(pluginID: String)
  }

  /// What a plugin still needs before the collector can fetch with it.
  struct Setup: Equatable {
    var missingPrograms: [PluginInfo.Requirement]
    var needsSignIn: Bool
    /// Its sign-in status has not been read yet.
    var isChecking = false
    var isComplete: Bool { missingPrograms.isEmpty && !needsSignIn }
  }

  public let id = UUID()
  let channelID: Channel.ID
  private(set) var step: Step = .choose
  var query = ""
  var name = ""
  /// Set on the new source before its first fetch, which can follow within seconds.
  var skipsBacklog = false
  /// Values typed for the plugin's secret fields, by key.
  var secretValues: [String: String] = [:]
  var login: LoginViewModel?
  private(set) var secretStatus: [String: [String: Bool]] = [:]
  private(set) var message: String?
  private(set) var isWorking = false
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored let collector: (any CollectorControlling)?

  init(channelID: Channel.ID, store: any LibraryStoring, collector: (any CollectorControlling)?) {
    self.channelID = channelID
    self.store = store
    self.collector = collector
  }

  /// Every source type: the collector's loaded source plugins, or RSS without one, in
  /// `SourceIcon.order`.
  var plugins: [PluginInfo] {
    let loaded = collector?.plugins.filter { $0.isSource && $0.loadError == nil } ?? []
    let rank = { (plugin: PluginInfo) in SourceIcon.order.firstIndex(of: plugin.id) ?? SourceIcon.order.count }
    return (loaded.isEmpty ? [.rss] : loaded).sorted {
      (rank($0), $0.name.localizedLowercase) < (rank($1), $1.name.localizedLowercase)
    }
  }

  /// Typed into the list's search field.
  var search = ""

  /// The plugins the list shows: those matching `search`, ready ones first when this Mac checks
  /// setup. One untitled group otherwise.
  var groups: [(title: String?, plugins: [PluginInfo])] {
    let term = search.trimmingCharacters(in: .whitespaces)
    let shown = term.isEmpty ? plugins : plugins.filter {
      $0.name.localizedCaseInsensitiveContains(term) || $0.summary.localizedCaseInsensitiveContains(term)
    }
    guard checksSetup else { return shown.isEmpty ? [] : [(nil, shown)] }
    let ready = shown.filter { setup(for: $0).isComplete }
    let other = shown.filter { !setup(for: $0).isComplete }
    return [("Ready to add", ready), ("Needs setup", other)].filter { !$0.plugins.isEmpty }
  }

  /// Only the collector Mac fetches and keeps the sign-ins, so only it checks and sets them up.
  var checksSetup: Bool { collector?.isThisMacCollector ?? false }

  var plugin: PluginInfo? {
    switch step {
    case .choose: nil
    case .setup(let id), .details(let id): plugins.first { $0.id == id }
    }
  }

  func setup(for plugin: PluginInfo) -> Setup {
    guard checksSetup else { return Setup(missingPrograms: [], needsSignIn: false) }
    let needsAuth = Self.needsAuth(plugin)
    return Setup(
      missingPrograms: plugin.requirements.filter { !$0.installed },
      needsSignIn: needsAuth && !plugin.isSignedIn(secretStatus[plugin.id]),
      isChecking: needsAuth && secretStatus[plugin.id] == nil
    )
  }

  private static func needsAuth(_ plugin: PluginInfo) -> Bool {
    plugin.authRequired && (plugin.hasInteractiveLogin || !plugin.secretFields.isEmpty)
  }

  /// Reads sign-ins, and moves a setup step opened before they arrived on when nothing is
  /// missing. Runs again when the plugins or this Mac's role change (`refreshKey`).
  func load() async {
    await refreshSignIns()
    advanceIfReady()
  }

  /// Changes when the sign-ins should be read again: the collector's catalog arrived, or this Mac
  /// became (or stopped being) the collector.
  var refreshKey: String {
    "\(checksSetup)|" + plugins.map(\.id).joined(separator: ",")
  }

  func refreshSignIns() async {
    guard let collector, checksSetup else { return }
    for plugin in plugins where Self.needsAuth(plugin) {
      // A failed read counts as nothing set, so the row stops showing it is checking.
      secretStatus[plugin.id] = (try? await collector.secretStatus(pluginID: plugin.id)) ?? [:]
    }
  }

  func choose(_ plugin: PluginInfo) {
    query = ""
    name = ""
    secretValues = [:]
    message = nil
    step = setup(for: plugin).isComplete ? .details(pluginID: plugin.id) : .setup(pluginID: plugin.id)
  }

  func back() {
    message = nil
    step = .choose
  }

  var canSaveSecrets: Bool {
    guard let plugin else { return false }
    return plugin.secretFields.contains { !secretValues[$0.key, default: ""].trimmingCharacters(in: .whitespaces).isEmpty }
  }

  /// Saves what was typed, then moves on once nothing is missing.
  func saveSecrets() async {
    guard let collector, let plugin else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      for field in plugin.secretFields {
        let value = secretValues[field.key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
        if !value.isEmpty {
          try await collector.setSecret(pluginID: plugin.id, key: field.key, value: value)
        }
      }
      message = nil
    } catch {
      message = error.localizedDescription
      return
    }
    await continueIfReady()
    let status = secretStatus[plugin.id] ?? [:]
    let missing = plugin.secretFields.filter { status[$0.key] != true }.map(\.label)
    if step == .setup(pluginID: plugin.id), !missing.isEmpty {
      message = "Still missing: \(missing.formatted())."
    }
  }

  /// Starts the plugin's interactive login (QR code, phone code).
  func signIn() {
    guard let collector, let plugin else { return }
    let login = LoginViewModel(pluginName: plugin.name, session: collector.startLogin(pluginID: plugin.id))
    login.onFinish = { [weak self] in
      self?.login = nil
      Task { await self?.continueIfReady() }
    }
    self.login = login
  }

  /// Checks the plugins' programs again, after the user installed one.
  func checkAgain() async {
    guard let collector else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      try await collector.refreshPlugins()
      message = nil
    } catch {
      message = error.localizedDescription
    }
    await continueIfReady()
  }

  /// Re-reads the plugin's sign-in and goes on to the details once nothing is missing.
  func continueIfReady() async {
    await refreshSignIns()
    advanceIfReady()
  }

  private func advanceIfReady() {
    guard case .setup = step, let plugin, setup(for: plugin).isComplete else { return }
    step = .details(pluginID: plugin.id)
  }

  var canAdd: Bool {
    guard case .details = step, let plugin else { return false }
    return plugin.accepts(query: query)
  }

  /// Set for a channel not saved yet: `add()` hands the source here instead of saving it.
  @ObservationIgnored var onDraft: ((Source) -> Void)?

  /// Adds the source on the plugin's default interval, and on the collector Mac fetches it right
  /// away instead of waiting for the next pass.
  func add() {
    guard canAdd, let plugin else { return }
    if let onDraft {
      let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
      let name = name.trimmingCharacters(in: .whitespaces)
      onDraft(
        Mutations.newSource(
          pluginID: plugin.id,
          name: name.isEmpty ? NativeLibraryStore.defaultName(pluginID: plugin.id, query: query) : name,
          query: query,
          intervalMinutes: max(plugin.defaultIntervalMinutes, 1),
          skipInitialBacklog: skipsBacklog
        )
      )
      onAction(.dismiss)
      return
    }
    let id = withErrorReporting {
      try store.addSource(
        channelID: channelID,
        pluginID: plugin.id,
        query: query,
        name: name.trimmingCharacters(in: .whitespaces),
        intervalMinutes: plugin.defaultIntervalMinutes,
        skipInitialBacklog: skipsBacklog
      )
    }
    if let id, let collector, collector.isThisMacCollector {
      // Outlives the sheet; a failure shows on the source like any scheduled run's.
      firstFetch = Task { _ = try? await collector.fetchNow(sourceID: id) }
    }
    onAction(.dismiss)
  }

  /// The fetch `add()` started, kept for tests.
  @ObservationIgnored private(set) var firstFetch: Task<Void, Never>?

  func cancel() {
    login?.close()
    onAction(.dismiss)
  }
}
