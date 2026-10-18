import BentoData
import Foundation

#if os(macOS)
  import AppKit
  typealias PlatformFont = NSFont
  typealias PlatformColor = NSColor
  typealias PlatformFontDescriptor = NSFontDescriptor
#else
  import UIKit
  typealias PlatformFont = UIFont
  typealias PlatformColor = UIColor
  typealias PlatformFontDescriptor = UIFontDescriptor
#endif

// The editor shows a doc as one text: the title, then one paragraph per visible block. Each
// paragraph carries its block's identity and looks in `.docParagraph`; inline styles are kept as
// flags (`.docBold` and the rest) rather than read back from fonts, so a heading's bold weight is
// never mistaken for bold text. Blocks that are not text (files, tables, pages, link cards,
// separators) are a single attachment character.

extension NSAttributedString.Key {
  /// The paragraph's block: a `DocParagraph`.
  static let docParagraph = NSAttributedString.Key("BentoDocParagraph")
  /// Marks the title paragraph.
  static let docTitle = NSAttributedString.Key("BentoDocTitle")
  static let docBold = NSAttributedString.Key("BentoDocBold")
  static let docItalic = NSAttributedString.Key("BentoDocItalic")
  static let docStrike = NSAttributedString.Key("BentoDocStrike")
  static let docCode = NSAttributedString.Key("BentoDocCode")
}

/// What a paragraph is: its block (id and looks; text aside) and the number its list item shows.
final class DocParagraph: NSObject {
  let block: DocBlock
  let listNumber: Int

  init(block: DocBlock, listNumber: Int = 0) {
    self.block = block
    self.listNumber = listNumber
  }

  override func isEqual(_ object: Any?) -> Bool {
    guard let other = object as? DocParagraph else { return false }
    return other.block == block && other.listNumber == listNumber
  }

  override var hash: Int { block.id.hashValue }
}

/// Line separators keep a block's own line breaks inside its paragraph.
let docLineSeparator: Character = "\u{2028}"
let docAttachmentCharacter: Character = "\u{FFFC}"

/// Sizes and spacing, close to Craft's.
enum DocMetrics {
  #if os(macOS)
    static let body: CGFloat = 15
  #else
    static let body: CGFloat = 17
  #endif
  static let docTitle: CGFloat = body * 2.1
  static let indentStep: CGFloat = 26
  /// The column bullets, numbers, checkboxes and toggles sit in.
  static let markerWidth: CGFloat = 26
  static let focusInset: CGFloat = 16
  static let plateInset: CGFloat = 14
  static let lineHeight: CGFloat = 1.32

  static func size(_ kind: DocBlock.Kind) -> CGFloat {
    switch kind {
    case .title: body * 1.75
    case .subtitle: body * 1.4
    case .heading: body * 1.18
    case .caption: body * 0.85
    case .code: body * 0.92
    default: body
    }
  }

  static func spacingBefore(_ kind: DocBlock.Kind) -> CGFloat {
    switch kind {
    case .title: body * 1.3
    case .subtitle: body * 1.0
    case .heading: body * 0.75
    case .strong: body * 0.4
    case .bullet, .numbered, .todo, .toggle: 1
    default: body * 0.35
    }
  }
}

enum DocTextStyle {
  static func font(for block: DocBlock, bold: Bool = false, italic: Bool = false, code: Bool = false) -> PlatformFont {
    let size = DocMetrics.size(block.kind)
    if code || block.kind == .code {
      return PlatformFont.monospacedSystemFont(ofSize: code ? size * 0.92 : size, weight: bold ? .semibold : .regular)
    }
    let weight: PlatformFont.Weight = switch block.kind {
    case .title, .subtitle: .bold
    case .heading, .strong: bold ? .bold : .semibold
    default: bold ? .bold : .regular
    }
    var font = PlatformFont.systemFont(ofSize: size, weight: weight)
    let design: PlatformFontDescriptor.SystemDesign? = switch block.font {
    case .system: nil
    case .serif: .serif
    case .mono: .monospaced
    case .rounded: .rounded
    }
    if let design, let descriptor = font.fontDescriptor.withDesign(design) {
      font = PlatformFont(descriptor: descriptor, size: size) ?? font
    }
    if italic { font = font.italicVariant }
    return font
  }

