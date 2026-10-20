import AVKit
import CryptoKit
import BentoData
import Dependencies
import ImageIO
import LinkPresentation
import QuickLook
import MarkdownView
import SQLiteData
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

extension EnvironmentValues {
  /// Opens a doc a `bento-doc` link points at.
  @Entry var openDocLink: (Doc.ID) -> Void = { _ in }
  /// Shows the links to an address in another style, rewriting the doc's Markdown; nil where the
  /// Markdown cannot be changed (an article in the reader).
  @Entry var setLinkStyle: ((String, DocEmbeds.LinkStyle) -> Void)? = nil
  /// Whether the doc a `bento-doc` link points at is here; a link to one that is not is shown
  /// greyed out and does nothing.
  @Entry var docLinkExists: (Doc.ID) -> Bool = { _ in true }
}

/// Markdown shown the way an X Article reads: a readable column, clear headings, images and
/// videos at full width, posts as cards, toggles that fold. Text selects across the whole body.
/// Images and files kept with a doc come from the library; posts and videos are shown live from
/// where they are.
struct DocMarkdownBody: View, Equatable {
  let markdown: String
  /// Where relative links and images are read from, for an article saved from the web.
  var baseURL: URL?

  // Laying out a long doc takes a noticeable moment, so it is redone only when the Markdown
  // changes, not whenever something around it does (`.equatable()` where it is used).
  nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.markdown == rhs.markdown && lhs.baseURL == rhs.baseURL
  }

  var body: some View {
    MarkdownText(DocEmbeds.prepare(markdown))
      .modifier(DocMarkdownStyle())
      .markdownElementRenderer(.image(DocAssetImageRenderer(), urlScheme: DocAsset.scheme))
      .markdownElementRenderer(.link(DocAssetFileRenderer(), urlScheme: DocAsset.scheme))
      .markdownElementRenderer(.link(DocLinkRenderer(), urlScheme: DocLink.scheme))
      .markdownElementRenderer(.image(WebImageRenderer(), urlScheme: "https"))
      .markdownElementRenderer(.image(WebImageRenderer(), urlScheme: "http"))
      .markdownElementRenderer(.blockDirective(ToggleRenderer(), name: DocEmbeds.toggle))
      .markdownElementRenderer(.blockDirective(PostRenderer(), name: DocEmbeds.post))
      .markdownElementRenderer(.blockDirective(VideoRenderer(), name: DocEmbeds.video))
      .markdownElementRenderer(.blockDirective(LinkCardRenderer(), name: DocEmbeds.link))
      .modifier(BaseURL(url: baseURL))
  }

  private struct BaseURL: ViewModifier {
    let url: URL?
    func body(content: Content) -> some View {
      if let url { content.markdownBaseURL(url) } else { content }
    }
  }
}

/// A doc or article laid out a section at a time as it scrolls into view, so even a long one opens
/// at once. Text selects across a section; a drag cannot run on into the next.
struct DocMarkdownSections: View, Equatable {
  let markdown: String
  var baseURL: URL?

  var body: some View {
    LazyVStack(alignment: .leading, spacing: 16) {
      ForEach(Array(DocEmbeds.sections(markdown).enumerated()), id: \.offset) { _, section in
        DocMarkdownBody(markdown: section, baseURL: baseURL).equatable()
      }
    }
  }
}

/// The look, after X Articles: body text at a comfortable reading size, headings a calm step up,
/// room between blocks, plain links, and quotes set off by a thin bar rather than a box.
struct DocMarkdownStyle: ViewModifier {
  func body(content: Content) -> some View {
    content
      .font(PlatformFont.systemFont(ofSize: 28, weight: .bold), for: .h1)
      .font(PlatformFont.systemFont(ofSize: 23, weight: .bold), for: .h2)
      .font(PlatformFont.systemFont(ofSize: 20, weight: .semibold), for: .h3)
      .font(PlatformFont.systemFont(ofSize: 17, weight: .semibold), for: .h4)
      .font(PlatformFont.systemFont(ofSize: 17), for: .body)
      .font(PlatformFont.systemFont(ofSize: 17), for: .blockQuote)
      .font(PlatformFont.monospacedSystemFont(ofSize: 14, weight: .regular), for: .codeBlock)
      .font(PlatformFont.systemFont(ofSize: 15, weight: .semibold), for: .tableHeader)
      .font(PlatformFont.systemFont(ofSize: 15), for: .tableBody)
      .markdownComponentSpacing(16)
      .markdownListIndent(24)
      .markdownLinksUnderlined(false)
      .markdownBlockQuoteStyle(DocQuoteStyle())
      .markdownCodeBlockStyle(DocCodeBlockStyle())
      .textSelection(.enabled)
  }
}

