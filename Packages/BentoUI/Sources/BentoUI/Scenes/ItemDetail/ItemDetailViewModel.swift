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
  /// The doc this item was saved to from here.
  private(set) var savedDocID: Doc.ID?
  @ObservationIgnored private let store: any LibraryStoring
  @ObservationIgnored private let docs: any DocsStoring

  init(itemID: FeedItem.ID, store: any LibraryStoring, docs: any DocsStoring) {
    self.itemID = itemID
    self.store = store
    self.docs = docs
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

  /// Saves the item as a doc to read and annotate later: its link, summary, text and article.
  func saveToDocs() {
    guard let item, savedDocID == nil else { return }
    let title = item.translatedTitle ?? item.title ?? String(item.text.prefix { $0 != "\n" }.prefix(80))
    var blocks: [DocContent] = []
    if let url = item.url { blocks.append(DocContent(kind: .link, text: url)) }
    if let summary = item.summary, !summary.isEmpty { blocks.append(DocContent(text: summary, decoration: .focus)) }
    blocks += DocMarkdown.blocks(from: item.text)
    if let markdown = detailMarkdown { blocks += [DocContent(kind: .divider)] + DocMarkdown.blocks(from: markdown) }
    savedDocID = withErrorReporting { try docs.addDoc(folderID: nil, title: title, blocks: blocks) }
  }

  func toggleBookmark() {
    withErrorReporting { try store.setBookmarked(itemID, !isBookmarked) }
  }
}
