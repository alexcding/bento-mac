import BentoData
import Foundation
import SQLiteData

@Selection
public struct FeedRow: Identifiable, Sendable {
  public let item: FeedItem
  public let isRead: Bool
  public let isBookmarked: Bool
  public var id: FeedItem.ID { item.id }
}

@Selection
struct BookmarkRow: Sendable {
  let bookmark: Bookmark
  let isRead: Bool

  /// Bookmarks show through the same card as feed items.
  var feedRow: FeedRow { FeedRow(item: bookmark.asFeedItem, isRead: isRead, isBookmarked: true) }
}

enum FeedQuery {
  static let pageSize = 300

  /// Feed items for all items or one channel, newest first.
  static func items(channelID: Channel.ID?, search: String, unreadOnly: Bool) -> some Statement<FeedRow> {
    let needle = normalized(search)
    return FeedItem
      .where {
        if let channelID {
          $0.sourceID.in(ChannelSource.where { $0.channelID.eq(channelID) }.select(\.sourceID))
        } else {
          // Items left from a deleted source (on a device that missed the delete) stay hidden.
          $0.sourceID.in(Source.select(\.id))
        }
      }
      .where { item in
        if !needle.isEmpty {
          #sql(
            """
            instr(bentoLower(coalesce(\(item.title), '') || ' ' || coalesce(\(item.translatedTitle), '') || ' ' || \
            \(item.text) || ' ' || coalesce(\(item.summary), '')), \(bind: needle)) > 0
            """,
            as: Bool.self
          )
        }
      }
      .leftJoin(ReadState.all) { $0.id.eq($1.feedItemID) }
      .leftJoin(Bookmark.all) { $0.id.eq($2.id) }
      .where { _, read, _ in
        if unreadOnly { read.feedItemID.is(nil) }
      }
      .order { item, _, _ in item.publishedAt.desc() }
      .limit(pageSize)
      .select { FeedRow.Columns(item: $0, isRead: $1.feedItemID.isNot(nil), isBookmarked: $2.id.isNot(nil)) }
  }

  /// Saved copies, most recently bookmarked first. They show even after the original is gone.
  static func bookmarks(search: String, unreadOnly: Bool) -> some Statement<BookmarkRow> {
    let needle = normalized(search)
    return Bookmark
      .where { bookmark in
        if !needle.isEmpty {
          #sql(
            """
            instr(bentoLower(coalesce(\(bookmark.title), '') || ' ' || coalesce(\(bookmark.translatedTitle), '') || ' ' || \
            \(bookmark.text) || ' ' || coalesce(\(bookmark.summary), '')), \(bind: needle)) > 0
            """,
            as: Bool.self
          )
        }
      }
      .leftJoin(ReadState.all) { $0.id.eq($1.feedItemID) }
      .where { _, read in
        if unreadOnly { read.feedItemID.is(nil) }
      }
      .order { bookmark, _ in bookmark.createdAt.desc() }
      .select { BookmarkRow.Columns(bookmark: $0, isRead: $1.feedItemID.isNot(nil)) }
  }

  private static func normalized(_ search: String) -> String {
    search.trimmingCharacters(in: .whitespaces).lowercased()
  }
}
