import Foundation

/// What can be inserted into a doc, from the `/` menu or the tools panel: the Markdown it writes,
/// or a picker it opens.
struct MarkdownInsert: Identifiable, Hashable {
  enum Action: Hashable {
    /// Markdown for a line of its own; `cursor` is where the caret lands, counted from its start.
    case block(String, cursor: Int)
    /// Markdown inside the line; `cursor` as for a block.
    case inline(String, cursor: Int)
    /// Restyles the line the cursor is in (`# `, `- `, `> `; empty for body text), as a style
    /// does in a word processor.
    case line(String)
    case docLink, image, file
  }

  let name: String
  let symbol: String
  let keywords: [String]
  let action: Action
  var id: String { name }

  func matches(_ query: String) -> Bool {
    query.isEmpty || name.localizedCaseInsensitiveContains(query) || keywords.contains { $0.hasPrefix(query.lowercased()) }
  }

  static let sections: [(String, [MarkdownInsert])] = [
    ("Text", [
      MarkdownInsert(name: "Body", symbol: "text.alignleft", keywords: ["text", "paragraph", "plain"], action: .line("")),
      MarkdownInsert(name: "Heading 1", symbol: "textformat.size.larger", keywords: ["h1", "title"], action: .line("# ")),
      MarkdownInsert(name: "Heading 2", symbol: "textformat.size", keywords: ["h2", "subtitle"], action: .line("## ")),
      MarkdownInsert(name: "Heading 3", symbol: "textformat.size.smaller", keywords: ["h3"], action: .line("### ")),
      MarkdownInsert(name: "Quote", symbol: "text.quote", keywords: ["blockquote", "focus"], action: .line("> ")),
    ]),
    ("Lists", [
      MarkdownInsert(name: "Bulleted List", symbol: "list.bullet", keywords: ["bullet", "ul"], action: .line("- ")),
      MarkdownInsert(name: "Numbered List", symbol: "list.number", keywords: ["ol", "number"], action: .line("1. ")),
      MarkdownInsert(name: "Task List", symbol: "checklist", keywords: ["todo", "checkbox"], action: .line("- [ ] ")),
      MarkdownInsert(
        name: "Toggle", symbol: "chevron.right.square", keywords: ["details", "fold", "collapse"],
        action: .block("<details><summary>Summary</summary>\n\n\n</details>", cursor: 18)
      ),
    ]),
    ("Blocks", [
      MarkdownInsert(name: "Code Block", symbol: "chevron.left.forwardslash.chevron.right", keywords: ["code", "fence"], action: .block("```\n\n```", cursor: 4)),
      MarkdownInsert(
        name: "Table", symbol: "tablecells", keywords: ["grid"],
        action: .block("| Column | Column |\n| --- | --- |\n|  |  |", cursor: 2)
      ),
      MarkdownInsert(name: "Divider", symbol: "minus", keywords: ["line", "hr", "separator"], action: .block("---\n", cursor: 4)),
    ]),
    ("Insert", [
      MarkdownInsert(name: "Link to Doc", symbol: "arrow.up.right.square", keywords: ["doc", "page", "backlink"], action: .docLink),
      MarkdownInsert(name: "Link", symbol: "link", keywords: ["url", "web"], action: .inline("[](https://)", cursor: 1)),
      MarkdownInsert(
        name: "Link Preview", symbol: "rectangle.and.text.magnifyingglass", keywords: ["bookmark", "regular", "url"],
        action: .block("https://", cursor: 8)
      ),
      MarkdownInsert(
        name: "Link Card", symbol: "rectangle.portrait.and.arrow.right", keywords: ["card", "bookmark", "url"],
        action: .block("[](https:// \"card\")", cursor: 11)
      ),
      MarkdownInsert(name: "Image", symbol: "photo", keywords: ["picture", "photo"], action: .image),
      MarkdownInsert(name: "File", symbol: "doc", keywords: ["attachment", "pdf"], action: .file),
    ]),
  ]

  static let all = sections.flatMap(\.1)

  static func named(_ name: String) -> MarkdownInsert { all.first { $0.name == name }! }
}

/// The rules that make typing Markdown easy: lists that continue on Return, indenting that nests,
/// and the `/` and `[[` menus.
enum MarkdownEditing {
  /// A list or quote line's indentation, marker (`- `, `3. `, `- [ ] `, `> `) and text.
  struct ListLine: Equatable {
    var indent: String
    var marker: String
    var text: String
  }

