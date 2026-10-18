import BentoData
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// What the controller needs from the platform text view.
@MainActor
protocol DocTextViewing: AnyObject {
  var docTextStorage: NSTextStorage { get }
  var docTextLayoutManager: NSTextLayoutManager? { get }
  var docSelectedRange: NSRange { get set }
  var docTypingAttributes: [NSAttributedString.Key: Any] { get set }
  var docHasMarkedText: Bool { get }
  /// A character range's bounds in the editor's coordinates (top-left origin, visible area).
  func docRect(for range: NSRange) -> CGRect?
  func docScrollToSelection()
  /// A rect in text container coordinates, in the text view's own.
  func docFrame(fromContainer rect: CGRect) -> CGRect
  func docAddSubview(_ view: PlatformView)
  func docNeedsLayout()
}

/// Keeps the text view and the model in step. Edits in the text view are read back as
/// paragraphs and given to the model (`applyParagraphs`); changes in the model (undo, Format,
/// Insert, sync from another device) are drawn into the text by replacing just the paragraphs
/// that differ, keeping the cursor where it was.
@MainActor
final class DocTextController: NSObject, DocAttachmentHost {
  let model: DocEditorViewModel
  let state = DocTextState()
  let layoutDelegate: DocLayoutDelegate
  /// The Mac text view's TextKit 2 storage, kept here as TextKit holds it weakly.
  let contentStorage = NSTextContentStorage()
  weak var view: (any DocTextViewing)?

  /// What the text shows now, as blocks (looks and Markdown text; places ignored).
  private var shown: [DocBlock] = []
  private var shownTitle: String?
  private var shownLinkTitles: [Doc.ID: String] = [:]
  /// Set while the controller itself changes the text, so those changes are not read back.
  private(set) var isUpdating = false
  private var attachmentViews: [DocBlock.ID: PlatformView] = [:]
  private var attachmentHeights: [DocBlock.ID: CGFloat] = [:]
  private var lastFocusRequest: DocEditorViewModel.FocusRequest?

  init(model: DocEditorViewModel) {
    self.model = model
    layoutDelegate = DocLayoutDelegate(state: state)
    super.init()
    model.inlineFormatter = { [weak self] in self?.toggleInline($0) }
    model.linkInserter = { [weak self] in self?.insertDocLink($0, id: $1, title: $2) }
    model.slashRemover = { [weak self] in self?.removeQuery($0, prefix: "/") }
    model.linkFormatter = { [weak self] url in
      guard let self, let range = self.view?.docSelectedRange else { return }
      self.setLink(url, on: range)
    }
  }

  // MARK: Model to text

  /// Draws what changed in the model into the text.
  func syncFromModel() {
    guard let view, !isUpdating, !view.docHasMarkedText else { return }
    let target = model.visibleBlocks.map(Self.normalized)
    let title = model.title
    let linkTitles = model.linkedTitles
    var focus: DocEditorViewModel.FocusRequest?
    if let request = model.focusRequest, request != lastFocusRequest {
      lastFocusRequest = request
      focus = request
    }
    if target != shown || title != shownTitle || linkTitles != shownLinkTitles {
      redraw(target, title: title, linkTitles: linkTitles)
    }
    if let focus { place(caretIn: focus.id, at: focus.offset) }
  }

  private func redraw(_ target: [DocBlock], title: String, linkTitles: [Doc.ID: String]) {
    guard let view else { return }
    let storage = view.docTextStorage
    let selection = savedSelection()
    let ranges = paragraphRanges(storage)
    isUpdating = true
    storage.beginEditing()
    if shownTitle != nil, target.map(\.id) == shown.map(\.id), ranges.count == target.count + 1 {
      let numbers = DocTextRenderer.listNumbers(target)
      let linksChanged = linkTitles != shownLinkTitles
      // Back to front, so earlier ranges stay valid.
      for (index, block) in target.enumerated().reversed() where index + 1 < ranges.count {
        let range = ranges[index + 1]
        let number = numbers[block.id] ?? 0
        let current = storage.attribute(.docParagraph, at: range.location, effectiveRange: nil) as? DocParagraph
        let linked = linksChanged && !DocLink.docIDs(in: block.text).isEmpty
        if block != shown[index] || linked {
          storage.replaceCharacters(
            in: range, with: DocTextRenderer.renderParagraph(block, number: number, host: self, displayText: model.displayText(block))
          )
        } else if current?.listNumber != number || current?.block != block {
          storage.addAttribute(.docParagraph, value: DocParagraph(block: block, listNumber: number), range: range)
        }
      }
      if title != shownTitle, let range = ranges.first {
        storage.replaceCharacters(in: range, with: DocTextRenderer.renderTitle(title))
      }
    } else {
      storage.setAttributedString(DocTextRenderer.render(title: title, blocks: target, host: self) { self.model.displayText($0) })
    }
    storage.endEditing()
    isUpdating = false
    shown = target
    shownTitle = title
    shownLinkTitles = linkTitles
    restore(selection)
    updateTypingAttributes()
    updateRects()
    view.docNeedsLayout()
  }

