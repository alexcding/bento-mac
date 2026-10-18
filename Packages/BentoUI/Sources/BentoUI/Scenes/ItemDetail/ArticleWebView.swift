import BentoData
import SwiftUI
import WebKit

/// An HTML detail as a reading page: the source's icon, author and date over the title, then the
/// article. Feed HTML is untrusted, so scripts are off and links open in the browser.
enum ArticlePage {
  static func html(item: FeedItem, body: String, iconURL: URL?) -> String {
    let title = (item.translatedTitle ?? item.title).map { "<h1>\(escape($0))</h1>" } ?? ""
    let author = item.authorName ?? item.authorHandle ?? ""
    let date = item.publishedAt.formatted(date: .abbreviated, time: .shortened)
    let icon = iconURL.map { #"<img class="icon" src="\#(escape($0.absoluteString))" alt="">"# } ?? ""
    return """
      <!doctype html>
      <html><head><meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <meta http-equiv="Content-Security-Policy" content="\(contentPolicy)">
      <style>\(css)</style></head>
      <body><main>
      <header>\(icon)<span class="author">\(escape(author))</span><time>\(escape(date))</time></header>
      \(title)
      <article>\(body)</article>
      </main></body></html>
      """
  }

  /// Feed HTML may show pictures, video and inline styles over https, and embed https frames
  /// (video players). No scripts, stylesheets, fonts, forms or redirects.
  static let contentPolicy =
    "default-src 'none'; img-src https: data:; media-src https:; style-src 'unsafe-inline'; frame-src https:; form-action 'none'"

  static func escape(_ text: String) -> String {
    text.replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  private static let css = """
    :root { color-scheme: light dark; }
    body { margin: 0; font: -apple-system-body; font-family: -apple-system, system-ui, sans-serif;
      line-height: 1.55; color: CanvasText; background: Canvas; }
    main { max-width: 720px; margin: 0 auto; padding: 24px 28px 48px; }
    header { display: flex; align-items: center; gap: 8px; color: GrayText; font-size: 0.85em; }
    header .icon { width: 20px; height: 20px; border-radius: 5px; object-fit: contain; }
    header .author { font-weight: 600; color: CanvasText; }
    header time::before { content: "·"; margin-right: 8px; }
    h1 { font-size: 1.6em; line-height: 1.25; margin: 12px 0 20px; }
    article img, article video, article iframe { max-width: 100%; height: auto; border-radius: 8px; }
    article a { color: AccentColor; color: -apple-system-control-accent; }
    article pre { overflow-x: auto; padding: 12px; border-radius: 8px; background: rgba(127,127,127,0.12); }
    article blockquote { margin: 0; padding-left: 14px; border-left: 3px solid rgba(127,127,127,0.35); color: GrayText; }
    article table { border-collapse: collapse; max-width: 100%; overflow-x: auto; display: block; }
    article td, article th { border: 1px solid rgba(127,127,127,0.3); padding: 4px 8px; }
    """
}

/// Shows an HTML string with scripts off. Clicked links open in the default browser.
@MainActor
struct ArticleWebView {
  let html: String
  let baseURL: URL?

  final class Coordinator: NSObject, WKNavigationDelegate {
    var loaded: String?
    var baseURL: URL?

    /// The page itself, its embeds and its `#` links load; web links open in the browser;
    /// anything else (other schemes, redirects, form posts) is blocked.
    func webView(
      _ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
      decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
    ) {
      guard let url = action.request.url else { return decisionHandler(.cancel) }
      let isPage = action.navigationType == .other && (url == baseURL || url.absoluteString == "about:blank")
      let isEmbed = (action.targetFrame.map { !$0.isMainFrame } ?? false) && url.scheme?.lowercased() == "https"
      if isPage || isEmbed || Self.isSameDocument(url, webView.url) {
        return decisionHandler(.allow)
      }
      decisionHandler(.cancel)
      guard action.navigationType == .linkActivated, ["http", "https", "mailto"].contains(url.scheme?.lowercased())
      else { return }
      #if os(macOS)
        NSWorkspace.shared.open(url)
      #else
        UIApplication.shared.open(url)
      #endif
    }

    static func isSameDocument(_ url: URL, _ current: URL?) -> Bool {
      guard url.fragment != nil, let current else { return false }
      var target = URLComponents(url: url, resolvingAgainstBaseURL: false)
      var page = URLComponents(url: current, resolvingAgainstBaseURL: false)
      target?.fragment = nil
      page?.fragment = nil
      return target == page
    }
  }

  func makeCoordinator() -> Coordinator { Coordinator() }

  private func makeWebView(_ coordinator: Coordinator) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.defaultWebpagePreferences.allowsContentJavaScript = false
    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = coordinator
    return webView
  }

  private func load(_ webView: WKWebView, _ coordinator: Coordinator) {
    guard coordinator.loaded != html else { return }
    coordinator.loaded = html
    coordinator.baseURL = baseURL
    webView.loadHTMLString(html, baseURL: baseURL)
  }
}

#if os(macOS)
  extension ArticleWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateNSView(_ webView: WKWebView, context: Context) { load(webView, context.coordinator) }
  }
#else
  extension ArticleWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context.coordinator) }
    func updateUIView(_ webView: WKWebView, context: Context) { load(webView, context.coordinator) }
  }
#endif
