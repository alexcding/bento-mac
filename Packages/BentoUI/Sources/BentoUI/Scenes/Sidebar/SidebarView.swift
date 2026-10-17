import SwiftUI

struct SidebarView: View {
  @Bindable var model: SidebarViewModel

  var body: some View {
    List(selection: Binding($model.selection)) {
      Label("All items", systemImage: "tray.full")
        .badge(model.unreadTotal)
        .tag(SidebarDestination.all)
      Label("Bookmarks", systemImage: "bookmark")
        .badge(model.bookmarkCount)
        .tag(SidebarDestination.bookmarks)

      Section("Channels") {
        ForEach(model.rows) { row in
          ChannelRowView(row: row)
            .badge(row.unreadCount)
            .tag(SidebarDestination.channel(row.id))
            .contextMenu {
              Button("Settings…") { model.openSettings(row.channel) }
              Button(row.channel.isEnabled ? "Pause" : "Resume") { model.toggleEnabled(row.channel) }
              Divider()
              Button("Delete", role: .destructive) { model.delete(row.channel) }
            }
        }
        Button {
          model.addChannel()
        } label: {
          Label("New channel", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
  }
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