/// A quote as X Articles set one: a thin bar beside quieter text, no box.
struct DocQuoteStyle: MarkdownBlockQuoteStyle {
  func makeBody(configuration: MarkdownBlockQuoteStyleConfiguration) -> some View {
    configuration.content
      .foregroundStyle(.secondary)
      .padding(.leading, 16)
      .padding(.vertical, 2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .overlay(alignment: .leading) {
        Capsule().fill(.tertiary).frame(width: 3)
      }
  }
}

/// Code as Craft shows it: plain fixed-width text with line numbers in a gutter, on a light
/// panel; Copy appears on hover.
struct DocCodeBlockStyle: MarkdownCodeBlockStyle {
  func makeBody(configuration: MarkdownCodeBlockStyleConfiguration) -> some View {
    DocCodeBlock(code: configuration.code)
  }
}

struct DocCodeBlock: View {
  let code: String
  @State private var hovering = false
  @State private var copied = false

  private var lines: [Substring] {
    let text = code.hasSuffix("\n") ? code.dropLast() : Substring(code)
    return text.split(separator: "\n", omittingEmptySubsequences: false)
  }

  var body: some View {
    let font = Font.system(size: 13.5, design: .monospaced)
    HStack(alignment: .top, spacing: 0) {
      // One text for the numbers and one for the code, rather than a view per line: a long doc can
      // hold many code blocks, and each view costs layout time.
      Text(lines.indices.map { "\($0 + 1)" }.joined(separator: "\n"))
      .multilineTextAlignment(.trailing)
      .lineSpacing(3)
      .font(font)
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 10)
      .padding(.vertical, 12)
      .overlay(alignment: .trailing) { Rectangle().fill(.separator).frame(width: 1) }
      ScrollView(.horizontal, showsIndicators: false) {
        Text(lines.joined(separator: "\n"))
        .lineSpacing(3)
        .font(font)
        .fixedSize()
        .textSelection(.enabled)
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
    .overlay(alignment: .topTrailing) {
      if hovering || copied {
        Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
          #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(code, forType: .string)
          #else
            UIPasteboard.general.string = code
          #endif
          copied = true
          Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
          }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .padding(8)
      }
    }
    .onHover { hovering = $0 }
  }
}

// MARK: Kept with the doc

/// An image kept with the doc, decoded off the main thread at the size it is shown.
struct DocAssetImageRenderer: MarkdownImageRenderer {
  func makeBody(configuration: MarkdownImageRendererConfiguration) -> some View {
    DocAssetImage(id: DocAsset.assetID(configuration.url), label: configuration.alternativeText ?? "")
  }
}

struct DocAssetImage: View {
  let id: DocAsset.ID?
  let label: String
  @State private var image: CGImage?
  @State private var missing = false
  /// The stored image, watched: one that syncs in after the text shows when it arrives.
  @FetchOne private var data: Data?

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .accessibilityLabel(label)
      } else if missing {
        Label(label.isEmpty ? "Image not available" : label, systemImage: "photo")
          .foregroundStyle(.secondary)
      } else {
        RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(height: 180)
      }
    }
    .frame(maxWidth: .infinity)
    .task(id: id) {
      guard let id else { return missing = true }
      _ = try? await $data.load(DocAsset.find(id).select(\.data))
    }
    .task(id: data?.count) {
      let data = data
      image = await Task.detached { data.flatMap { DocImage.decode($0, maxPixelSize: 2000) } }.value
      missing = image == nil && id != nil && data != nil
    }
  }
}

