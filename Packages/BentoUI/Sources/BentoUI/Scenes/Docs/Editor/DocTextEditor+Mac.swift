#if os(macOS)
  import AppKit
  import BentoData
  import SwiftUI

  /// The doc's text on the Mac: one TextKit 2 text view, in a scroll view.
  struct DocTextEditor: NSViewRepresentable {
    let model: DocEditorViewModel

    func makeCoordinator() -> DocTextController {
      DocTextController(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
      // TextKit 2: a layout manager over a content storage, which the controller keeps.
      let layoutManager = NSTextLayoutManager()
      let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      layoutManager.textContainer = container
      context.coordinator.contentStorage.addTextLayoutManager(layoutManager)
      let textView = DocNSTextView(frame: .zero, textContainer: container)
      textView.controller = context.coordinator
      textView.textLayoutManager?.delegate = context.coordinator.layoutDelegate
      context.coordinator.view = textView

      let scrollView = NSScrollView()
      scrollView.documentView = textView
      scrollView.hasVerticalScroller = true
      scrollView.autohidesScrollers = true
      scrollView.drawsBackground = false
      scrollView.contentView.postsBoundsChangedNotifications = true
      NotificationCenter.default.addObserver(
        textView, selector: #selector(DocNSTextView.scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
      )
      context.coordinator.syncFromModel()
      return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
      // Reading these here has SwiftUI call this again when they change.
      _ = model.blocks
      _ = model.title
      _ = model.linkedTitles
      _ = model.focusRequest
      context.coordinator.syncFromModel()
      (scrollView.documentView as? DocNSTextView)?.setCover(model.cover?.image)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: DocTextController) {
      NotificationCenter.default.removeObserver(scrollView.documentView as Any)
    }
  }

  final class DocNSTextView: NSTextView, NSTextViewDelegate, DocTextViewing {
    weak var controller: DocTextController?
    /// The handle that drags the block under the pointer.
    private let handle = DocDragHandle()
    /// Where a dragged block will land.
    private let dropLine = NSView()
    /// Opens the `/` menu on an empty line, as Craft's `+` does.
    private let plus = DocMarginButton(symbol: "plus")
    private var handleBlock: DocBlock.ID?

    /// Column width for comfortable reading, as in Craft.
    static let readingWidth: CGFloat = 720

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
      super.init(frame: frameRect, textContainer: container)
      setUp()
    }

    required init?(coder: NSCoder) {
      super.init(coder: coder)
      setUp()
    }

    private func setUp() {
      delegate = self
      isRichText = true
      allowsUndo = false
      drawsBackground = false
      isVerticallyResizable = true
      isHorizontallyResizable = false
      autoresizingMask = [.width]
      textContainer?.widthTracksTextView = true
      isAutomaticQuoteSubstitutionEnabled = true
      isAutomaticDashSubstitutionEnabled = true
      isAutomaticLinkDetectionEnabled = false
      usesFindBar = true
      isIncrementalSearchingEnabled = true
      linkTextAttributes = [.foregroundColor: NSColor.controlAccentColor, .cursor: NSCursor.pointingHand]
      textContainerInset = NSSize(width: 48, height: 36)
      addSubview(handle)
      handle.isHidden = true
      addSubview(plus)
      plus.isHidden = true
      plus.onClick = { [weak self] in
        guard let self, let id = self.handleBlock else { return }
        self.window?.makeFirstResponder(self)
        self.controller?.startSlash(in: id)
      }
      dropLine.wantsLayer = true
      dropLine.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
      dropLine.layer?.cornerRadius = 1.5
      dropLine.isHidden = true
      addSubview(dropLine)
      handle.onDragStart = { [weak self] event in self?.dragBlock(with: event) }
    }

    override func setFrameSize(_ newSize: NSSize) {
      super.setFrameSize(newSize)
      updateInsets()
    }

    // MARK: Cover

    /// The doc's cover, wide across the top, above the title.
    private let coverView = NSView()
    private var coverData: Data?
    static let coverHeight: CGFloat = 220

    func setCover(_ data: Data?) {
      guard data != coverData else { return }
      coverData = data
      let image = data.flatMap(NSImage.init(data:))
      coverView.wantsLayer = true
      coverView.layer?.contents = image
      coverView.layer?.contentsGravity = .resizeAspectFill
      coverView.layer?.masksToBounds = true
      if coverView.superview == nil { addSubview(coverView, positioned: .below, relativeTo: nil) }
      coverView.isHidden = image == nil
      updateInsets()
    }

    /// The text starts below the cover. A text view applies its inset's height to the bottom as
    /// well, so a doc with a cover also ends with room to scroll its last line up the screen.
    private func updateInsets() {
      let side = max(56, (frame.width - Self.readingWidth) / 2)
      let top: CGFloat = coverView.isHidden || coverData == nil ? 36 : Self.coverHeight + 32
      if abs(textContainerInset.width - side) > 0.5 || abs(textContainerInset.height - top) > 0.5 {
        textContainerInset = NSSize(width: side, height: top)
      }
      coverView.frame = CGRect(x: 0, y: 0, width: frame.width, height: Self.coverHeight)
    }

    // MARK: DocTextViewing

    var docTextStorage: NSTextStorage { textStorage ?? NSTextStorage() }
    var docTextLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var docSelectedRange: NSRange {
      get { selectedRange() }
      set { setSelectedRange(newValue) }
    }
    var docTypingAttributes: [NSAttributedString.Key: Any] {
      get { typingAttributes }
      set { typingAttributes = newValue }
    }
    var docHasMarkedText: Bool { hasMarkedText() }

    func docRect(for range: NSRange) -> CGRect? {
      guard let layout = textLayoutManager, let content = layout.textContentManager,
        let textRange = controller?.textRange(range, in: content)
      else { return nil }
      var rect = CGRect.null
      layout.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
        rect = rect.union(frame)
        return true
      }
      guard !rect.isNull else { return nil }
      let origin = textContainerOrigin
      return rect.offsetBy(dx: origin.x - visibleRect.minX, dy: origin.y - visibleRect.minY)
    }

    func docScrollToSelection() {
      scrollRangeToVisible(selectedRange())
    }

    func docFrame(fromContainer rect: CGRect) -> CGRect {
      rect.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y)
    }

    func docAddSubview(_ view: NSView) {
      if view.superview !== self { addSubview(view) }
    }

    func docNeedsLayout() {
      needsDisplay = true
    }

    override func viewWillDraw() {
      super.viewWillDraw()
      // Embedded blocks follow the text's layout.
      controller?.layoutAttachments()
    }

    @objc func scrolled() {
      controller?.updateRects()
    }

    // MARK: Delegate

    func textDidChange(_ notification: Notification) {
      controller?.textDidChange()
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
      controller?.willChange(range, replacement: replacementString)
      return true
    }

    func textViewDidChangeSelection(_ notification: Notification) {
      controller?.selectionDidChange()
    }

    func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
      guard let controller else { return false }
      switch selector {
      case #selector(insertNewline(_:)): return controller.handleReturn()
      case #selector(insertTab(_:)): return controller.handleIndent(by: 1)
      case #selector(insertBacktab(_:)): return controller.handleIndent(by: -1)
      case #selector(moveUp(_:)): return controller.model.movePopupSelection(by: -1)
      case #selector(moveDown(_:)): return controller.model.movePopupSelection(by: 1)
      case #selector(cancelOperation(_:)): return controller.model.dismissPopup()
      case #selector(deleteBackward(_:)): return controller.handleDeleteBackward()
      default: return false
      }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
      let url = link as? URL ?? (link as? String).flatMap(URL.init(string:))
      guard let url else { return false }
      if controller?.model.openLink(url) == true { return true }
      NSWorkspace.shared.open(url)
      return true
    }

    // MARK: Mouse

    override func mouseDown(with event: NSEvent) {
      let point = convert(event.locationInWindow, from: nil)
      let inContainer = CGPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
      if controller?.handleMarkerClick(at: inContainer) == true { return }
      super.mouseDown(with: event)
    }

    override func updateTrackingAreas() {
      super.updateTrackingAreas()
      for area in trackingAreas where area.owner === self && area.userInfo?["handle"] != nil { removeTrackingArea(area) }
      addTrackingArea(
        NSTrackingArea(rect: visibleRect, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow], owner: self, userInfo: ["handle": true])
      )
    }

    override func mouseMoved(with event: NSEvent) {
      super.mouseMoved(with: event)
      showHandle(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
      super.mouseExited(with: event)
      handle.isHidden = true
      plus.isHidden = true
    }

    /// Shows the drag handle in the margin of the block under the pointer.
    private func showHandle(at point: CGPoint) {
      guard let layout = textLayoutManager else { return }
      let inContainer = CGPoint(x: textContainerOrigin.x + 10, y: point.y - textContainerOrigin.y)
      guard let fragment = layout.textLayoutFragment(for: CGPoint(x: 10, y: inContainer.y)) as? DocParagraphFragment,
        let block = fragment.paragraph?.block
      else {
        handle.isHidden = true
        plus.isHidden = true
        return
      }
      let fragmentFrame = fragment.layoutFragmentFrame
      let lineHeight = fragment.textLineFragments.first?.typographicBounds.height ?? 20
      let x = textContainerOrigin.x + CGFloat(block.indent) * DocMetrics.indentStep - 26
      let y = textContainerOrigin.y + fragmentFrame.minY + (fragment.textLineFragments.first?.typographicBounds.minY ?? 0)
      let frame = CGRect(x: x, y: y + (lineHeight - 22) / 2, width: 20, height: 22)
      // An empty body line offers `+` for the block menu; any other block, its drag handle.
      let empty = block.kind == .text && fragment.isEmpty
      handle.frame = frame
      plus.frame = frame
      handle.isHidden = empty
      plus.isHidden = !empty
      handleBlock = block.id
    }

    /// Starts dragging the block under the handle; it drops between paragraphs.
    private func dragBlock(with event: NSEvent) {
      guard let id = handleBlock else { return }
      let item = NSPasteboardItem()
      item.setString(DocBlockDrag.payload(id), forType: .string)
      let draggingItem = NSDraggingItem(pasteboardWriter: item)
      let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: nil) ?? NSImage()
      draggingItem.setDraggingFrame(handle.frame, contents: image)
      beginDraggingSession(with: [draggingItem], event: event, source: self)
    }

    // MARK: Drops

    /// A block moved within the doc, or docs dragged from the list (dropped as links).
    private func isBlockDrag(_ sender: any NSDraggingInfo) -> Bool {
      guard let string = sender.draggingPasteboard.string(forType: .string) else { return false }
      return DocBlockDrag.blockID(string) != nil || !DocDrag.docIDs([string]).isEmpty
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
      guard isBlockDrag(sender) else { return super.draggingUpdated(sender) }
      showDropLine(after: blockAbove(convert(sender.draggingLocation, from: nil)))
      let isDoc = sender.draggingPasteboard.string(forType: .string).map { !DocDrag.docIDs([$0]).isEmpty } ?? false
      return isDoc ? .copy : .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
      dropLine.isHidden = true
      super.draggingExited(sender)
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) {
      dropLine.isHidden = true
      super.draggingEnded(sender)
    }

    /// A line between paragraphs, below the block a drop goes after (above the first block for
    /// the top).
    private func showDropLine(after target: DocBlock.ID?) {
      guard let controller, let layout = textLayoutManager, let content = layout.textContentManager else { return }
      let visible = controller.model.visibleBlocks
      let anchor = target ?? visible.first?.id
      guard let anchor, let range = controller.range(of: anchor), let textRange = controller.textRange(range, in: content),
        let fragment = layout.textLayoutFragment(for: textRange.location)
      else {
        dropLine.isHidden = true
        return
      }
      let frame = fragment.layoutFragmentFrame
      let y = textContainerOrigin.y + (target == nil ? frame.minY : frame.maxY)
      let width = (textContainer?.size.width ?? bounds.width) - 2 * (textContainer?.lineFragmentPadding ?? 5)
      dropLine.frame = CGRect(x: textContainerOrigin.x + (textContainer?.lineFragmentPadding ?? 5), y: y - 1.5, width: width, height: 3)
      dropLine.isHidden = false
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
      dropLine.isHidden = true
      let pasteboard = sender.draggingPasteboard
      let point = convert(sender.draggingLocation, from: nil)
      let target = blockAbove(point)
      if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
        Task { await controller?.model.attach(urls, after: target) }
        return true
      }
      if let string = pasteboard.string(forType: .string), let controller {
        let docs = DocDrag.docIDs(string.components(separatedBy: "\n"))
        if !docs.isEmpty {
          controller.model.insertDocLinks(docs, after: target)
          return true
        }
        if DocBlockDrag.blockID(string) != nil || DocMarkdown.linkURL(string.trimmingCharacters(in: .whitespacesAndNewlines)) != nil {
          return controller.model.drop(string, after: target)
        }
      }
      return super.performDragOperation(sender)
    }

    /// The block a drop at `point` goes after: the one it lands on when in its lower half, else
    /// the one before.
    private func blockAbove(_ point: CGPoint) -> DocBlock.ID? {
      guard let layout = textLayoutManager, let controller else { return nil }
      let inContainer = CGPoint(x: 10, y: point.y - textContainerOrigin.y)
      guard let fragment = layout.textLayoutFragment(for: inContainer) as? DocParagraphFragment else {
        return controller.model.visibleBlocks.last?.id
      }
      if fragment.isTitle { return nil }
      guard let id = fragment.paragraph?.block.id else { return nil }
      if inContainer.y > fragment.layoutFragmentFrame.midY { return id }
      let visible = controller.model.visibleBlocks
      guard let index = visible.firstIndex(where: { $0.id == id }) else { return id }
      return index > 0 ? visible[index - 1].id : nil
    }

    override func dragSelection(with event: NSEvent, offset mouseOffset: NSSize, slideBack: Bool) -> Bool {
      // Dragged text would lose its blocks; blocks move by their handle.
      false
    }

    // MARK: Pasteboard

    override func copy(_ sender: Any?) {
      guard let controller, selectedRange().length > 0 else { return super.copy(sender) }
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(controller.markdown(for: selectedRange()), forType: .string)
    }

    override func cut(_ sender: Any?) {
      guard selectedRange().length > 0 else { return }
      copy(sender)
      insertText("", replacementRange: selectedRange())
    }

    override func paste(_ sender: Any?) {
      guard let controller, let string = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
      controller.paste(string)
    }

    override func pasteAsPlainText(_ sender: Any?) {
      paste(sender)
    }

    // MARK: Undo

    @objc func undo(_ sender: Any?) {
      controller?.model.undo()
    }

    @objc func redo(_ sender: Any?) {
      controller?.model.redo()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
      switch item.action {
      case #selector(undo(_:)): controller?.model.canUndo ?? false
      case #selector(redo(_:)): controller?.model.canRedo ?? false
      default: super.validateUserInterfaceItem(item)
      }
    }
  }

  extension DocNSTextView {
    override func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
      context == .withinApplication ? .move : super.draggingSession(session, sourceOperationMaskFor: context)
    }
  }

  /// A small symbol button in a block's margin.
  final class DocMarginButton: NSView {
    var onClick: (() -> Void)?
    private let symbol: String

    init(symbol: String) {
      self.symbol = symbol
      super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
      fatalError("not coded")
    }

    override func draw(_ dirtyRect: NSRect) {
      guard let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Add a block") else { return }
      let tinted = image.withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) ?? image
      let size = tinted.size
      let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
      tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.5, respectFlipped: true, hints: nil)
    }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
      onClick?()
    }
  }

  /// The ⋮⋮ handle in a block's margin.
  final class DocDragHandle: NSView {
    var onDragStart: ((NSEvent) -> Void)?
    private var downEvent: NSEvent?

    override func draw(_ dirtyRect: NSRect) {
      guard let image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to move") else { return }
      let tinted = image.withSymbolConfiguration(.init(pointSize: 11, weight: .semibold)) ?? image
      NSColor.tertiaryLabelColor.set()
      let size = tinted.size
      let rect = CGRect(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2, width: size.width, height: size.height)
      tinted.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 0.55, respectFlipped: true, hints: nil)
    }

    override func resetCursorRects() {
      addCursorRect(bounds, cursor: .openHand)
    }

    override func mouseDown(with event: NSEvent) {
      downEvent = event
    }

    override func mouseDragged(with event: NSEvent) {
      guard let downEvent else { return }
      self.downEvent = nil
      onDragStart?(downEvent)
    }
  }
#endif
