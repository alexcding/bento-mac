import BentoData
import SwiftUI

/// One feed item as a card: author and time, title, summary or text, first image.
struct FeedCard: View {
  let item: FeedItem

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      header
      if let title = item.displayTitle {
        Text(title)
          .font(.headline)
          .lineLimit(3)
      }
      if let body = item.displayBody {
        Text(body)
          .font(.body)
          .foregroundStyle(.secondary)
          .lineLimit(4)
      }
      if let media = item.media.first {
        MediaThumbnail(media: media)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10))
  }

  private var header: some View {
    HStack(spacing: 8) {
      AsyncImage(url: item.authorAvatarURL.flatMap(URL.init(string:))) { image in
        image.resizable().scaledToFill()
      } placeholder: {
        Circle().fill(.quaternary)
      }
      .frame(width: 24, height: 24)
      .clipShape(Circle())

      Text(item.authorName ?? item.authorHandle ?? "Unknown")
        .font(.subheadline.weight(.semibold))
      Spacer()
      Text((item.isPublishedAtEstimated ? "~" : "") + item.publishedAt.formatted(.relative(presentation: .named)))
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
  }
}

private struct MediaThumbnail: View {
  let media: Media

  var body: some View {
    AsyncImage(url: URL(string: media.kind == .video ? (media.thumbnailURL ?? media.url) : media.url)) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      Rectangle().fill(.quaternary)
    }
    .frame(maxHeight: 240)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .overlay {
      if media.kind == .video {
        Image(systemName: "play.circle.fill")
          .font(.system(size: 44))
          .foregroundStyle(.white.opacity(0.9))
      }
    }
  }
}

extension FeedItem {
  /// `translatedTitle` ?? `title` ?? first line of `text`.
  var displayTitle: String? {
    translatedTitle ?? title ?? text.split(separator: "\n", maxSplits: 1).first.map(String.init)
  }

  /// `summary` ?? `text`, unless `text` is already shown as the title.
  var displayBody: String? {
    if let summary { return summary }
    if translatedTitle == nil, title == nil { return nil }
    return text.isEmpty ? nil : text
  }
}