/// A file kept with the doc: a row naming it, which opens or shares it.
struct DocAssetFileRenderer: MarkdownLinkRenderer {
  func makeBody(configuration: MarkdownLinkRendererConfiguration) -> some View {
    DocAssetFileRow(id: DocAsset.assetID(configuration.url), label: configuration.label)
  }
}

struct DocAssetFileRow<Label: View>: View {
  let id: DocAsset.ID?
  let label: Label
  @Dependency(\.defaultDatabase) private var database
  @State private var preview: URL?

  var body: some View {
    Button {
      Task { await open() }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: "doc")
        label
      }
    }
    .buttonStyle(.borderless)
    .quickLookPreview($preview)
  }

  /// Writes the file to a temporary folder and shows it in Quick Look.
  private func open() async {
    guard let id,
      let asset = try? await database.read({ try DocAsset.find(id).fetchOne($0) })
    else { return }
    let folder = FileManager.default.temporaryDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
    let url = folder.appending(path: asset.name.isEmpty ? "file" : asset.name)
    guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
      (try? asset.data.write(to: url)) != nil
    else { return }
    preview = url
  }
}

/// A link to another doc, which opens it.
struct DocLinkRenderer: MarkdownLinkRenderer {
  func makeBody(configuration: MarkdownLinkRendererConfiguration) -> some View {
    DocLinkButton(id: DocLink.docID(configuration.url), label: configuration.label)
  }
}

struct DocLinkButton<Label: View>: View {
  let id: Doc.ID?
  let label: Label
  @Environment(\.openDocLink) private var openDocLink
  @Environment(\.docLinkExists) private var docLinkExists

  var body: some View {
    let exists = id.map(docLinkExists) ?? false
    Button {
      if let id, exists { openDocLink(id) }
    } label: {
      HStack(spacing: 3) {
        Image(systemName: exists ? "arrow.up.right.square" : "questionmark.square.dashed")
        label
      }
    }
    .buttonStyle(.borderless)
    .disabled(!exists)
    .help(exists ? "Open this doc" : "This doc is no longer here")
  }
}

// MARK: From the web

/// An image on the web, shown full width; only public web addresses are loaded.
struct WebImageRenderer: MarkdownImageRenderer {
  func makeBody(configuration: MarkdownImageRendererConfiguration) -> some View {
    DocWebImage(url: configuration.url, label: configuration.alternativeText ?? "")
  }
}

/// An image on the web, shown full width. Loaded as the downloader loads one: public addresses
/// only, redirects included, so a doc cannot make Bento reach into the local network.
struct DocWebImage: View {
  let url: URL
  let label: String
  @State private var image: CGImage?
  @State private var failed = false

  var body: some View {
    Group {
      if let image {
        Image(decorative: image, scale: 1).resizable().scaledToFit()
          .clipShape(RoundedRectangle(cornerRadius: 10))
          .accessibilityLabel(label)
      } else if failed {
        Link(destination: url) { Label(label.isEmpty ? "Image" : label, systemImage: "photo") }
      } else {
        RoundedRectangle(cornerRadius: 10).fill(.quaternary).frame(height: 180)
      }
    }
    .frame(maxWidth: .infinity)
    .task(id: url) {
      image = await DocWebImages.image(url)
      failed = image == nil
    }
  }
}

/// Web images shown in docs and articles, kept decoded while the app runs.
@MainActor
enum DocWebImages {
  private static let cache = NSCache<NSURL, CGImage>()

  static func image(_ url: URL) async -> CGImage? {
    if let cached = cache.object(forKey: url as NSURL) { return cached }
    guard let file = try? await DocImageDownloader.download(url.absoluteString, encode: false) else { return nil }
    let data = file.data
    guard let image = await Task.detached(operation: { DocImage.decode(data, maxPixelSize: 1800) }).value else { return nil }
    cache.setObject(image, forKey: url as NSURL)
    return image
  }
}

/// A video file on the web, played where it is.
struct VideoRenderer: MarkdownBlockDirectiveRenderer {
  func makeBody(configuration: MarkdownBlockDirectiveRendererConfiguration) -> some View {
    DocVideo(url: configuration.url)
  }
}

