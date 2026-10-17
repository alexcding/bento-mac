import BentoData
import Foundation
import Observation
import SQLiteData

/// App settings: collector options, plugins and their logins (Mac), AI profiles and tasks.
@MainActor
@Observable
public final class SettingsViewModel {
  public enum Tab: String, CaseIterable, Identifiable, Sendable {
    case general = "General"
    case plugins = "Plugins"
    case ai = "AI"
    public var id: Self { self }
  }

  var tab: Tab = .general
  var editingProfile: AiProfile?
  var editingTask: AiTask?
  var login: LoginViewModel?
  /// Plugin ID → which secrets are set.
  private(set) var secretStatus: [String: [String: Bool]] = [:]
  private(set) var message: String?

  @ObservationIgnored @FetchOne(AppSettings.find(AppSettings.singletonID)) var storedSettings: AppSettings?
  @ObservationIgnored @FetchAll(AiProfile.order(by: \.position)) var profiles: [AiProfile]
  @ObservationIgnored @FetchAll(AiTask.order(by: \.position)) var tasks: [AiTask]
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored let collector: (any CollectorControlling)?

  init(store: any LibraryStoring, collector: (any CollectorControlling)?) {
    self.store = store
    self.collector = collector
  }

  var tabs: [Tab] { collector == nil ? [.general, .ai] : Tab.allCases }
  var settings: AppSettings { storedSettings ?? AppSettings() }
  var plugins: [PluginInfo] { collector?.plugins ?? [] }

  // MARK: General

  func updateSettings(_ change: (inout AppSettings) -> Void) {
    var settings = settings
    change(&settings)
    withErrorReporting { try store.saveSettings(settings) }
  }

  // MARK: Plugins

  func refreshSecrets(for plugin: PluginInfo) async {
    guard let collector, !plugin.secretFields.isEmpty || plugin.hasInteractiveLogin else { return }
    if let status = try? await collector.secretStatus(pluginID: plugin.id) {
      secretStatus[plugin.id] = status
    }
  }

  func isSignedIn(_ plugin: PluginInfo) -> Bool {
    guard let status = secretStatus[plugin.id] else { return false }
    return plugin.hasInteractiveLogin ? status.values.contains(true) : !status.isEmpty && status.values.allSatisfy { $0 }
  }

  func saveSecret(_ value: String, key: String, plugin: PluginInfo) async {
    guard let collector, !value.isEmpty else { return }
    do {
      try await collector.setSecret(pluginID: plugin.id, key: key, value: value)
      message = nil
    } catch {
      message = error.localizedDescription
    }
    await refreshSecrets(for: plugin)
  }

  func signOut(_ plugin: PluginInfo) async {
    guard let collector else { return }
    let keys = plugin.hasInteractiveLogin ? plugin.interactiveSecretKeys : plugin.secretFields.map(\.key)
    for key in keys {
      try? await collector.deleteSecret(pluginID: plugin.id, key: key)
    }
    await refreshSecrets(for: plugin)
  }

  func signIn(_ plugin: PluginInfo) {
    guard let collector else { return }
    let model = LoginViewModel(pluginName: plugin.name, session: collector.startLogin(pluginID: plugin.id))
    model.onFinish = { [weak self] in
      self?.login = nil
      Task { await self?.refreshSecrets(for: plugin) }
    }
    login = model
  }

  // MARK: AI

  /// API keys of HTTP profiles are secrets of the pseudo-plugin `ai`, keyed by profile ID.
  static let aiSecretNamespace = "ai"

  func newProfile() {
    var profile = AiProfile()
    profile.name = "New profile"
    profile.position = profiles.count
    editingProfile = profile
  }

  func save(_ profile: AiProfile, apiKey: String) {
    withErrorReporting { try store.saveAiProfile(profile) }
    if profile.kind == .http, !apiKey.isEmpty, let collector {
      Task {
        do {
          try await collector.setSecret(pluginID: Self.aiSecretNamespace, key: profile.id.uuidString.lowercased(), value: apiKey)
        } catch {
          message = error.localizedDescription
        }
      }
    }
    editingProfile = nil
  }

  func delete(_ profile: AiProfile) {
    withErrorReporting { try store.deleteAiProfile(profile.id) }
    if let collector {
      Task { try? await collector.deleteSecret(pluginID: Self.aiSecretNamespace, key: profile.id.uuidString.lowercased()) }
    }
  }

  /// The stored task for a preset key, if the user customized it.
  func customized(_ key: String) -> AiTask? {
    tasks.first { $0.key == key }
  }

  var customTasks: [AiTask] {
    tasks.filter { !AiPresets.keys.contains($0.key) }
  }

  func editPreset(_ key: String) {
    editingTask = customized(key) ?? AiPresets.task(key, position: tasks.count)
  }

  func newTask() {
    var task = AiTask()
    task.name = "New task"
    task.outputs = [.init(name: "result", target: "summary", description: "")]
    task.position = tasks.count
    editingTask = task
  }

  func save(_ task: AiTask) {
    withErrorReporting { try store.saveAiTask(task) }
    editingTask = nil
  }

  func delete(_ task: AiTask) {
    withErrorReporting { try store.deleteAiTask(task.id) }
  }
}

/// The built-in tasks, as editable copies. The collector runs its own preset text until the user
/// saves a customized version.
enum AiPresets {
  static let keys = ["translate", "summarize"]

  static func name(_ key: String) -> String {
    key == "translate" ? "Translate to Simplified Chinese" : "Summarize"
  }

  static func task(_ key: String, position: Int) -> AiTask {
    var task = AiTask()
    task.key = key
    task.name = name(key)
    task.position = position
    if key == "translate" {
      task.instructions = """
        Translate each item into Simplified Chinese. Keep names, numbers and links exact. If an item is \
        already in Simplified Chinese, return its text unchanged. Translate the detail as clean Markdown and \
        drop navigation, ads and boilerplate; return an empty string when there is no detail.
        """
      task.outputs = [
        .init(name: "title", target: "translated_title", description: "The title translated; for items without a title, the first sentence of the text translated."),
        .init(name: "detail", target: "detail", description: "The detail translated as Markdown, or an empty string."),
      ]
    } else {
      task.instructions = """
        Summarize what each item says in one or two factual sentences, in the same language as the item. \
        Use the title, text and detail. Write about the content itself: never mention the item, its fields, \
        links or missing information. No opinions or marketing words.
        """
      task.outputs = [.init(name: "summary", target: "summary", description: "One or two sentence factual summary.")]
      task.batchSize = 4
    }
    return task
  }
}
