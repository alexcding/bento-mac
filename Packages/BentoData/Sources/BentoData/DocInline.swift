import Foundation

/// A stretch of a block's text with one set of inline styles.
public struct DocInlineRun: Hashable, Sendable {
  public var text: String
  public var bold = false
  public var italic = false
  public var strike = false
  public var code = false
  /// The link the text points at: a web address, or a `bento-doc` link to another doc.
  public var link: String?

  public init(_ text: String, bold: Bool = false, italic: Bool = false, strike: Bool = false, code: Bool = false, link: String? = nil) {
    self.text = text
    self.bold = bold
    self.italic = italic
    self.strike = strike
    self.code = code
    self.link = link
  }

  func sameStyle(as other: DocInlineRun) -> Bool {
    bold == other.bold && italic == other.italic && strike == other.strike && code == other.code && link == other.link
  }
}

/// Converts between a block's stored text (Markdown inline syntax: `**bold**`, `*italic*` or
/// `_italic_`, `~~struck~~`, `` `code` ``, `[text](url)`) and styled runs, as the editor shows
/// them. `markdown(_:)` writes what `parse(_:)` reads back unchanged, escaping where plain text
/// would otherwise read as syntax.
public enum DocInline {
  public static func parse(_ markdown: String) -> [DocInlineRun] {
    var runs: [DocInlineRun] = []
    parse(Array(markdown), style: DocInlineRun(""), into: &runs)
    return merged(runs)
  }

  /// The text without its syntax.
  public static func plainText(_ markdown: String) -> String {
    parse(markdown).map(\.text).joined()
  }

  public static func markdown(_ runs: [DocInlineRun]) -> String {
    let runs = merged(runs.filter { !$0.text.isEmpty })
    var out = ""
    var open: [Marker] = []

    func close(_ marker: Marker) {
      switch marker {
      case .link(let url): out += "](\(encodeURL(url)))"
      case .bold: out += "**"
      case .italic(let symbol): out += symbol
      case .strike: out += "~~"
      }
    }

    for (index, run) in runs.enumerated() {
      let wanted = wantedMarkers(run, runs: runs, at: index, open: open)
      while !open.isEmpty, !wanted.starts(with: open) {
        close(open.removeLast())
      }
      for marker in wanted.dropFirst(open.count) {
        switch marker {
        case .link: out += "["
        case .bold: out += "**"
        case .italic(let symbol): out += symbol
        case .strike: out += "~~"
        }
        open.append(marker)
      }
      // Code sits inside whatever styles wrap it, as a span of its own.
      out += run.code ? codeSpan(run.text) : escape(run.text, before: out.last, after: runs[safe: index + 1]?.text.first)
    }
    while let last = open.popLast() { close(last) }
    return out
  }

  // MARK: Writing

  private enum Marker: Equatable {
    case link(String)
    case bold
    case italic(String)
    case strike

    var isLink: Bool { if case .link = self { true } else { false } }

    /// Italic markers match whichever symbol was opened.
    func matches(_ other: Marker) -> Bool {
      switch (self, other) {
      case (.italic, .italic): true
      default: self == other
      }
    }
  }

  /// The markers a run needs, outermost first: link, bold, italic, strike. An italic already
  /// open keeps its symbol; a new one is `_` where that reads unambiguously at both ends and `*`
  /// inside a word.
  private static func wantedMarkers(_ run: DocInlineRun, runs: [DocInlineRun], at index: Int, open: [Marker]) -> [Marker] {
    var wanted: [Marker] = []
    if let link = run.link { wanted.append(.link(link)) }
    if run.bold { wanted.append(.bold) }
    if run.italic {
      if let existing = open.first(where: { $0.matches(.italic("")) }), Array(open.prefix(wanted.count)) == wanted {
        wanted.append(existing)
      } else {
        let before = index > 0 ? runs[index - 1].text.last : nil
        var end = index
        while end + 1 < runs.count, runs[end + 1].italic, !runs[end + 1].code { end += 1 }
        let after = runs[safe: end + 1]?.text.first
        let opensClean = before.map { !$0.isLetter && !$0.isNumber } ?? true
        let closesClean = after.map { !$0.isLetter && !$0.isNumber } ?? true
        wanted.append(.italic(opensClean && closesClean ? "_" : "*"))
      }
    }
    if run.strike { wanted.append(.strike) }
    return wanted
  }

