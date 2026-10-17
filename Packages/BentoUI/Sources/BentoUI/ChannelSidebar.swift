import BentoData
import SQLiteData
import SwiftUI

struct ChannelSidebar: View {
  @Binding var selection: SidebarSelection?

  @FetchAll(
    Channel
      .group(by: \.id)
      .order(by: \.position)
      .leftJoin(ChannelSource.all) { $0.id.eq($1.channelID) }
      .select { ChannelRow.Columns(channel: $0, sourceCount: $1.id.count()) },
    animation: .default
  )
  private var rows

  @State private var settingsChannelID: Channel.ID?
  @Dependency(\.defaultDatabase) private var database

  var body: some View {
    List(selection: $selection) {
      Label("All items", systemImage: "tray.full")
        .tag(SidebarSelection.all)
      Label("Bookmarks", systemImage: "bookmark")
        .tag(SidebarSelection.bookmarks)

      Section("Channels") {
        ForEach(rows) { row in
          ChannelRowView(row: row)
            .tag(SidebarSelection.channel(row.id))
            .contextMenu {
              Button("Settings…") { settingsChannelID = row.id }
              Button(row.channel.isEnabled ? "Pause" : "Resume") { toggle(row.channel) }
              Divider()
              Button("Delete", role: .destructive) { delete(row.channel) }
            }
        }
        Button {
          addChannel()
        } label: {
          Label("New channel", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
    .sheet(item: $settingsChannelID) { id in
      ChannelSettingsView(channelID: id)
    }
  }

  private func addChannel() {
    withErrorReporting {
      let id = try database.write { try Mutations.addChannel($0, name: "New channel") }
      selection = .channel(id)
      settingsChannelID = id
    }
  }

  private func toggle(_ channel: Channel) {
    var channel = channel
    channel.isEnabled.toggle()
    withErrorReporting { try database.write { try Mutations.updateChannel($0, channel) } }
  }

  private func delete(_ channel: Channel) {
    if selection == .channel(channel.id) { selection = .all }
    withErrorReporting { try database.write { try Mutations.deleteChannel($0, id: channel.id) } }
  }
}

@Selection
struct ChannelRow: Identifiable {
  let channel: Channel
  let sourceCount: Int
  var id: Channel.ID { channel.id }
}

private struct ChannelRowView: View {
  let row: ChannelRow

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Label(row.channel.name, systemImage: "number")
      Text(
        "\(row.sourceCount) \(row.sourceCount == 1 ? "source" : "sources") · \(row.channel.isEnabled ? "Enabled" : "Paused")"
      )
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(.leading, 26)
    }
    .padding(.vertical, 2)
  }
}

extension UUID: @retroactive Identifiable {
  public var id: UUID { self }
}
