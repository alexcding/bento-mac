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
@MainActor
@Observable
final class CollectorService: SourceStatusProviding {
  static let agentLabel = "io.github.alexcding.bento.collector"

  private(set) var agentStatus: SMAppService.Status
  private(set) var lastSync: (date: Date, saved: Int)?
  private(set) var lastError: String?
  private(set) var statuses: [Source.ID: SourceStatus] = [:]
  private(set) var plugins: [PluginInfo] = []

  let dataDirectory: URL
  var collectorURL: URL { dataDirectory.appending(path: "collector.sqlite") }
  var configURL: URL { dataDirectory.appending(path: "collector-config.json") }
  var logURL: URL { dataDirectory.appending(path: "collector.log") }

  @ObservationIgnored private let database: any DatabaseWriter
  @ObservationIgnored private let agent = SMAppService.agent(plistName: "\(agentLabel).plist")
  @ObservationIgnored private let ingestor: OutboxIngestor
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var syncTask: Task<Void, Never>?

  /// Polling interval for config, outbox and status.
  private static let pollInterval = Duration.seconds(5)
  /// Set when the user stops the collector, so launching the app does not restart it.
  private static let stoppedByUserKey = "collectorStoppedByUser"

  init(dataDirectory: URL, database: any DatabaseWriter) {
    self.dataDirectory = dataDirectory
    self.database = database
    ingestor = OutboxIngestor(collectorURL: dataDirectory.appending(path: "collector.sqlite"), database: database)
    agentStatus = agent.status
    if agent.status == .notRegistered, !UserDefaults.standard.bool(forKey: Self.stoppedByUserKey) {
      start()
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
    let (database, ingestor, configURL, collectorURL) = (database, ingestor, configURL, collectorURL)
    do {
      let result = try await Task.detached(priority: .utility) {
        let config = try database.read { try CollectorConfigExporter.json($0) }
        try CollectorConfigExporter.write(config, to: configURL)
        let saved = try ingestor.ingestPending()
        let statuses = try CollectorStatusReader.read(collectorURL: collectorURL)
        let plugins = try CollectorDiagnostics.plugins(collectorURL: collectorURL)
        return (saved, statuses, plugins)
      }.value
      lastSync = (.now, result.0)
      statuses = result.1
      let plugins = result.2.map {
        PluginInfo(id: $0.id, name: $0.name, version: $0.version, manifest: $0.manifest, requirements: $0.requirements, error: $0.error)
      }
      if plugins != self.plugins { self.plugins = plugins }
      lastError = nil
      agentStatus = agent.status
      if result.0 > 0 { logger.info("Saved \(result.0) outbox rows") }
    } catch {
      lastError = error.localizedDescription
      logger.error("Collector sync failed: \(error)")
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
