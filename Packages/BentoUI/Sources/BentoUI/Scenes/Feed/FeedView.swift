import SwiftUI

/// Cards for the sidebar selection, grouped by day, with search, an unread filter and keyboard
/// shortcuts (j/k move, s bookmark, m read/unread).
struct FeedView: View {
  @Bindable var model: FeedViewModel

  var body: some View {
    Group {
      if model.rows.isEmpty {
        ContentUnavailableView(
          emptyTitle,
          systemImage: model.search.isEmpty ? "tray" : "magnifyingglass",
          description: Text(model.search.isEmpty && !model.unreadOnly ? "Items appear here as sources are fetched." : "")
        )
      } else {
        List(selection: $model.selectedItemID) {
          ForEach(model.days, id: \.day) { day in
            Section {
              ForEach(day.rows) { row in
                FeedCard(model: FeedCardModel(row.item), isRead: row.isRead, isBookmarked: row.isBookmarked)
                  .tag(row.id)
                  .listRowSeparator(.hidden)
                  .contextMenu { rowMenu(row) }
              }
            } header: {
              if let date = day.day { Text(date.formatted(.dateTime.weekday(.wide).month().day())) }
            }
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle(model.title)
    .searchable(text: $model.search, prompt: "Search titles and text")
    .toolbar { toolbar }
    .task(id: ReloadKey(search: model.search, unreadOnly: model.unreadOnly)) { await model.reload() }
    .onKeyPress(characters: ["j", "k", "s", "m"]) { press in
      switch press.characters {
      case "j": model.moveSelection(by: 1)
      case "k": model.moveSelection(by: -1)
      case "s": if let row = model.selectedRow { model.toggleBookmark(row) }
      case "m": if let row = model.selectedRow { model.toggleRead(row) }
      default: return .ignored
      }
      return .handled
    }
  }

  private var emptyTitle: String {
    if !model.search.isEmpty { return "No results" }
    return model.unreadOnly ? "All caught up" : "No items yet"
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      Toggle("Unread Only", systemImage: "line.3.horizontal.decrease.circle", isOn: $model.unreadOnly)
      Button("Mark All as Read", systemImage: "checkmark.circle") { model.markAllRead() }
      if model.destination.channelID != nil {
        Button("Channel Settings", systemImage: "slider.horizontal.3") { model.openChannelSettings() }
      }
    }
  }

  @ViewBuilder
  private func rowMenu(_ row: FeedRow) -> some View {
    Button(row.isRead ? "Mark as Unread" : "Mark as Read") { model.toggleRead(row) }
    Button(row.isBookmarked ? "Remove Bookmark" : "Bookmark") { model.toggleBookmark(row) }
    if let url = row.item.url.flatMap(URL.init(string:)) {
      ShareLink(item: url)
    }
  }

  private struct ReloadKey: Hashable {
    let search: String
    let unreadOnly: Bool
  }
}
