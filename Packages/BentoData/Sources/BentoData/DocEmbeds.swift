import Foundation

/// The parts of a doc's Markdown that render as more than text: a toggle written as HTML's
/// `<details>`, and a web link on a line of its own, shown as a post, a video or a link card. Each
/// is rewritten as a block directive (`@Toggle`, `@Post`, `@Video`, `@Link`) for the renderer to
/// draw; the stored Markdown keeps the portable form, which other apps show as a fold-out or a
/// link.
///
/// Posts, videos and link previews are shown live from where they are; only their address is
/// kept.
public enum DocEmbeds {
  public static let toggle = "Toggle"
  public static let post = "Post"
  public static let video = "Video"
  public static let link = "Link"

  /// Hosts whose links on a line of their own show as an embedded post.
  static let postHosts = ["x.com", "twitter.com", "mobile.twitter.com", "youtube.com", "m.youtube.com", "youtu.be", "vimeo.com"]
  static let videoExtensions = ["mp4", "m4v", "mov", "webm"]

  /// The Markdown with toggles, posts and videos as block directives. Code blocks are left as
  /// they are. A line of the text itself that starts with `@` (a handle, say) or, inside a toggle,
  /// with `}` is escaped, so it reads as text rather than as directive syntax.
  public static func prepare(_ markdown: String) -> String {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false)
      .map(String.init)
    var out: [String] = []
    var fence: String?
    var toggleDepth = 0
    var index = 0
    while index < lines.count {
      let line = lines[index]
      index += 1
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let open = fence {
        out.append(line)
        if trimmed.hasPrefix(open) { fence = nil }
        continue
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = String(trimmed.prefix(3))
        out.append(line)
        continue
      }
      if var summary = detailsOpening(trimmed) {
        // GitHub's form puts the summary on the next line.
        if summary.isEmpty, let next = lines[index...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
          let found = summaryLine(lines[next].trimmingCharacters(in: .whitespaces))
        {
          summary = found
          index = next + 1
        }
        toggleDepth += 1
        // The summary is the directive's first line, so it needs no quoting as an argument.
        out += ["@\(toggle) {", escaped(summary.isEmpty ? "Details" : summary, inToggle: true), ""]
        continue
      }
      if toggleDepth > 0, trimmed.lowercased().hasSuffix("</details>") {
        let before = String(trimmed.dropLast("</details>".count))
        if !before.trimmingCharacters(in: .whitespaces).isEmpty { out.append(escaped(before, inToggle: true)) }
        toggleDepth -= 1
        out += ["", "}"]
        continue
      }
      if let url = postURL(trimmed) {
        out.append("@\(post)(url: \"\(url)\")")
        continue
      }
      if let url = videoURL(trimmed) {
        out.append("@\(video)(url: \"\(url)\")")
        continue
      }
      // Every style, plain links included, so each can be switched from its context menu.
      if let line = linkLine(trimmed) {
        // The link's own text names it until the page's title is fetched.
        let title = line.text.replacingOccurrences(of: "\"", with: "\u{201D}").replacingOccurrences(of: "\\", with: "")
        out.append("@\(link)(url: \"\(quoted(line.url))\", style: \"\(line.style.rawValue)\", title: \"\(title)\")")
        continue
      }
      out.append(escaped(line, inToggle: toggleDepth > 0))
    }
    // An unclosed toggle runs to the end, as a browser shows it.
    out += Array(repeating: "}", count: toggleDepth)
    return out.joined(separator: "\n")
  }

  /// A line of text with a leading `@`, or a leading `}` inside a toggle, escaped.
  private static func escaped(_ line: String, inToggle: Bool) -> String {
    let indent = line.prefix { $0 == " " }
    let rest = line.dropFirst(indent.count)
    guard rest.hasPrefix("@") || (inToggle && rest.hasPrefix("}")) else { return line }
    return indent + "\\" + rest
  }

  /// The text of a `<summary>…</summary>` line.
  static func summaryLine(_ line: String) -> String? {
    guard let start = line.range(of: "<summary>", options: [.caseInsensitive, .anchored]),
      let end = line.range(of: "</summary>", options: .caseInsensitive, range: start.upperBound..<line.endIndex)
    else { return nil }
    return line[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
  }

  /// The Markdown split into sections of at least `minLength` characters, each starting at a
  /// heading, so a long doc can be laid out a section at a time as it scrolls into view. Code
  /// blocks and toggles are never split; a doc without headings stays whole.
  public static func sections(_ markdown: String, minLength: Int = 2000) -> [String] {
    // Reference links (`[text][1]` with `[1]: url` elsewhere) work only within one document.
    if markdown.range(of: #"(?m)^ {0,3}\[[^\]]+\]:\s"#, options: .regularExpression) != nil { return [markdown] }
    var sections: [String] = []
    var current: [Substring] = []
    var length = 0
    var fence: String?
    var toggles = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let open = fence {
        if trimmed.hasPrefix(open) { fence = nil }
      } else if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = String(trimmed.prefix(3))
      } else if detailsOpening(trimmed) != nil {
        toggles += 1
      } else if toggles > 0, trimmed.lowercased().hasSuffix("</details>") {
        toggles -= 1
      } else if toggles == 0, line.hasPrefix("#"), length >= minLength {
        sections.append(current.joined(separator: "\n"))
        current = []
        length = 0
      }
      current.append(line)
      length += line.count + 1
    }
    if !current.isEmpty { sections.append(current.joined(separator: "\n")) }
    return sections
  }

