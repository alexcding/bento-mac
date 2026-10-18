import BentoData
import SQLiteData
import SwiftUI

/// What a source's icon is drawn from: its plugin, and for web feeds the site whose icon it shows.
struct SourceIconInfo: Hashable, Sendable {
  let pluginID: String
  /// The site's own icons, best first, for sources that are a web address (RSS).
  let siteIcons: [URL]

  init(_ source: Source) {
    pluginID = source.pluginID
    if source.pluginID == "rss", let url = URL(string: source.query), url.host() != nil {
      siteIcons = ["/apple-touch-icon.png", "/favicon.ico"].compactMap { URL(string: $0, relativeTo: url)?.absoluteURL }
    } else {
      siteIcons = []
    }
  }
}

extension EnvironmentValues {
  /// Every source's icon, by source ID, for cards to fall back on.
  @Entry var sourceIcons: [Source.ID: SourceIconInfo] = [:]
}

extension View {
  /// Puts every source's icon in the environment, kept current as sources change.
  func providesSourceIcons() -> some View {
    modifier(SourceIconsModifier())
  }
}

private struct SourceIconsModifier: ViewModifier {
  @FetchAll var sources: [Source]

  func body(content: Content) -> some View {
    content.environment(\.sourceIcons, Dictionary(sources.map { ($0.id, SourceIconInfo($0)) }) { first, _ in first })
  }
}

/// A source's icon: its site's icon when it has one, else its plugin's tile.
struct SourceAvatar: View {
  let info: SourceIconInfo
  var size: CGFloat = 28

  var body: some View {
    RemoteIcon(urls: info.siteIcons) { image in
      image.resizable().scaledToFit()
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size / 4, style: .continuous))
    } fallback: {
      SourceIcon(pluginID: info.pluginID, size: size)
    }
  }
}

/// The first of `urls` that loads as an image, else `fallback`.
struct RemoteIcon<Loaded: View, Fallback: View>: View {
  let urls: [URL]
  @ViewBuilder let loaded: (Image) -> Loaded
  @ViewBuilder let fallback: () -> Fallback
  @State private var index = 0

  var body: some View {
    Group {
      if index < urls.count {
        let current = index
        AsyncImage(url: urls[current]) { phase in
          switch phase {
          case .success(let image): loaded(image)
          // Moves on once per failed address, however often the fallback reappears.
          case .failure: fallback().onAppear { if index == current { index = current + 1 } }
          default: fallback()
          }
        }
      } else {
        fallback()
      }
    }
    .onChange(of: urls) { index = 0 }
  }
}
