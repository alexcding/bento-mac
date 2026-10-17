import BentoData
import Foundation
import Observation
import SQLiteData

/// One source's settings, collector status, and (on the Mac) Fetch Now and Preview.
@MainActor
@Observable
public final class SourceEditorViewModel: Identifiable {
  public enum Action: Equatable {
    case dismiss
  }

  public let sourceID: Source.ID
  public nonisolated var id: Source.ID { sourceID }
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  private(set) var isWorking = false
  private(set) var runMessage: String?
  private(set) var preview: PreviewResult?

  @ObservationIgnored @FetchOne var source: Source?
  /// Tasks a source can add beyond the Translate and Summarize switches.
  @ObservationIgnored @FetchAll(
    AiTask.where { !$0.key.in(["translate", "summarize"]) }.order(by: \.position)
  )
  var customTasks: [AiTask]
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let statuses: any SourceStatusProviding
  @ObservationIgnored let collector: (any CollectorControlling)?

  static let intervals = [10, 15, 30, 60, 120, 360, 720, 1440]

  init(
    sourceID: Source.ID,
    store: any LibraryStoring,
    statuses: any SourceStatusProviding,
    collector: (any CollectorControlling)?
  ) {
    self.sourceID = sourceID
    self.store = store
    self.statuses = statuses
    self.collector = collector
  }

  func load() async {
    _ = await withErrorReporting { try await $source.load(Source.find(sourceID)) }
  }

  var plugin: PluginInfo? {
    guard let source else { return nil }
    return collector?.plugins.first { $0.id == source.pluginID } ?? (source.pluginID == "rss" ? .rss : nil)
  }

  var status: SourceStatus? { statuses.status(for: sourceID) }

  func update(_ change: (inout Source) -> Void) {
    guard var source else { return }
    change(&source)
    withErrorReporting { try store.updateSource(source) }
  }

  /// The key a source stores for a task: its `key`, or its ID for tasks without one.
  static func key(for task: AiTask) -> String {
    task.key.isEmpty ? task.id.uuidString.lowercased() : task.key
  }

  func isTaskOn(_ task: AiTask) -> Bool {
    source?.aiTaskKeys.contains(Self.key(for: task)) ?? false
  }

  func setTask(_ task: AiTask, on: Bool) {
    let key = Self.key(for: task)
    update { source in
      source.aiTaskKeys.removeAll { $0 == key }
      if on { source.aiTaskKeys.append(key) }
    }
  }

  func fetchNow() async {
    guard let collector else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      let summary = try await collector.fetchNow(sourceID: sourceID)
      runMessage = Self.describe(summary)
    } catch {
      runMessage = error.localizedDescription
    }
  }

  func loadPreview() async {
    guard let collector else { return }
    isWorking = true
    defer { isWorking = false }
    do {
      preview = try await collector.preview(sourceID: sourceID)
      runMessage = nil
    } catch {
      runMessage = error.localizedDescription
    }
  }

  func dismissPreview() {
    preview = nil
  }

  func done() {
    onAction(.dismiss)
  }

  nonisolated static func describe(_ summary: RunSummary) -> String {
    if let error = summary.error { return error }
    var parts = ["Fetched \(summary.fetched)", "\(summary.new) new"]
    if summary.backlogSkipped > 0 { parts.append("\(summary.backlogSkipped) existing posts skipped") }
    if !summary.aiFailures.isEmpty { parts.append("AI: \(summary.aiFailures.joined(separator: "; "))") }
    return parts.joined(separator: " · ")
  }
}
