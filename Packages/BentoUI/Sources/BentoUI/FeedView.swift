import BentoData
import SQLiteData
import SwiftUI

/// Cards for the sidebar selection, grouped by day, newest first, with search.
struct FeedView: View {
  let filter: SidebarSelection
  @Binding var selectedItemID: FeedItem.ID?

  @FetchAll private var rows: [FeedRow]
  @State private var search = ""
  @State private var showSettings = false

  var body: some View {
    Group {
      if rows.isEmpty {
        ContentUnavailableView(
          search.isEmpty ? "No items yet" : "No results",
          systemImage: search.isEmpty ? "tray" : "magnifyingglass",
          description: Text(search.isEmpty ? "Items appear here as the collector fetches them." : "")
        )
      } else {
        List(selection: $selectedItemID) {
          ForEach(Self.days(rows), id: \.day) { group in
            Section(group.day.formatted(.dateTime.weekday(.wide).month().day())) {
              ForEach(group.rows) { row in
                FeedCard(item: row.item, isRead: row.isRead, isBookmarked: row.isBookmarked)
                  .tag(row.id)
                  .listRowSeparator(.hidden)
              }
            }
          }
        }
        .listStyle(.plain)
      }
    }
    .searchable(text: $search, prompt: "Search titles and text")
    .toolbar {
      if case .channel = filter {
        Button("Channel Settings", systemImage: "slider.horizontal.3") { showSettings = true }
      }
    }
    .sheet(isPresented: $showSettings) {
      if case .channel(let id) = filter { ChannelSettingsView(channelID: id) }
    }
    .task(id: search) {
      _ = await withErrorReporting {
        try await $rows.load(Self.query(filter: filter, search: search), animation: .default)
      }
    }
  }

  static let pageSize = 300

  static func query(filter: SidebarSelection, search: String) -> some Statement<FeedRow> {
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    return FeedItem
      .where {
        if case .channel(let channelID) = filter {
          $0.sourceID.in(ChannelSource.where { $0.channelID.eq(channelID) }.select(\.sourceID))
        }
      }
      .where {
        if !needle.isEmpty {
          #sql(
            """
            instr(lower(coalesce(\($0.title), '') || ' ' || coalesce(\($0.translatedTitle), '') || ' ' || \
            \($0.text) || ' ' || coalesce(\($0.summary), '')), \(bind: needle)) > 0
            """,
            as: Bool.self
          )
        }
      }
      .leftJoin(ReadState.all) { $0.id.eq($1.feedItemID) }
      .leftJoin(Bookmark.all) { $0.id.eq($2.feedItemID) }
      .where { _, _, bookmark in
        if case .bookmarks = filter { bookmark.feedItemID.isNot(nil) }
      }
      .order { item, _, _ in item.publishedAt.desc() }
      .limit(pageSize)
      .select {
        FeedRow.Columns(item: $0, isRead: $1.feedItemID.isNot(nil), isBookmarked: $2.feedItemID.isNot(nil))
      }
  }

  struct DayGroup {
    let day: Date
    let rows: [FeedRow]
  }

  /// Rows are already newest first, so consecutive runs share a day.
  static func days(_ rows: [FeedRow], calendar: Calendar = .current) -> [DayGroup] {
    var groups: [DayGroup] = []
    for row in rows {
      let day = calendar.startOfDay(for: row.item.publishedAt)
      if let last = groups.last, last.day == day {
        groups[groups.count - 1] = DayGroup(day: day, rows: last.rows + [row])
      } else {
        groups.append(DayGroup(day: day, rows: [row]))
      }
    }
    return groups
  }
}

@Selection
struct FeedRow: Identifiable {
  let item: FeedItem
  let isRead: Bool
  let isBookmarked: Bool
  var id: FeedItem.ID { item.id }
}