  private static func escape(_ text: String, before: Character?, after: Character?) -> String {
    let characters = Array(text)
    var out = ""
    for (index, character) in characters.enumerated() {
      let previous = index > 0 ? characters[index - 1] : before
      let next = index + 1 < characters.count ? characters[index + 1] : after
      switch character {
      case "\\", "*", "`", "[", "]":
        out += "\\\(character)"
      case "~" where previous == "~" || next == "~":
        out += "\\~"
      case "_" where isBoundary(previous) || isBoundary(next):
        out += "\\_"
      default:
        out.append(character)
      }
    }
    return out
  }

  private static func codeSpan(_ text: String) -> String {
    var longest = 0
    var current = 0
    for character in text {
      current = character == "`" ? current + 1 : 0
      longest = max(longest, current)
    }
    let fence = String(repeating: "`", count: longest + 1)
    // A space keeps a backtick at either end apart from the fence.
    let pad = text.hasPrefix("`") || text.hasSuffix("`") ? " " : ""
    return fence + pad + text + pad + fence
  }

  private static func encodeURL(_ url: String) -> String {
    url.replacingOccurrences(of: " ", with: "%20").replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")
  }

  // MARK: Reading

  private static let escapable: Set<Character> = ["\\", "*", "_", "~", "`", "[", "]", "(", ")", "#", "-", "+", ">", "!", "|"]

  private static func parse(_ text: [Character], style: DocInlineRun, into runs: inout [DocInlineRun]) {
    var buffer = ""
    var i = 0

    func flush() {
      guard !buffer.isEmpty else { return }
      var run = style
      run.text = buffer
      runs.append(run)
      buffer = ""
    }

    func has(_ marker: String, at index: Int) -> Bool {
      let marker = Array(marker)
      guard index >= 0, index + marker.count <= text.count else { return false }
      return Array(text[index..<index + marker.count]) == marker
    }

    while i < text.count {
      let character = text[i]
      if character == "\\", i + 1 < text.count, escapable.contains(text[i + 1]) {
        buffer.append(text[i + 1])
        i += 2
        continue
      }
      if character == "`" {
        var fence = 0
        while i + fence < text.count, text[i + fence] == "`" { fence += 1 }
        if let close = closingFence(text, from: i + fence, length: fence) {
          flush()
          var content = String(text[(i + fence)..<close])
          if content.count >= 2, content.hasPrefix(" "), content.hasSuffix(" "), content.contains("`") {
            content = String(content.dropFirst().dropLast())
          }
          var run = style
          run.text = content
          run.code = true
          runs.append(run)
          i = close + fence
          continue
        }
        buffer += String(repeating: "`", count: fence)
        i += fence
        continue
      }
      // A marker opens only before text and closes only after it, so `2 * 3 * 4` stays plain.
      if has("**", at: i), opens(text, at: i + 2), let close = closing(text, marker: "**", from: i + 2), close > i + 2,
        !text[close - 1].isWhitespace
      {
        flush()
        var inner = style
        inner.bold = true
        parse(Array(text[(i + 2)..<close]), style: inner, into: &runs)
        i = close + 2
        continue
      }
      if has("~~", at: i), opens(text, at: i + 2), let close = closing(text, marker: "~~", from: i + 2), close > i + 2,
        !text[close - 1].isWhitespace
      {
        flush()
        var inner = style
        inner.strike = true
        parse(Array(text[(i + 2)..<close]), style: inner, into: &runs)
        i = close + 2
        continue
      }
      if character == "*", !has("**", at: i), opens(text, at: i + 1), let close = closingStar(text, from: i + 1) {
        flush()
        var inner = style
        inner.italic = true
        parse(Array(text[(i + 1)..<close]), style: inner, into: &runs)
        i = close + 1
        continue
      }
      if character == "_", isBoundary(i > 0 ? text[i - 1] : nil), i + 1 < text.count, !text[i + 1].isWhitespace,
        let close = closingUnderscore(text, from: i + 1)
      {
        flush()
        var inner = style
        inner.italic = true
        parse(Array(text[(i + 1)..<close]), style: inner, into: &runs)
        i = close + 1
        continue
      }
      if character == "[", let (close, end, url) = link(text, from: i) {
        flush()
        var inner = style
        inner.link = url
        parse(Array(text[(i + 1)..<close]), style: inner, into: &runs)
        i = end + 1
        continue
      }
      buffer.append(character)
      i += 1
    }
    flush()
  }