  private static func normalized(_ block: DocBlock) -> DocBlock {
    var block = block
    block.position = 0
    return block
  }

  // MARK: Text to model

  /// The edit the text view is about to make, for the one-paragraph fast path.
  private var pendingEdit: (range: NSRange, replacement: String)?

  /// The text view is about to replace `range` with `replacement` (nil: change attributes). Only
  /// an edit that replaces no line break or embedded block can take the fast path.
  func willChange(_ range: NSRange, replacement: String?) {
    pendingEdit = nil
    guard !isUpdating, let replacement, let storage = view?.docTextStorage, NSMaxRange(range) <= storage.length else { return }
    if let id = blockID(at: range.location) {
      let line = (storage.string as NSString).paragraphRange(for: NSRange(location: range.location, length: 0))
      model.editWillStart(in: id, at: range.location - line.location)
    }
    let replaced = (storage.string as NSString).substring(with: range)
    guard !replaced.contains("\n"), !replaced.contains(docAttachmentCharacter) else { return }
    pendingEdit = (range, replacement)
  }

  /// The user changed the text: read it back and give it to the model.
  func textDidChange() {
    guard let view, !isUpdating, !view.docHasMarkedText else { return }
    let edit = pendingEdit
    pendingEdit = nil
    defer { model.editDidEnd() }
    if let edit, applyWithinParagraph(edit) { return }
    let storage = view.docTextStorage
    let paragraphs = DocTextReader.paragraphs(storage)
    let caret = blockID(at: view.docSelectedRange.location)
    let assigned = model.applyParagraphs(paragraphs, caretBlockID: caret)
    let ranges = paragraphRanges(storage)
    if paragraphs.count != ranges.count {
      // Text split around an embedded block shares its line; draw it all afresh, the cursor in
      // the new block.
      shown = []
      shownTitle = nil
      syncFromModel()
      if let last = assigned.max(by: { $0.key < $1.key })?.value { place(caretAtEndOf: last) }
      selectionDidChange()
      return
    }
    // Mark new paragraphs with their blocks, so the text knows them from now on.
    if !assigned.isEmpty {
      isUpdating = true
      for (index, id) in assigned where ranges.indices.contains(index) {
        guard let block = model.block(id) else { continue }
        storage.addAttribute(.docParagraph, value: DocParagraph(block: block), range: ranges[index])
      }
      isUpdating = false
    }
    // What the text now shows; anything the model changed besides (a new block's looks, a
    // typed shortcut, list numbers) is drawn in next.
    shown = paragraphs.enumerated().compactMap { index, paragraph -> DocBlock? in
      if paragraph.isTitle { return nil }
      if let id = paragraph.attachmentID { return model.block(id).map(Self.normalized) }
      guard var block = paragraph.block else { return nil }
      if let id = assigned[index], let new = model.block(id) {
        // A new paragraph still looks like the one it was split from; it is redrawn as its block.
        block = new
        block.text = "\u{FFFF}"
      } else {
        block.text = paragraph.markdown
      }
      return Self.normalized(block)
    }
    shownTitle = paragraphs.first?.isTitle == true ? paragraphs[0].markdown : nil
    syncFromModel()
    selectionDidChange()
  }

