import AppKit
import BentoCollectorClient
import BentoData
import ServiceManagement
import SwiftUI

struct CollectorView: View {
  @Bindable var model: CollectorViewModel

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      switch model.tab {
      case .sources: sourcesTable
      case .runs: runsTable
      case .log: logView
      }
    }
    .frame(minWidth: 720, minHeight: 420)
    .toolbar {
      ToolbarItem(placement: .principal) {
        Picker("View", selection: $model.tab) {
          ForEach(CollectorViewModel.Tab.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
      }
    }
    .task { await model.refreshWhileVisible() }
  }

  private var header: some View {
    HStack(spacing: 12) {
      Circle()
        .fill(model.service.agentStatus == .enabled ? .green : .orange)
        .frame(width: 8, height: 8)
      Text(
        model.service.isThisMacCollector
          ? "Collector: \(model.service.agentStatus.label)"
          : "Collecting on \(model.service.collectorDeviceName ?? "no Mac yet")"
      )
      .font(.headline)
      if let sync = model.service.lastSync {
        Text("Last sync \(sync.date.formatted(date: .omitted, time: .standard)) · \(sync.saved) new")
          .foregroundStyle(.secondary)
      }
      Spacer()
      if let error = model.service.lastError ?? model.loadError {
        Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
      }
      controls
    }
    .padding(10)
  }

  @ViewBuilder
  private var controls: some View {
    switch model.service.isThisMacCollector ? model.service.agentStatus : nil {
    case nil:
      Button("Collect on This Mac") { Task { try? await model.service.becomeCollector() } }
    case .enabled:
      Button("Restart") { Task { await model.service.restart() } }
      Button("Stop") { Task { await model.service.stop() } }
    case .requiresApproval:
      Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
    default:
      Button("Start") { model.service.start() }
    }
  }

  private var sourcesTable: some View {
    Table(model.sources) {
      TableColumn("Source") { source in
        VStack(alignment: .leading) {
          Text(source.name)
          Text(source.query).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      TableColumn("Status") { source in
        let status = model.service.status(for: source.id)
        if let error = status?.lastError {
          Text(error).foregroundStyle(.orange).lineLimit(2).help(error)
        } else if let lastRun = status?.lastRunAt {
          Text("OK · \(lastRun.formatted(.relative(presentation: .named)))")
        } else {
          Text(source.isEnabled ? "Waiting" : "Paused").foregroundStyle(.secondary)
        }
      }
      TableColumn("Runs") { Text("\(model.performance[$0.id]?.runs ?? 0)").monospacedDigit() }
        .width(50)
      TableColumn("Failures") { Text("\(model.performance[$0.id]?.failures ?? 0)").monospacedDigit() }
        .width(60)
      TableColumn("Avg") { Text(Self.duration(model.performance[$0.id]?.averageDuration)).monospacedDigit() }
        .width(70)
      TableColumn("Slowest") { Text(Self.duration(model.performance[$0.id]?.slowestDuration)).monospacedDigit() }
        .width(70)
      TableColumn("New items") { Text("\(model.performance[$0.id]?.newItems ?? 0)").monospacedDigit() }
        .width(70)
    }
  }

  private var runsTable: some View {
    Table(model.runs) {
      TableColumn("Started") { Text($0.startedAt.formatted(date: .abbreviated, time: .standard)) }
      TableColumn("Source") { Text(model.sourceName($0.sourceID)) }
      TableColumn("Duration") { Text(Self.duration($0.duration)).monospacedDigit() }.width(70)
      TableColumn("Fetched") { Text("\($0.fetched)").monospacedDigit() }.width(60)
      TableColumn("New") { Text("\($0.newItems)").monospacedDigit() }.width(50)
      TableColumn("Error") { run in
        Text(run.error ?? "").foregroundStyle(.orange).lineLimit(1).help(run.error ?? "")
      }
    }
  }

  private var logView: some View {
    VStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(Array(model.logLines.enumerated()), id: \.offset) { index, line in
              Text(line)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(line.contains(" WARN ") ? .orange : line.contains(" ERROR ") ? .red : .primary)
                .textSelection(.enabled)
                .id(index)
            }
          }
          .padding(8)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: model.logLines.count) { proxy.scrollTo(model.logLines.count - 1, anchor: .bottom) }
      }
      Divider()
      HStack {
        Text("\(model.logLines.count) lines · \(model.service.logURL.path)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        Spacer()
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(model.logLines.joined(separator: "\n"), forType: .string)
        }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([model.service.logURL]) }
      }
      .padding(8)
    }
  }

  static func duration(_ duration: Duration?) -> String {
    guard let duration else { return "–" }
    let ms = duration.components.seconds * 1000 + duration.components.attoseconds / 1_000_000_000_000_000
    return ms < 1000 ? "\(ms) ms" : String(format: "%.1f s", Double(ms) / 1000)
  }
}
