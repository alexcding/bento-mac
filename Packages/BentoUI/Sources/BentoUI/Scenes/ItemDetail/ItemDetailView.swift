import BentoData
import SwiftUI

struct ItemDetailView: View {
  let model: ItemDetailViewModel
  @Environment(\.openURL) private var openURL
  @Environment(\.sourceIcons) private var sourceIcons

  var body: some View {
    Group {
      let detail = model.detail
      if let item = model.item, let detail, detail.format == .html {
        ArticleWebView(
          html: ArticlePage.html(item: item, body: detail.body, iconURL: iconURL(item)),
          baseURL: item.url.flatMap(URL.init(string:))
        )
        .toolbar { toolbar(item) }
      } else if let item = model.item {
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            FeedCard(model: FeedCardModel(item), isRead: true, isBookmarked: model.isBookmarked, isExpanded: true)
            if item.summary != nil || item.translatedTitle != nil || item.title != nil, !item.text.isEmpty {
              Text(item.text).textSelection(.enabled)
            }
            ForEach(Array(item.media.dropFirst().enumerated()), id: \.offset) { _, media in
              MediaThumbnail(media: media)
            }
            if let reference = model.reference {
              FeedCard(model: FeedCardModel(reference), isRead: true, isExpanded: true)
                .padding(.horizontal, 10)
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            }
            if let detail {
              Divider()
              switch detail.format {
              case .link:
                if let url = URL(string: detail.body) { Link("Read the Full Article", destination: url) }
              case .text:
                Text(detail.body).textSelection(.enabled)
              case .markdown, .html:
                Text(Self.attributed(detail.body)).textSelection(.enabled)
              }
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

  /// The item's own picture, else its site's favicon.
  private func iconURL(_ item: FeedItem) -> URL? {
    item.authorAvatarURL.flatMap(URL.init(string:)) ?? sourceIcons[item.sourceID]?.siteIcons.last
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