  /// Typing inside one paragraph, which is most edits: reads and saves just that paragraph.
  /// False when the edit may change the doc's structure, for the full path.
  private func applyWithinParagraph(_ edit: (range: NSRange, replacement: String)) -> Bool {
    guard let view, shownTitle != nil else { return false }
    let structural: Set<Character> = ["\n", docAttachmentCharacter, "\r"]
    guard !edit.replacement.contains(where: structural.contains) else { return false }
    let storage = view.docTextStorage
    let string = storage.string as NSString
    let location = min(edit.range.location, string.length)
    let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
    // The edit stayed inside the paragraph: its new end is still within it.
    guard location + (edit.replacement as NSString).length <= NSMaxRange(paragraph) else { return false }
    var content = paragraph
    if content.length > 0, string.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
    let states = DocTextReader.paragraph(storage, content: content, at: paragraph)
    guard states.count == 1, let state = states.first, state.attachmentID == nil else { return false }
    if state.isTitle {
      guard paragraph.location == 0 else { return false }
      model.setTitle(state.markdown)
      shownTitle = state.markdown
    } else {
      guard let id = state.blockID, let index = shown.firstIndex(where: { $0.id == id }),
        model.applyParagraph(state, caretBlockID: blockID(at: view.docSelectedRange.location))
      else { return false }
      if var block = state.block {
        block.text = state.markdown
        shown[index] = Self.normalized(block)
      }
    }
    syncFromModel()
    selectionDidChange()
    return true
  }

  // MARK: Selection

  func selectionDidChange() {
    guard let view, !isUpdating else { return }
    let selection = view.docSelectedRange
    let focused = blockID(at: selection.location)
    let selected = blockIDs(in: selection)
    let string = view.docTextStorage.string as NSString
    let line = string.paragraphRange(for: NSRange(location: min(selection.location, string.length), length: 0))
    model.selectionChanged(focused: focused, selected: selection.length > 0 ? selected : [], offset: selection.location - line.location)
    let caretMoved = state.caretBlockID != focused
    let previous = state.caretBlockID
    state.caretBlockID = focused
    if caretMoved { redrawHints(previous, focused) }
    updateTypingAttributes()
    updateQueries()
    updateRects()
  }

  /// Positions for the popups and the format bar.
  func updateRects() {
    guard let view else { return }
    let selection = view.docSelectedRange
    model.caretRect = view.docRect(for: NSRange(location: selection.location, length: 0))
    let rect = selection.length > 0 ? view.docRect(for: selection) : nil
    if model.selectionRect != rect { model.selectionRect = rect }
  }

  private func redrawHints(_ ids: DocBlock.ID?...) {
    guard let view, let layout = view.docTextLayoutManager, let content = layout.textContentManager else { return }
    let ranges = paragraphRanges(view.docTextStorage)
    for id in ids.compactMap({ $0 }) {
      guard let index = shown.firstIndex(where: { $0.id == id }), index + 1 < ranges.count,
        let range = textRange(ranges[index + 1], in: content)
      else { continue }
      layout.invalidateLayout(for: range)
    }
  }

  /// Typing goes into the paragraph the cursor is in, even an empty one, whose only character
  /// is its line break. Text views take typing attributes from the character before the cursor,
  /// which there is the previous paragraph's break.
  private func updateTypingAttributes() {
    guard let view else { return }
    let storage = view.docTextStorage
    let selection = view.docSelectedRange
    guard selection.length == 0, storage.length > 0 else { return }
    let string = storage.string as NSString
    let paragraph = string.paragraphRange(for: NSRange(location: min(selection.location, string.length), length: 0))
    let onAttachmentLine = paragraph.location < storage.length
      && storage.attribute(.attachment, at: paragraph.location, effectiveRange: nil) != nil
    let atStart = selection.location == paragraph.location
    guard atStart || onAttachmentLine, paragraph.location < storage.length else { return }
    var attributes = storage.attributes(at: paragraph.location, effectiveRange: nil)
    let onAttachment = attributes[.attachment] != nil
      || (attributes[.docParagraph] as? DocParagraph)?.block.kind.isAttachment == true
    attributes[.attachment] = nil
    if string.character(at: paragraph.location) == 0x0A || onAttachment {
      for key in [NSAttributedString.Key.docBold, .docItalic, .docStrike, .docCode, .link, .backgroundColor] {
        attributes[key] = nil
      }
    }
    if onAttachment {
      // Typed next to an embedded block, text starts a body line of its own.
      let line = DocBlock(docID: model.docID)
      attributes.merge(DocTextRenderer.separatorAttributes(line, number: 0)) { _, new in new }
    }
    view.docTypingAttributes = attributes
  }

  // MARK: Commands

  /// Return: picks a popup choice, adds a line inside a code block, or ends a list on an empty
  /// item. False lets the text view start a new paragraph.
  func handleReturn() -> Bool {
    if model.choosePopupSelection() { return true }
    guard let view, let id = blockID(at: view.docSelectedRange.location), let block = model.block(id) else { return false }
    if block.kind == .code {
      insertText(String(docLineSeparator))
      return true
    }
    return model.endList(id)
  }

