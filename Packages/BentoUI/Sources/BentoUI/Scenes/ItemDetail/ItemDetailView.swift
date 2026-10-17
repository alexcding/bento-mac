import BentoData
import SwiftUI

struct ItemDetailView: View {
  let model: ItemDetailViewModel
  @Environment(\.openURL) private var openURL

  var body: some View {
    Group {
      if let item = model.item {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            FeedCard(model: FeedCardModel(item), isRead: true, isBookmarked: model.isBookmarked)
            if item.summary != nil || item.translatedTitle != nil || item.title != nil, !item.text.isEmpty {
              Text(item.text).textSelection(.enabled)
            }
            ForEach(Array(item.media.dropFirst().enumerated()), id: \.offset) { _, media in
              MediaThumbnail(media: media)
            }
            if let reference = model.reference {
              FeedCard(model: FeedCardModel(reference), isRead: true)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }
            if let markdown = model.detailMarkdown {
              Divider()
              Text(Self.attributed(markdown)).textSelection(.enabled)
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
    .task { await model.load() }
    .onKeyPress(characters: ["s", "o"]) { press in
      switch press.characters {
      case "s": model.toggleBookmark()
      case "o": if let url = model.item?.url.flatMap(URL.init(string:)) { openURL(url) }
      default: return .ignored
      }
      return .handled
    }
  }

  static func attributed(_ markdown: String) -> AttributedString {
    (try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(markdown)
  }

  @ToolbarContentBuilder
  private func toolbar(_ item: FeedItem) -> some ToolbarContent {
    ToolbarItemGroup {
      Button(
        model.isBookmarked ? "Remove Bookmark" : "Bookmark",
        systemImage: model.isBookmarked ? "bookmark.fill" : "bookmark"
      ) { model.toggleBookmark() }
      if let url = item.url.flatMap(URL.init(string:)) {
        ShareLink(item: url)
        Button("Open Original", systemImage: "safari") { openURL(url) }
      }
    }
  }
}
