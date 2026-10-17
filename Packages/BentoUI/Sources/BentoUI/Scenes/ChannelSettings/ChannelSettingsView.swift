import BentoData
import SwiftUI

struct ChannelSettingsView: View {
  @Bindable var model: ChannelSettingsViewModel

  var body: some View {
    NavigationStack {
      Form {
        if let channel = model.channel {
          Section("Channel") {
            TextField("Name", text: $model.name)
              .onSubmit { model.saveName() }
            Toggle("Enabled", isOn: Binding(get: { channel.isEnabled }, set: { model.setEnabled($0) }))
          }
        }
        Section("Sources") {
          ForEach(model.sources) { source in
            SourceRow(
              source: source,
              pluginName: model.pluginName(for: source),
              status: model.status(for: source),
              toggle: { var copy = source; copy.isEnabled = $0; model.update(copy) },
              edit: { model.edit(source) },
              delete: { model.delete(source) }
            )
          }
          addSourceRow
        }
      }
      .formStyle(.grouped)
      .navigationTitle(model.channel?.name ?? "Channel")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { model.done() }
        }
      }
    }
    .frame(minWidth: 520, minHeight: 440)
    .task { await model.load() }
    .sheet(item: $model.sourceEditor) { editor in
      SourceEditorView(model: editor)
    }
  }

  private var addSourceRow: some View {
    HStack {
      Picker("Type", selection: $model.newSourcePluginID) {
        ForEach(model.availablePlugins) { plugin in
          Text(plugin.name).tag(plugin.id)
        }
      }
      .labelsHidden()
      .fixedSize()
      TextField(model.newSourcePlugin?.queryHint ?? "Query", text: $model.newSourceQuery)
        .onSubmit { model.addSource() }
      Button("Add") { model.addSource() }
        .disabled(!model.canAddSource)
    }
  }
}

private struct SourceRow: View {
  let source: Source
  let pluginName: String
  let status: SourceStatus?
  let toggle: (Bool) -> Void
  let edit: () -> Void
  let delete: () -> Void

  var body: some View {
    HStack(alignment: .top) {
      Toggle("", isOn: Binding(get: { source.isEnabled }, set: { toggle($0) })).labelsHidden()
      VStack(alignment: .leading, spacing: 4) {
        Text(source.name)
        Text("\(pluginName) · \(source.query.isEmpty ? "default feed" : source.query)")
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(1)
        if let error = status?.lastError {
          Label(error, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange).lineLimit(2)
        } else if let status, let lastRun = status.lastRunAt {
          Text("Fetched \(lastRun.formatted(.relative(presentation: .named))) · \(status.lastNewItems) new")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer()
      Button("Edit", systemImage: "slider.horizontal.3", action: edit).labelStyle(.iconOnly).buttonStyle(.borderless)
      Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
  }
}