  /// Delete at the start of a block: takes off its style, keeps embedded blocks above from being
  /// merged into, and never merges into the title.
  func handleDeleteBackward() -> Bool {
    guard let view else { return false }
    let selection = view.docSelectedRange
    let storage = view.docTextStorage
    // Delete right after an embedded block, or with it selected, deletes the block (undoably).
    let target = selection.length == 1 ? selection.location : selection.location - 1
    if selection.length <= 1, target >= 0, target < storage.length,
      let attachment = storage.attribute(.attachment, at: target, effectiveRange: nil) as? DocBlockAttachment
    {
      model.remove(attachment.blockID)
      return true
    }
    guard selection.length == 0, selection.location > 0 else { return false }
    let string = storage.string as NSString
    let paragraph = string.paragraphRange(for: NSRange(location: selection.location, length: 0))
    guard paragraph.location == selection.location else { return false }
    guard let id = blockID(at: selection.location) else { return false }
    if model.unstyle(id) { return true }
    let previous = string.paragraphRange(for: NSRange(location: paragraph.location - 1, length: 0))
    let isEmpty = string.character(at: paragraph.location) == 0x0A
    if storage.attribute(.docTitle, at: previous.location, effectiveRange: nil) as? Bool == true,
      storage.attribute(.docParagraph, at: previous.location, effectiveRange: nil) == nil
    {
      // Into the title only an empty line goes.
      if isEmpty { model.remove(id) }
      return true
    }
    if storage.attribute(.attachment, at: previous.location, effectiveRange: nil) != nil {
      if isEmpty {
        model.remove(id)
      } else {
        view.docSelectedRange = NSRange(location: previous.location, length: 1)
      }
      return true
    }
    return false
  }

  /// Tab and Shift-Tab.
  func handleIndent(by offset: Int) -> Bool {
    guard let view else { return false }
    let ids = blockIDs(in: view.docSelectedRange)
    guard !ids.isEmpty else { return false }
    model.indent(ids, by: offset)
    return true
  }

  /// A click on a checkbox or toggle in the margin. `point` is in text container coordinates.
  func handleMarkerClick(at point: CGPoint) -> Bool {
    guard let layout = view?.docTextLayoutManager,
      let fragment = layout.textLayoutFragment(for: point) as? DocParagraphFragment,
      let rect = fragment.markerRect, let block = fragment.paragraph?.block
    else { return false }
    let local = CGPoint(x: point.x - fragment.layoutFragmentFrame.minX, y: point.y - fragment.layoutFragmentFrame.minY)
    guard rect.insetBy(dx: -4, dy: -4).contains(local) else { return false }
    if block.kind == .todo { model.toggleChecked(block.id) } else { model.toggleCollapsed(block.id) }
    return true
  }

  /// Bold, italic, strikethrough or code on the selection, or for what is typed next.
  func toggleInline(_ style: DocEditorViewModel.InlineStyle) {
    guard let view else { return }
    let key: NSAttributedString.Key = switch style {
    case .bold: .docBold
    case .italic: .docItalic
    case .strike: .docStrike
    case .code: .docCode
    }
    let selection = view.docSelectedRange
    let storage = view.docTextStorage
    guard selection.length > 0 else {
      var typing = view.docTypingAttributes
      typing[key] = typing[key] == nil ? true : nil
      view.docTypingAttributes = restyled(typing)
      return
    }
    var allOn = true
    storage.enumerateAttribute(key, in: selection) { value, _, stop in
      if value as? Bool != true {
        allOn = false
        stop.pointee = true
      }
    }
    storage.beginEditing()
    if allOn { storage.removeAttribute(key, range: selection) } else { storage.addAttribute(key, value: true, range: selection) }
    storage.enumerateAttributes(in: selection) { attributes, range, _ in
      storage.setAttributes(restyled(attributes), range: range)
    }
    storage.endEditing()
    textDidChange()
    view.docSelectedRange = selection
  }

  /// A web link on the selection, or none when `url` is empty.
  func setLink(_ url: String, on range: NSRange) {
    guard let view, range.length > 0 else { return }
    let storage = view.docTextStorage
    if let link = URL(string: url.trimmingCharacters(in: .whitespaces)), !url.isEmpty {
      storage.addAttribute(.link, value: link, range: range)
    } else {
      storage.removeAttribute(.link, range: range)
    }
    textDidChange()
  }

