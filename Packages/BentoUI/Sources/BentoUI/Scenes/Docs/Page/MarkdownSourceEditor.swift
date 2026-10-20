import SwiftUI

#if os(macOS)
  import AppKit
  typealias PlatformColor = NSColor
#else
  import UIKit
  typealias PlatformColor = UIColor
#endif

/// Talks to the Markdown text view: edits made from outside it (the tools panel, a menu choice)
/// go through here so they land at the cursor and can be undone, and the view reports what is
/// typed, menus opening, and files pasted in.
@MainActor
final class MarkdownEditorController {
  #if os(macOS)
    weak var textView: MarkdownNSTextView?
  #else
    weak var textView: MarkdownUITextView?
  #endif

  /// A menu opened, narrowed or closed at the cursor; the rect is the caret's, in the editor's
  /// visible area.
  var onMenu: (MarkdownEditing.MenuTrigger?, CGRect) -> Void = { _, _ in }
  /// A key pressed while a menu is open; returns whether the menu used it.
  var onMenuKey: (MenuKey) -> Bool = { _ in false }
  /// Files or a picture pasted or dropped in.
  var onFiles: ([URL]) -> Void = { _ in }
  /// The editor took or lost the keyboard focus.
  var onFocus: (Bool) -> Void = { _ in }

  enum MenuKey { case up, down, choose, dismiss }

  var selectedRange: NSRange {
    #if os(macOS)
      textView?.selectedRange() ?? NSRange(location: 0, length: 0)
    #else
      textView?.selectedRange ?? NSRange(location: 0, length: 0)
    #endif
  }

  var text: String { textView?.text ?? "" }

  /// Replaces `range` with `string` as typing would (undoable), leaving the cursor `cursor`
  /// characters (UTF-16) into it, or after it.
  func replace(_ range: NSRange, with string: String, cursor: Int? = nil) {
    guard let textView else { return }
    let caret = NSRange(location: range.location + (cursor ?? (string as NSString).length), length: 0)
    #if os(macOS)
      textView.insertText(string, replacementRange: range)
      textView.setSelectedRange(caret)
      textView.scrollRangeToVisible(caret)
    #else
      guard let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
        let end = textView.position(from: start, offset: range.length),
        let textRange = textView.textRange(from: start, to: end)
      else { return }
      textView.replace(textRange, withText: string)
      textView.selectedRange = caret
      textView.scrollRangeToVisible(caret)
    #endif
    focus()
  }

  /// Inserts Markdown at the cursor, replacing a selection; a block goes on a line of its own.
  func insert(_ markdown: String, block: Bool, cursor: Int? = nil) {
    let ns = text as NSString
    let range = selectedRange
    var string = markdown
    var offset = cursor ?? (markdown as NSString).length
    if block {
      if range.location > 0, ns.character(at: range.location - 1) != 10 {
        string = "\n" + string
        offset += 1
      }
      let end = range.location + range.length
      if end < ns.length, ns.character(at: end) != 10 { string += "\n" }
    }
    replace(range, with: string, cursor: offset)
  }

  /// Wraps the selection in a marker (`**`, `_`, `~~`, `` ` ``), or puts the cursor between a pair.
  func wrap(_ marker: String) {
    let range = selectedRange
    let selected = (text as NSString).substring(with: range)
    let length = (marker as NSString).length
    replace(range, with: marker + selected + marker, cursor: selected.isEmpty ? length : length * 2 + (selected as NSString).length)
  }

  /// Restyles the line the cursor is in (see `MarkdownEditing.restyled`), keeping the cursor on
  /// the same text.
  func restyleLine(_ prefix: String) {
    let ns = text as NSString
    let selection = selectedRange
    let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
    var line = ns.substring(with: lineRange)
    if line.hasSuffix("\n") { line.removeLast() }
    let restyled = MarkdownEditing.restyled(line, with: prefix)
    let delta = (restyled as NSString).length - (line as NSString).length
    let cursor = max(0, selection.location - lineRange.location + delta)
    replace(NSRange(location: lineRange.location, length: (line as NSString).length), with: restyled, cursor: min(cursor, (restyled as NSString).length))
  }

  /// Makes the selection a link, with the cursor where its address goes.
  func link() {
    let range = selectedRange
    let selected = (text as NSString).substring(with: range)
    replace(range, with: "[\(selected)](https://)", cursor: (selected as NSString).length + 3)
  }

