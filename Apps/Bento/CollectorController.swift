import BentoData
import Foundation
import OSLog
import SQLiteData
import ServiceManagement

private let logger = Logger(subsystem: "Bento", category: "Collector")

/// Owns the `bento-collector` LaunchAgent and moves its outbox into the synced database.
@MainActor
@Observable
final class CollectorController {
  private(set) var agentStatus: SMAppService.Status
  private(set) var lastIngest: (date: Date, saved: Int)?
  private(set) var lastError: String?

  private let agent = SMAppService.agent(plistName: "io.github.alexcding.bento.collector.plist")
  private let ingestor: OutboxIngestor
  private var started = false

  /// Phase 0 polls the outbox; the control socket replaces this with push notifications.
  private static let pollInterval = Duration.seconds(5)

  init(dataDirectory: URL) {
    @Dependency(\.defaultDatabase) var database
    ingestor = OutboxIngestor(
      collectorURL: dataDirectory.appending(path: "collector.sqlite"),
      database: database
    )
    agentStatus = agent.status
  }

  func start() async {
    guard !started else { return }
    started = true
    if agent.status == .notRegistered { register() }
    while !Task.isCancelled {
      await ingestNow()
      try? await Task.sleep(for: Self.pollInterval)
    }
  }

  func ingestNow() async {
    let ingestor = ingestor
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

  func register() {
    do {
      try agent.register()
    } catch {
      lastError = error.localizedDescription
      logger.error("Registering collector failed: \(error)")
    }
    agentStatus = agent.status
  }

  func unregister() async {
    do {
      try await agent.unregister()
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
          throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "emit-test-item exited with \(process.terminationStatus)"])
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
