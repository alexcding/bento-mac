import BentoData
import Dependencies
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
    showFirstFrame()
  }

  /// The item and its article, read at once (a row or two, well under a millisecond), so the
  /// detail's first frame shows them rather than a blank column; `load` then watches them.
  private func showFirstFrame() {
    @Dependency(\.defaultDatabase) var database
    first = try? database.read { db in
      let item = try FeedItem.find(itemID).fetchOne(db) ?? Bookmark.find(itemID).fetchOne(db)?.asFeedItem
      let blob = try FeedItemDetail.find(itemID).fetchOne(db)?.markdown ?? BookmarkDetail.find(itemID).fetchOne(db)?.markdown
      return (item, blob)
    }
  }

  /// What the first read found, shown until `load` has the live rows.
  @ObservationIgnored private var first: (item: FeedItem?, blob: Data?)?

  /// Whether there is anything to show yet: the quick first read, or the loaded item.
  var isReady: Bool { hasLoaded || first?.item != nil }

  var item: FeedItem? { feedItem ?? bookmark?.asFeedItem ?? (hasLoaded ? nil : first?.item) }
  var isBookmarked: Bool { bookmark != nil }

  /// The article detail in its own format, from the item or its bookmarked copy. Decoded once per
  /// stored blob.
  var detail: DetailContent? {
    guard let blob = feedDetail?.markdown ?? bookmarkDetail?.markdown ?? (hasLoaded ? nil : first?.blob) else { return nil }
    if let decoded, decoded.blob == blob { return decoded.detail }
    let detail = try? DetailCodec.decode(blob)
    decoded = (blob, detail)
    return detail
  }
  @ObservationIgnored private var decoded: (blob: Data, detail: DetailContent?)?

  /// Loads the item and marks it read.
  /// Set once the first load is done, so the view shows nothing for that moment rather than its
  /// empty state flashing up before the content.
  private(set) var hasLoaded = false

  /// The item shows as soon as it and its article are in; whether it is bookmarked, the post it
  /// quotes, and marking it read follow. An item gone from the feed shows from its bookmark.
  func load() async {
    _ = await withErrorReporting {
      try await $feedItem.load(FeedItem.find(itemID))
      try await $feedDetail.load(FeedItemDetail.find(itemID))
      if feedItem == nil {
        try await $bookmark.load(Bookmark.find(itemID))
        try await $bookmarkDetail.load(BookmarkDetail.find(itemID))
      }
    }
    hasLoaded = true
    _ = await withErrorReporting {
      if feedItem != nil {
        try await $bookmark.load(Bookmark.find(itemID))
        try await $bookmarkDetail.load(BookmarkDetail.find(itemID))
      }
      if let referenceID = feedItem?.referenceItemID {
        try await $reference.load(FeedItem.find(referenceID))
      }
      try store.setRead([itemID], true)
    }
  }

  /// Saves the item as a doc to read and annotate later: its link, summary, text and article, as
  /// Markdown. Its images are kept with the doc once fetched; videos and posts stay links.
  func saveToDocs() {
    guard let item, savedDocID == nil else { return }
    let title = item.translatedTitle ?? item.title ?? String(item.text.prefix { $0 != "\n" }.prefix(80))
    // Relative images in the article are read against its page.
    let base = item.url.flatMap(URL.init(string:))
    var parts: [String] = []
    if let url = item.url { parts.append(url) }
    if let summary = item.summary, !summary.isEmpty {
      parts.append(summary.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n"))
    }
    if !item.text.isEmpty { parts.append(DocMarkdown.absoluteImages(item.text, baseURL: base)) }
    if let detail {
      let article: String =
        switch detail.format {
        case .markdown: DocMarkdown.absoluteImages(detail.body, baseURL: base)
        case .html: DocHTML.markdown(from: detail.body, baseURL: base)
        // Each line its own paragraph: a single line break is only a space in Markdown.
        case .text: detail.body.split(whereSeparator: \.isNewline).joined(separator: "\n\n")
        case .link: detail.body
        }
      if !article.isEmpty { parts += ["---", article] }
    }
    savedDocID = withErrorReporting { try docs.addDoc(folderID: nil, title: title, body: parts.joined(separator: "\n\n")) }
    // The images are fetched into the doc after it is made, so saving stays instant.
    if let savedDocID { Task { [docs] in await docs.fetchImages(docID: savedDocID) } }
  }

  func toggleBookmark() {
    withErrorReporting { try store.setBookmarked(itemID, !isBookmarked) }
  }
}
