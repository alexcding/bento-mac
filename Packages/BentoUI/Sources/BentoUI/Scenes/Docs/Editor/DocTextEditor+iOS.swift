#if os(iOS)
  import BentoData
  import SwiftUI
  import UIKit

  /// The doc's text on iOS: one TextKit 2 text view, which scrolls itself.
  struct DocTextEditor: UIViewRepresentable {
    let model: DocEditorViewModel

    func makeCoordinator() -> DocTextController {
      DocTextController(model: model)
    }

    func makeUIView(context: Context) -> DocUITextView {
      // TextKit 2: a layout manager over a content storage, which the controller keeps. (The
      // `usingTextLayoutManager:` initializer would skip this class's own set-up.)
      let layoutManager = NSTextLayoutManager()
      let container = NSTextContainer(size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude))
      container.widthTracksTextView = true
      layoutManager.textContainer = container
      context.coordinator.contentStorage.addTextLayoutManager(layoutManager)
      let textView = DocUITextView(frame: .zero, textContainer: container)
      textView.controller = context.coordinator
      textView.textLayoutManager?.delegate = context.coordinator.layoutDelegate
      context.coordinator.view = textView
      context.coordinator.syncFromModel()
      return textView
    }

    func updateUIView(_ textView: DocUITextView, context: Context) {
      // Reading these here has SwiftUI call this again when they change.
      _ = model.blocks
      _ = model.title
      _ = model.linkedTitles
      _ = model.focusRequest
      context.coordinator.syncFromModel()
      textView.setCover(model.cover?.image)
    }
  }

  final class DocUITextView: UITextView, UITextViewDelegate, DocTextViewing {
    weak var controller: DocTextController?
    private lazy var docUndoManager = DocUndoManager { [weak self] in self?.controller?.model }

    static let readingWidth: CGFloat = 720

    override init(frame: CGRect, textContainer: NSTextContainer?) {
      super.init(frame: frame, textContainer: textContainer)
      delegate = self
      backgroundColor = .clear
      alwaysBounceVertical = true
      keyboardDismissMode = .interactive
      linkTextAttributes = [.foregroundColor: UIColor.tintColor]
      dataDetectorTypes = []
      isFindInteractionEnabled = true
      textContainerInset = UIEdgeInsets(top: 24, left: 20, bottom: 120, right: 20)
      addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped(_:))).configured { $0.cancelsTouchesInView = false })
    }

    required init?(coder: NSCoder) {
      fatalError("not coded")
    }

    // MARK: Cover

    /// The doc's cover, wide across the top, above the title.
    private let coverView = UIImageView()
    private var coverData: Data?
    static let coverHeight: CGFloat = 180

    func setCover(_ data: Data?) {
      guard data != coverData else { return }
      coverData = data
      coverView.image = data.flatMap(UIImage.init(data:))
      coverView.contentMode = .scaleAspectFill
      coverView.clipsToBounds = true
      if coverView.superview == nil { insertSubview(coverView, at: 0) }
      coverView.isHidden = coverView.image == nil
      setNeedsLayout()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      let side = max(20, (bounds.width - Self.readingWidth) / 2)
      let top: CGFloat = coverView.image == nil ? 24 : Self.coverHeight + 24
      if abs(textContainerInset.left - side) > 0.5 || abs(textContainerInset.top - top) > 0.5 {
        textContainerInset = UIEdgeInsets(top: top, left: side, bottom: 120, right: side)
      }
      coverView.frame = CGRect(x: 0, y: 0, width: bounds.width, height: Self.coverHeight)
      // Embedded blocks follow the text's layout.
      controller?.layoutAttachments()
    }

    // MARK: DocTextViewing

    var docTextStorage: NSTextStorage { textStorage }
    var docTextLayoutManager: NSTextLayoutManager? { textLayoutManager }
    var docSelectedRange: NSRange {
      get { selectedRange }
      set { selectedRange = newValue }
    }
    var docTypingAttributes: [NSAttributedString.Key: Any] {
      get { typingAttributes }
      set { typingAttributes = newValue }
    }
    var docHasMarkedText: Bool { markedTextRange != nil }

    func docRect(for range: NSRange) -> CGRect? {
      guard let start = position(from: beginningOfDocument, offset: range.location),
        let end = position(from: start, offset: range.length),
        let textRange = textRange(from: start, to: end)
      else { return nil }
      let rect = range.length == 0 ? caretRect(for: start) : firstRect(for: textRange)
      guard !rect.isNull, !rect.isInfinite else { return nil }
      return rect.offsetBy(dx: -contentOffset.x, dy: -contentOffset.y)
    }

    func docScrollToSelection() {
      scrollRangeToVisible(selectedRange)
    }

    func docFrame(fromContainer rect: CGRect) -> CGRect {
      rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top)
    }

    func docAddSubview(_ view: UIView) {
      if view.superview !== self { addSubview(view) }
    }

    func docNeedsLayout() {
      setNeedsLayout()
    }

    // MARK: Delegate

    func textViewDidChange(_ textView: UITextView) {
      controller?.textDidChange()
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      controller?.selectionDidChange()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
      controller?.updateRects()
    }

    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
      guard let controller, markedTextRange == nil else { return true }
      if text == "\n" { return !controller.handleReturn() }
      if text.isEmpty, range.length == 1, selectedRange.length <= 1, controller.handleDeleteBackward() {
        return false
      }
      controller.willChange(range, replacement: text)
      return true
    }

    func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
      guard case .link(let url) = textItem.content, DocLink.docID(url) != nil else { return defaultAction }
      return UIAction { [weak self] _ in _ = self?.controller?.model.openLink(url) }
    }

    // MARK: Keys

    override var keyCommands: [UIKeyCommand]? {
      var commands = [
        UIKeyCommand(input: "\t", modifierFlags: [], action: #selector(indentForward)),
        UIKeyCommand(input: "\t", modifierFlags: .shift, action: #selector(indentBack)),
      ]
      if controller?.model.linkQuery != nil || controller?.model.slashQuery != nil {
        commands += [
          UIKeyCommand(input: UIKeyCommand.inputUpArrow, modifierFlags: [], action: #selector(popupUp)),
          UIKeyCommand(input: UIKeyCommand.inputDownArrow, modifierFlags: [], action: #selector(popupDown)),
          UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(popupDismiss)),
        ]
      }
      for command in commands { command.wantsPriorityOverSystemBehavior = true }
      return commands
    }

    @objc private func indentForward() { _ = controller?.handleIndent(by: 1) }
    @objc private func indentBack() { _ = controller?.handleIndent(by: -1) }
    @objc private func popupUp() { _ = controller?.model.movePopupSelection(by: -1) }
    @objc private func popupDown() { _ = controller?.model.movePopupSelection(by: 1) }
    @objc private func popupDismiss() { _ = controller?.model.dismissPopup() }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
      let point = recognizer.location(in: self)
      let inContainer = CGPoint(x: point.x - textContainerInset.left, y: point.y - textContainerInset.top)
      _ = controller?.handleMarkerClick(at: inContainer)
    }

    // MARK: Pasteboard

    override func copy(_ sender: Any?) {
      guard let controller, selectedRange.length > 0 else { return super.copy(sender) }
      UIPasteboard.general.string = controller.markdown(for: selectedRange)
    }

    override func cut(_ sender: Any?) {
      guard selectedRange.length > 0 else { return }
      copy(sender)
      replace(selectedTextRange!, withText: "")
    }

    override func paste(_ sender: Any?) {
      guard let controller, let string = UIPasteboard.general.string else { return super.paste(sender) }
      controller.paste(string)
    }

    // MARK: Undo

    override var undoManager: UndoManager? { docUndoManager }
  }

  /// Hands the text view's undo (⌘Z, shake, three-finger swipe) to the doc's own undo.
  final class DocUndoManager: UndoManager {
    private let model: () -> DocEditorViewModel?

    init(model: @escaping () -> DocEditorViewModel?) {
      self.model = model
      super.init()
      // The text view still records its own typing here; the doc's undo is the one that counts,
      // so keep no more than one of those.
      levelsOfUndo = 1
    }

    override var canUndo: Bool { MainActor.assumeIsolated { model()?.canUndo ?? false } }
    override var canRedo: Bool { MainActor.assumeIsolated { model()?.canRedo ?? false } }
    override func undo() { MainActor.assumeIsolated { model()?.undo() } }
    override func redo() { MainActor.assumeIsolated { model()?.redo() } }
  }

  extension NSObjectProtocol {
    fileprivate func configured(_ change: (Self) -> Void) -> Self {
      change(self)
      return self
    }
  }
#endif
