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
            SourceRow(source: source, status: model.status(for: source), update: model.update, delete: model.delete)
          }
          HStack {
            TextField("RSS or Atom feed URL", text: $model.newFeedURL)
              .onSubmit { model.addFeed() }
            Button("Add") { model.addFeed() }
              .disabled(!model.canAddFeed)
          }
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
    .frame(minWidth: 480, minHeight: 420)
    .task { await model.load() }
  }
}

private struct SourceRow: View {
  let source: Source
  let status: SourceStatus?
  let update: (Source) -> Void
  let delete: (Source) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Toggle(source.name, isOn: binding(\.isEnabled))
        Spacer()
        Picker("Every", selection: binding(\.intervalMinutes)) {
          ForEach(ChannelSettingsViewModel.intervals, id: \.self) { minutes in
            Text(minutes < 60 ? "\(minutes) min" : "\(minutes / 60) h").tag(minutes)
          }
        }
        .fixedSize()
        Button("Delete", systemImage: "trash", role: .destructive) { delete(source) }
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
      Text(source.query).font(.caption).foregroundStyle(.secondary).lineLimit(1)
      if let status {
        if let error = status.lastError {
          Label(error, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(2)
        } else if let lastRun = status.lastRunAt {
          Text("Fetched \(lastRun.formatted(.relative(presentation: .named))) · \(status.lastNewItems) new")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<Source, Value>) -> Binding<Value> {
    Binding(
      get: { source[keyPath: keyPath] },
      set: { value in
        var copy = source
        copy[keyPath: keyPath] = value
        update(copy)
      }
    )
  }
}
