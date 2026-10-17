import SwiftUI

struct SidebarView: View {
  @Bindable var model: SidebarViewModel

  var body: some View {
    List(selection: Binding($model.selection)) {
      Label("All items", systemImage: "tray.full")
        .badge(model.unreadTotal)
        .sidebarRow(.all, selection: model.selection)
        .background(QuietSelection())
      Label("Bookmarks", systemImage: "bookmark")
        .badge(model.bookmarkCount)
        .sidebarRow(.bookmarks, selection: model.selection)

      Section {
        ForEach(model.rows) { row in
          ChannelRowView(row: row)
            .badge(row.unreadCount)
            .sidebarRow(.channel(row.id), selection: model.selection)
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
      } header: {
        Text("Channels").sidebarHeading()
      }
    }
    .listStyle(.sidebar)
    .sidebarStyle()
  }
}

private struct ChannelRowView: View {
  let row: ChannelRow

  var body: some View {
    Label(row.channel.name, systemImage: "number")
      .opacity(row.channel.isEnabled ? 1 : 0.5)
      .help("\(row.sourceCount) \(row.sourceCount == 1 ? "source" : "sources")\(row.channel.isEnabled ? "" : " · Paused")")
  }
}