  /// Fonts, colours and backgrounds that follow from a run's style flags and its paragraph.
  private func restyled(_ attributes: [NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any] {
    guard let block = (attributes[.docParagraph] as? DocParagraph)?.block else { return attributes }
    var attributes = attributes
    let code = attributes[.docCode] as? Bool == true
    attributes[.font] = DocTextStyle.font(
      for: block, bold: attributes[.docBold] as? Bool == true, italic: attributes[.docItalic] as? Bool == true, code: code
    )
    attributes[.strikethroughStyle] =
      attributes[.docStrike] as? Bool == true || (block.kind == .todo && block.isChecked) ? NSUnderlineStyle.single.rawValue : nil
    attributes[.backgroundColor] = code ? PlatformColor.secondaryLabelColor.withAlphaComponent(0.12) : nil
    attributes[.foregroundColor] = code ? PlatformColor.systemPink : DocTextStyle.color(for: block)
    return attributes
  }

  private func insertText(_ text: String) {
    guard let view else { return }
    let selection = view.docSelectedRange
    view.docTextStorage.replaceCharacters(in: selection, with: NSAttributedString(string: text, attributes: view.docTypingAttributes))
    view.docSelectedRange = NSRange(location: selection.location + (text as NSString).length, length: 0)
    textDidChange()
  }

  // MARK: `[[` and `/`

  /// Puts the cursor in a block and types `/`, opening the block menu there.
  func startSlash(in id: DocBlock.ID) {
    guard let view else { return }
    place(caretAtEndOf: id)
    let location = view.docSelectedRange.location
    view.docTextStorage.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: "/", attributes: view.docTypingAttributes))
    view.docSelectedRange = NSRange(location: location + 1, length: 0)
    textDidChange()
  }

  /// Looks at the text before the cursor for a `[[` link or `/` command being typed.
  private func updateQueries() {
    guard let view else { return }
    let selection = view.docSelectedRange
    guard selection.length == 0, let id = blockID(at: selection.location), let block = model.block(id), block.kind.isEditable,
      block.kind != .code
    else {
      model.linkQueryChanged(nil)
      model.slashQueryChanged(nil)
      return
    }
    let before = textBeforeCaret()
    if let open = before.range(of: "[[", options: .backwards) {
      let query = String(before[open.upperBound...])
      if !query.contains("]"), query.count <= 60 {
        model.linkQueryChanged(.init(blockID: id, query: query))
        model.slashQueryChanged(nil)
        return
      }
    }
    model.linkQueryChanged(nil)
    if let slash = before.range(of: "/", options: .backwards) {
      let query = String(before[slash.upperBound...])
      let startsWord = slash.lowerBound == before.startIndex || before[before.index(before: slash.lowerBound)].isWhitespace
      if startsWord, query.count <= 24, !query.contains(where: \.isWhitespace) || query.isEmpty {
        model.slashQueryChanged(.init(blockID: id, query: query))
        return
      }
    }
    model.slashQueryChanged(nil)
  }

  /// The caret paragraph's text up to the cursor.
  private func textBeforeCaret() -> String {
    guard let view else { return "" }
    let string = view.docTextStorage.string as NSString
    let location = min(view.docSelectedRange.location, string.length)
    let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
    return string.substring(with: NSRange(location: paragraph.location, length: location - paragraph.location))
  }

  /// Replaces `[[query` before the cursor with a link to the doc, shown with its title.
  private func insertDocLink(_ query: DocEditorViewModel.CaretQuery, id: Doc.ID, title: String) {
    guard let view, let range = queryRange(query, prefix: "[[") else { return }
    let storage = view.docTextStorage
    var attributes = storage.attributes(at: max(range.location - 1, 0), effectiveRange: nil)
    if range.location < storage.length { attributes = storage.attributes(at: range.location, effectiveRange: nil) }
    attributes[.link] = DocLink.url(id)
    attributes[.attachment] = nil
    let text = NSMutableAttributedString(string: title.isEmpty ? "Untitled" : title, attributes: restyled(attributes))
    var plain = attributes
    plain[.link] = nil
    text.append(NSAttributedString(string: " ", attributes: restyled(plain)))
    storage.replaceCharacters(in: range, with: text)
    view.docSelectedRange = NSRange(location: range.location + text.length, length: 0)
    textDidChange()
  }

  private func removeQuery(_ query: DocEditorViewModel.CaretQuery, prefix: String) {
    guard let view, let range = queryRange(query, prefix: prefix) else { return }
    view.docTextStorage.replaceCharacters(in: range, with: "")
    view.docSelectedRange = NSRange(location: range.location, length: 0)
    textDidChange()
  }

  private func queryRange(_ query: DocEditorViewModel.CaretQuery, prefix: String) -> NSRange? {
    guard let view else { return nil }
    let typed = prefix + query.query
    let before = textBeforeCaret()
    guard before.hasSuffix(typed) else { return nil }
    let length = (typed as NSString).length
    return NSRange(location: view.docSelectedRange.location - length, length: length)
  }

  // MARK: Copy and paste

  /// The selection as Markdown, embedded blocks included, for the pasteboard.
  func markdown(for range: NSRange) -> String {
    guard let view, range.length > 0 else { return "" }
    let text = view.docTextStorage.attributedSubstring(from: range)
    let contents = DocTextReader.paragraphs(text).compactMap { paragraph -> DocContent? in
      if let id = paragraph.attachmentID { return model.block(id)?.content }
      guard var content = paragraph.block?.content else {
        return paragraph.markdown.isEmpty ? nil : DocContent(text: paragraph.markdown)
      }
      content.text = paragraph.markdown
      return content
    }
    return DocMarkdown.markdown(title: "", blocks: contents).trimmingCharacters(in: .newlines)
  }

  /// Pastes text: one line goes in where the cursor is, with its inline styles; more becomes
  /// blocks, the line the cursor is in split around them.
  func paste(_ string: String) {
    guard let view else { return }
    let string = string.replacingOccurrences(of: "\r\n", with: "\n")
    let selection = view.docSelectedRange
    let storage = view.docTextStorage
    let lines = string.split(separator: "\n", omittingEmptySubsequences: false)
    let contents = DocMarkdown.blocks(from: string)
    var attributes = view.docTypingAttributes
    attributes[.attachment] = nil
    // A link pasted into an empty line becomes a link card.
    if lines.count <= 1, let url = DocMarkdown.linkURL(string), let id = blockID(at: selection.location),
      let block = model.block(id), block.kind == .text, block.text.isEmpty, selection.length == 0
    {
      model.makeLink(id, url: url)
      return
    }
    // One line goes in where the cursor is: plain text, a link, or a bare marker like "-".
    if lines.count <= 1, contents.count <= 1,
      contents.first.map({ $0.kind == .text || $0.kind == .link || ($0.kind.isList && $0.text.isEmpty) }) ?? true
    {
      let text = NSMutableAttributedString()
      for run in DocInline.parse(string) {
        var runAttributes = attributes
        runAttributes[.docBold] = run.bold ? true : nil
        runAttributes[.docItalic] = run.italic ? true : nil
        runAttributes[.docStrike] = run.strike ? true : nil
        runAttributes[.docCode] = run.code ? true : nil
        runAttributes[.link] = run.link.flatMap(URL.init(string:))
        text.append(NSAttributedString(string: run.text, attributes: restyled(runAttributes)))
      }
      storage.replaceCharacters(in: selection, with: text)
      view.docSelectedRange = NSRange(location: selection.location + text.length, length: 0)
      textDidChange()
      return
    }
    // Blocks go in through the model, embedded ones included, all as one undo step. The line is
    // split at the cursor first, so they land between its halves; an empty line is replaced.
    model.groupEdits { pasteBlocks(string, attributes: attributes) }
  }

  private func pasteBlocks(_ string: String, attributes: [NSAttributedString.Key: Any]) {
    guard let view else { return }
    let storage = view.docTextStorage
    let selection = view.docSelectedRange
    if selection.length > 0 {
      storage.replaceCharacters(in: selection, with: "")
      view.docSelectedRange = NSRange(location: selection.location, length: 0)
      textDidChange()
    }
    let content = storage.string as NSString
    let location = view.docSelectedRange.location
    let line = content.paragraphRange(for: NSRange(location: min(location, content.length), length: 0))
    let lineEnd = NSMaxRange(line) > line.location && content.character(at: NSMaxRange(line) - 1) == 0x0A ? NSMaxRange(line) - 1 : NSMaxRange(line)
    let inTitle = blockID(at: line.location) == nil
    if location > line.location, location < lineEnd, !inTitle {
      storage.replaceCharacters(in: NSRange(location: location, length: 0), with: NSAttributedString(string: "\n", attributes: attributes))
      view.docSelectedRange = NSRange(location: location, length: 0)
      textDidChange()
    }
    guard let id = blockID(at: line.location), let block = model.block(id) else {
      // From the title, the blocks go first.
      model.insertMarkdown(string, after: nil)
      return
    }
    let empty = block.kind.isEditable && block.text.isEmpty
    if !empty, location == line.location {
      // At the start of a line (or before an embedded block), before it.
      let visible = model.visibleBlocks
      let previous = visible.firstIndex { $0.id == id }.flatMap { $0 > 0 ? visible[$0 - 1].id : nil }
      model.insertMarkdown(string, after: previous)
    } else {
      model.insertMarkdown(string, after: id, replacing: empty ? id : nil)
    }
  }

  // MARK: Embedded blocks

  nonisolated func height(for blockID: DocBlock.ID, kind: DocBlock.Kind, width: CGFloat) -> CGFloat {
    MainActor.assumeIsolated {
      attachmentHeights[blockID] ?? DocAttachmentView.estimatedHeight(kind, table: model.table(blockID))
    }
  }

  private func makeView(for blockID: DocBlock.ID) -> PlatformView {
    if let view = attachmentViews[blockID] { return view }
    let content = DocAttachmentView(model: model, blockID: blockID) { [weak self] height in
      self?.attachmentResized(blockID, height: height)
    }
    #if os(macOS)
      let view = NSHostingView(rootView: content)
    #else
      let controller = UIHostingController(rootView: content)
      controller.view.backgroundColor = .clear
      let view: UIView = controller.view
    #endif
    attachmentViews[blockID] = view
    return view
  }

  /// Puts each embedded block's view where its attachment character was laid out, and drops the
  /// views of blocks no longer in the text.
  func layoutAttachments() {
    guard let view, let layout = view.docTextLayoutManager, let content = layout.textContentManager else { return }
    let storage = view.docTextStorage
    // Only around what is on screen: laying out every embedded block on each scroll would undo
    // TextKit's laying out of just the viewport. A screenful either side keeps views ready.
    var range = NSRange(location: 0, length: storage.length)
    if let viewport = layout.textViewportLayoutController.viewportRange {
      let start = content.offset(from: content.documentRange.location, to: viewport.location)
      let end = content.offset(from: content.documentRange.location, to: viewport.endLocation)
      let margin = max(end - start, 2_000)
      let lower = max(start - margin, 0)
      range = NSIntersectionRange(range, NSRange(location: lower, length: end + margin - lower))
    }
    var placed: Set<DocBlock.ID> = []
    storage.enumerateAttribute(.attachment, in: range) { value, range, _ in
      guard let attachment = value as? DocBlockAttachment, let textRange = textRange(range, in: content) else { return }
      var frame = CGRect.null
      layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, segment, _, _ in
        frame = frame.union(segment)
        return true
      }
      guard !frame.isNull else { return }
      let height = attachmentHeights[attachment.blockID] ?? frame.height
      let attachmentView = makeView(for: attachment.blockID)
      let target = view.docFrame(fromContainer: CGRect(x: frame.minX, y: frame.maxY - height - 4, width: frame.width, height: height))
      if attachmentView.frame != target { attachmentView.frame = target }
      attachmentView.isHidden = false
      view.docAddSubview(attachmentView)
      placed.insert(attachment.blockID)
    }
    // Views of blocks gone from the doc go; those just off screen hide until they are back.
    let present = Set(model.visibleBlocks.lazy.filter(\.kind.isAttachment).map(\.id))
    for (id, attachmentView) in attachmentViews where !placed.contains(id) {
      if present.contains(id) {
        attachmentView.isHidden = true
      } else {
        attachmentView.removeFromSuperview()
        attachmentViews[id] = nil
      }
    }
  }

  /// An embedded view found its height: lay its line out again.
  private func attachmentResized(_ id: DocBlock.ID, height: CGFloat) {
    guard abs((attachmentHeights[id] ?? 0) - height) > 0.5 else { return }
    attachmentHeights[id] = height
    guard let view, let layout = view.docTextLayoutManager, let content = layout.textContentManager,
      let index = shown.firstIndex(where: { $0.id == id })
    else { return }
    let ranges = paragraphRanges(view.docTextStorage)
    guard index + 1 < ranges.count, let range = textRange(ranges[index + 1], in: content) else { return }
    layout.invalidateLayout(for: range)
    view.docNeedsLayout()
  }

  // MARK: Helpers

  /// The text's paragraph ranges, line breaks included: the title first, then one per block.
  func paragraphRanges(_ storage: NSAttributedString) -> [NSRange] {
    let string = storage.string as NSString
    var ranges: [NSRange] = []
    var location = 0
    while location < string.length {
      let range = string.paragraphRange(for: NSRange(location: location, length: 0))
      ranges.append(range)
      location = NSMaxRange(range)
    }
    return ranges
  }

  /// The block of the paragraph at a location; nil in the title.
  func blockID(at location: Int) -> DocBlock.ID? {
    guard let storage = view?.docTextStorage, storage.length > 0 else { return nil }
    let string = storage.string as NSString
    let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
    let probe = min(paragraph.location, storage.length - 1)
    if let attachment = storage.attribute(.attachment, at: probe, effectiveRange: nil) as? DocBlockAttachment {
      return attachment.blockID
    }
    return (storage.attribute(.docParagraph, at: probe, effectiveRange: nil) as? DocParagraph)?.block.id
  }

  private func blockIDs(in range: NSRange) -> [DocBlock.ID] {
    guard let storage = view?.docTextStorage else { return [] }
    let string = storage.string as NSString
    var ids: [DocBlock.ID] = []
    var location = range.location
    repeat {
      if let id = blockID(at: location), !ids.contains(id) { ids.append(id) }
      let paragraph = string.paragraphRange(for: NSRange(location: min(location, string.length), length: 0))
      location = NSMaxRange(paragraph)
    } while location < NSMaxRange(range) && location < string.length
    return ids
  }

  private struct SavedSelection {
    let anchor: Anchor
    let length: Int
  }

  /// A place in the text by its paragraph's block and the distance from the paragraph's end,
  /// which survives the paragraph being redrawn (a typed "# " taken off its start included).
  private enum Anchor {
    case block(DocBlock.ID, fromEnd: Int)
    case title(Int)
    case offset(Int)
  }

  private func savedSelection() -> SavedSelection {
    guard let view else { return SavedSelection(anchor: .offset(0), length: 0) }
    let selection = view.docSelectedRange
    let string = view.docTextStorage.string as NSString
    let location = min(selection.location, string.length)
    let paragraph = string.paragraphRange(for: NSRange(location: location, length: 0))
    var contentEnd = NSMaxRange(paragraph)
    if contentEnd > paragraph.location, contentEnd <= string.length, string.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
    if let id = blockID(at: location) {
      return SavedSelection(anchor: .block(id, fromEnd: contentEnd - location), length: selection.length)
    }
    if paragraph.location == 0 { return SavedSelection(anchor: .title(location), length: selection.length) }
    return SavedSelection(anchor: .offset(location), length: selection.length)
  }

  private func restore(_ saved: SavedSelection) {
    guard let view else { return }
    let string = view.docTextStorage.string as NSString
    let location: Int
    switch saved.anchor {
    case .block(let id, let fromEnd):
      guard let range = range(of: id) else { return }
      var end = NSMaxRange(range)
      if end > range.location, string.character(at: end - 1) == 0x0A { end -= 1 }
      location = max(range.location, end - fromEnd)
    case .title(let offset):
      location = min(offset, paragraphRanges(view.docTextStorage).first.map { max(NSMaxRange($0) - 1, 0) } ?? 0)
    case .offset(let offset):
      location = min(offset, string.length)
    }
    view.docSelectedRange = NSRange(location: location, length: min(saved.length, string.length - location))
  }

  /// The paragraph of a block, line break included.
  func range(of id: DocBlock.ID) -> NSRange? {
    guard let view else { return nil }
    let ranges = paragraphRanges(view.docTextStorage)
    return ranges.first { range in
      range.location < view.docTextStorage.length && blockID(at: range.location) == id
    }
  }

  private func place(caretAtEndOf id: DocBlock.ID) {
    place(caretIn: id, at: nil)
  }

  /// Puts the cursor in a block, `offset` characters in, or at its end.
  private func place(caretIn id: DocBlock.ID, at offset: Int?) {
    guard let view, let range = range(of: id) else { return }
    let string = view.docTextStorage.string as NSString
    var end = NSMaxRange(range)
    if end > range.location, string.character(at: end - 1) == 0x0A { end -= 1 }
    if model.block(id)?.kind.isAttachment == true { end = NSMaxRange(range) }
    let location = offset.map { min(range.location + $0, end) } ?? end
    view.docSelectedRange = NSRange(location: min(location, string.length), length: 0)
    view.docScrollToSelection()
    selectionDidChange()
  }

  func textRange(_ range: NSRange, in content: NSTextContentManager) -> NSTextRange? {
    guard let start = content.location(content.documentRange.location, offsetBy: range.location),
      let end = content.location(start, offsetBy: range.length)
    else { return nil }
    return NSTextRange(location: start, end: end)
  }
}