  static var titleFont: PlatformFont { PlatformFont.systemFont(ofSize: DocMetrics.docTitle, weight: .bold) }

  static func color(for block: DocBlock) -> PlatformColor {
    if block.kind == .todo, block.isChecked { return .secondaryLabelColor }
    switch block.color {
    case .standard: return block.kind == .caption ? .secondaryLabelColor : .labelColor
    case .gray: return .systemGray
    case .lightGray: return .systemGray.withAlphaComponent(0.6)
    case .purple: return .systemPurple
    case .blue: return .systemBlue
    case .cyan: return .systemCyan
    case .teal: return .systemTeal
    case .green: return .systemGreen
    case .yellow: return .systemYellow
    case .orange: return .systemOrange
    case .red: return .systemRed
    }
  }

  /// Where the text starts: the indent, the marker column, and room for a decoration.
  static func textInset(for block: DocBlock) -> CGFloat {
    var inset = CGFloat(block.indent) * DocMetrics.indentStep
    if block.kind.hasMarker { inset += DocMetrics.markerWidth }
    if block.decoration == .focus { inset += DocMetrics.focusInset }
    if block.decoration == .block || block.kind == .code { inset += DocMetrics.plateInset }
    return inset
  }

  static func paragraphStyle(for block: DocBlock) -> NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    let inset = textInset(for: block)
    style.firstLineHeadIndent = inset
    style.headIndent = inset
    if block.decoration == .block || block.kind == .code { style.tailIndent = -DocMetrics.plateInset }
    style.lineHeightMultiple = block.kind == .code ? 1.15 : DocMetrics.lineHeight
    style.paragraphSpacingBefore = DocMetrics.spacingBefore(block.kind)
    let plate = block.decoration == .block || block.kind == .code
    style.paragraphSpacing = plate ? DocMetrics.body * 0.6 : 2
    if plate { style.paragraphSpacingBefore += DocMetrics.body * 0.5 }
    style.alignment = switch block.alignment {
    case .leading: .natural
    case .center: .center
    case .trailing: .right
    case .justified: .justified
    }
    return style
  }

  static var titleParagraphStyle: NSParagraphStyle {
    let style = NSMutableParagraphStyle()
    style.paragraphSpacing = DocMetrics.body * 0.6
    style.lineHeightMultiple = 1.1
    return style
  }
}

extension DocBlock.Kind {
  /// Kinds drawn with a bullet, number, checkbox or toggle in the margin.
  var hasMarker: Bool { isList }
  /// Kinds shown as an embedded view rather than text: a link shows as its preview card.
  var isAttachment: Bool { !isEditable || self == .link }
}

extension PlatformFont {
  var italicVariant: PlatformFont {
    #if os(macOS)
      let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.italic))
      return PlatformFont(descriptor: descriptor, size: pointSize) ?? self
    #else
      guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(.traitItalic)) else { return self }
      return PlatformFont(descriptor: descriptor, size: pointSize)
    #endif
  }
}

#if os(iOS)
  extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
    static var tertiaryLabelColor: UIColor { .tertiaryLabel }
    static var separatorColor: UIColor { .separator }
  }
#endif

// MARK: Writing a doc into text

/// Builds the editor's text from blocks.
@MainActor
enum DocTextRenderer {
  /// The whole doc: the title, then each block. Every paragraph ends in a line break that
  /// carries its attributes, so an empty block keeps its identity and looks.
  static func render(
    title: String, blocks: [DocBlock], host: (any DocAttachmentHost)?, displayText: (DocBlock) -> String
  ) -> NSAttributedString {
    let text = NSMutableAttributedString(attributedString: renderTitle(title))
    let numbers = listNumbers(blocks)
    for block in blocks {
      text.append(renderParagraph(block, number: numbers[block.id] ?? 0, host: host, displayText: displayText(block)))
    }
    return text
  }

  /// The title paragraph, its line break included.
  static func renderTitle(_ title: String) -> NSAttributedString {
    NSAttributedString(string: title + "\n", attributes: titleAttributes)
  }

