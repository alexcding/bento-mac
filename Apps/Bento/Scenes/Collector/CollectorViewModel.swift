import BentoCollectorClient
import BentoData
import Foundation
import Observation
import SQLiteData

/// Diagnostics for the collector: per-source performance, run history and the live log.
@MainActor
@Observable
final class CollectorViewModel {
  enum Tab: String, CaseIterable, Identifiable {
    case sources = "Sources"
    case runs = "Runs"
    case log = "Log"
    var id: Self { self }
  }

  var tab: Tab = .sources
  private(set) var runs: [CollectorRun] = []
  private(set) var performance: [UUID: SourcePerformance] = [:]
  private(set) var logLines: [String] = []
  private(set) var loadError: String?

  @ObservationIgnored @FetchAll(Source.order(by: \.name)) var sources: [Source]
  let service: CollectorService

  /// How often an open diagnostics window refreshes.
  static let refreshInterval = Duration.seconds(3)

  init(service: CollectorService) {
    self.service = service
  }

  func sourceName(_ id: UUID?) -> String {
    sources.first { $0.id == id }?.name ?? "Unknown source"
  }

  func refresh() async {
    let (collectorURL, logURL) = (service.collectorURL, service.logURL)
    do {
      let (runs, log) = try await Task.detached(priority: .utility) {
        (
          try CollectorDiagnostics.recentRuns(collectorURL: collectorURL),
          try CollectorDiagnostics.logTail(url: logURL)
        )
      }.value
      self.runs = runs
      performance = CollectorDiagnostics.performance(runs)
      logLines = log
      loadError = nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  /// Refreshes until the window closes (the view's task is cancelled).
  func refreshWhileVisible() async {
    while !Task.isCancelled {
      await refresh()
      try? await Task.sleep(for: Self.refreshInterval)
    }
  }
}
