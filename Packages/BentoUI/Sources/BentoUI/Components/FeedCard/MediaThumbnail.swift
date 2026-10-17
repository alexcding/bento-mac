import BentoData
import SwiftUI

/// An image, or a video's thumbnail with a play badge.
struct MediaThumbnail: View {
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
