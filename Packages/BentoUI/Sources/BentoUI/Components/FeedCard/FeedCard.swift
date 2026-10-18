import BentoData
import SwiftUI

/// What a card shows, derived from a feed item (or a bookmark's copy of one).
struct FeedCardModel: Equatable {
  let sourceID: Source.ID
  let author: String
  let avatarURL: URL?
  let time: String
  let title: String?
  let body: String?
  let media: Media?
  /// An article's picture, shown in the leading slot instead of an avatar. Social posts (no title
  /// of their own) keep the author's avatar there.
  let thumbnailURL: URL?

  init(_ item: FeedItem) {
    sourceID = item.sourceID
    author = item.authorName ?? item.authorHandle ?? "Unknown"
    avatarURL = item.authorAvatarURL.flatMap(URL.init(string:))
    time = (item.isPublishedAtEstimated ? "~" : "") + item.publishedAt.formatted(.relative(presentation: .named))
    let firstLine = item.text.split(separator: "\n", maxSplits: 1).first.map(String.init)
    title = item.translatedTitle ?? item.title ?? firstLine
    // When the title is the text's first line, the text is not repeated as the body.
    let hasOwnTitle = item.translatedTitle != nil || item.title != nil
    body = item.summary ?? (hasOwnTitle && !item.text.isEmpty ? item.text : nil)
    media = item.media.first
    thumbnailURL = hasOwnTitle
      ? media.flatMap { URL(string: $0.kind == .video ? ($0.thumbnailURL ?? $0.url) : $0.url) }
      : nil
  }
}

/// A Mail-style row: no background, unread dot in the leading gutter, the author in bold with the
/// time, then a one-line title and a two-line preview, in Mail's text styles.
struct FeedCard: View {
  let model: FeedCardModel
  var isRead = false
  var isBookmarked = false
  /// Shows the whole title and preview, for the item's own page, instead of a few lines.
  var isExpanded = false
  /// Off when every row has the same author (one RSS feed): the title leads instead. The avatar
  /// still shows.
  var showsAuthor = true
  @Environment(\.sourceIcons) private var sourceIcons

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      HStack(alignment: .top, spacing: 4) {
        if !isExpanded {
          unreadDot
        }
        if let thumbnail = rowThumbnail {
          RemoteIcon(urls: [thumbnail]) { image in
            image.resizable().scaledToFill()
              .frame(width: Self.thumbnailSize, height: Self.thumbnailSize)
              .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
          } fallback: {
            avatar
          }
        } else {
          avatar
        }
      }
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
          if showsAuthor {
            Text(model.author).font(.headline).lineLimit(1)
          } else if let title = model.title {
            Text(title).font(.headline).lineLimit(isExpanded ? nil : 1)
          }
          Spacer()
          if isBookmarked {
            Image(systemName: "bookmark.fill").font(.caption).foregroundStyle(.secondary)
          }
          Text(model.time).font(.subheadline).foregroundStyle(.secondary)
        }
        if showsAuthor, let title = model.title {
          Text(title).font(Self.textFont).lineLimit(isExpanded ? nil : 1)
        }
        if let body = model.body {
          Text(body).font(Self.textFont).foregroundStyle(.secondary).lineLimit(isExpanded ? nil : 2)
        }
        if let media = model.media, rowThumbnail == nil {
          MediaThumbnail(media: media).padding(.top, 6)
        }
      }
      // Separators start under the text, as in Mail.
      .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
    }
    .padding(.vertical, 8)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private static let avatarSize: CGFloat = 32
  private static let thumbnailSize: CGFloat = 48

  /// The leading thumbnail in list rows. The item's own page shows the picture full width.
  private var rowThumbnail: URL? { isExpanded ? nil : model.thumbnailURL }

  /// Mail's subject and preview size: the body size on the Mac, one step smaller on iOS.
  #if os(macOS)
    private static let textFont = Font.body
  #else
    private static let textFont = Font.subheadline
  #endif

  private var unreadDot: some View {
    Circle()
      .fill(isRead ? AnyShapeStyle(.clear) : AnyShapeStyle(.tint))
      .frame(width: 9, height: 9)
      .frame(width: 12)
      .padding(.top, 5)
      .accessibilityLabel("Unread")
      .accessibilityHidden(isRead)
  }

  /// The author's picture, else the source's icon, else the author's initial.
  private var avatar: some View {
    RemoteIcon(urls: model.avatarURL.map { [$0] } ?? []) { image in
      image.resizable().scaledToFill()
        .frame(width: Self.avatarSize, height: Self.avatarSize)
        .clipShape(Circle())
    } fallback: {
      if let info = sourceIcons[model.sourceID] {
        SourceAvatar(info: info, size: Self.avatarSize)
      } else {
        Circle().fill(.quaternary)
          .frame(width: Self.avatarSize, height: Self.avatarSize)
          .overlay {
            Text(model.author.prefix(1).uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          }
      }
    }
  }
}
