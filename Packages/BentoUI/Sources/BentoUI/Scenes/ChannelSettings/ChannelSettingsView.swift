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
        if model.collector != nil {
          destinationsSection
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

  private var destinationsSection: some View {
    Section {
      ForEach(model.destinations) { destination in
        DestinationRow(
          destination: destination,
          canManage: model.canManageDestinations,
          update: { model.update($0) },
          replaceSecret: { value in Task { await model.replaceSecret(of: destination, with: value) } },
          delete: { Task { await model.delete(destination) } }
        )
      }
      if model.canManageDestinations {
        addDestinationRow
      }
      if let message = model.destinationMessage {
        Text(message).font(.caption).foregroundStyle(.orange)
      }
    } header: {
      Text("Post to")
    } footer: {
      Text(
        model.canManageDestinations
          ? "New items from this channel's sources are posted here. Webhook URLs and bot tokens are kept in the Keychain; posting as you uses the Telegram or X sign-in in Settings → Plugins."
          : "Destinations are set up on the collector Mac, which keeps their webhook URLs and bot tokens in its Keychain."
      )
    }
  }

  private var addDestinationRow: some View {
    VStack(alignment: .leading) {
      HStack {
        Picker("Kind", selection: $model.newDestinationKind) {
          ForEach(Destination.Kind.addable, id: \.self) { Text($0.label).tag($0) }
        }
        .labelsHidden()
        .fixedSize()
        TextField("Name", text: $model.newDestinationName)
      }
      HStack {
        if model.newDestinationKind.needsSecret {
          SecureField(model.newDestinationKind.secretPrompt, text: $model.newDestinationSecret)
        }
        if model.newDestinationKind.needsChat {
          TextField(model.newDestinationKind.chatPrompt, text: $model.newDestinationChatID)
        }
        Button("Add") { Task { await model.addDestination() } }
          .disabled(!model.canAddDestination)
      }
    }
  }

  private var addSourceRow: some View {
    VStack(alignment: .leading) {
      addSourceFields
      Toggle("Skip posts that already exist", isOn: $model.newSourceSkipsBacklog)
        .font(.caption)
    }
  }

  private var addSourceFields: some View {
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

private struct DestinationRow: View {
  let destination: Destination
  let canManage: Bool
  let update: (Destination) -> Void
  let replaceSecret: (String) -> Void
  let delete: () -> Void
  @State private var newSecret = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Toggle("", isOn: binding(\.isEnabled)).labelsHidden()
        VStack(alignment: .leading) {
          Text(destination.name)
          Text([destination.kind.label, destination.chatID].compactMap { $0 }.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        Button("Delete", systemImage: "trash", role: .destructive, action: delete)
          .labelStyle(.iconOnly)
          .buttonStyle(.borderless)
      }
      Stepper(
        "Wait \(destination.postDelaySeconds) s between posts",
        value: binding(\.postDelaySeconds),
        in: 0...600,
        step: 5
      )
      .font(.caption)
      if canManage, destination.kind.needsSecret {
        HStack {
          SecureField("New \(destination.kind.secretPrompt.lowercased())", text: $newSecret)
          Button("Replace") {
            replaceSecret(newSecret)
            newSecret = ""
          }
          .disabled(newSecret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .font(.caption)
      }
    }
  }

  private func binding<Value>(_ keyPath: WritableKeyPath<Destination, Value>) -> Binding<Value> {
    Binding(
      get: { destination[keyPath: keyPath] },
      set: { value in
        var copy = destination
        copy[keyPath: keyPath] = value
        update(copy)
      }
    )
  }
}
