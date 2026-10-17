import BentoCollectorClient
import BentoData
import BentoUI
import Foundation
import OSLog
import SQLiteData
import ServiceManagement

private let logger = Logger(subsystem: "Bento", category: "Collector")

/// Owns the `bento-collector` LaunchAgent: starts, stops and restarts it, writes its config from
/// the synced database, moves its outbox into the synced database, and reads its status.
/// Lives as long as the app, independent of any window.
///
/// One Mac collects (`AppSettings.collectorDeviceID`); the first to launch claims the role. On any
/// other Mac the agent stays stopped and its config enables no source.
@MainActor
@Observable
final class CollectorService: SourceStatusProviding {
  static let agentLabel = "io.github.alexcding.bento.collector"

  private(set) var agentStatus: SMAppService.Status
  private(set) var lastSync: (date: Date, saved: Int)?
  var lastError: String?
  private(set) var statuses: [Source.ID: SourceStatus] = [:]
  private(set) var plugins: [PluginInfo] = []
  private(set) var isThisMacCollector = false
  /// The collector Mac's name, from the synced settings.
  private(set) var collectorDeviceName: String?
  private(set) var secretsSynced = false

  let dataDirectory: URL
  var collectorURL: URL { dataDirectory.appending(path: "collector.sqlite") }
  var configURL: URL { dataDirectory.appending(path: "collector-config.json") }
  var logURL: URL { dataDirectory.appending(path: "collector.log") }

  @ObservationIgnored private let database: any DatabaseWriter
  @ObservationIgnored private let agent = SMAppService.agent(plistName: "\(agentLabel).plist")
  @ObservationIgnored private let ingestor: OutboxIngestor
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var syncTask: Task<Void, Never>?
  @ObservationIgnored private let device = CollectorDevice.current
  /// Pulls pending iCloud changes; nil when sync is off.
  @ObservationIgnored private let fetchRemoteChanges: (@Sendable () async throws -> Void)?
  @ObservationIgnored private var claimTask: Task<Void, Never>?
  /// Why claiming the role at launch failed; kept until a retry succeeds.
  @ObservationIgnored private var claimError: String?
  /// The collector the agent was last started or stopped for; `.none` before the first sync.
  @ObservationIgnored private var reconciledCollector: UUID?? = .none

  /// Polling interval for config, outbox and status.
  private static let pollInterval = Duration.seconds(5)
  /// Set when the user stops the collector, so launching the app does not restart it.
  private static let stoppedByUserKey = "collectorStoppedByUser"

