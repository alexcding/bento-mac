import BentoData
import Foundation
import Observation
import SQLiteData

@MainActor
@Observable
public final class FeedViewModel {
  public enum Action: Equatable {
    case selectedItem(FeedItem.ID?)
    case openChannelSettings(Channel.ID)
  }

  public let destination: SidebarDestination
  public var search = ""
  public var unreadOnly = false
  public var selectedItemID: FeedItem.ID? {
    didSet { if selectedItemID != oldValue { onAction(.selectedItem(selectedItemID)) } }
  }
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchAll var itemRows: [FeedRow]
  @ObservationIgnored @FetchAll var bookmarkRows: [BookmarkRow]
  @ObservationIgnored private let store: any LibraryStoring

  init(destination: SidebarDestination, store: any LibraryStoring) {
    self.destination = destination
    self.store = store
  }

  var title: String {
    switch destination {
    case .all: "All items"
    case .bookmarks: "Bookmarks"
    case .channel: "Channel"
    }
  }

  var rows: [FeedRow] {
    destination == .bookmarks ? bookmarkRows.map(\.feedRow) : itemRows
  }

  /// One feed's items all carry its name as the author, so the author shows only when it varies,
  /// or when some item has no title to lead the row instead.
  var showsAuthor: Bool {
    let rows = rows
    guard rows.allSatisfy({ $0.item.title != nil || $0.item.translatedTitle != nil }) else { return true }
    return Set(rows.lazy.map { $0.item.authorName ?? $0.item.authorHandle }).count > 1
  }

  /// Feed items group by publish day; bookmarks are one list in the order they were saved.
  var days: [FeedDay] {
    destination == .bookmarks ? (rows.isEmpty ? [] : [FeedDay(day: nil, rows: rows)]) : FeedDay.group(rows)
  }

  /// Reloads for the current search and unread filter. Called by the view when either changes.
  func reload() async {
    _ = await withErrorReporting {
      if destination == .bookmarks {
        try await $bookmarkRows.load(FeedQuery.bookmarks(search: search, unreadOnly: unreadOnly))
      } else {
        try await $itemRows.load(
          FeedQuery.items(channelID: destination.channelID, search: search, unreadOnly: unreadOnly)
        )
      }
    }
  }

  func openChannelSettings() {
    if let id = destination.channelID { onAction(.openChannelSettings(id)) }
  }

  func toggleBookmark(_ row: FeedRow) {
    withErrorReporting { try store.setBookmarked(row.id, !row.isBookmarked) }
  }

  func toggleRead(_ row: FeedRow) {
    withErrorReporting { try store.setRead([row.id], !row.isRead) }
  }

  /// Marks everything in this view read: the channel, all items, or (for Bookmarks) only the
  /// listed bookmarks.
  func markAllRead() {
    withErrorReporting {
      if destination == .bookmarks {
        try store.setRead(rows.map(\.id), true)
      } else {
        try store.markAllRead(channelID: destination.channelID)
      }
    }
  }

  /// Moves the selection by `offset` rows (keyboard j/k).
  func moveSelection(by offset: Int) {
    guard !rows.isEmpty else { return }
    let current = rows.firstIndex { $0.id == selectedItemID }
    let next = current.map { $0 + offset } ?? (offset > 0 ? 0 : rows.count - 1)
    selectedItemID = rows[min(max(next, 0), rows.count - 1)].id
  }

  var selectedRow: FeedRow? { rows.first { $0.id == selectedItemID } }
}

struct FeedDay {
  /// `nil` for an undated list (bookmarks).
  let day: Date?
  let rows: [FeedRow]

  /// Rows are newest first, so consecutive runs share a day.
  static func group(_ rows: [FeedRow], calendar: Calendar = .current) -> [FeedDay] {
    var days: [FeedDay] = []
    for row in rows {
      let day = calendar.startOfDay(for: row.item.publishedAt)
      if let last = days.last, last.day == day {
        days[days.count - 1] = FeedDay(day: day, rows: last.rows + [row])
      } else {
        days.append(FeedDay(day: day, rows: [row]))
      }
    }
    return days
  }
}
