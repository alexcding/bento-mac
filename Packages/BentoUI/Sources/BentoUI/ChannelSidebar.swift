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

  @Dependency(\.defaultDatabase) private var database

  var body: some View {
    List(selection: $selection) {
      Label("All items", systemImage: "tray.full")
        .tag(SidebarSelection.all)

      Section("Channels") {
        ForEach(rows) { row in
          ChannelRowView(row: row)
            .tag(SidebarSelection.channel(row.id))
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
  }

  private func addChannel() {
    withErrorReporting {
      try database.write { db in
        try Channel.insert {
          Channel.Draft(name: "New channel", position: rows.count)
        }
        .execute(db)
      }
    }
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
