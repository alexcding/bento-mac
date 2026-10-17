import BentoData
import Foundation
import Observation
import SQLiteData

/// One item: the live feed item, or its bookmarked copy once the original is gone.
@MainActor
@Observable
public final class ItemDetailViewModel: Identifiable {
  public let itemID: FeedItem.ID
  public nonisolated var id: FeedItem.ID { itemID }

  @ObservationIgnored @FetchOne var feedItem: FeedItem?
  @ObservationIgnored @FetchOne var feedDetail: FeedItemDetail?
  @ObservationIgnored @FetchOne var bookmark: Bookmark?
  @ObservationIgnored @FetchOne var bookmarkDetail: BookmarkDetail?
  @ObservationIgnored @FetchOne var reference: FeedItem?
  @ObservationIgnored private let store: any LibraryStoring

  init(itemID: FeedItem.ID, store: any LibraryStoring) {
    self.itemID = itemID
    self.store = store
  }

  var item: FeedItem? { feedItem ?? bookmark?.asFeedItem }
  var isBookmarked: Bool { bookmark != nil }

  /// The article detail as Markdown, from the item or its bookmarked copy.
  var detailMarkdown: String? {
    guard let blob = feedDetail?.markdown ?? bookmarkDetail?.markdown else { return nil }
    return try? DetailCodec.decode(blob)
  }

  /// Loads the item and marks it read.
  func load() async {
    _ = await withErrorReporting {
      try await $feedItem.load(FeedItem.find(itemID))
      try await $feedDetail.load(FeedItemDetail.find(itemID))
      try await $bookmark.load(Bookmark.find(itemID))
      try await $bookmarkDetail.load(BookmarkDetail.find(itemID))
      if let referenceID = feedItem?.referenceItemID {
        try await $reference.load(FeedItem.find(referenceID))
      }
      try store.setRead([itemID], true)
    }
  }

  func toggleBookmark() {
    withErrorReporting { try store.setBookmarked(itemID, !isBookmarked) }
  }
}