  static var titleAttributes: [NSAttributedString.Key: Any] {
    [
      .docTitle: true, .font: DocTextStyle.titleFont, .foregroundColor: PlatformColor.labelColor,
      .paragraphStyle: DocTextStyle.titleParagraphStyle,
    ]
  }

  /// A block's paragraph, its line break included.
  static func renderParagraph(_ block: DocBlock, number: Int, host: (any DocAttachmentHost)?, displayText: String) -> NSAttributedString {
    let text = NSMutableAttributedString(attributedString: render(block, number: number, host: host, displayText: displayText))
    text.append(NSAttributedString(string: "\n", attributes: separatorAttributes(block, number: number)))
    return text
  }

  /// One block's paragraph, without the separator that ends it.
  static func render(_ block: DocBlock, number: Int, host: (any DocAttachmentHost)?, displayText: String) -> NSAttributedString {
    let paragraph = DocParagraph(block: block, listNumber: number)
    let base: [NSAttributedString.Key: Any] = [
      .docParagraph: paragraph,
      .paragraphStyle: DocTextStyle.paragraphStyle(for: block),
      .font: DocTextStyle.font(for: block),
      .foregroundColor: DocTextStyle.color(for: block),
    ]
    if block.kind.isAttachment {
      var attributes = base
      attributes[.attachment] = DocBlockAttachment(blockID: block.id, kind: block.kind, host: host)
      return NSAttributedString(string: String(docAttachmentCharacter), attributes: attributes)
    }
    let runs = block.kind == .code ? [DocInlineRun(block.text)] : DocInline.parse(displayText)
    let text = NSMutableAttributedString()
    for run in runs {
      var attributes = base
      attributes[.font] = DocTextStyle.font(for: block, bold: run.bold, italic: run.italic, code: run.code)
      if run.bold { attributes[.docBold] = true }
      if run.italic { attributes[.docItalic] = true }
      if run.strike || (block.kind == .todo && block.isChecked) {
        attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
      }
      if run.strike { attributes[.docStrike] = true }
      if run.code, block.kind != .code {
        attributes[.docCode] = true
        attributes[.backgroundColor] = PlatformColor.secondaryLabelColor.withAlphaComponent(0.12)
        attributes[.foregroundColor] = PlatformColor.systemPink
      }
      if let link = run.link, let url = URL(string: link) { attributes[.link] = url }
      let string = run.text.replacingOccurrences(of: "\n", with: String(docLineSeparator))
      text.append(NSAttributedString(string: string, attributes: attributes))
    }
    if text.length == 0 {
      // An empty paragraph still carries its block, through the separator after it.
      return NSAttributedString(string: "", attributes: base)
    }
    return text
  }

  /// The attributes a paragraph's separator takes, so typing at the end of an empty paragraph
  /// and the paragraph's layout keep its block.
  static func separatorAttributes(_ block: DocBlock, number: Int) -> [NSAttributedString.Key: Any] {
    [
      .docParagraph: DocParagraph(block: block, listNumber: number),
      .paragraphStyle: DocTextStyle.paragraphStyle(for: block),
      .font: DocTextStyle.font(for: block),
      .foregroundColor: DocTextStyle.color(for: block),
    ]
  }

  /// The number each numbered item shows: its place in the run of numbered items at its level.
  static func listNumbers(_ blocks: [DocBlock]) -> [DocBlock.ID: Int] {
    var numbers: [DocBlock.ID: Int] = [:]
    var counters: [Int: Int] = [:]
    for block in blocks {
      counters = counters.filter { $0.key < block.indent || (block.kind == .numbered && $0.key == block.indent) }
      if block.kind == .numbered {
        let number = (counters[block.indent] ?? 0) + 1
        counters[block.indent] = number
        numbers[block.id] = number
      } else if !(block.kind.isList || block.indent > 0) {
        counters = [:]
      }
    }
    return numbers
  }
}

// MARK: Reading text back into blocks

/// A paragraph as the editor holds it: its block (if it has one yet), looks and Markdown text.
struct DocParagraphState: Equatable {
  /// The block the paragraph came from; nil for text pasted or typed outside any block.
  var blockID: DocBlock.ID?
  /// Looks, from the paragraph's attributes; `text` is ignored.
  var block: DocBlock?
  var isTitle: Bool
  var markdown: String
  /// For an attachment paragraph, the attachment's block.
  var attachmentID: DocBlock.ID?
}

