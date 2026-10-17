import BentoData
import SwiftUI

struct SourceEditorView: View {
  @Bindable var model: SourceEditorViewModel

  var body: some View {
    NavigationStack {
      Group {
        if let source = model.source {
          form(source)
        } else {
          ProgressView()
        }
      }
      .navigationTitle(model.source?.name ?? "Source")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.done() }
        }
      }
    }
    .frame(minWidth: 520, minHeight: 560)
    .task { await model.load() }
    .sheet(isPresented: Binding(get: { model.preview != nil }, set: { if !$0 { model.dismissPreview() } })) {
      if let preview = model.preview { PreviewList(preview: preview) { model.dismissPreview() } }
    }
  }

  private func form(_ source: Source) -> some View {
    Form {
      Section {
        TextField("Name", text: binding(source.name) { $0.name = $1 })
        TextField(model.plugin?.queryHint ?? "Query", text: binding(source.query) { $0.query = $1 })
        LabeledContent("Plugin", value: model.plugin?.name ?? source.pluginID)
        Toggle("Enabled", isOn: binding(source.isEnabled) { $0.isEnabled = $1 })
        Picker("Fetch every", selection: binding(source.intervalMinutes) { $0.intervalMinutes = $1 }) {
          ForEach(SourceEditorViewModel.intervals, id: \.self) { minutes in
            Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h").tag(minutes)
          }
        }
        Stepper(
          "Items per fetch: \(source.limit.map(String.init) ?? "default")",
          value: binding(source.limit ?? 20) { $0.limit = $1 },
          in: 1...100
        )
      }
      Section("Processing") {
        Toggle("Translate", isOn: binding(source.translate) { $0.translate = $1 })
        Toggle("Summarize", isOn: binding(source.summarize) { $0.summarize = $1 })
        Toggle("Fetch article text", isOn: binding(source.fetchDetail) { $0.fetchDetail = $1 })
        Toggle("Skip existing posts on first fetch", isOn: binding(source.skipInitialBacklog) { $0.skipInitialBacklog = $1 })
        ForEach(model.customTasks) { task in
          Toggle(task.name.isEmpty ? "Untitled task" : task.name, isOn: Binding(
            get: { model.isTaskOn(task) },
            set: { model.setTask(task, on: $0) }
          ))
        }
      }
      if let status = model.status {
        Section("Collector") {
          if let error = status.lastError {
            Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
          }
          if let lastRun = status.lastRunAt {
            LabeledContent("Last fetch", value: lastRun.formatted(.relative(presentation: .named)))
          }
          LabeledContent("Next fetch", value: status.nextRunAt.formatted(.relative(presentation: .named)))
        }
      }
      if model.collector != nil {
        Section {
          HStack {
            Button("Fetch Now") { Task { await model.fetchNow() } }
            Button("Preview") { Task { await model.loadPreview() } }
            if model.isWorking { ProgressView().controlSize(.small) }
          }
          .disabled(model.isWorking)
          if let message = model.runMessage {
            Text(message).font(.caption).foregroundStyle(.secondary)
          }
        } footer: {
          Text("Preview fetches and processes the next items without saving them.")
        }
      }
    }
    .formStyle(.grouped)
  }

  private func binding<Value>(_ value: Value, set: @escaping (inout Source, Value) -> Void) -> Binding<Value> {
    Binding(get: { value }, set: { newValue in model.update { set(&$0, newValue) } })
  }
}

private struct PreviewList: View {
  let preview: PreviewResult
  let close: () -> Void

  var body: some View {
    NavigationStack {
      List {
        if !preview.aiFailures.isEmpty {
          Section("AI problems") {
            ForEach(preview.aiFailures, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
          }
        }
        Section(preview.items.isEmpty ? "Nothing new" : "\(preview.items.count) new items") {
          ForEach(preview.items) { item in
            FeedCard(model: FeedCardModel(item)).listRowSeparator(.hidden)
          }
        }
      }
      .navigationTitle("Preview")
      .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Close", action: close) } }
    }
    .frame(minWidth: 480, minHeight: 520)
  }
}