  /// `line` restyled with `prefix`: any heading, list or quote marker it had replaced; the same
  /// style again turns it back into body text. List indentation is kept; a heading has none.
  static func restyled(_ line: String, with prefix: String) -> String {
    let indent = String(line.prefix { $0 == " " })
    var rest = String(line.dropFirst(indent.count))
    var current = ""
    if let heading = rest.range(of: #"^#{1,6} "#, options: .regularExpression) {
      current = String(rest[heading])
    } else if let item = listLine(rest) {
      current = item.marker
    }
    rest.removeFirst(current.count)
    let same = current == prefix || (Int(current.dropLast(2)) != nil && Int(prefix.dropLast(2)) != nil)
    let next = same ? "" : prefix
    return (next.hasPrefix("#") ? "" : indent) + next + rest
  }

  static func listLine(_ line: String) -> ListLine? {
    let indent = String(line.prefix { $0 == " " || $0 == "\t" })
    let rest = line.dropFirst(indent.count)
    for marker in ["- [ ] ", "- [x] ", "- [X] ", "* [ ] ", "- ", "* ", "+ ", "> "] where rest.hasPrefix(marker) {
      return ListLine(indent: indent, marker: marker, text: String(rest.dropFirst(marker.count)))
    }
    let digits = rest.prefix(while: \.isNumber)
    if !digits.isEmpty, digits.count < 10, rest.dropFirst(digits.count).hasPrefix(". ") {
      return ListLine(indent: indent, marker: digits + ". ", text: String(rest.dropFirst(digits.count + 2)))
    }
    return nil
  }

  /// What Return does at the end of `line`: start the next item (numbers counting on, tasks
  /// unchecked), or end the list when the item is empty.
  enum Return: Equatable {
    case continueWith(String)
    case endList
  }

  static func onReturn(after line: String) -> Return? {
    guard let item = listLine(line) else { return nil }
    if item.text.trimmingCharacters(in: .whitespaces).isEmpty { return .endList }
    var marker = item.marker
    if let number = Int(marker.dropLast(2)) {
      marker = "\(number + 1). "
    } else if marker.hasSuffix("] ") {
      marker = String(marker.prefix(1)) + " [ ] "
    }
    return .continueWith(item.indent + marker)
  }

  /// The indentation that nests `line` under the list item above it: its text's column, which is
  /// what Markdown needs (two spaces under `- `, three under `1. `).
  static func indented(_ line: String, linesAbove: [String]) -> String {
    let current = line.prefix { $0 == " " }.count
    for above in linesAbove.reversed() where !above.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let item = listLine(above) else { break }
      let column = item.indent.count + item.marker.count
      if column > current { return String(repeating: " ", count: column) + line.dropFirst(current) }
      if item.indent.count < current { break }
    }
    return String(repeating: " ", count: current + 2) + line.dropFirst(current)
  }

  /// `line` moved out one level: to the indentation of the item it is nested under.
  static func outdented(_ line: String, linesAbove: [String]) -> String {
    let current = line.prefix { $0 == " " }.count
    guard current > 0 else { return line }
    var target = 0
    for above in linesAbove.reversed() where !above.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let item = listLine(above) else { break }
      if item.indent.count < current {
        target = item.indent.count
        break
      }
    }
    return String(repeating: " ", count: target) + line.dropFirst(current)
  }

  enum MenuKind: Equatable { case insert, docLink }

  /// A menu being typed at the cursor: `/heading` or `[[physics`, and where its trigger starts.
  struct MenuTrigger: Equatable {
    var kind: MenuKind
    var query: String
    /// The trigger and query, in UTF-16 offsets into the text, replaced by the choice.
    var range: NSRange
  }

  /// The menu the text before the cursor opens: `/` at the start of a line or after a space,
  /// `[[` anywhere; each followed by what has been typed since.
  static func trigger(in text: String, cursor: Int) -> MenuTrigger? {
    let ns = text as NSString
    guard cursor <= ns.length else { return nil }
    let lineStart = ns.lineRange(for: NSRange(location: cursor, length: 0)).location
    let before = ns.substring(with: NSRange(location: lineStart, length: cursor - lineStart))
    if let open = before.range(of: "[[", options: .backwards) {
      let query = String(before[open.upperBound...])
      if !query.contains("]"), query.count <= 40 {
        let start = lineStart + before[..<open.lowerBound].utf16.count
        return MenuTrigger(kind: .docLink, query: query, range: NSRange(location: start, length: cursor - start))
      }
    }
    if let slash = before.range(of: "/", options: .backwards) {
      let query = String(before[slash.upperBound...])
      let atWordStart = slash.lowerBound == before.startIndex || before[before.index(before: slash.lowerBound)] == " "
      if atWordStart, query.count <= 20, !query.contains(" "), !query.contains("/") {
        let start = lineStart + before[..<slash.lowerBound].utf16.count
        return MenuTrigger(kind: .insert, query: query, range: NSRange(location: start, length: cursor - start))
      }
    }
    return nil
  }
}
