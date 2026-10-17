import BentoData
import SQLiteData
import SwiftUI

/// Full item: header, title, text, all media, the quoted or reposted item, and the article detail.
struct FeedItemDetailView: View {
  let itemID: FeedItem.ID

  @FetchOne private var item: FeedItem?
  @FetchOne private var detail: FeedItemDetail?
  @FetchOne private var reference: FeedItem?
  @FetchOne private var bookmarkCount = 0
  @Dependency(\.defaultDatabase) private var database
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if let item {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            FeedCard(item: item, isRead: true)
            if !item.text.isEmpty, item.displayBody != nil || item.summary != nil {
              Text(item.text).textSelection(.enabled)
            }
            ForEach(Array(item.media.dropFirst().enumerated()), id: \.offset) { _, media in
              MediaThumbnail(media: media)
            }
            if let reference {
              FeedCard(item: reference, isRead: true)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }
            if let markdown = detailMarkdown {
              Divider()
              Text(markdown).textSelection(.enabled)
            }
          }
          .padding()
          .frame(maxWidth: 720, alignment: .leading)
        }
        .toolbar { toolbar(item) }
      } else {
        ContentUnavailableView("Item not found", systemImage: "questionmark.circle")
      }
    }
    .task {
      _ = await withErrorReporting {
        try await $item.load(FeedItem.find(itemID))
        try await $detail.load(FeedItemDetail.find(itemID))
        try await $bookmarkCount.load(Bookmark.where { $0.feedItemID.eq(itemID) }.count())
        if let referenceID = item?.referenceItemID {
          try await $reference.load(FeedItem.find(referenceID))
        }
        try await database.write { try Mutations.markRead($0, itemID: itemID) }
      }
    }
  }

  private var detailMarkdown: AttributedString? {
    guard let blob = detail?.markdown, let text = try? DetailCodec.decode(blob) else { return nil }
    return (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
    )) ?? AttributedString(text)
  }

  @ToolbarContentBuilder
  private func toolbar(_ item: FeedItem) -> some ToolbarContent {
    ToolbarItemGroup {
      let isBookmarked = bookmarkCount > 0
      Button(isBookmarked ? "Remove Bookmark" : "Bookmark", systemImage: isBookmarked ? "bookmark.fill" : "bookmark") {
        withErrorReporting {
          try database.write { try Mutations.setBookmarked($0, itemID: item.id, !isBookmarked) }
        }
      }
      if let url = item.url.flatMap(URL.init(string:)) {
        Button("Open Original", systemImage: "safari") { openURL(url) }
      }
    }
  }
}
