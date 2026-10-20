import Foundation

/// Turns an article's HTML into Markdown, for saving it to a doc: paragraphs, headings, list
/// items, quotes, code, images, bold, italic and links. Scripts, styles and anything else are
/// dropped.
public enum DocHTML {
  /// The article as Markdown, one blank line between blocks, its images at their full address.
  public static func markdown(from html: String, baseURL: URL? = nil) -> String {
    let (converted, code) = markdownText(html)
    var text = converted
      .split(separator: "\n", omittingEmptySubsequences: false)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .joined(separator: "\n")
      .replacingOccurrences(of: #"\n{3,}"#, with: "\n\n", options: .regularExpression)
      .replacingOccurrences(of: #"(?<=\S) {2,}(?=\S)"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespacesAndNewlines)
    // Code goes back last, after the tidying, so its indentation and blank lines stay as written.
    text = replace(#"\x{E000}(\d+)\x{E001}"#, in: text) { match in
      Int(match[1]).flatMap { code.indices.contains($0) ? "```\n" + code[$0] + "\n```" : nil } ?? ""
    }
    return DocMarkdown.absoluteImages(text, baseURL: baseURL)
  }

  /// The article as Markdown, its code blocks still behind placeholders.
  private static func markdownText(_ html: String) -> (String, [String]) {
    var text = html
    // Whole elements that carry nothing to read.
    for tag in ["script", "style", "head", "noscript", "svg"] {
      text = replace(#"<\#(tag)\b[\s\S]*?</\#(tag)>"#, in: text, with: "")
    }
    // Code blocks keep their text exactly: set aside behind placeholders while the rest is
    // converted, and put back last.
    var code: [String] = []
    text = replace(#"<pre\b[^>]*>([\s\S]*?)</pre>"#, in: text) { match in
      code.append(LinkMetadata.decodeEntities(stripTags(match[1])))
      return "\n\u{E000}\(code.count - 1)\u{E001}\n"
    }
    // Images get lines of their own, as Markdown images, which become file blocks to fetch.
    text = replace(#"<img\b[^>]*?\bsrc\s*=\s*["']([^"']+)["'][^>]*>"#, in: text) { match in
      match[1].hasPrefix("data:") ? "" : "\n![](\(match[1]))\n"
    }
    // Inline styles, tag by tag rather than as pairs, so unclosed tags cost no backtracking; a
    // stray marker reads back as plain text.
    // Spaces just inside a tag go outside its marker, as Markdown emphasis cannot start before a
    // space or end after one; a pair with nothing inside is dropped.
    text = replace(#"<(strong|b)\b[^>]*>(\s*)</(strong|b)>"#, in: text, with: "$2")
    text = replace(#"<(em|i)\b[^>]*>(\s*)</(em|i)>"#, in: text, with: "$2")
    text = replace(#"<(strong|b)\b[^>]*>(\s*)"#, in: text, with: "$2**")
    text = replace(#"(\s*)</(strong|b)>"#, in: text, with: "**$1")
    text = replace(#"<(em|i)\b[^>]*>(\s*)"#, in: text, with: "$2_")
    text = replace(#"(\s*)</(em|i)>"#, in: text, with: "_$1")
    text = replace(#"</?code\b[^>]*>"#, in: text, with: "`")
    // Links are short; the bound keeps an unclosed one from scanning the rest of the page.
    text = replace(#"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]{0,2000}?)</a>"#, in: text) { match in
      // A linked image keeps its own line, outside the link: a link cannot hold a file block.
      var images: [String] = []
      let rest = replace(#"!\[\]\([^)\n]*\)"#, in: match[2]) {
        images.append($0[0])
        return " "
      }
      let label = stripTags(rest).trimmingCharacters(in: .whitespacesAndNewlines)
      let link = label.isEmpty ? "" : "[\(label)](\(match[1]))"
      return images.reversed().map { "\n\($0)\n" }.joined() + link
    }
    // Block elements each start a line, with the Markdown that marks their kind.
    for level in 1...6 {
      let marks = String(repeating: "#", count: min(level, 4))
      text = replace(#"<h\#(level)\b[^>]*>([\s\S]*?)</h\#(level)>"#, in: text) { "\n\(marks) " + oneLine($0[1]) + "\n" }
    }
    text = replace(#"<li\b[^>]*>([\s\S]*?)</li>"#, in: text) { "\n- " + oneLine($0[1]) + "\n" }
    text = replace(#"<blockquote\b[^>]*>([\s\S]*?)</blockquote>"#, in: text) { "\n> " + oneLine($0[1]) + "\n" }
    text = replace(#"<hr\b[^>]*>"#, in: text, with: "\n---\n")
    text = replace(#"<br\s*/?>"#, in: text, with: "\n")
    text = replace(#"</?(p|div|section|article|header|footer|ul|ol|table|tr|figure|figcaption)\b[^>]*>"#, in: text, with: "\n")
    text = LinkMetadata.decodeEntities(stripTags(text))
    return (text, code)
  }

  private static func stripTags(_ text: String) -> String {
    replace(#"<[^>]+>"#, in: text, with: "")
  }

  /// An element's text on one line, its own line breaks folded into spaces.
  private static func oneLine(_ text: String) -> String {
    stripTags(text).split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }

  private static func replace(_ pattern: String, in text: String, with template: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
  }

  private static func replace(_ pattern: String, in text: String, _ transform: ([String]) -> String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
    var result = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: result) else { continue }
      let groups = (0..<match.numberOfRanges).map { index in
        Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
      }
      result.replaceSubrange(range, with: transform(groups))
    }
    return result
  }
}
