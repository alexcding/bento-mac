import BentoData
import Foundation
import OSLog
import SQLiteData
import ServiceManagement

private let logger = Logger(subsystem: "Bento", category: "Collector")

/// Owns the `bento-collector` LaunchAgent and moves its outbox into the synced database.
/// Lives as long as the app, independent of any window.
@MainActor
@Observable
final class CollectorController {
  private(set) var agentStatus: SMAppService.Status
  private(set) var lastIngest: (date: Date, saved: Int)?
  private(set) var lastError: String?

  private let agent = SMAppService.agent(plistName: "io.github.alexcding.bento.collector.plist")
  private let ingestor: OutboxIngestor
  @ObservationIgnored private var pollTask: Task<Void, Never>?
  @ObservationIgnored private var ingestTask: Task<Void, Never>?

  /// Phase 0 polls the outbox; the control socket replaces this with push notifications.
  private static let pollInterval = Duration.seconds(5)
  /// Set when the user stops the collector, so launching the app does not restart it.
  private static let stoppedByUserKey = "collectorStoppedByUser"

  init(dataDirectory: URL) {
    @Dependency(\.defaultDatabase) var database
    ingestor = OutboxIngestor(
      collectorURL: dataDirectory.appending(path: "collector.sqlite"),
      database: database
    )
    agentStatus = agent.status
    if agent.status == .notRegistered, !UserDefaults.standard.bool(forKey: Self.stoppedByUserKey) {
      register()
    }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.ingestNow()
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  /// Saves pending outbox rows. Calls made while a run is in flight wait for that run instead
  /// of starting a second one.
  func ingestNow() async {
    if let ingestTask {
      await ingestTask.value
      return
    }
    let ingestor = ingestor
    let task = Task {
      do {
        let saved = try await Task.detached(priority: .utility) { try ingestor.ingestPending() }.value
        lastIngest = (.now, saved)
        lastError = nil
        if saved > 0 { logger.info("Saved \(saved) outbox rows") }
      } catch {
        lastError = error.localizedDescription
        logger.error("Outbox ingest failed: \(error)")
      }
    }
    ingestTask = task
    await task.value
    ingestTask = nil
  }

  func register() {
    do {
      try agent.register()
      UserDefaults.standard.removeObject(forKey: Self.stoppedByUserKey)
    } catch {
      lastError = error.localizedDescription
      logger.error("Registering collector failed: \(error)")
    }
    agentStatus = agent.status
  }

  func unregister() async {
    do {
      try await agent.unregister()
      UserDefaults.standard.set(true, forKey: Self.stoppedByUserKey)
    } catch {
      lastError = error.localizedDescription
    }
    agentStatus = agent.status
  }

  func refreshStatus() {
    agentStatus = agent.status
  }

  /// Runs the embedded binary's `emit-test-item`, for checking the outbox → iCloud path.
  func emitTestItem() async {
    guard let url = Bundle.main.url(forAuxiliaryExecutable: "bento-collector") else {
      lastError = "bento-collector is missing from the app bundle"
      return
    }
    do {
      try await Task.detached {
        let process = Process()
        process.executableURL = url
        process.arguments = ["emit-test-item"]
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
          throw CocoaError(
            .executableLoad,
            userInfo: [NSLocalizedDescriptionKey: "emit-test-item exited with \(process.terminationStatus)"]
          )
        }
      }.value
      await ingestNow()
    } catch {
      lastError = error.localizedDescription
    }
  }
}

extension SMAppService.Status {
  var label: String {
    switch self {
    case .enabled: "Running"
    case .requiresApproval: "Needs approval in Login Items"
    case .notRegistered: "Not registered"
    case .notFound: "Not found in app bundle"
    @unknown default: "Unknown"
    }
  }
}