@MainActor
enum DocTextReader {
  /// Reads every paragraph. An attachment found inside a text paragraph (text typed or merged
  /// next to it) is split out as a paragraph of its own.
  static func paragraphs(_ text: NSAttributedString) -> [DocParagraphState] {
    let string = text.string as NSString
    var states: [DocParagraphState] = []
    var location = 0
    while location < string.length {
      let range = string.paragraphRange(for: NSRange(location: location, length: 0))
      var content = range
      if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
      states += paragraph(text, content: content, at: range)
      if range.length == 0 { break }
      location = NSMaxRange(range)
    }
    // The empty line after the last paragraph's break is not a block; it is where a click below
    // the doc puts the cursor, and text typed there becomes one.
    return states
  }

  /// One paragraph of the text: `content` without its line break, `range` with it.
  static func paragraph(_ text: NSAttributedString, content: NSRange, at range: NSRange) -> [DocParagraphState] {
    let probe = min(range.location, max(text.length - 1, 0))
    let attributes = text.length > 0 ? text.attributes(at: probe, effectiveRange: nil) : [:]
    let isTitle = attributes[.docTitle] as? Bool == true && attributes[.docParagraph] == nil
    let paragraph = attributes[.docParagraph] as? DocParagraph
    if isTitle {
      return [DocParagraphState(blockID: nil, block: nil, isTitle: true, markdown: plain(text, content))]
    }
    let isCode = paragraph?.block.kind == .code
    // Text on an embedded block's line (typed next to it, or left when it was deleted) is never
    // that block: it becomes a body line of its own.
    var ownsText = paragraph.map { !$0.block.kind.isAttachment } ?? true
    let looks: DocBlock? = paragraph.map { paragraph in
      guard paragraph.block.kind.isAttachment else { return paragraph.block }
      var block = DocBlock(docID: paragraph.block.docID)
      block.indent = paragraph.block.indent
      return block
    }
    var states: [DocParagraphState] = []
    var runs: [DocInlineRun] = []
    var start = true

    func flushText() {
      let markdown = isCode ? runs.map(\.text).joined() : DocInline.markdown(runs)
      // Text found after an attachment is a paragraph without a block of its own.
      states.append(
        DocParagraphState(blockID: start && ownsText ? paragraph?.block.id : nil, block: looks, isTitle: false, markdown: markdown)
      )
      runs = []
      start = false
      ownsText = true
    }

    var sawText = false
    text.enumerateAttributes(in: content) { attributes, runRange, _ in
      if let attachment = attributes[.attachment] as? DocBlockAttachment {
        for _ in 0..<runRange.length {
          if sawText || !runs.isEmpty { flushText() } else { start = false }
          let owner = attributes[.docParagraph] as? DocParagraph
          states.append(
            DocParagraphState(
              blockID: attachment.blockID, block: owner?.block.id == attachment.blockID ? owner?.block : nil,
              isTitle: false, markdown: "", attachmentID: attachment.blockID
            )
          )
          sawText = false
        }
        return
      }
      sawText = true
      let raw = (text.string as NSString).substring(with: runRange)
        .replacingOccurrences(of: String(docLineSeparator), with: "\n")
        .replacingOccurrences(of: String(docAttachmentCharacter), with: "")
      var run = DocInlineRun(raw)
      run.bold = attributes[.docBold] as? Bool == true
      run.italic = attributes[.docItalic] as? Bool == true
      run.strike = attributes[.docStrike] as? Bool == true
      run.code = attributes[.docCode] as? Bool == true
      if let url = attributes[.link] as? URL { run.link = url.absoluteString } else if let link = attributes[.link] as? String { run.link = link }
      runs.append(run)
    }
    if sawText || states.isEmpty { flushText() }
    return states
  }

  private static func plain(_ text: NSAttributedString, _ range: NSRange) -> String {
    (text.string as NSString).substring(with: range).replacingOccurrences(of: String(docLineSeparator), with: " ")
  }
}