  /// The summary of a `<details>` line: `<details>` alone, or with `<summary>…</summary>` after.
  static func detailsOpening(_ line: String) -> String? {
    let lower = line.lowercased()
    guard lower.hasPrefix("<details>") || lower.hasPrefix("<details ") else { return nil }
    guard let start = line.range(of: "<summary>", options: .caseInsensitive),
      let end = line.range(of: "</summary>", options: .caseInsensitive, range: start.upperBound..<line.endIndex)
    else { return "" }
    return line[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespaces)
  }

  /// A post's address when the line is nothing but a link to one, bare or as `<url>`.
  static func postURL(_ line: String) -> String? {
    let bare = line.hasPrefix("<") && line.hasSuffix(">") ? String(line.dropFirst().dropLast()) : line
    guard !bare.contains(" "), let url = URL(string: bare), ["http", "https"].contains(url.scheme?.lowercased()),
      let host = url.host()?.lowercased()
    else { return nil }
    let site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    guard postHosts.contains(site) else { return nil }
    // On X a post is a status; elsewhere, any page that is not the site's front page.
    if site.hasSuffix("x.com") || site.hasSuffix("twitter.com") { return url.path().contains("/status/") ? quoted(bare) : nil }
    return url.path().count > 1 || url.query() != nil ? quoted(bare) : nil
  }

  /// How a web link on a line of its own shows, as Craft names them: regular (a compact card, the
  /// default), card (the page's picture large on top), or plain link text. Kept as the Markdown link's title, so
  /// the line stays an ordinary link anywhere else.
  public enum LinkStyle: String, CaseIterable, Sendable {
    case regular, card, text
  }

  /// A line that is nothing but a web link: bare, `<url>`, or `[text](url "style")`.
  public struct LinkLine: Equatable, Sendable {
    public var url: String
    public var text: String
    public var style: LinkStyle
  }

  public static func linkLine(_ line: String) -> LinkLine? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    var address = trimmed.hasPrefix("<") && trimmed.hasSuffix(">") ? String(trimmed.dropFirst().dropLast()) : trimmed
    var text = ""
    var style = LinkStyle.regular
    if let regex = try? NSRegularExpression(pattern: #"^\[((?:\\.|[^\]\\])*)\]\(\s*<?([^)\s>]+)>?(?:\s+"(regular|rect|card|text)")?\s*\)$"#),
      let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
    {
      let group = { (index: Int) in Range(match.range(at: index), in: trimmed).map { String(trimmed[$0]) } }
      text = group(1) ?? ""
      address = group(2) ?? ""
      // "rect" is an older name for regular.
      style = group(3).flatMap { $0 == "rect" ? .regular : LinkStyle(rawValue: $0) } ?? .regular
    }
    guard !address.contains(" "), let url = URL(string: address), ["http", "https"].contains(url.scheme?.lowercased()),
      url.host() != nil
    else { return nil }
    return LinkLine(url: address, text: text, style: style)
  }

  /// The Markdown for a link line in `style`; its text is kept.
  public static func markdown(_ line: LinkLine) -> String {
    switch line.style {
    case .regular: line.text.isEmpty ? line.url : "[\(line.text)](\(line.url))"
    case .card: "[\(line.text)](\(line.url) \"card\")"
    // Plain link text is what shows, so a link without any shows its address.
    case .text: "[\(line.text.isEmpty ? line.url : line.text)](\(line.url) \"text\")"
    }
  }

  /// `markdown` with every line that is a link to `url` shown in `style`; code blocks are left as
  /// they are.
  public static func restyleLinks(_ markdown: String, url: String, style: LinkStyle) -> String {
    var fence: String?
    return markdown.split(separator: "\n", omittingEmptySubsequences: false).map { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let open = fence {
        if trimmed.hasPrefix(open) { fence = nil }
        return String(line)
      }
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        fence = String(trimmed.prefix(3))
        return String(line)
      }
      guard var link = linkLine(String(line)), link.url == url else { return String(line) }
      let indent = line.prefix { $0 == " " }
      link.style = style
      return indent + self.markdown(link)
    }
    .joined(separator: "\n")
  }

  /// A video's address when the line is nothing but a Markdown image of a video file.
  static func videoURL(_ line: String) -> String? {
    guard let address = DocMarkdown.imageURL(line), let url = URL(string: address),
      ["http", "https"].contains(url.scheme?.lowercased()), videoExtensions.contains(url.pathExtension.lowercased())
    else { return nil }
    return quoted(address)
  }

  /// An address safe inside a directive's quoted argument.
  private static func quoted(_ address: String) -> String {
    address.replacingOccurrences(of: "\"", with: "%22")
  }
}
