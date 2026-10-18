import Foundation

/// Converts between doc blocks and Markdown: pasted or imported text becomes blocks, and a doc
/// exports as Markdown. Block structure is parsed; inline Markdown (bold, italic, strikethrough,
/// code, links) stays in the text, which is how blocks store it.
///
/// Titles map to heading levels: Title `#`, Subtitle `##`, Heading `###`, Strong `####`. Focus
/// is a quote, Caption is `<small>`. Looks with no Markdown form (color, font, alignment) are
/// left out of an export.
public enum DocMarkdown {
  public static func blocks(from markdown: String) -> [DocContent] {
    var blocks: [DocContent] = []
    var code: (language: String, lines: [String])?
    var table: [[String]] = []

    func flushTable() {
      guard !table.isEmpty else { return }
      blocks.append(DocContent(kind: .table, text: DocTable(rows: table).json))
      table = []
    }

    for line in markdown.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false) {
      let line = String(line)
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if let open = code {
        if trimmed.hasPrefix("```") {
          blocks.append(DocContent(kind: .code, text: open.lines.joined(separator: "\n"), language: open.language))
          code = nil
        } else {
          code = (open.language, open.lines + [line])
        }
        continue
      }
      if trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count > 1 {
        let cells = trimmed.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
          .map { $0.trimmingCharacters(in: .whitespaces) }
        // The `| --- | --- |` line under the header carries no cells.
        if !cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { table.append(cells) }
        continue
      }
      flushTable()
      if trimmed.hasPrefix("```") {
        code = (String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces), [])
        continue
      }
      if let block = block(fromLine: line) { blocks.append(block) }
    }
    flushTable()
    if let code { blocks.append(DocContent(kind: .code, text: code.lines.joined(separator: "\n"), language: code.language)) }
    return blocks
  }

  /// One line's block; nil for a blank line.
  static func block(fromLine line: String) -> DocContent? {
    let indent = indentLevel(line)
    // Only leading space is dropped: a typed shortcut ends in one ("# ").
    let body = String(line.drop { $0 == " " || $0 == "\t" })
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { return nil }
    if ["---", "***", "___"].contains(trimmed) { return DocContent(kind: .divider) }
    // A list marker with nothing after it (editors drop the trailing space) is an empty item.
    // Only markers that are not also ordinary text on a line of their own: a lone "*" or
    // "2024." stays text.
    switch trimmed {
    case "-": return DocContent(kind: .bullet, indent: indent)
    case "- [ ]", "* [ ]": return DocContent(kind: .todo, indent: indent)
    case "- [x]", "* [x]", "- [X]", "* [X]": return DocContent(kind: .todo, isChecked: true, indent: indent)
    case "▸": return DocContent(kind: .toggle, indent: indent)
    default: break
    }
    let headings: [(String, DocBlock.Kind)] = [("#### ", .strong), ("### ", .heading), ("## ", .subtitle), ("# ", .title)]
    for (prefix, kind) in headings where body.hasPrefix(prefix) {
      return DocContent(kind: kind, text: String(body.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
    }
    if body.hasPrefix("#####") {
      return DocContent(kind: .strong, text: String(body.drop { $0 == "#" }).trimmingCharacters(in: .whitespaces))
    }
    for prefix in ["- [ ] ", "* [ ] ", "- [x] ", "* [x] ", "- [X] ", "* [X] ", "[] ", "[ ] "] where body.hasPrefix(prefix) {
      let checked = prefix.contains("x") || prefix.contains("X")
      return DocContent(kind: .todo, text: String(body.dropFirst(prefix.count)), isChecked: checked, indent: indent)
    }
    if body.hasPrefix("▸ ") {
      return DocContent(kind: .toggle, text: String(body.dropFirst(2)), indent: indent)
    }
    for prefix in ["- ", "* ", "+ "] where body.hasPrefix(prefix) {
      return DocContent(kind: .bullet, text: String(body.dropFirst(prefix.count)), indent: indent)
    }
    if let dot = body.firstIndex(of: "."), !body[..<dot].isEmpty, body[..<dot].allSatisfy(\.isNumber),
      body[body.index(after: dot)...].hasPrefix(" ")
    {
      return DocContent(kind: .numbered, text: String(body[body.index(dot, offsetBy: 2)...]), indent: indent)
    }
    if body.hasPrefix("> ") || trimmed == ">" {
      return DocContent(text: String(body.dropFirst()).trimmingCharacters(in: .whitespaces), indent: indent, decoration: .focus)
    }
    if trimmed.hasPrefix("<small>"), trimmed.hasSuffix("</small>") {
      return DocContent(kind: .caption, text: String(trimmed.dropFirst(7).dropLast(8)))
    }
    if !trimmed.contains(" "), let url = URL(string: trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))),
      url.scheme == "http" || url.scheme == "https"
    {
      return DocContent(kind: .link, text: url.absoluteString)
    }
    return DocContent(text: trimmed, indent: indent)
  }

  /// The block a typed prefix turns a plain text block into, as Craft does: "# " a title,
  /// "- " a bullet, "[] " a to-do, "> " Focus, "---" a divider. Nil when the text has no such
  /// prefix.
  public static func shortcut(_ text: String) -> DocContent? {
    guard !text.contains("\n") else { return nil }
    // Typed markers turn into a style only once followed by a space, so "-" stays a dash.
    let bare = text.trimmingCharacters(in: .whitespaces)
    if ["-", "*", "+", "[]", "[ ]", "- [ ]", "▸"].contains(bare) || (bare.hasSuffix(".") && bare.dropLast().allSatisfy(\.isNumber)),
      !text.hasSuffix(" ")
    {
      return nil
    }
    if text.hasPrefix("```") { return DocContent(kind: .code, language: String(text.dropFirst(3))) }
    guard let block = block(fromLine: text), block.kind != .link,
      block.kind != .text || block.decoration != .none
    else { return nil }
    return block
  }

  /// The URL when `text` is nothing but a web link, as when one is pasted into an empty block.
  public static func linkURL(_ text: String) -> String? {
    guard let block = block(fromLine: text), block.kind == .link else { return nil }
    return block.text
  }

  /// The doc as Markdown, its title as the first heading. `pageTitles` names the docs inside
  /// page and card blocks, by block index.
  public static func markdown(title: String, blocks: [DocContent], pageTitles: [Int: String] = [:]) -> String {
    var lines: [String] = []
    if !title.isEmpty { lines += ["# \(title)", ""] }
    var numbers: [Int: Int] = [:]
    var previous: DocBlock.Kind?
    for (index, block) in blocks.enumerated() {
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
      case .page, .card: line = ["**\(pageTitles[index] ?? block.text)**"]
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

  private static func indentLevel(_ line: String) -> Int {
    var width = 0
    for character in line {
      if character == " " { width += 1 } else if character == "\t" { width += 2 } else { break }
    }
    return width / 2
  }
}
