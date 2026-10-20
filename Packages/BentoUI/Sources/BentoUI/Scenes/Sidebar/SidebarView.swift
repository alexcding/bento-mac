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
              Button("Delete…", role: .destructive) { model.channelToDelete = row.channel }
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

      Section {
        Label("All docs", systemImage: "doc.text")
          .badge(model.docCount)
          .sidebarRow(.allDocs, selection: model.selection)
          .dropDestination(for: String.self) { items, _ in model.dropDocs(items, into: nil) }
        Label("Starred", systemImage: "star")
          .sidebarRow(.starredDocs, selection: model.selection)
        OutlineGroup(model.folderTree, children: \.children) { node in
          DocFolderRowView(model: model, row: node.row)
            .badge(node.row.docCount)
            .sidebarRow(.docFolder(node.id), selection: model.selection)
            .dropDestination(for: String.self) { items, _ in model.dropDocs(items, into: node.id) }
            .contextMenu {
              Button("Rename") { model.renamingFolderID = node.id }
              Button("New Subfolder") { model.addFolder(parentID: node.id) }
              Divider()
              Button("Delete Folder…", role: .destructive) { model.folderToDelete = node.row }
            }
        }
        Button {
          model.addFolder()
        } label: {
          Label("New folder", systemImage: "plus")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
      } header: {
        Text("Docs").sidebarHeading()
      }
    }
    .listStyle(.sidebar)
    .confirmationDialog(
      "Delete “\(model.channelToDelete?.name ?? "")”?",
      isPresented: Binding(get: { model.channelToDelete != nil }, set: { if !$0 { model.channelToDelete = nil } }),
      presenting: model.channelToDelete
    ) { channel in
      Button("Delete Channel", role: .destructive) { model.delete(channel) }
    } message: { _ in
      Text("Its sources and their items are deleted too, unless another channel uses them. Bookmarks are kept.")
    }
    .confirmationDialog(
      "Delete “\(model.folderToDelete?.folder.name ?? "")”?",
      isPresented: Binding(get: { model.folderToDelete != nil }, set: { if !$0 { model.folderToDelete = nil } }),
      presenting: model.folderToDelete
    ) { row in
      Button("Delete Folder and Its Docs", role: .destructive) { model.deleteFolder(row.id) }
    } message: { _ in
      Text("Its subfolders and every doc in them are deleted too, on all your devices.")
    }
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

/// A folder's name, or a field to rename it in place.
private struct DocFolderRowView: View {
  let model: SidebarViewModel
  let row: DocFolderRow
  @State private var name = ""
  @FocusState private var focused: Bool

  var body: some View {
    if model.renamingFolderID == row.id {
      Label {
        TextField("Folder name", text: $name)
          .focused($focused)
          .onAppear {
            name = row.folder.name
            focused = true
          }
          .onSubmit { model.renameFolder(row.id, to: name) }
          #if os(macOS)
            .onExitCommand { model.renamingFolderID = nil }
          #endif
          .onChange(of: focused) { if !focused, model.renamingFolderID == row.id { model.renameFolder(row.id, to: name) } }
      } icon: {
        Image(systemName: "folder")
      }
    } else {
      Label(row.folder.name, systemImage: "folder")
    }
  }
}
