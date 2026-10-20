import Foundation

/// Markdown helpers for docs: images made absolute or listed for fetching, and (for the "Docs as
/// Markdown" migration only) the writer that turned the old blocks into Markdown.
public enum DocMarkdown {
  /// The Markdown with its images' relative addresses read against `baseURL`, so they load
  /// wherever the text is shown.
  public static func absoluteImages(_ markdown: String, baseURL: URL?) -> String {
    guard let baseURL, let regex = try? NSRegularExpression(pattern: #"(!\[[^\]]*\]\(\s*<?)([^)\s>]+)"#) else {
      return markdown
    }
    var result = markdown
    for match in regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).reversed() {
      guard let range = Range(match.range(at: 2), in: result) else { continue }
      let address = String(result[range])
      guard URL(string: address)?.scheme == nil, let url = URL(string: address, relativeTo: baseURL)?.absoluteURL,
        ["http", "https"].contains(url.scheme?.lowercased())
      else { continue }
      result.replaceSubrange(range, with: url.absoluteString)
    }
    return result
  }

  /// The web images a doc's Markdown shows, in order, without repeats; videos are left out, as
  /// they stay where they are.
  public static func webImageURLs(_ markdown: String) -> [String] {
    guard let regex = try? NSRegularExpression(pattern: #"!\[[^\]]*\]\(\s*<?(https?://[^)\s>]+)"#) else { return [] }
    var seen: Set<String> = []
    return regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).compactMap { match in
      guard let range = Range(match.range(at: 1), in: markdown) else { return nil }
      let address = String(markdown[range])
      let ext = URL(string: address)?.pathExtension.lowercased() ?? ""
      guard !DocEmbeds.videoExtensions.contains(ext), seen.insert(address).inserted else { return nil }
      return address
    }
  }

  /// The address of a Markdown image, `![alt](url)` (with an optional title), that is the whole
  /// line.
  static func imageURL(_ line: String) -> String? {
    guard line.hasPrefix("!["), line.hasSuffix(")"),
      let regex = try? NSRegularExpression(pattern: #"^!\[[^\]]*\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)$"#),
      let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
      let range = Range(match.range(at: 1), in: line)
    else { return nil }
    return String(line[range])
  }

  /// The doc as Markdown, its title as the first heading. Page and card blocks are turned into
  /// links by the migration before they get here.
  static func markdown(title: String, blocks: [DocContent]) -> String {
    var lines: [String] = []
    if !title.isEmpty { lines += ["# \(title)", ""] }
    var numbers: [Int: Int] = [:]
    var previous: DocBlock.Kind?
    for block in blocks {
      let pad = String(repeating: "  ", count: block.indent)
      if block.kind != .numbered { numbers = [:] }
      if let previous, !(previous.isList && block.kind.isList), lines.last != "" { lines.append("") }
      var line: [String]
      switch block.kind {
      case .text: line = ["\(pad)\(block.text)"]
      case .title: line = ["# \(block.text)"]
      case .subtitle: line = ["## \(block.text)"]
      case .heading: line = ["### \(block.text)"]
      case .strong: line = ["#### \(block.text)"]
      case .caption: line = ["<small>\(block.text)</small>"]
      case .bullet: line = ["\(pad)- \(block.text)"]
      case .toggle: line = ["\(pad)▸ \(block.text)"]
      case .numbered:
        numbers = numbers.filter { $0.key <= block.indent }
        let number = (numbers[block.indent] ?? 0) + 1
        numbers[block.indent] = number
        line = ["\(pad)\(number). \(block.text)"]
      case .todo: line = ["\(pad)- [\(block.isChecked ? "x" : " ")] \(block.text)"]
      case .code: line = ["```\(block.language)", block.text, "```"]
      case .divider: line = ["---"]
      case .link: line = ["<\(block.text)>"]
      case .file: line = ["[\(block.text)](\(block.text.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? block.text))"]
      case .page, .card: line = ["\(pad)\(block.text)"]
      case .table: line = tableLines(DocTable(json: block.text))
      }
      if block.decoration == .focus { line = line.map { "> \($0)" } }
      lines += line
      previous = block.kind
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func tableLines(_ table: DocTable) -> [String] {
    func row(_ cells: [String]) -> String {
      "| " + cells.map { $0.replacingOccurrences(of: "|", with: "\\|") }.joined(separator: " | ") + " |"
    }
    guard let header = table.rows.first else { return [] }
    return [row(header), row(Array(repeating: "---", count: header.count))] + table.rows.dropFirst().map(row)
  }
}