  func focus() {
    #if os(macOS)
      textView?.window?.makeFirstResponder(textView)
    #else
      textView?.becomeFirstResponder()
    #endif
  }
}

/// Colours Markdown as it is typed: headings larger and bold, markers and link addresses quiet,
/// code in a fixed-width face. The text itself is never changed.
enum MarkdownHighlighter {
  static let size: CGFloat = 15

  private static let rules: [(NSRegularExpression, Style)] = [
    (#"^#{1,6} .*$"#, .heading),
    (#"^\s*(?:[-*+]|\d+\.)(?= )"#, .marker),
    (#"^\s*>"#, .marker),
    (#"\[[ xX]\](?= )"#, .marker),
    (#"\*\*|__|~~"#, .marker),
    (#"`[^`\n]+`"#, .code),
    (#"\]\([^)\n]*\)"#, .marker),
    (#"^</?details>.*$|^<summary>.*$"#, .marker),
    (#"^---+\s*$"#, .marker),
  ].compactMap { pattern, style in
    (try? NSRegularExpression(pattern: pattern, options: .anchorsMatchLines)).map { ($0, style) }
  }

  private enum Style { case heading, marker, code }

  static var baseAttributes: [NSAttributedString.Key: Any] {
    [.font: PlatformFont.systemFont(ofSize: size), .foregroundColor: PlatformColor.labelColor]
  }

  /// Colours the whole text.
  static func apply(to storage: NSTextStorage) {
    apply(to: storage, editedRange: nil)
  }

  /// Colours the lines an edit touched, or everything when that is unknown or the edit touched a
  /// code fence (which changes how every line after it reads). Typing in a long doc so redoes a
  /// line, not the whole text.
  static func apply(to storage: NSTextStorage, editedRange: NSRange?) {
    let ns = storage.string as NSString
    var range = NSRange(location: 0, length: ns.length)
    var inFence = false
    if let edited = editedRange, edited.location <= ns.length {
      let lines = ns.paragraphRange(for: NSRange(location: edited.location, length: min(edited.length, ns.length - edited.location)))
      if !ns.substring(with: lines).contains("```") {
        range = lines
        inFence = fenceIsOpen(ns.substring(to: lines.location))
      }
    }
    storage.beginEditing()
    storage.setAttributes(baseAttributes, range: range)
    let text = storage.string
    for (regex, style) in rules {
      for match in regex.matches(in: text, range: range) {
        switch style {
        case .heading:
          let level = ns.substring(with: match.range).prefix { $0 == "#" }.count
          let size = max(size, 24 - CGFloat(level) * 2.5)
          storage.addAttribute(.font, value: PlatformFont.systemFont(ofSize: size, weight: .bold), range: match.range)
        case .marker:
          storage.addAttribute(.foregroundColor, value: PlatformColor.secondaryLabelColor, range: match.range)
        case .code:
          storage.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), range: match.range)
        }
      }
    }
    // Fenced code, fences included, in a fixed-width face.
    var location = range.location
    for line in ns.substring(with: range).split(separator: "\n", omittingEmptySubsequences: false) {
      let length = (String(line) as NSString).length
      let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
      if inFence || isFence {
        let lineRange = NSRange(location: location, length: min(length, NSMaxRange(range) - location))
        storage.addAttribute(.font, value: PlatformFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), range: lineRange)
        if isFence { storage.addAttribute(.foregroundColor, value: PlatformColor.secondaryLabelColor, range: lineRange) }
      }
      if isFence { inFence.toggle() }
      location += length + 1
      if location >= NSMaxRange(range) { break }
    }
    storage.endEditing()
  }

  /// Whether the lines an edit replaces hold a code fence: changing one changes how every line
  /// after it reads, so the whole text is coloured again.
  static func touchesFence(_ text: String, _ range: NSRange) -> Bool {
    let ns = text as NSString
    guard NSMaxRange(range) <= ns.length else { return true }
    return ns.substring(with: ns.paragraphRange(for: range)).contains("```")
  }

  /// Whether `text` ends inside a fenced code block.
  private static func fenceIsOpen(_ text: String) -> Bool {
    var open = false
    text.enumerateLines { line, _ in
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { open.toggle() }
    }
    return open
  }
}

#if os(macOS)
  /// The Markdown text view: plain text, Return and Tab doing list work, keys steering an open menu.
  final class MarkdownNSTextView: NSTextView {
    weak var controller: MarkdownEditorController?

    var text: String { string }

    override func becomeFirstResponder() -> Bool {
      let became = super.becomeFirstResponder()
      if became { controller?.onFocus(true) }
      return became
    }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned { controller?.onFocus(false) }
      return resigned
    }

    override func paste(_ sender: Any?) {
      if pasteFiles(NSPasteboard.general) { return }
      pasteAsPlainText(sender)
    }

    /// Files, or a picture with no text, pasted in are kept with the doc.
    func pasteFiles(_ pasteboard: NSPasteboard) -> Bool {
      if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        controller?.onFiles(urls)
        return true
      }
      guard pasteboard.string(forType: .string) == nil,
        let image = NSImage(pasteboard: pasteboard), let tiff = image.tiffRepresentation,
        let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
      else { return false }
      let url = FileManager.default.temporaryDirectory.appending(path: "Pasted \(UUID().uuidString.prefix(6)).png")
      guard (try? png.write(to: url)) != nil else { return false }
      controller?.onFiles([url])
      return true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      if pasteFiles(sender.draggingPasteboard) { return true }
      return super.performDragOperation(sender)
    }

    /// The caret's rect in the visible part of the editor, top-left origin.
    func caretRect() -> CGRect {
      guard let window else { return .zero }
      let screen = firstRect(forCharacterRange: selectedRange(), actualRange: nil)
      let inView = convert(window.convertFromScreen(screen), from: nil)
      return inView.offsetBy(dx: -visibleRect.minX, dy: -visibleRect.minY)
    }
  }

  struct MarkdownSourceEditor: NSViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeNSView(context: Context) -> NSScrollView {
      let textView = MarkdownNSTextView(frame: .zero)
      textView.controller = controller
      controller.textView = textView
      textView.delegate = context.coordinator
      textView.isRichText = false
      textView.allowsUndo = true
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.drawsBackground = false
      textView.textContainerInset = NSSize(width: 20, height: 20)
      textView.isVerticallyResizable = true
      textView.autoresizingMask = .width
      textView.textContainer?.widthTracksTextView = true
      textView.typingAttributes = MarkdownHighlighter.baseAttributes
      textView.string = text
      if let storage = textView.textStorage { MarkdownHighlighter.apply(to: storage) }
      let scrollView = NSScrollView()
      scrollView.documentView = textView
      scrollView.hasVerticalScroller = true
      scrollView.autohidesScrollers = true
      scrollView.drawsBackground = false
      DispatchQueue.main.async { textView.window?.makeFirstResponder(textView) }
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      context.coordinator.parent = self
      guard let textView = scrollView.documentView as? MarkdownNSTextView, textView.string != text else { return }
      let selection = textView.selectedRange()
      textView.string = text
      if let storage = textView.textStorage { MarkdownHighlighter.apply(to: storage) }
      let length = (text as NSString).length
      textView.setSelectedRange(NSRange(location: min(selection.location, length), length: 0))
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
      var parent: MarkdownSourceEditor
      /// Where the change about to be made lands, so only those lines are coloured again.
      private var pendingEdit: NSRange?

      init(_ parent: MarkdownSourceEditor) {
        self.parent = parent
      }

      func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString text: String?) -> Bool {
        pendingEdit = MarkdownHighlighter.touchesFence(textView.string, range) ? nil
          : NSRange(location: range.location, length: ((text ?? "") as NSString).length)
        return true
      }

      func textDidChange(_ notification: Notification) {
        guard let textView = notification.object as? MarkdownNSTextView else { return }
        if let storage = textView.textStorage { MarkdownHighlighter.apply(to: storage, editedRange: pendingEdit) }
        pendingEdit = nil
        textView.typingAttributes = MarkdownHighlighter.baseAttributes
        parent.text = textView.string
        reportMenu(textView)
      }

      func textViewDidChangeSelection(_ notification: Notification) {
        guard let textView = notification.object as? MarkdownNSTextView else { return }
        reportMenu(textView)
      }

      private func reportMenu(_ textView: MarkdownNSTextView) {
        let selection = textView.selectedRange()
        let trigger = selection.length == 0 ? MarkdownEditing.trigger(in: textView.string, cursor: selection.location) : nil
        parent.controller.onMenu(trigger, trigger == nil ? .zero : textView.caretRect())
      }

      func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        let controller = parent.controller
        switch selector {
        case #selector(NSResponder.moveUp(_:)): return controller.onMenuKey(.up)
        case #selector(NSResponder.moveDown(_:)): return controller.onMenuKey(.down)
        case #selector(NSResponder.cancelOperation(_:)): return controller.onMenuKey(.dismiss)
        case #selector(NSResponder.insertNewline(_:)):
          if controller.onMenuKey(.choose) { return true }
          return continueList(textView)
        case #selector(NSResponder.insertTab(_:)):
          if controller.onMenuKey(.choose) { return true }
          return shiftLine(textView, outward: false)
        case #selector(NSResponder.insertBacktab(_:)): return shiftLine(textView, outward: true)
        default: return false
        }
      }

      /// Return in a list item starts the next one; in an empty item, ends the list.
      private func continueList(_ textView: NSTextView) -> Bool {
        let ns = textView.string as NSString
        let cursor = textView.selectedRange()
        guard cursor.length == 0 else { return false }
        let lineRange = ns.lineRange(for: cursor)
        let line = ns.substring(with: NSRange(location: lineRange.location, length: cursor.location - lineRange.location))
        switch MarkdownEditing.onReturn(after: line) {
        case .continueWith(let prefix):
          textView.insertText("\n" + prefix, replacementRange: cursor)
          return true
        case .endList:
          textView.insertText("", replacementRange: NSRange(location: lineRange.location, length: cursor.location - lineRange.location))
          return true
        case nil:
          return false
        }
      }

      /// Tab nests the line under the item above; Shift-Tab brings it back out.
      private func shiftLine(_ textView: NSTextView, outward: Bool) -> Bool {
        let ns = textView.string as NSString
        let cursor = textView.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: cursor.location, length: 0))
        var line = ns.substring(with: lineRange)
        let newline = line.hasSuffix("\n")
        if newline { line.removeLast() }
        guard MarkdownEditing.listLine(line) != nil || outward else { return false }
        let above = ns.substring(to: lineRange.location).components(separatedBy: "\n")
        let shifted = outward ? MarkdownEditing.outdented(line, linesAbove: above) : MarkdownEditing.indented(line, linesAbove: above)
        let delta = (shifted as NSString).length - (line as NSString).length
        textView.insertText(shifted, replacementRange: NSRange(location: lineRange.location, length: (line as NSString).length))
        textView.setSelectedRange(NSRange(location: max(lineRange.location, cursor.location + delta), length: 0))
        return true
      }
    }
  }
