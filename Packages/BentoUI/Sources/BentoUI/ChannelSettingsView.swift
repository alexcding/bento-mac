import BentoData
import SQLiteData
import SwiftUI

/// Channel name and pause switch, and its sources with collector status.
struct ChannelSettingsView: View {
  let channelID: Channel.ID

  @FetchOne private var channel: Channel?
  @FetchAll private var sources: [Source]
  @State private var name = ""
  @State private var newFeedURL = ""
  @Dependency(\.defaultDatabase) private var database
  @Environment(\.dismiss) private var dismiss
  @Environment(\.sourceStatuses) private var statuses

  static let intervals = [10, 15, 30, 60, 120, 360]

  var body: some View {
    NavigationStack {
      Form {
        if let channel {
          Section("Channel") {
            TextField("Name", text: $name)
              .onSubmit { rename(channel) }
            Toggle("Enabled", isOn: Binding(get: { channel.isEnabled }, set: { setEnabled(channel, $0) }))
          }
        }
        Section("Sources") {
          ForEach(sources) { source in
            SourceRow(source: source, status: statuses[source.id], update: update, delete: delete)
          }
          HStack {
            TextField("RSS or Atom feed URL", text: $newFeedURL)
              .onSubmit(addFeed)
            Button("Add", action: addFeed)
              .disabled(URL(string: newFeedURL)?.scheme?.hasPrefix("http") != true)
          }
        }
      }
      .formStyle(.grouped)
      .navigationTitle(channel?.name ?? "Channel")
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            if let channel { rename(channel) }
            dismiss()
          }
        }
      }
    }
    .frame(minWidth: 480, minHeight: 420)
    .task {
      _ = await withErrorReporting {
        try await $channel.load(Channel.find(channelID))
        try await $sources.load(
          Source
            .where { $0.id.in(ChannelSource.where { $0.channelID.eq(channelID) }.select(\.sourceID)) }
            .order(by: \.name)
            .select { $0 }
        )
        name = channel?.name ?? ""
      }
    }
  }

  private func rename(_ channel: Channel) {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty, trimmed != channel.name else { return }
    var channel = channel
    channel.name = trimmed
    withErrorReporting { try database.write { try Mutations.updateChannel($0, channel) } }
  }

  private func setEnabled(_ channel: Channel, _ enabled: Bool) {
    var channel = channel
    channel.isEnabled = enabled
    withErrorReporting { try database.write { try Mutations.updateChannel($0, channel) } }
  }

  private func addFeed() {
    let url = newFeedURL.trimmingCharacters(in: .whitespaces)
    guard let parsed = URL(string: url), parsed.scheme?.hasPrefix("http") == true else { return }
    _ = withErrorReporting {
      try database.write { db in
        try Mutations.addSource(db, channelID: channelID, pluginID: "rss", name: parsed.host() ?? url, query: url)
      }
    }
    newFeedURL = ""
  }

  private func update(_ source: Source) {
    withErrorReporting { try database.write { try Mutations.updateSource($0, source) } }
  }

  private func delete(_ source: Source) {
    withErrorReporting { try database.write { try Mutations.deleteSource($0, id: source.id) } }
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
          ForEach(ChannelSettingsView.intervals, id: \.self) { minutes in
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