struct DocVideo: View {
  let url: URL?
  @State private var player: AVPlayer?

  var body: some View {
    VideoPlayer(player: player)
      .aspectRatio(16 / 9, contentMode: .fit)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .task(id: url) {
        if player == nil, let url, await NativeLinkPreviewer.isPublicWebResolved(url) { player = AVPlayer(url: url) }
      }
      .onDisappear { player?.pause() }
  }
}

/// A post (on X, YouTube, Vimeo) as a card: its preview fetched when shown, opened on its site.
struct PostRenderer: MarkdownBlockDirectiveRenderer {
  func makeBody(configuration: MarkdownBlockDirectiveRendererConfiguration) -> some View {
    if let url = configuration.url { DocPostCard(url: url).id(url) }
  }
}

struct DocPostCard: View {
  let url: URL
  @State private var metadata: BentoData.LinkMetadata?
  @State private var image: CGImage?

  var body: some View {
    Link(destination: url) {
      VStack(alignment: .leading, spacing: 8) {
        if let image {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
            .frame(maxWidth: .infinity, maxHeight: 220).clipped()
        }
        VStack(alignment: .leading, spacing: 4) {
          Text(metadata?.siteName.isEmpty == false ? metadata!.siteName : url.host() ?? "")
            .font(.caption).foregroundStyle(.secondary)
          if let title = metadata?.title, !title.isEmpty { Text(title).font(.headline).lineLimit(3) }
          if let summary = metadata?.summary, !summary.isEmpty {
            Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(4)
          }
          if metadata == nil { Text(url.absoluteString).font(.subheadline).lineLimit(1) }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
        .padding(.top, image == nil ? 12 : 0)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    }
    .buttonStyle(.plain)
    .task(id: url) {
      let preview = await DocLinkPreviews.preview(url, maxPixelSize: 1200)
      metadata = preview.metadata
      image = preview.isIcon ? nil : preview.image
    }
  }
}

/// A web link on a line of its own, as Craft shows one: regular (title, description and
/// site beside a small picture) or a card (the picture large on top). Fetched when shown; opened
/// on its site; its style switched from its context menu.
struct LinkCardRenderer: MarkdownBlockDirectiveRenderer {
  func makeBody(configuration: MarkdownBlockDirectiveRendererConfiguration) -> some View {
    let style = configuration.arguments.first { $0.name == "style" }.flatMap { DocEmbeds.LinkStyle(rawValue: $0.value) }
    let title = configuration.arguments.first { $0.name == "title" }?.value ?? ""
    // A card is its address and style: one in another place, or restyled, starts from fresh.
    if let url = configuration.url {
      DocLinkCard(url: url, style: style ?? .regular, linkText: title).id("\((style ?? .regular).rawValue) \(url.absoluteString)")
    }
  }
}

struct DocLinkCard: View {
  let url: URL
  let style: DocEmbeds.LinkStyle
  /// The link's own text, shown until the page's title is fetched.
  var linkText = ""
  @State private var preview: DocLinkPreview
  @Environment(\.setLinkStyle) private var setLinkStyle

  init(url: URL, style: DocEmbeds.LinkStyle, linkText: String = "") {
    self.url = url
    self.style = style
    self.linkText = linkText
    // A preview already fetched shows in the first frame, so the card never flickers.
    _preview = State(initialValue: DocLinkPreviews.cached(url, maxPixelSize: Self.pixels(style)) ?? DocLinkPreview())
  }

  private static func pixels(_ style: DocEmbeds.LinkStyle) -> Int { style == .card ? 800 : 500 }

  private var title: String {
    if let title = preview.metadata?.title, !title.isEmpty, title != url.host() { return title }
    return linkText.isEmpty ? (url.host() ?? url.absoluteString) : linkText
  }

  private var summary: String? {
    preview.metadata?.summary.isEmpty == false ? preview.metadata?.summary : nil
  }

  /// The address as Craft shows it under a card: without its scheme.
  private var address: String {
    var text = url.absoluteString
    for scheme in ["https://", "http://"] where text.hasPrefix(scheme) { text.removeFirst(scheme.count) }
    return text
  }

  var body: some View {
    Group {
      if style == .text {
        // A plain link: its text (else its address), still switchable from its context menu.
        Link(linkText.isEmpty ? url.absoluteString : linkText, destination: url)
          .font(.system(size: 17))
          .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        Link(destination: url) {
          if style == .card { card } else { regular }
        }
        .buttonStyle(.plain)
      }
    }
    .help(url.absoluteString)
    .contextMenu {
      if let setLinkStyle {
        Picker("Show As", selection: Binding(get: { style }, set: { setLinkStyle(url.absoluteString, $0) })) {
          Text("Regular").tag(DocEmbeds.LinkStyle.regular)
          Text("Card").tag(DocEmbeds.LinkStyle.card)
          Text("Plain Link").tag(DocEmbeds.LinkStyle.text)
        }
        .pickerStyle(.inline)
      }
      Button("Copy Link", systemImage: "link") {
        #if os(macOS)
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(url.absoluteString, forType: .string)
        #else
          UIPasteboard.general.url = url
        #endif
      }
    }
    // Keyed on the style too: a plain link switched to a card fetches its preview then.
    .task(id: "\(style.rawValue) \(url.absoluteString)") {
      guard style != .text, preview.metadata == nil else { return }
      preview = await DocLinkPreviews.preview(url, maxPixelSize: Self.pixels(style))
    }
  }

  // Craft's frame: a white panel on a light grey plate, the address in a strip underneath.

  // The same size before and after the preview arrives, so nothing around the card moves.
  private var regular: some View {
    plate {
      HStack(spacing: 14) {
        picture(width: 120, height: 64)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
          Text(summary ?? " ").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
      .padding(.trailing, 12)
    }
  }

  private var card: some View {
    plate {
      VStack(alignment: .leading, spacing: 0) {
        picture(width: nil, height: 150)
        VStack(alignment: .leading, spacing: 3) {
          Text(title).font(.system(size: 15, weight: .semibold)).lineLimit(2, reservesSpace: true)
          Text(summary ?? " ").font(.system(size: 13)).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .frame(width: 280)
  }

  private func plate(@ViewBuilder content: () -> some View) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      content()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background)
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.separator))
        .padding(3)
      HStack(spacing: 6) {
        if let icon = preview.icon {
          Image(decorative: icon, scale: 1).resizable().scaledToFit().frame(width: 14, height: 14)
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        Text(address).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
      .padding(.horizontal, 10)
      .padding(.top, 4)
      .padding(.bottom, 7)
    }
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
  }

  /// The page's picture filling its space; else its icon, or an empty tile, in the middle.
  @ViewBuilder
  private func picture(width: CGFloat?, height: CGFloat) -> some View {
    if let image = preview.image, !preview.isIcon {
      Image(decorative: image, scale: 1).resizable().scaledToFill()
        .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
        .frame(width: width)
        .clipped()
    } else {
      ZStack {
        if width == nil { Rectangle().fill(.quaternary.opacity(0.3)) }
        Group {
          if let image = preview.image {
            Image(decorative: image, scale: 1).resizable().scaledToFit().padding(8)
          } else {
            Color.clear
          }
        }
        .frame(width: min(height - 16, 56), height: min(height - 16, 56))
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      }
      .frame(maxWidth: width ?? .infinity, minHeight: height, maxHeight: height)
      .frame(width: width)
    }
  }
}

/// What a link card shows: the page's details, its picture (or, without one, its site's icon
/// standing in), and the site's small icon for the address strip.
struct DocLinkPreview {
  var metadata: BentoData.LinkMetadata?
  var image: CGImage?
  var isIcon = false
  var icon: CGImage?
}

/// Link and post previews. A preview is fetched once and then kept as it is, on this device
/// (in Application Support, never synced: the doc keeps only the address), so a card shows the
/// same each time and appears at once. Only a fetch that found something is kept; one that did
/// not is tried again next time.
///
/// The page is read directly first, which also finds its description. A page that gives nothing
/// that way (one behind a script check, or built by script) is asked of Apple's LinkPresentation,
/// which loads it as a browser does, for its title and picture or icon.
@MainActor
enum DocLinkPreviews {
  private struct Found: Codable {
    var title = ""
    var summary = ""
    var siteName = ""
    var image: Data?
    var isIcon = false
    var icon: Data?

    var metadata: BentoData.LinkMetadata {
      var metadata = BentoData.LinkMetadata(siteName: siteName)
      metadata.title = title
      metadata.summary = summary
      return metadata
    }

    /// A real title or picture; a site's icon alone means the page itself could not be read.
    var isWorthKeeping: Bool { !title.isEmpty || (image != nil && !isIcon) }
  }

  private final class Decoded {
    let preview: DocLinkPreview
    init(_ preview: DocLinkPreview) { self.preview = preview }
  }

  /// Previews decoded at a size, by address, for a card's first frame; let go under memory
  /// pressure, as they can be decoded again from what is kept.
  private static let decoded = NSCache<NSString, Decoded>()
  /// Fetches under way, so the same address shown twice is fetched once.
  private static var fetching: [URL: Task<Found, Never>] = [:]

  /// A preview decoded earlier in this run, for a card's first frame.
  static func cached(_ url: URL, maxPixelSize: Int) -> DocLinkPreview? {
    decoded.object(forKey: "\(maxPixelSize) \(url.absoluteString)" as NSString)?.preview
  }

  static func preview(_ url: URL, maxPixelSize: Int) async -> DocLinkPreview {
    let key = "\(maxPixelSize) \(url.absoluteString)" as NSString
    if let cached = decoded.object(forKey: key) { return cached.preview }
    let file = storeURL(url)
    var result = await Task.detached { file.flatMap { try? Data(contentsOf: $0) }.flatMap { try? PropertyListDecoder().decode(Found.self, from: $0) } }.value
    if result == nil {
      let shared = fetching[url]
      let task = shared ?? Task { await fetch(url) }
      fetching[url] = task
      let fetched = await task.value
      // The caller that started the fetch finishes it: clears it and keeps the result.
      let started = shared == nil
      if started, fetching[url] == task { fetching[url] = nil }
      guard fetched.isWorthKeeping else {
        // Not kept, so tried again next time; the site's icon still shows meanwhile.
        let icon = await Task.detached { fetched.icon.flatMap { DocImage.decode($0, maxPixelSize: 64) } }.value
        return DocLinkPreview(metadata: fetched.metadata, icon: icon)
      }
      result = fetched
      if started, let file, let data = try? PropertyListEncoder().encode(fetched) {
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
      }
    }
    guard let result else { return DocLinkPreview() }
    let (image, icon) = await Task.detached {
      (result.image.flatMap { DocImage.decode($0, maxPixelSize: maxPixelSize) }, result.icon.flatMap { DocImage.decode($0, maxPixelSize: 64) })
    }.value
    let preview = DocLinkPreview(metadata: result.metadata, image: image, isIcon: result.isIcon && image != nil, icon: icon)
    decoded.setObject(Decoded(preview), forKey: key)
    return preview
  }

  /// Where a link's preview is kept: one file per address, named by its hash.
  private static func storeURL(_ url: URL) -> URL? {
    guard let folder = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    else { return nil }
    let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    return folder.appending(path: "Bento/LinkPreviews/\(name).plist")
  }

  private static func fetch(_ url: URL) async -> Found {
    async let favicon = favicon(for: url)
    let page = try? await NativeLinkPreviewer().preview(for: url)
    var found = Found(title: page?.title ?? "", summary: page?.summary ?? "", siteName: page?.siteName ?? url.host() ?? "")
    // A page without a title is given its host's name (after a redirect, often with or without
    // "www."), which is no title.
    let host = (url.host() ?? "").lowercased()
    let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    if [bare, "www." + bare].contains(found.title.lowercased()) { found.title = "" }
    // After a redirect to another site, that site's host stands in the same way; it is also
    // what the site name falls back to, so a title equal to a host-like site name is none.
    if found.title == found.siteName, found.title.contains("."), !found.title.contains(" ") { found.title = "" }
    let titled = !found.title.isEmpty
    if let image = page?.image, !image.isEmpty { found.image = image }
    if !titled || found.image == nil, await NativeLinkPreviewer.isPublicWebResolved(url),
      let presented = await linkPresentation(url)
    {
      if !titled, let title = presented.title, !title.isEmpty { found.title = title }
      if found.image == nil, let image = presented.image {
        found.image = image
        found.isIcon = presented.isIcon
      }
      found.icon = presented.icon
    }
    if found.icon == nil { found.icon = await favicon }
    if found.image == nil, let icon = found.icon {
      found.image = icon
      found.isIcon = true
    }
    return found
  }

  /// The page's title, picture (else its icon) and icon as LinkPresentation finds them.
  private static func linkPresentation(_ url: URL) async -> (title: String?, image: Data?, isIcon: Bool, icon: Data?)? {
    let provider = LPMetadataProvider()
    provider.timeout = 12
    guard let found = try? await provider.startFetchingMetadata(for: url) else { return nil }
    var icon: Data?
    if let provider = found.iconProvider { icon = await load(provider) }
    // Kept as a preview at the size the page's own preview images are kept at.
    if let provider = found.imageProvider, let data = await load(provider),
      let image = await Task.detached(operation: { NativeLinkPreviewer.thumbnail(data) }).value
    {
      return (found.title, image, false, icon)
    }
    return (found.title, icon, icon != nil, icon)
  }

  /// The site's `/favicon.ico`, small and from a public address only.
  private static func favicon(for url: URL) async -> Data? {
    guard let host = url.host(), let icon = URL(string: "https://\(host)/favicon.ico"),
      await NativeLinkPreviewer.isPublicWebResolved(icon)
    else { return nil }
    var request = URLRequest(url: icon, timeoutInterval: 8)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    guard let (data, response) = try? await URLSession.shared.data(for: request, delegate: PublicWebRedirects()),
      (response as? HTTPURLResponse)?.statusCode == 200, data.count < 300_000,
      CGImageSourceCreateWithData(data as CFData, nil).map({ CGImageSourceGetCount($0) > 0 }) == true
    else { return nil }
    return data
  }

  private static func load(_ provider: NSItemProvider) async -> Data? {
    await withCheckedContinuation { continuation in
      _ = provider.loadDataRepresentation(for: .image) { data, _ in continuation.resume(returning: data) }
    }
  }
}

/// A toggle: its summary, with the rest folded inside.
struct ToggleRenderer: MarkdownBlockDirectiveRenderer {
  func makeBody(configuration: MarkdownBlockDirectiveRendererConfiguration) -> some View {
    // The renderer hands the inside back indented as a directive's children; without that indent
    // it is the Markdown that was written.
    let lines = configuration.wrappedString.split(separator: "\n", omittingEmptySubsequences: false)
    let indent = lines.filter { !$0.allSatisfy(\.isWhitespace) }.map { $0.prefix { $0 == " " }.count }.min() ?? 0
    let text = lines.map { $0.dropFirst(min(indent, $0.prefix { $0 == " " }.count)) }
    DocToggle(
      summary: text.first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "",
      contents: text.dropFirst().joined(separator: "\n")
    )
  }
}

struct DocToggle: View {
  let summary: String
  let contents: String
  @State private var isExpanded = false

  var body: some View {
    DisclosureGroup(isExpanded: $isExpanded) {
      // The inside renders as its own Markdown, with the same styles and embeds.
      DocMarkdownBody(markdown: contents).padding(.top, 6)
    } label: {
      Text((try? AttributedString(markdown: summary)) ?? AttributedString(summary)).font(.body.weight(.semibold))
    }
  }
}

extension MarkdownBlockDirectiveRendererConfiguration {
  /// The `url:` argument of a post or video.
  var url: URL? {
    arguments.first { $0.name == "url" }.flatMap { URL(string: $0.value) }
  }
}

enum DocImage {
  /// The image at most `maxPixelSize` on its long side, the right way up.
  static func decode(_ data: Data, maxPixelSize: Int) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}
