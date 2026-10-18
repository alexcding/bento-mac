import Foundation

/// Turns an article's HTML into doc blocks, for saving it to a doc: paragraphs, headings, list
/// items, quotes and code become blocks; bold, italic, code and links become inline Markdown.
/// Scripts, styles and anything else are dropped.
public enum DocHTML {
  public static func blocks(from html: String) -> [DocContent] {
    var text = html
    // Whole elements that carry nothing to read.
    for tag in ["script", "style", "head", "noscript", "svg"] {
      text = replace(#"<\#(tag)\b[\s\S]*?</\#(tag)>"#, in: text, with: "")
    }
    // Code blocks keep their text as is, fenced.
    text = replace(#"<pre\b[^>]*>([\s\S]*?)</pre>"#, in: text) { match in
      "\n```\n" + LinkMetadata.decodeEntities(stripTags(match[1])) + "\n```\n"
    }
    // Inline styles and links, as the Markdown blocks store.
    text = replace(#"<(strong|b)\b[^>]*>([\s\S]*?)</\1>"#, in: text) { "**" + $0[2] + "**" }
    text = replace(#"<(em|i)\b[^>]*>([\s\S]*?)</\1>"#, in: text) { "_" + $0[2] + "_" }
    text = replace(#"<code\b[^>]*>([\s\S]*?)</code>"#, in: text) { "`" + $0[1] + "`" }
    text = replace(#"<a\b[^>]*href\s*=\s*["']([^"']+)["'][^>]*>([\s\S]*?)</a>"#, in: text) { match in
      let label = stripTags(match[2]).trimmingCharacters(in: .whitespacesAndNewlines)
      return label.isEmpty ? "" : "[\(label)](\(match[1]))"
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
    return DocMarkdown.blocks(from: text)
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
