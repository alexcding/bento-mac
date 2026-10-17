import BentoData
import Foundation

/// What only the Mac can do: talk to the collector daemon. The Mac app provides it; iOS does not,
/// and screens hide what needs it.
@MainActor
public protocol CollectorControlling: AnyObject {
  /// Plugins the collector loaded (or failed to load), refreshed as it republishes its catalog.
  var plugins: [PluginInfo] { get }
  /// Whether this Mac is the one collector. Other Macs only read what it collects; the synced
  /// `AppSettings.collectorDeviceName` says which Mac that is.
  var isThisMacCollector: Bool { get }
  /// Whether sign-ins and destination secrets are in iCloud Keychain, shared with the user's
  /// other Macs (a build signed with a developer team). Otherwise they stay on this Mac.
  var secretsSynced: Bool { get }
  /// Moves collecting and publishing to this Mac. Items already in the library count as
  /// collected, so none is processed or published again.
  func becomeCollector() async throws
  /// Which of a plugin's secrets are set. Values never leave the collector.
  func secretStatus(pluginID: String) async throws -> [String: Bool]
  func setSecret(pluginID: String, key: String, value: String) async throws
  func deleteSecret(pluginID: String, key: String) async throws
  /// Starts an interactive login (QR code, phone code).
  func startLogin(pluginID: String) -> any LoginSession
  /// Runs a source now, whatever its schedule. Only on the collector Mac.
  func fetchNow(sourceID: Source.ID) async throws -> RunSummary
  /// What a source's next run would add, without storing anything.
  func preview(sourceID: Source.ID) async throws -> PreviewResult
}

/// One login in progress.
@MainActor
public protocol LoginSession: AnyObject {
  var events: AsyncStream<LoginEvent> { get }
  /// Sends what the user typed for a text or password prompt.
  func send(_ input: String)
  func cancel()
}

public enum LoginEvent: Equatable, Sendable {
  case prompt(kind: PromptKind, message: String, qr: String?)
  case done
  case failed(String)

  public enum PromptKind: String, Equatable, Sendable {
    case qr, text, password
  }
}

public struct RunSummary: Equatable, Sendable {
  public var fetched = 0
  public var new = 0
  public var backlogSkipped = 0
  public var aiFailures: [String] = []
  public var error: String?

  public init(fetched: Int = 0, new: Int = 0, backlogSkipped: Int = 0, aiFailures: [String] = [], error: String? = nil) {
    self.fetched = fetched
    self.new = new
    self.backlogSkipped = backlogSkipped
    self.aiFailures = aiFailures
    self.error = error
  }
}

public struct PreviewResult: Equatable, Sendable {
  public var items: [FeedItem]
  public var aiFailures: [String]
  /// Existing posts a first run would skip (the source skips its backlog).
  public var backlogSkipped: Int

  public init(items: [FeedItem], aiFailures: [String], backlogSkipped: Int = 0) {
    self.items = items
    self.aiFailures = aiFailures
    self.backlogSkipped = backlogSkipped
  }
}

/// A plugin as Settings shows it, decoded from the manifest the collector publishes.
public struct PluginInfo: Identifiable, Hashable, Sendable {
  public let id: String
  public var name: String
  public var version: String
  public var summary: String
  public var isSource: Bool
  public var queryHint: String?
  public var defaultIntervalMinutes: Int
  public var secretFields: [SecretField]
  /// Signs in through `startLogin` (QR or phone code) rather than typed secrets.
  public var hasInteractiveLogin: Bool
  public var interactiveSecretKeys: [String]
  public var requirements: [Requirement]
  /// Why the plugin did not load.
  public var loadError: String?

  public struct SecretField: Hashable, Sendable {
    public var key: String
    public var label: String
    public var help: String?
  }

  public struct Requirement: Hashable, Sendable {
    public var name: String
    public var installed: Bool
    public var detail: String
    public var install: String
  }

  /// Decodes the collector's catalog row: `plugin.json` and the requirement statuses.
  public init(id: String, name: String, version: String, manifest: Data, requirements: Data, error: String?) {
    let json = (try? JSONSerialization.jsonObject(with: manifest)) as? [String: Any] ?? [:]
    let source = json["source"] as? [String: Any]
    let auth = json["auth"] as? [String: Any] ?? [:]
    let capabilities = json["capabilities"] as? [String] ?? []
    self.id = (json["id"] as? String) ?? id
    self.name = name
    self.version = version
    summary = json["description"] as? String ?? ""
    isSource = capabilities.contains("source") && source != nil
    queryHint = source?["query_hint"] as? String
    defaultIntervalMinutes = source?["default_interval_minutes"] as? Int ?? 30
    secretFields = (auth["kind"] as? String == "secrets" ? auth["fields"] as? [[String: Any]] : nil)?.compactMap {
      guard let key = $0["key"] as? String else { return nil }
      return SecretField(key: key, label: $0["label"] as? String ?? key, help: $0["help"] as? String)
    } ?? []
    hasInteractiveLogin = auth["kind"] as? String == "interactive"
    interactiveSecretKeys = hasInteractiveLogin ? auth["secrets"] as? [String] ?? [] : []
    self.requirements = ((try? JSONSerialization.jsonObject(with: requirements)) as? [[String: Any]] ?? []).map {
      Requirement(
        name: $0["name"] as? String ?? "",
        installed: $0["installed"] as? Bool ?? false,
        detail: $0["detail"] as? String ?? "",
        install: $0["install"] as? String ?? ""
      )
    }
    loadError = error
  }

  /// The built-in RSS source, for when no collector is available (iOS).
  public static let rss = PluginInfo(
    id: "rss", name: "RSS / Atom", version: "",
    manifest: Data(#"{"id":"rss","capabilities":["source"],"source":{"default_interval_minutes":30,"query_hint":"Feed URL"}}"#.utf8),
    requirements: Data("[]".utf8), error: nil
  )

  /// Whether a query is acceptable for this plugin. RSS needs a web URL; other plugins accept an
  /// empty query (a default feed) or any text.
  public func accepts(query: String) -> Bool {
    guard id == "rss" else { return true }
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else { return false }
    return ["http", "https"].contains(scheme) && url.host() != nil
  }
}