  init(
    dataDirectory: URL,
    database: any DatabaseWriter,
    fetchRemoteChanges: (@Sendable () async throws -> Void)?
  ) {
    self.dataDirectory = dataDirectory
    self.database = database
    self.fetchRemoteChanges = fetchRemoteChanges
    ingestor = OutboxIngestor(collectorURL: dataDirectory.appending(path: "collector.sqlite"), database: database)
    agentStatus = agent.status
    claimTask = Task { [weak self] in await self?.claimIfUnset() }
    Task { [weak self] in
      let output = try? await CollectorCommand.run(["secrets", "backend"])
      let json = output.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      self?.secretsSynced = json?["synced"] as? Bool ?? false
    }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.sync()
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  func status(for sourceID: Source.ID) -> SourceStatus? {
    statuses[sourceID]
  }

  /// Writes the config, saves pending outbox rows and refreshes status. Runs never overlap: each
  /// call queues one run after the one in flight, so rows written meanwhile are picked up.
  func sync() async {
    let previous = syncTask
    let task = Task {
      await previous?.value
      await performSync()
    }
    syncTask = task
    await task.value
    if syncTask == task { syncTask = nil }
  }

  private func performSync() async {
    let (database, ingestor, configURL, collectorURL, deviceID) = (database, ingestor, configURL, collectorURL, device.id)
    do {
      let result = try await Task.detached(priority: .utility) {
        let (config, settings) = try database.read { db in
          let settings = try Mutations.settings(db)
          return (try CollectorConfigExporter.json(db, collecting: settings.collectorDeviceID == deviceID), settings)
        }
        try CollectorConfigExporter.write(config, to: configURL)
        let saved = try ingestor.ingestPending()
        let statuses = try CollectorStatusReader.read(collectorURL: collectorURL)
        let plugins = try CollectorDiagnostics.plugins(collectorURL: collectorURL)
        return (saved, statuses, plugins, settings)
      }.value
      lastSync = (.now, result.0)
      statuses = result.1
      let plugins = result.2.map {
        PluginInfo(id: $0.id, name: $0.name, version: $0.version, manifest: $0.manifest, requirements: $0.requirements, error: $0.error)
      }
      if plugins != self.plugins { self.plugins = plugins }
      collectorDeviceName = result.3.collectorDeviceName
      let collector = result.3.collectorDeviceID
      isThisMacCollector = collector == deviceID
      lastError = claimError
      if reconciledCollector != .some(collector) {
        reconciledCollector = collector
        await reconcileAgent(collector: collector)
      }
      agentStatus = agent.status
      if result.0 > 0 { logger.info("Saved \(result.0) outbox rows") }
    } catch {
      lastError = error.localizedDescription
      logger.error("Collector sync failed: \(error)")
    }
  }

  /// At launch: claims the collector role when no Mac has it, but only once iCloud has caught up,
  /// so a Mac that has not yet seen the synced settings never takes the role from another.
  /// Retries every minute until it succeeds.
  private func claimIfUnset() async {
    while !Task.isCancelled {
      let database = database
      if (try? await database.read({ try Mutations.settings($0).collectorDeviceID })) != nil {
        claimError = nil
        return
      }
      do {
        try await takeOver(onlyIfUnset: true)
        claimError = nil
        return
      } catch {
        claimError = "Could not set up collecting: \(error.localizedDescription)"
        lastError = claimError
        logger.error("Claiming the collector role failed: \(error)")
      }
      try? await Task.sleep(for: .seconds(60))
    }
  }

  /// Makes this Mac the collector. Its daemon first marks every item already in the library as
  /// seen, so nothing another Mac collected is processed or published again. A launch claim
  /// (`onlyIfUnset`) needs a successful iCloud fetch; a takeover the user asked for does its best.
  func takeOver(onlyIfUnset: Bool) async throws {
    do {
      try await pullRemoteChanges()
    } catch where !onlyIfUnset {
      logger.warning("Fetching iCloud changes failed: \(error)")
    }
    let (database, device) = (database, device)
    if onlyIfUnset, try await database.read({ try Mutations.settings($0).collectorDeviceID }) != nil { return }
    let ids = try await database.read { try Mutations.feedItemIDs($0) }
    _ = try await CollectorCommand.run(
      ["seen", "import"],
      input: Data(ids.map { $0.uuidString.lowercased() }.joined(separator: "\n").utf8)
    )
    _ = try await database.write {
      try Mutations.claimCollector($0, deviceID: device.id, deviceName: device.name, onlyIfUnset: onlyIfUnset)
    }
    if !onlyIfUnset {
      UserDefaults.standard.removeObject(forKey: Self.stoppedByUserKey)
      claimError = nil
    }
    logger.info("This Mac collects now (\(ids.count) items marked seen)")
    await sync()
  }

  /// Fetches pending iCloud changes, giving up after 30 seconds (offline).
  private func pullRemoteChanges() async throws {
    guard let fetchRemoteChanges else { return }
    let fetch = Task { try await fetchRemoteChanges() }
    let timeout = Task {
      try await Task.sleep(for: .seconds(30))
      fetch.cancel()
    }
    defer { timeout.cancel() }
    try await fetch.value
  }

  /// Runs the agent on the collector Mac (unless the user stopped it) and stops it when another
  /// Mac collects. With no collector yet, leaves it as it is.
  private func reconcileAgent(collector: UUID?) async {
    if collector == device.id {
      if agent.status == .notRegistered, !UserDefaults.standard.bool(forKey: Self.stoppedByUserKey) { start() }
    } else if collector != nil, agent.status != .notRegistered {
      do {
        try await agent.unregister()
        logger.info("Stopped the collector: \(self.collectorDeviceName ?? "another Mac") collects")
      } catch {
        lastError = error.localizedDescription
      }
    }
  }

  func start() {
    do {
      try agent.register()
      UserDefaults.standard.removeObject(forKey: Self.stoppedByUserKey)
    } catch {
      lastError = error.localizedDescription
      logger.error("Starting collector failed: \(error)")
    }
    agentStatus = agent.status
  }

  func stop() async {
    do {
      try await agent.unregister()
      UserDefaults.standard.set(true, forKey: Self.stoppedByUserKey)
    } catch {
      lastError = error.localizedDescription
    }
    agentStatus = agent.status
  }

  /// Kills and relaunches the daemon (`launchctl kickstart -k`).
  func restart() async {
    let target = "gui/\(getuid())/\(Self.agentLabel)"
    do {
      try await Task.detached {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/launchctl")
        process.arguments = ["kickstart", "-k", target]
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
          let message = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
          throw CollectorError.restartFailed(message.trimmingCharacters(in: .whitespacesAndNewlines))
        }
      }.value
      lastError = nil
      logger.info("Collector restarted")
    } catch {
      lastError = error.localizedDescription
    }
    agentStatus = agent.status
  }
}

/// This Mac, as the collector role knows it: a random ID in local (never synced) defaults.
struct CollectorDevice: Sendable {
  let id: UUID
  let name: String

  static let current: CollectorDevice = {
    let key = "collectorDeviceID"
    let defaults = UserDefaults.standard
    let id = defaults.string(forKey: key).flatMap(UUID.init(uuidString:)) ?? {
      let id = UUID()
      defaults.set(id.uuidString, forKey: key)
      return id
    }()
    return CollectorDevice(id: id, name: Host.current().localizedName ?? "Mac")
  }()
}

enum CollectorError: LocalizedError {
  case restartFailed(String)

  var errorDescription: String? {
    switch self {
    case .restartFailed(let message): "Restart failed: \(message.isEmpty ? "launchctl returned an error" : message)"
    }
  }
}

extension SMAppService.Status {
  var label: String {
    switch self {
    case .enabled: "Running"
    case .requiresApproval: "Needs approval in Login Items"
    case .notRegistered: "Stopped"
    case .notFound: "Not found in app bundle"
    @unknown default: "Unknown"
    }
  }
}
