import Foundation

/// A web page's preview: what Open Graph and Twitter card tags (or, failing those, the page's
/// `<title>` and description) say about it.
public struct LinkMetadata: Hashable, Sendable {
  public var title: String
  public var summary: String
  public var siteName: String
  /// The preview image's address, resolved against the page.
  public var imageURL: URL?
  /// The preview image itself, once fetched; empty until then.
  public var image: Data
  /// Where the page offers its oEmbed description, for pages whose tags say little.
  public var oEmbedURL: URL?

  public init(
    title: String = "", summary: String = "", siteName: String = "", imageURL: URL? = nil, image: Data = Data(),
    oEmbedURL: URL? = nil
  ) {
    self.title = title
    self.summary = summary
    self.siteName = siteName
    self.imageURL = imageURL
    self.image = image
    self.oEmbedURL = oEmbedURL
  }

  /// Reads the preview from a page's HTML. Only `<head>` matters, so the scan stops at `<body>`.
  public static func parse(html: String, url: URL) -> LinkMetadata {
    let head = html.range(of: "<body", options: .caseInsensitive).map { String(html[..<$0.lowerBound]) } ?? html
    var tags: [String: String] = [:]
    for tag in matches(of: #"<meta\s[^>]*>"#, in: head) {
      let attributes = attributes(of: tag)
      guard let key = (attributes["property"] ?? attributes["name"] ?? attributes["itemprop"])?.lowercased(),
        let content = attributes["content"], !content.isEmpty, tags[key] == nil
      else { continue }
      tags[key] = decodeEntities(content)
    }
    let pageTitle = matches(of: #"<title[^>]*>[\s\S]*?</title>"#, in: head).first.map {
      decodeEntities($0.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression))
    }
    let oEmbed = matches(of: #"<link\s[^>]*>"#, in: head).map(attributes(of:)).first {
      $0["type"]?.lowercased() == "application/json+oembed"
    }?["href"].flatMap { URL(string: decodeEntities($0), relativeTo: url)?.absoluteURL }
    let image = tags["og:image:secure_url"] ?? tags["og:image"] ?? tags["og:image:url"] ?? tags["twitter:image"]
      ?? tags["twitter:image:src"] ?? tags["image"]
    return LinkMetadata(
      title: clean(tags["og:title"] ?? tags["twitter:title"] ?? pageTitle ?? ""),
      summary: clean(tags["og:description"] ?? tags["twitter:description"] ?? tags["description"] ?? firstParagraph(html) ?? ""),
      siteName: clean(tags["og:site_name"] ?? tags["application-name"] ?? url.host()?.replacingOccurrences(of: "www.", with: "") ?? ""),
      imageURL: image.flatMap { URL(string: $0, relativeTo: url)?.absoluteURL },
      oEmbedURL: oEmbed
    )
  }

  /// Fills in what an oEmbed response (JSON) adds: its title, author, provider and thumbnail, and
  /// for posts with no title (an X post) the post's text from its HTML.
  public mutating func merge(oEmbed json: Data) {
    guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
    func string(_ key: String) -> String? { (object[key] as? String).map(Self.clean).flatMap { $0.isEmpty ? nil : $0 } }
    let postText = string("html").map { html in
      Self.clean(Self.decodeEntities(
        (Self.matches(of: #"<p[^>]*>[\s\S]*?</p>"#, in: html).first ?? html)
          .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
      ))
    }
    if let title = string("title") {
      self.title = title
    } else if let postText, let author = string("author_name") {
      title = author
      if summary.isEmpty { summary = postText }
    }
    if summary.isEmpty, let author = string("author_name"), string("title") != nil { summary = "By \(author)" }
    if let provider = string("provider_name") { siteName = provider }
    if imageURL == nil, let thumbnail = string("thumbnail_url") { imageURL = URL(string: thumbnail) }
  }

  /// The first paragraph long enough to describe the page, for pages with no description tag.
  static func firstParagraph(_ html: String) -> String? {
    for paragraph in matches(of: #"<p[\s>][\s\S]*?</p>"#, in: html) {
      let text = clean(decodeEntities(paragraph.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)))
      // Wikipedia-style reference marks read as noise in a preview.
      let plain = text.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
      if plain.count >= 80 { return String(plain.prefix(300)) }
    }
    return nil
  }

  private static func matches(of pattern: String, in text: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
      Range($0.range, in: text).map { String(text[$0]) }
    }
  }

  /// A tag's attributes by lowercased name, quoted with either quote.
  private static func attributes(of tag: String) -> [String: String] {
    guard let regex = try? NSRegularExpression(pattern: #"([a-zA-Z_:-]+)\s*=\s*("([^"]*)"|'([^']*)')"#) else { return [:] }
    var result: [String: String] = [:]
    for match in regex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
      guard let name = Range(match.range(at: 1), in: tag) else { continue }
      let value = Range(match.range(at: 3), in: tag) ?? Range(match.range(at: 4), in: tag)
      result[tag[name].lowercased()] = value.map { String(tag[$0]) } ?? ""
    }
    return result
  }

  private static func clean(_ text: String) -> String {
    text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func decodeEntities(_ text: String) -> String {
    guard text.contains("&") else { return text }
    var result = text
    for (entity, character) in [("&quot;", "\""), ("&#39;", "'"), ("&#x27;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " ")] {
      result = result.replacingOccurrences(of: entity, with: character)
    }
    // Numeric references, then `&amp;` last so `&amp;lt;` stays `&lt;`.
    if let regex = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#) {
      for match in regex.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
        guard let range = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result) else { continue }
        let hex = match.range(at: 1).length > 0
        if let code = UInt32(result[digits], radix: hex ? 16 : 10), let scalar = Unicode.Scalar(code) {
          result.replaceSubrange(range, with: String(Character(scalar)))
        }
      }
    }
    return result.replacingOccurrences(of: "&amp;", with: "&")
  }
}
