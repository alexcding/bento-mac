import BentoData
import SwiftUI

/// What a card shows, derived from a feed item (or a bookmark's copy of one).
struct FeedCardModel: Equatable {
  let author: String
  let avatarURL: URL?
  let time: String
  let title: String?
  let body: String?
  let media: Media?

  init(_ item: FeedItem) {
    author = item.authorName ?? item.authorHandle ?? "Unknown"
    avatarURL = item.authorAvatarURL.flatMap(URL.init(string:))
    time = (item.isPublishedAtEstimated ? "~" : "") + item.publishedAt.formatted(.relative(presentation: .named))
    let firstLine = item.text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    title = item.translatedTitle ?? item.title ?? firstLine
    // When the title is the text's first line, the text is not repeated as the body.
    let hasOwnTitle = item.translatedTitle != nil || item.title != nil
    body = item.summary ?? (hasOwnTitle && !item.text.isEmpty ? item.text : nil)
    media = item.media.first
  }
}

struct FeedCard: View {
  let model: FeedCardModel
  var isRead = false
  var isBookmarked = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let title = model.title {
        Text(title).font(.headline).lineLimit(3)
      }
      if let body = model.body {
        Text(body).font(.body).foregroundStyle(.secondary).lineLimit(4)
      }
      if let media = model.media {
        MediaThumbnail(media: media)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
  }

  private var header: some View {
    HStack(spacing: 8) {
      AsyncImage(url: model.avatarURL) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Circle().fill(.quaternary)
      }
      .frame(width: 24, height: 24)
      .clipShape(Circle())
      Text(model.author).font(.subheadline.weight(.semibold))
      if !isRead {
        Circle().fill(.tint).frame(width: 7, height: 7).accessibilityLabel("Unread")
      }
      Spacer()
      if isBookmarked {
        Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.secondary)
      }
      Text(model.time).font(.caption).foregroundStyle(.tertiary)
    }
  }
}