#else
  extension UIColor {
    static var labelColor: UIColor { .label }
    static var secondaryLabelColor: UIColor { .secondaryLabel }
  }

  /// The Markdown text view on iOS: as on the Mac, with the menu steered from a hardware keyboard.
  final class MarkdownUITextView: UITextView {
    weak var controller: MarkdownEditorController?

    override func paste(_ sender: Any?) {
      let board = UIPasteboard.general
      if !board.hasStrings, let image = board.image, let png = image.pngData() {
        let url = FileManager.default.temporaryDirectory.appending(path: "Pasted \(UUID().uuidString.prefix(6)).png")
        if (try? png.write(to: url)) != nil {
          controller?.onFiles([url])
          return
        }
      }
      if let string = board.string {
        replace(selectedTextRange ?? textRange(from: endOfDocument, to: endOfDocument)!, withText: string)
      }
    }

    override var keyCommands: [UIKeyCommand]? {
      [
        UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(menuUp)),
        UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(menuDown)),
        UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(menuDismiss)),
        UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(outdent)),
      ].map {
        $0.wantsPriorityOverSystemBehavior = true
        return $0
      }
    }

    @objc private func menuUp() { _ = controller?.onMenuKey(.up) }
    @objc private func menuDown() { _ = controller?.onMenuKey(.down) }
    @objc private func menuDismiss() { _ = controller?.onMenuKey(.dismiss) }
    @objc private func outdent() { (delegate as? MarkdownSourceEditor.Coordinator)?.shiftLine(self, outward: true) }

    func caretRect() -> CGRect {
      guard let position = selectedTextRange?.end else { return .zero }
      return caretRect(for: position).offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
    }
  }

  struct MarkdownSourceEditor: UIViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeUIView(context: Context) -> MarkdownUITextView {
      let textView = MarkdownUITextView()
      textView.controller = controller
      controller.textView = textView
      textView.delegate = context.coordinator
      textView.backgroundColor = .clear
      textView.smartQuotesType = .no
      textView.smartDashesType = .no
      textView.autocapitalizationType = .sentences
      textView.textContainerInset = UIEdgeInsets(top: 20, left: 16, bottom: 120, right: 16)
      textView.typingAttributes = MarkdownHighlighter.baseAttributes
      textView.text = text
      MarkdownHighlighter.apply(to: textView.textStorage)
      return textView
    }

    func updateUIView(_ textView: MarkdownUITextView, context: Context) {
      context.coordinator.parent = self
      guard textView.text != text else { return }
      let selection = textView.selectedRange
      textView.text = text
      MarkdownHighlighter.apply(to: textView.textStorage)
      textView.selectedRange = NSRange(location: min(selection.location, (text as NSString).length), length: 0)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
      var parent: MarkdownSourceEditor
      /// Where the change about to be made lands, so only those lines are coloured again.
      private var pendingEdit: NSRange?

      init(_ parent: MarkdownSourceEditor) {
        self.parent = parent
      }

      func textViewDidChange(_ textView: UITextView) {
        let selection = textView.selectedRange
        MarkdownHighlighter.apply(to: textView.textStorage, editedRange: pendingEdit)
        pendingEdit = nil
        textView.selectedRange = selection
        textView.typingAttributes = MarkdownHighlighter.baseAttributes
        parent.text = textView.text
        reportMenu(textView)
      }

      func textViewDidChangeSelection(_ textView: UITextView) {
        reportMenu(textView)
      }

      func textViewDidBeginEditing(_ textView: UITextView) {
        parent.controller.onFocus(true)
      }

      func textViewDidEndEditing(_ textView: UITextView) {
        parent.controller.onFocus(false)
      }

      private func reportMenu(_ textView: UITextView) {
        guard let textView = textView as? MarkdownUITextView else { return }
        let selection = textView.selectedRange
        let trigger = selection.length == 0 ? MarkdownEditing.trigger(in: textView.text, cursor: selection.location) : nil
        parent.controller.onMenu(trigger, trigger == nil ? .zero : textView.caretRect())
      }

      func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        pendingEdit = MarkdownHighlighter.touchesFence(textView.text, range) ? nil
          : NSRange(location: range.location, length: (text as NSString).length)
        if text == "\n" {
          if parent.controller.onMenuKey(.choose) { return false }
          return !continueList(textView, at: range)
        }
        if text == "\t" {
          if parent.controller.onMenuKey(.choose) { return false }
          return !shiftLine(textView, outward: false)
        }
        return true
      }

      private func continueList(_ textView: UITextView, at range: NSRange) -> Bool {
        guard range.length == 0 else { return false }
        let ns = textView.text as NSString
        let lineRange = ns.lineRange(for: range)
        let line = ns.substring(with: NSRange(location: lineRange.location, length: range.location - lineRange.location))
        switch MarkdownEditing.onReturn(after: line) {
        case .continueWith(let prefix):
          parent.controller.replace(range, with: "\n" + prefix)
          return true
        case .endList:
          parent.controller.replace(NSRange(location: lineRange.location, length: range.location - lineRange.location), with: "")
          return true
        case nil:
          return false
        }
      }

      @discardableResult
      func shiftLine(_ textView: UITextView, outward: Bool) -> Bool {
        let ns = textView.text as NSString
        let cursor = textView.selectedRange
        let lineRange = ns.lineRange(for: NSRange(location: cursor.location, length: 0))
        var line = ns.substring(with: lineRange)
        if line.hasSuffix("\n") { line.removeLast() }
        guard MarkdownEditing.listLine(line) != nil || outward else { return false }
        let above = ns.substring(to: lineRange.location).components(separatedBy: "\n")
        let shifted = outward ? MarkdownEditing.outdented(line, linesAbove: above) : MarkdownEditing.indented(line, linesAbove: above)
        let delta = (shifted as NSString).length - (line as NSString).length
        parent.controller.replace(NSRange(location: lineRange.location, length: (line as NSString).length), with: shifted)
        textView.selectedRange = NSRange(location: max(lineRange.location, cursor.location + delta), length: 0)
        return true
      }
    }
  }
#endif
