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

  /// Every source type: the collector's loaded source plugins, or RSS without one.
  var plugins: [PluginInfo] {
    let loaded = collector?.plugins.filter { $0.isSource && $0.loadError == nil } ?? []
    return loaded.isEmpty ? [.rss] : loaded
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
    return Setup(
      missingPrograms: plugin.requirements.filter { !$0.installed },
      needsSignIn: Self.needsAuth(plugin) && !plugin.isSignedIn(secretStatus[plugin.id])
    )
  }

  private static func needsAuth(_ plugin: PluginInfo) -> Bool {
    plugin.authRequired && (plugin.hasInteractiveLogin || !plugin.secretFields.isEmpty)
  }

  func load() async {
    await refreshSignIns()
  }

  func refreshSignIns() async {
    guard let collector, checksSetup else { return }
    for plugin in plugins where Self.needsAuth(plugin) {
      if let status = try? await collector.secretStatus(pluginID: plugin.id) {
        secretStatus[plugin.id] = status
      }
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
    }
    await continueIfReady()
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
    await collector.refreshPlugins()
    await continueIfReady()
  }

  /// Re-reads the plugin's sign-in and goes on to the details once nothing is missing.
  func continueIfReady() async {
    await refreshSignIns()
    guard case .setup = step, let plugin, setup(for: plugin).isComplete else { return }
    step = .details(pluginID: plugin.id)
  }

  var canAdd: Bool {
    guard case .details = step, let plugin else { return false }
    return plugin.accepts(query: query)
  }

  func add() {
    guard canAdd, let plugin else { return }
    withErrorReporting {
      try store.addSource(
        channelID: channelID,
        pluginID: plugin.id,
        query: query,
        name: name.trimmingCharacters(in: .whitespaces),
        intervalMinutes: plugin.defaultIntervalMinutes,
        skipInitialBacklog: skipsBacklog
      )
    }
    onAction(.dismiss)
  }

  func cancel() {
    login?.close()
    onAction(.dismiss)
  }
}