  private static func opens(_ text: [Character], at index: Int) -> Bool {
    index < text.count && !text[index].isWhitespace
  }

  /// The `*` closing an italic span: one after text, not part of a `**` pair.
  private static func closingStar(_ text: [Character], from start: Int) -> Int? {
    var from = start
    while let close = closing(text, marker: "*", from: from) {
      if close > start, !text[close - 1].isWhitespace { return close }
      from = close + 1
    }
    return nil
  }

  /// Where a run of exactly `length` backticks closes a code span.
  private static func closingFence(_ text: [Character], from start: Int, length: Int) -> Int? {
    var i = start
    while i < text.count {
      guard text[i] == "`" else {
        i += 1
        continue
      }
      var count = 0
      while i + count < text.count, text[i + count] == "`" { count += 1 }
      if count == length { return i }
      i += count
    }
    return nil
  }

  /// The next unescaped `marker` after `start`, stepping over code spans, links and (for a
  /// single `*`) `**` pairs.
  private static func closing(_ text: [Character], marker: String, from start: Int) -> Int? {
    let marker = Array(marker)
    var i = start
    while i < text.count {
      let character = text[i]
      if character == "\\" {
        i += 2
        continue
      }
      if character == "`" {
        var fence = 0
        while i + fence < text.count, text[i + fence] == "`" { fence += 1 }
        if let close = closingFence(text, from: i + fence, length: fence) {
          i = close + fence
          continue
        }
        i += fence
        continue
      }
      if marker == ["*"], character == "*", i + 1 < text.count, text[i + 1] == "*" {
        // A bold pair inside italic text.
        if let close = closing(text, marker: "**", from: i + 2) {
          i = close + 2
          continue
        }
      }
      if i + marker.count <= text.count, Array(text[i..<i + marker.count]) == marker {
        return i
      }
      i += 1
    }
    return nil
  }

  private static func closingUnderscore(_ text: [Character], from start: Int) -> Int? {
    var i = start
    while i < text.count {
      if text[i] == "\\" {
        i += 2
        continue
      }
      if text[i] == "_", i > start, !text[i - 1].isWhitespace, isBoundary(i + 1 < text.count ? text[i + 1] : nil) {
        return i
      }
      i += 1
    }
    return nil
  }

  /// A `[text](url)` link starting at `start`: where its text closes, where it ends, and its URL.
  private static func link(_ text: [Character], from start: Int) -> (Int, Int, String)? {
    var i = start + 1
    var close: Int?
    while i < text.count {
      if text[i] == "\\" {
        i += 2
        continue
      }
      if text[i] == "[" { return nil }
      if text[i] == "]" {
        close = i
        break
      }
      i += 1
    }
    guard let close, close + 1 < text.count, text[close + 1] == "(" else { return nil }
    var end = close + 2
    while end < text.count, text[end] != ")", !text[end].isWhitespace { end += 1 }
    guard end < text.count, text[end] == ")", end > close + 2 else { return nil }
    let url = String(text[(close + 2)..<end])
      .replacingOccurrences(of: "%28", with: "(").replacingOccurrences(of: "%29", with: ")").replacingOccurrences(of: "%20", with: " ")
    return (close, end, url)
  }

  private static func isBoundary(_ character: Character?) -> Bool {
    guard let character else { return true }
    return !character.isLetter && !character.isNumber
  }

  private static func merged(_ runs: [DocInlineRun]) -> [DocInlineRun] {
    var result: [DocInlineRun] = []
    for run in runs where !run.text.isEmpty {
      if let last = result.last, last.sameStyle(as: run) {
        result[result.count - 1].text += run.text
      } else {
        result.append(run)
      }
    }
    return result
  }
}

extension Array {
  fileprivate subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}
