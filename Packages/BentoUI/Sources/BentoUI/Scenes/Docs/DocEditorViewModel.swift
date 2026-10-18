import BentoData
import Dependencies
import Foundation
import Observation
import SQLiteData
import SwiftUI
import UniformTypeIdentifiers

/// One doc, edited as one continuous text the way Craft does. The text view (`DocTextEditor`)
/// shows the blocks as paragraphs and reports each edit back as paragraphs, which this model turns
/// into block changes: new, changed, moved and deleted blocks. Commands from the inspector, the
/// `/` menu and `[[` links change blocks here, and the text view redraws what changed. Each edit
/// is one undo step.
@MainActor
@Observable
public final class DocEditorViewModel: Identifiable {
  public enum Action: Equatable {
    /// Open another doc: one inside a page or card block, or one linked to.
    case openDoc(Doc.ID)
    /// Back to the doc this one was opened from.
    case back
  }

  public let docID: Doc.ID
  public nonisolated var id: Doc.ID { docID }
  /// The title of the doc this one was opened from, for the back button.
  public var parentTitle: String?
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  /// The stored blocks with local edits laid over until the database catches up.
  private(set) var blocks: [DocBlock] = []
  private(set) var title = ""
  /// The block the cursor is in, and every block the selection touches. Format applies to these.
  private(set) var focusedBlockID: DocBlock.ID?
  private(set) var selectedBlockIDs: [DocBlock.ID] = []
  /// A `[[` doc link or `/` command being typed, with what it could become.
  private(set) var linkQuery: CaretQuery?
  private(set) var linkSuggestions: [Doc] = []
  private(set) var slashQuery: CaretQuery?
  /// Current titles of the docs this doc links to, shown in place of the titles stored in links.
  private(set) var linkedTitles: [Doc.ID: String] = [:]
  private(set) var canUndo = false
  private(set) var canRedo = false
  /// Where the cursor and the selection are, in the editor's coordinates, for the popups and the
  /// format bar.
  var caretRect: CGRect?
  var selectionRect: CGRect?
  /// A file block's contents written out for Quick Look.
  var previewURL: URL?
  /// Files to pick, opened by `/image`, `/file` and the Insert panel.
  var importing: ImportKind?
  /// Asks the text view to put the cursor at the end of a block.
  private(set) var focusRequest: FocusRequest?

  struct FocusRequest: Equatable {
    let id: DocBlock.ID
    /// Where in the block's text, in characters as shown; nil for its end.
    var offset: Int?
    let serial: Int
  }

  @ObservationIgnored @FetchOne var doc: Doc?
  @ObservationIgnored @FetchAll var storedBlocks: [DocBlock]
  /// The docs inside this doc's page and card blocks.
  @ObservationIgnored @FetchAll var pages: [Doc]
  /// The previews of this doc's link blocks.
  @ObservationIgnored @FetchAll var previews: [DocLinkPreview]
  /// Link blocks whose preview is being fetched.
  private(set) var fetchingPreviews: Set<DocBlock.ID> = []
  /// Blocks whose attached file has arrived, so an image can show once its data syncs.
  @ObservationIgnored @FetchAll var fileBlockIDs: [DocBlock.ID]
  /// Docs with a link to this one.
  @ObservationIgnored @FetchAll var backlinks: [Doc]
  /// The doc's cover image, if it has one.
  @ObservationIgnored @FetchOne var cover: DocCover?
  /// Applies an inline style to the text view's selection; set by the text view.
  @ObservationIgnored var inlineFormatter: ((InlineStyle) -> Void)?
  /// Puts a web link on the selected text (an empty string takes it off); set by the text view.
  @ObservationIgnored var linkFormatter: ((String) -> Void)?
  /// Asks the view for a link to put on the selection (⌘K).
  var askingForLink = false

  func setLinkOnSelection(_ url: String) {
    askingForLink = false
    var url = url.trimmingCharacters(in: .whitespaces)
    if !url.isEmpty, !url.contains("://"), url.contains(".") { url = "https://" + url }
    linkFormatter?(url)
  }

  /// Replaces the `[[query` before the cursor with a doc link; set by the text view.
  @ObservationIgnored var linkInserter: ((CaretQuery, Doc.ID, String) -> Void)?
  /// Removes the `/query` before the cursor; set by the text view.
  @ObservationIgnored var slashRemover: ((CaretQuery) -> Void)?

  @ObservationIgnored private var pending: [DocBlock.ID: Pending] = [:]
  /// Merges again once kept local edits are old enough to give way to the stored rows.
  @ObservationIgnored private var expiry: Task<Void, Never>?
  @ObservationIgnored private var undoStack: [UndoStep] = []
  @ObservationIgnored private var redoStack: [UndoStep] = []
  /// Set while an edit runs, so the changes it makes become one undo step.
  @ObservationIgnored private var openStep: StepStart?
  @ObservationIgnored private var dismissedLinkQuery: CaretQuery?
  @ObservationIgnored private var suggestionSearch: Task<Void, Never>?
  @ObservationIgnored private var titleLookup: Task<Void, Never>?
  @ObservationIgnored private var requestedTitles: Set<Doc.ID> = []
  @ObservationIgnored private var focusSerial = 0
  @ObservationIgnored private let store: any DocsStoring
  @ObservationIgnored private let linkPreviewer: any LinkPreviewing
  @ObservationIgnored @Dependency(\.defaultDatabase) private var database
  @ObservationIgnored @Dependency(\.date.now) private var now

  private struct Pending {
    /// nil when the block was deleted here.
    let block: DocBlock?
    let since: Date
  }

  /// Text typed after `[[` or `/` in a block, up to the cursor.
  struct CaretQuery: Equatable {
    let blockID: DocBlock.ID
    let query: String
    var selected = 0
  }

  enum InlineStyle {
    case bold, italic, strike, code
  }

  enum ImportKind: Identifiable {
    case image, file
    var id: Self { self }
    var types: [UTType] { self == .image ? [.image] : [.item] }
  }

  init(docID: Doc.ID, store: any DocsStoring, linkPreviewer: any LinkPreviewing = NativeLinkPreviewer()) {
    self.docID = docID
    self.store = store
    self.linkPreviewer = linkPreviewer
  }

  func load() async {
    let docID = docID
    let link = DocLink.url(docID).absoluteString
    _ = await withErrorReporting {
      try await $doc.load(Doc.find(docID))
      try await $storedBlocks.load(DocBlock.where { $0.docID.eq(docID) }.order { ($0.position, $0.id) })
      try await $pages.load(
        Doc.where { $0.parentBlockID.in(DocBlock.where { $0.docID.eq(docID) }.select { Optional($0.id) }) }
      )
      try await $previews.load(
        DocLinkPreview.where { $0.blockID.in(DocBlock.where { $0.docID.eq(docID) }.select(\.id)) }
      )
      try await $fileBlockIDs.load(
        DocFile.where { $0.blockID.in(DocBlock.where { $0.docID.eq(docID) }.select(\.id)) }.select(\.blockID)
      )
      try await $cover.load(DocCover.find(docID))
      try await $backlinks.load(
        Doc
          .where { doc in
            doc.id.in(
              DocBlock
                .where { #sql("instr(\($0.text), \(bind: link)) > 0", as: Bool.self) }
                .select(\.docID)
            )
          }
          .where { $0.id.neq(docID) }
          .order { $0.updatedAt.desc() }
      )
    }
    title = doc?.title ?? ""
    merge()
    // Linked docs may have been renamed since this doc was last open.
    refreshLinkedTitles(force: true)
  }

  /// Takes in what the database now holds. Local edits the database has not reflected yet stay
  /// on top for a few seconds; after that the stored row wins, so another device's edit is never
  /// held back for long.
  func merge(scheduling: Bool = true) {
    var byID = Dictionary(storedBlocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    for (id, local) in pending {
      if byID[id] == local.block || now.timeIntervalSince(local.since) > Self.pendingLifetime {
        pending[id] = nil
      } else {
        byID[id] = local.block
      }
    }
    let merged = byID.values.sorted { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
    if merged != blocks { blocks = merged }
    // No further change may arrive to trigger another merge, so one is scheduled.
    // One follow-up per change is enough: by then every edit kept here has expired.
    expiry?.cancel()
    if scheduling, !pending.isEmpty {
      expiry = Task { [weak self] in
        try? await Task.sleep(for: .seconds(Self.pendingLifetime + 0.1))
        guard !Task.isCancelled else { return }
        self?.merge(scheduling: false)
      }
    }
    refreshLinkedTitles()
  }

  static let pendingLifetime: TimeInterval = 3

  /// The title the doc has elsewhere, unless it is being typed here.
  func mergeTitle() {
    if let stored = doc?.title, stored != title, openStep == nil, undoStack.last?.coalescing != "title" {
      title = stored
    }
  }

  // MARK: Edits from the text view

  /// Takes the text view's paragraphs after an edit and makes the blocks match: a paragraph
  /// whose block appears twice (Return copies it) is a new block, as is one whose block is not
  /// in this doc (pasted), blocks with no paragraph are deleted, and blocks in a new order are
  /// moved. Returns the new blocks' ids by paragraph index, for the text view to mark.
  @discardableResult
  func applyParagraphs(_ paragraphs: [DocParagraphState], caretBlockID: DocBlock.ID? = nil) -> [Int: DocBlock.ID] {
    let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let visible = visibleBlocks
    // Which paragraph keeps a block that appears more than once: the one still holding its
    // text, else the first with any text, else the first.
    var owner: [DocBlock.ID: Int] = [:]
    for (index, paragraph) in paragraphs.enumerated() {
      guard !paragraph.isTitle, paragraph.attachmentID == nil, let id = paragraph.blockID, byID[id] != nil else { continue }
      guard let current = owner[id] else {
        owner[id] = index
        continue
      }
      let text = byID[id]?.text
      if paragraphs[current].markdown != text,
        paragraph.markdown == text || (paragraphs[current].markdown.isEmpty && !paragraph.markdown.isEmpty)
      {
        owner[id] = index
      }
    }

    enum Target {
      case existing(DocBlock)
      case new(DocBlock, paragraph: Int)
    }
    var newTitle: String?
    var targets: [Target] = []
    var usedAttachments: Set<DocBlock.ID> = []
    for (index, paragraph) in paragraphs.enumerated() {
      if paragraph.isTitle, newTitle == nil {
        newTitle = paragraph.markdown
        continue
      }
      if let attachmentID = paragraph.attachmentID {
        // A copied attachment has nothing to copy it from here; only the original stays.
        if let block = byID[attachmentID], usedAttachments.insert(attachmentID).inserted {
          targets.append(.existing(block))
        }
        continue
      }
      var looks = paragraph.block ?? DocBlock(docID: docID)
      looks.text = paragraph.markdown
      if paragraph.isTitle {
        // Return in the title starts the first line of the doc.
        targets.append(.new(DocBlock(docID: docID, text: paragraph.markdown), paragraph: index))
      } else if let id = paragraph.blockID, owner[id] == index, var existing = byID[id] {
        existing.copyLooks(from: looks)
        existing.text = paragraph.markdown
        targets.append(.existing(convertShortcut(existing, typing: id == caretBlockID)))
      } else {
        let original = paragraph.blockID.flatMap { byID[$0] }
        targets.append(.new(continuation(of: looks, splitFrom: original), paragraph: index))
      }
    }

    let kept = Set(targets.compactMap { if case .existing(let block) = $0 { block.id } else { nil } })
    var gone = visible.map(\.id).filter { !kept.contains($0) }
    // Blocks folded under a deleted toggle go with it.
    for id in gone where byID[id]?.isCollapsed == true {
      gone += subtree(id).dropFirst().map(\.id).filter { !kept.contains($0) && !gone.contains($0) }
    }
    let changed = targets.compactMap { target -> DocBlock? in
      guard case .existing(let block) = target, byID[block.id] != block else { return nil }
      return block
    }
    let hasNew = targets.contains { if case .new = $0 { true } else { false } }
    let keptOrder = targets.compactMap { if case .existing(let block) = $0 { block.id } else { nil } }
    let moved = blocksToMove(keptOrder, visible: visible.map(\.id).filter(kept.contains))
    let titleChanged = newTitle.map { $0 != title } ?? false
    guard titleChanged || hasNew || !gone.isEmpty || !changed.isEmpty || !moved.isEmpty else { return [:] }

    // Typing in one block, or in the title, keeps adding to one undo step.
    let onlyText = !hasNew && gone.isEmpty && moved.isEmpty
    let key: String? =
      if onlyText, !titleChanged, changed.count == 1, changed[0].text != byID[changed[0].id]?.text,
        changed[0].kind == byID[changed[0].id]?.kind
      {
        "text \(changed[0].id)"
      } else if onlyText, changed.isEmpty, titleChanged {
        "title"
      } else {
        nil
      }
    var assigned: [Int: DocBlock.ID] = [:]
    perform(coalescing: key) {
      if let newTitle, titleChanged {
        title = newTitle
        withErrorReporting { try store.renameDoc(docID, title: newTitle) }
      }
      for block in changed { save(block) }
      if !gone.isEmpty { removeBlocks(gone) }
      // Moves go before inserts, so new blocks land after the moved ones they follow.
      for (id, after) in moved {
        openStep?.placesChanged = true
        let placed = withErrorReporting { try store.moveBlocks(subtree(id).map(\.id), after: after) } ?? []
        for block in placed { keep(block) }
      }
      if !moved.isEmpty { merge() }
      var previous: DocBlock.ID?
      for target in targets {
        switch target {
        case .existing(let block):
          previous = afterSubtree(block.id)
        case .new(let template, let paragraph):
          openStep?.placesChanged = true
          let inserted = withErrorReporting { try store.insertBlocks(docID: docID, after: previous, templates: [template]) }
          if let block = inserted?.first {
            keep(block)
            assigned[paragraph] = block.id
            previous = block.id
          }
        }
      }
      merge()
    }
    return assigned
  }

  /// The fast path for typing inside one paragraph: saves its block alone. False when the
  /// paragraph is not one block's text, for `applyParagraphs` to sort out.
  func applyParagraph(_ paragraph: DocParagraphState, caretBlockID: DocBlock.ID?) -> Bool {
    guard !paragraph.isTitle, paragraph.attachmentID == nil, let id = paragraph.blockID, let current = block(id),
      !current.kind.isAttachment, let looks = paragraph.block
    else { return false }
    var block = current
    block.copyLooks(from: looks)
    block.text = paragraph.markdown
    block = convertShortcut(block, typing: id == caretBlockID)
    guard block != current else { return true }
    let typing = block.kind == current.kind && block.text != current.text
    if typing {
      perform(coalescing: "text \(id)") { saveTyping(block) }
    } else {
      perform { save(block) }
    }
    return true
  }

  // MARK: Saving typing

  /// Typed text waiting to be written. Typing is saved when it pauses (or every second while it
  /// goes on) rather than at each keystroke: each write has the doc's open queries read the whole
  /// doc again, and syncs a change to iCloud. Everything else writes at once, saving typing first.
  @ObservationIgnored private var unsaved: [DocBlock.ID: DocBlock] = [:]
  @ObservationIgnored private var flushTask: Task<Void, Never>?
  @ObservationIgnored private var unsavedSince: Date?

  static let typingSaveDelay: Duration = .milliseconds(400)
  static let typingSaveLimit: TimeInterval = 1

  private func saveTyping(_ block: DocBlock) {
    keep(block)
    unsaved[block.id] = block
    let since = unsavedSince ?? Date()
    unsavedSince = since
    flushTask?.cancel()
    // Typing that goes on is still saved every second.
    if Date().timeIntervalSince(since) >= Self.typingSaveLimit { return flushTyping() }
    flushTask = Task { [weak self] in
      try? await Task.sleep(for: Self.typingSaveDelay)
      guard !Task.isCancelled else { return }
      self?.flushTyping()
    }
  }

  /// Writes typed text that is waiting. Called before any other change, and when the doc closes
  /// or the app moves to the background.
  func flushTyping() {
    flushTask?.cancel()
    flushTask = nil
    unsavedSince = nil
    guard !unsaved.isEmpty else { return }
    let blocks = unsaved.values
    unsaved = [:]
    for block in blocks {
      // Kept on screen until the database shows it, counted from now.
      pending[block.id] = Pending(block: block, since: now)
      withErrorReporting { try store.updateBlock(block) }
    }
  }

  func setTitle(_ newTitle: String) {
    guard newTitle != title else { return }
    perform(coalescing: "title") {
      title = newTitle
      withErrorReporting { try store.renameDoc(docID, title: newTitle) }
    }
  }

  /// The block after which the next paragraph's block goes: this one, or the last block folded
  /// under it.
  private func afterSubtree(_ id: DocBlock.ID) -> DocBlock.ID {
    guard let block = block(id), block.kind == .toggle, block.isCollapsed else { return id }
    return subtree(id).last?.id ?? id
  }

  /// A block typed into at its start with a Markdown prefix ("# ", "- ", "[] ", "> ") takes that
  /// style, as in Craft.
  private func convertShortcut(_ block: DocBlock, typing: Bool) -> DocBlock {
    // Matched on the plain text, as stored text escapes `[` and the like.
    let plain = DocInline.plainText(block.text)
    guard typing, block.kind == .text, block.decoration == .none, let shortcut = DocMarkdown.shortcut(plain) else { return block }
    var block = block
    block.kind = shortcut.kind
    block.text = shortcut.kind == .divider ? "" : Self.dropping(plain.count - shortcut.text.count, from: block.text)
    block.isChecked = shortcut.isChecked
    block.decoration = shortcut.decoration
    block.language = shortcut.language
    if shortcut.kind == .table { block.text = DocTable.empty.json }
    return block
  }

  /// Markdown text without its first `count` characters of plain text, styles kept.
  private static func dropping(_ count: Int, from markdown: String) -> String {
    var remaining = count
    var runs = DocInline.parse(markdown)
    while remaining > 0, !runs.isEmpty {
      let take = min(remaining, runs[0].text.count)
      runs[0].text.removeFirst(take)
      remaining -= take
      if runs[0].text.isEmpty { runs.removeFirst() }
    }
    return DocInline.markdown(runs)
  }

  /// The block a new paragraph makes. One split off the middle of a block keeps its looks; an
  /// empty one after a list item continues the list (unchecked), after a heading it is body
  /// text, and after an open toggle it is its first nested line.
  private func continuation(of paragraph: DocBlock, splitFrom original: DocBlock?) -> DocBlock {
    var block = DocBlock(docID: docID)
    block.copyLooks(from: paragraph)
    block.text = paragraph.text
    block.isChecked = false
    block.isCollapsed = false
    if paragraph.kind.isAttachment { block.kind = .text }
    guard paragraph.text.isEmpty, original != nil else { return block }
    switch paragraph.kind {
    case .toggle:
      block.kind = .text
      block.indent = paragraph.indent + 1
    case .title, .subtitle, .heading, .strong, .caption:
      block.kind = .text
      block.alignment = .leading
    default:
      break
    }
    return block
  }

  /// The blocks to move so `order` holds: everything outside the longest run already in order,
  /// each after the block before it in `order`.
  private func blocksToMove(_ order: [DocBlock.ID], visible: [DocBlock.ID]) -> [(DocBlock.ID, DocBlock.ID?)] {
    guard order != visible else { return [] }
    let place = Dictionary(visible.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let ranks = order.map { place[$0] ?? 0 }
    let staying = Set(longestIncreasing(ranks).map { order[$0] })
    var moves: [(DocBlock.ID, DocBlock.ID?)] = []
    for (index, id) in order.enumerated() where !staying.contains(id) {
      moves.append((id, index > 0 ? afterSubtree(order[index - 1]) : nil))
    }
    return moves
  }

  /// Indices of a longest increasing subsequence.
  private func longestIncreasing(_ values: [Int]) -> [Int] {
    var tails: [Int] = []
    var previous = Array(repeating: -1, count: values.count)
    for (index, value) in values.enumerated() {
      var low = 0
      var high = tails.count
      while low < high {
        let mid = (low + high) / 2
        if values[tails[mid]] < value { low = mid + 1 } else { high = mid }
      }
      if low > 0 { previous[index] = tails[low - 1] }
      if low == tails.count { tails.append(index) } else { tails[low] = index }
    }
    var result: [Int] = []
    var index = tails.last ?? -1
    while index >= 0 {
      result.append(index)
      index = previous[index]
    }
    return result.reversed()
  }

  /// Where the text view's cursor and selection are.
  func selectionChanged(focused: DocBlock.ID?, selected: [DocBlock.ID], offset: Int? = nil) {
    if focusedBlockID != focused { focusedBlockID = focused }
    if selectedBlockIDs != selected { selectedBlockIDs = selected }
    caretOffset = offset
  }

  /// Where the cursor is in its block, in characters as shown; undo puts it back there.
  @ObservationIgnored private var caretOffset: Int?
  /// Where an edit the text view is about to make starts; text views move the cursor before
  /// they report the edit, so this is the place undo returns to.
  @ObservationIgnored private var editStart: Caret?

  func editWillStart(in blockID: DocBlock.ID, at offset: Int) {
    editStart = Caret(blockID: blockID, offset: offset)
  }

  /// The text view's edit has been applied (or came to nothing).
  func editDidEnd() {
    editStart = nil
  }

  /// Return on an empty list item ends the list, as in Craft: a nested item moves out a level,
  /// one at the top becomes body text.
  func endList(_ id: DocBlock.ID) -> Bool {
    guard var block = block(id), block.kind.isList, DocInline.plainText(block.text).isEmpty else { return false }
    perform {
      if block.indent > 0 { block.indent -= 1 } else { block.kind = .text }
      save(block)
    }
    return true
  }

  /// Delete at the start of a styled block takes the style off before anything else: out a
  /// level, then back to body text.
  func unstyle(_ id: DocBlock.ID) -> Bool {
    guard var block = block(id), block.indent > 0 || block.kind != .text || block.decoration != .none,
      !block.kind.isAttachment
    else { return false }
    perform {
      if block.indent > 0 {
        block.indent -= 1
      } else {
        block.kind = .text
        block.decoration = .none
        block.isChecked = false
      }
      save(block)
    }
    return true
  }

  /// Tab and Shift-Tab nest the selected blocks or bring them back.
  func indent(_ ids: [DocBlock.ID], by offset: Int) {
    let edited = ids.compactMap(block).compactMap { block -> DocBlock? in
      var block = block
      let indent = min(max(block.indent + offset, 0), 6)
      guard indent != block.indent else { return nil }
      block.indent = indent
      return block
    }
    guard !edited.isEmpty else { return }
    perform {
      for block in edited { save(block) }
    }
  }

  // MARK: Format

  func toggleInline(_ style: InlineStyle) {
    inlineFormatter?(style)
  }

  func toggleChecked(_ id: DocBlock.ID) {
    edit([id]) { $0.isChecked.toggle() }
  }

  func toggleCollapsed(_ id: DocBlock.ID) {
    edit([id]) { $0.isCollapsed.toggle() }
  }

  /// The blocks Format changes: the selected ones, else the one the cursor is in.
  private var formatTargets: [DocBlock.ID] {
    selectedBlockIDs.isEmpty ? focusedBlockID.map { [$0] } ?? [] : selectedBlockIDs
  }

  /// Gives the selected blocks a style, keeping their text. Pressing a list style they already
  /// have takes them back to body text, as in Craft. A page or card keeps the text as the title
  /// of its new doc.
  func setKind(_ kind: DocBlock.Kind) {
    let targets = formatTargets.compactMap(block).filter { $0.kind != .file }
    guard !targets.isEmpty else { return }
    let kind = kind.isList && targets.allSatisfy({ $0.kind == kind }) ? .text : kind
    edit(targets.map(\.id)) { block in
      if block.kind == .table || block.kind == .divider, kind.isEditable { block.text = "" }
      if kind.holdsDoc { block.text = DocInline.plainText(block.text) }
      block.kind = kind
      if kind == .divider { block.text = "" }
      if kind == .table { block.text = DocTable.empty.json }
    }
  }

  func setAlignment(_ alignment: DocBlock.Alignment) {
    edit(formatTargets) { $0.alignment = alignment }
  }

  /// Focus and Block are on or off; turning one on replaces the other.
  func toggleDecoration(_ decoration: DocBlock.Decoration) {
    let targets = formatTargets.compactMap(block)
    let on = !targets.allSatisfy { $0.decoration == decoration }
    edit(targets.map(\.id)) { $0.decoration = on ? decoration : .none }
  }

  func setColor(_ color: DocBlock.BlockColor) {
    edit(formatTargets) { $0.color = color }
  }

  func setFont(_ font: DocBlock.BlockFont) {
    edit(formatTargets) { $0.font = font }
  }

  func setLanguage(_ id: DocBlock.ID, _ language: String) {
    edit([id]) { $0.language = language }
  }

  var focusedBlock: DocBlock? { focusedBlockID.flatMap(block) }

  // MARK: Insert

  /// What the Insert panel and the `/` menu add.
  enum Insertion: Hashable {
    case block(DocBlock.Kind)
    case code(language: String)
    case separator(DocBlock.LineWeight)
    /// Starts a `[[` doc link.
    case docLink
    case importFiles(ImportKind)
  }

  struct InsertItem: Identifiable, Hashable {
    let name: String
    let symbol: String
    let insertion: Insertion
    var keywords: [String] = []
    var id: String { name }
  }

  static let insertSections: [(String, [InsertItem])] = [
    ("Text", [
      InsertItem(name: "Body", symbol: "text.alignleft", insertion: .block(.text), keywords: ["text", "paragraph"]),
      InsertItem(name: "Title", symbol: "textformat.size.larger", insertion: .block(.title), keywords: ["h1", "heading"]),
      InsertItem(name: "Subtitle", symbol: "textformat.size", insertion: .block(.subtitle), keywords: ["h2", "heading"]),
      InsertItem(name: "Heading", symbol: "textformat.size.smaller", insertion: .block(.heading), keywords: ["h3"]),
      InsertItem(name: "Strong", symbol: "bold", insertion: .block(.strong), keywords: ["h4"]),
      InsertItem(name: "Caption", symbol: "textformat.subscript", insertion: .block(.caption), keywords: ["small"]),
    ]),
    ("Suggested", [
      InsertItem(name: "Card", symbol: "rectangle.portrait.on.rectangle.portrait", insertion: .block(.card), keywords: ["subpage"]),
      InsertItem(name: "Page", symbol: "doc.text", insertion: .block(.page), keywords: ["subpage"]),
      InsertItem(name: "Task List", symbol: "checklist", insertion: .block(.todo), keywords: ["todo", "checkbox"]),
      InsertItem(name: "Table", symbol: "tablecells", insertion: .block(.table), keywords: ["grid"]),
      InsertItem(name: "Image", symbol: "photo", insertion: .importFiles(.image), keywords: ["picture", "photo"]),
      InsertItem(name: "File", symbol: "folder", insertion: .importFiles(.file), keywords: ["attachment", "pdf"]),
      InsertItem(name: "Page Break", symbol: "rectangle.split.1x2", insertion: .separator(.strong), keywords: ["divider"]),
    ]),
    ("Lists", [
      InsertItem(name: "Bulleted List", symbol: "list.bullet", insertion: .block(.bullet), keywords: ["ul"]),
      InsertItem(name: "Numbered List", symbol: "list.number", insertion: .block(.numbered), keywords: ["ol"]),
      InsertItem(name: "Toggle", symbol: "chevron.right.square", insertion: .block(.toggle), keywords: ["fold", "collapse"]),
    ]),
    ("Rich Blocks", [
      InsertItem(name: "Smart Link", symbol: "link", insertion: .block(.link), keywords: ["url", "web"]),
      InsertItem(name: "Link to Doc", symbol: "arrow.up.right.square", insertion: .docLink, keywords: ["backlink", "reference"]),
      InsertItem(name: "Code Block", symbol: "chevron.left.forwardslash.chevron.right", insertion: .code(language: ""), keywords: ["code"]),
      InsertItem(name: "Formula", symbol: "x.squareroot", insertion: .code(language: "latex"), keywords: ["math", "latex"]),
      InsertItem(name: "Mermaid", symbol: "point.3.connected.trianglepath.dotted", insertion: .code(language: "mermaid"), keywords: ["diagram"]),
    ]),
    ("Separators", [
      InsertItem(name: "Extralight", symbol: "ellipsis", insertion: .separator(.extraLight), keywords: ["divider"]),
      InsertItem(name: "Light", symbol: "line.horizontal.3.decrease", insertion: .separator(.light), keywords: ["divider"]),
      InsertItem(name: "Regular", symbol: "minus", insertion: .separator(.regular), keywords: ["divider", "line"]),
      InsertItem(name: "Strong", symbol: "rectangle.fill", insertion: .separator(.strong), keywords: ["divider"]),
    ]),
  ]

  /// Adds a block after the one the cursor is in, or at the end. An empty body line where the
  /// cursor is becomes the new block instead, as `/` does in Craft.
  func insert(_ insertion: Insertion) {
    let current = focusedBlock
    let reuse = current.map { $0.kind == .text && DocInline.plainText($0.text).isEmpty } ?? false
    let afterID = focusedBlockID ?? blocks.last?.id
    var template = DocBlock(docID: docID)
    switch insertion {
    case .importFiles(let kind):
      importing = kind
      return
    case .docLink:
      template.text = "[["
    case .block(let kind):
      template.kind = kind
      if kind == .table { template.text = DocTable.empty.json }
    case .code(let language):
      template.kind = .code
      template.language = language
    case .separator(let weight):
      template.kind = .divider
      template.lineWeight = weight
    }
    perform {
      var target: DocBlock?
      if reuse, var block = current {
        block.copyLooks(from: template)
        block.indent = current?.indent ?? 0
        block.text = template.text
        save(block)
        target = block
      } else {
        target = insertBlocks([template], after: afterID).first
      }
      guard let target else { return }
      if target.kind.holdsDoc { withErrorReporting { _ = try store.docInside(target.id) } }
      if !target.kind.isAttachment {
        requestFocus(target.id)
      } else if let after = insertBlocks([DocBlock(docID: docID)], after: target.id).first {
        // A line after an embedded block to keep typing in.
        requestFocus(after.id)
      }
    }
  }

  /// Adds an empty body block at the end and puts the cursor there.
  func addText() {
    perform {
      if let block = insertBlocks([DocBlock(docID: docID)], after: blocks.last?.id).first { requestFocus(block.id) }
    }
  }

  private func requestFocus(_ id: DocBlock.ID, at offset: Int? = nil) {
    focusSerial += 1
    focusRequest = FocusRequest(id: id, offset: offset, serial: focusSerial)
  }

  /// Deletes a block and what is nested in it, kept for undo.
  func remove(_ id: DocBlock.ID) {
    perform { removeBlocks(subtree(id).map(\.id)) }
  }

  private func removeBlocks(_ ids: [DocBlock.ID]) {
    for id in ids { unsaved[id] = nil }
    let snapshot = withErrorReporting { try store.snapshot(blockIDs: ids) }
    if let snapshot { openStep?.removed.merge(snapshot) }
    for id in ids { pending[id] = Pending(block: nil, since: now) }
    blocks.removeAll { ids.contains($0.id) }
    withErrorReporting { try store.deleteBlocks(ids) }
  }

  // MARK: Moving

  /// The block and the blocks nested under it, which move with it.
  func subtree(_ id: DocBlock.ID) -> [DocBlock] {
    guard let index = blocks.firstIndex(where: { $0.id == id }) else { return [] }
    let indent = blocks[index].indent
    var tree = [blocks[index]]
    for block in blocks[(index + 1)...] {
      guard block.indent > indent else { break }
      tree.append(block)
    }
    return tree
  }

  /// Moves a block, with what is nested under it, right below `targetID` (after a collapsed
  /// toggle's hidden blocks), or to the top when it is nil. Dropping a block into its own subtree
  /// does nothing.
  func move(_ id: DocBlock.ID, after targetID: DocBlock.ID?) {
    let tree = subtree(id)
    guard !tree.isEmpty, !tree.contains(where: { $0.id == targetID }) else { return }
    let target = targetID.map(afterSubtree)
    let index = blocks.firstIndex { $0.id == id } ?? 0
    // Already right there.
    guard target != (index > 0 ? blocks[index - 1].id : nil) else { return }
    perform {
      openStep?.placesChanged = true
      let moved = withErrorReporting { try store.moveBlocks(tree.map(\.id), after: target) } ?? []
      for block in moved { keep(block) }
      merge()
    }
  }

  /// ⌥⌘↑ and ⌥⌘↓: moves the block the cursor is in, keeping the cursor where it was in it.
  func moveFocusedBlock(by offset: Int) {
    guard let id = focusedBlockID else { return }
    move(id, by: offset)
    requestFocus(id, at: caretOffset)
  }

  /// Move Up and Move Down: past the neighbouring block and what is nested under it.
  func move(_ id: DocBlock.ID, by offset: Int) {
    guard let index = blocks.firstIndex(where: { $0.id == id }) else { return }
    let indent = blocks[index].indent
    if offset < 0 {
      // The previous block at this level or above starts the subtree to pass.
      guard let previous = blocks[..<index].lastIndex(where: { $0.indent <= indent }) else { return }
      move(id, after: previous > 0 ? blocks[previous - 1].id : nil)
    } else {
      let next = index + subtree(id).count
      guard next < blocks.count, let end = subtree(blocks[next].id).last else { return }
      move(id, after: end.id)
    }
  }

  /// Something dropped after a block: another block (moved there), files (attached), a web link
  /// (a link block) or text (its blocks).
  func drop(_ text: String, after targetID: DocBlock.ID?) -> Bool {
    if let id = DocBlockDrag.blockID(text) {
      move(id, after: targetID)
      return true
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    // Files come as file URLs, or from Finder as plain paths.
    let fileURL = URL(string: trimmed).flatMap { $0.isFileURL ? $0 : nil }
      ?? (trimmed.hasPrefix("/") && FileManager.default.fileExists(atPath: trimmed) ? URL(fileURLWithPath: trimmed) : nil)
    if let fileURL {
      Task { await attach([fileURL], after: targetID) }
      return true
    }
    if let link = DocMarkdown.linkURL(trimmed) {
      perform { _ = insertBlocks([DocBlock(docID: docID, kind: .link, text: link)], after: targetID) }
      return true
    }
    return insertMarkdown(text, after: targetID)
  }

  /// Runs several edits, made through the text or here, as one undo step.
  func groupEdits(_ edits: () -> Void) {
    perform(edits)
  }

  /// Docs dragged from the list onto this one become links to them, a line each, after a block.
  func insertDocLinks(_ ids: [Doc.ID], after targetID: DocBlock.ID?) {
    let docs = withErrorReporting { try database.read { db in try Doc.where { $0.id.in(ids) }.fetchAll(db) } } ?? []
    let lines = ids.compactMap { id in docs.first { $0.id == id } }.filter { $0.id != docID }
    guard !lines.isEmpty else { return }
    perform {
      let templates = lines.map { DocBlock(docID: docID, text: DocLink.markdown(title: $0.title, id: $0.id)) }
      for doc in lines { linkedTitles[doc.id] = doc.title }
      if let last = insertBlocks(templates, after: targetID).last { requestFocus(last.id) }
    }
  }

  /// Adds the blocks of Markdown text (pasted, dropped) after a block, in place of an empty
  /// line when `replacing` names one.
  @discardableResult
  func insertMarkdown(_ markdown: String, after targetID: DocBlock.ID?, replacing empty: DocBlock.ID? = nil) -> Bool {
    let contents = DocMarkdown.blocks(from: markdown)
    guard !contents.isEmpty else { return false }
    perform {
      let inserted = insertBlocks(contents.map { DocBlock(docID: docID, content: $0, position: 0) }, after: targetID)
      if let empty { removeBlocks([empty]) }
      for block in inserted where block.kind.holdsDoc { withErrorReporting { _ = try store.docInside(block.id) } }
      if let last = inserted.last(where: { !$0.kind.isAttachment }) ?? inserted.last { requestFocus(last.id) }
    }
    return true
  }

  /// Attaches files after `afterID`, else after the block the cursor is in, else at the end. Files
  /// are read and written off the main thread; each becomes an undo step of its own once written,
  /// so typing meanwhile stays out of it.
  func attach(_ urls: [URL], after afterID: DocBlock.ID? = nil) async {
    var afterID = afterID ?? focusedBlockID ?? blocks.last?.id
    for url in urls {
      let block = await withErrorReporting {
        let file = try await DocFileReader.read(url)
        return try await store.insertFile(docID: docID, after: afterID, file: file)
      }
      guard let block else { continue }
      keep(block)
      merge()
      afterID = block.id
      recordInsert(block)
    }
  }

  /// An undo step for a block added outside `perform`.
  private func recordInsert(_ block: DocBlock) {
    undoStack.append(
      UndoStep(
        changes: [block.id: Change(before: nil, after: block)], caretBefore: nil, titleBefore: title, titleAfter: title,
        restoreForUndo: DocSnapshot(), createdDocs: [], at: now
      )
    )
    redoStack.removeAll()
    updateUndoState()
  }

  // MARK: Doc links and `/`

  /// The text view saw `[[query` (or nothing) before the cursor.
  func linkQueryChanged(_ query: CaretQuery?) {
    guard let query else {
      dismissedLinkQuery = nil
      if linkQuery != nil { closeLinkQuery() }
      return
    }
    guard query != dismissedLinkQuery else { return }
    if linkQuery?.query != query.query || linkQuery?.blockID != query.blockID {
      linkQuery = query
      searchLinkSuggestions(query.query)
    }
  }

  /// The text view saw `/query` (or nothing) before the cursor.
  func slashQueryChanged(_ query: CaretQuery?) {
    if query?.query != slashQuery?.query || query?.blockID != slashQuery?.blockID { slashQuery = query }
  }

  private func closeLinkQuery() {
    linkQuery = nil
    linkSuggestions = []
  }

  /// Escape closes the open popup; the same `[[` stays closed until its text changes.
  func dismissPopup() -> Bool {
    if var query = linkQuery {
      query.selected = 0
      dismissedLinkQuery = query
      closeLinkQuery()
      return true
    }
    if slashQuery != nil {
      slashQuery = nil
      return true
    }
    return false
  }

  /// Up and Down move through the open popup's choices.
  func movePopupSelection(by offset: Int) -> Bool {
    if var query = linkQuery, !linkChoices.isEmpty {
      query.selected = (query.selected + offset + linkChoices.count) % linkChoices.count
      linkQuery = query
      return true
    }
    if var query = slashQuery, !slashChoices.isEmpty {
      query.selected = (query.selected + offset + slashChoices.count) % slashChoices.count
      slashQuery = query
      return true
    }
    return false
  }

  /// Return picks the open popup's highlighted choice. False when no popup has choices, so
  /// Return splits the line as usual.
  func choosePopupSelection() -> Bool {
    if let query = linkQuery, let choice = linkChoices[safe: query.selected] {
      chooseLink(choice)
      return true
    }
    if let query = slashQuery, let item = slashChoices[safe: query.selected] {
      chooseSlash(item)
      return true
    }
    return false
  }

  private func searchLinkSuggestions(_ query: String) {
    let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
    let docID = docID
    suggestionSearch?.cancel()
    suggestionSearch = Task { [weak self, database] in
      let docs = (try? await database.read { db in
        try Doc
          .where { $0.id.neq(docID) }
          .where { doc in
            if !needle.isEmpty { #sql("instr(bentoLower(\(doc.title)), \(bind: needle)) > 0", as: Bool.self) }
          }
          .order { $0.updatedAt.desc() }
          .limit(8)
          .fetchAll(db)
      }) ?? []
      guard !Task.isCancelled, let self, self.linkQuery?.query == query else { return }
      self.linkSuggestions = docs
      if var current = self.linkQuery, current.selected >= self.linkChoices.count {
        current.selected = 0
        self.linkQuery = current
      }
    }
  }

  /// What the link list offers: matching docs, then a new doc named after the query.
  enum LinkChoice: Hashable {
    case doc(Doc)
    case create(String)
  }

  var linkChoices: [LinkChoice] {
    guard let query = linkQuery else { return [] }
    let name = query.query.trimmingCharacters(in: .whitespaces)
    let exact = linkSuggestions.contains { $0.title.caseInsensitiveCompare(name) == .orderedSame }
    return linkSuggestions.map(LinkChoice.doc) + (name.isEmpty || exact ? [] : [.create(name)])
  }

  /// The `/` menu's items for the typed query.
  var slashChoices: [InsertItem] {
    guard let query = slashQuery else { return [] }
    let needle = query.query.lowercased()
    let items = Self.insertSections.flatMap(\.1)
    guard !needle.isEmpty else { return items }
    return items.filter { item in
      item.name.lowercased().contains(needle) || item.keywords.contains { $0.hasPrefix(needle) }
    }
  }

  /// Links the doc chosen (or a new one) in place of `[[query`. A doc made here is part of the
  /// undo step, so undo takes it away again.
  func chooseLink(_ choice: LinkChoice) {
    guard let query = linkQuery else { return }
    closeLinkQuery()
    perform {
      let target: (id: Doc.ID, title: String)
      switch choice {
      case .doc(let doc): target = (doc.id, doc.title)
      case .create(let name):
        let id = withErrorReporting { try store.addDoc(folderID: doc?.folderID, title: name, blocks: []) }
        guard let id else { return }
        openStep?.createdDocs.append(id)
        target = (id, name)
      }
      linkedTitles[target.id] = target.title
      requestedTitles.insert(target.id)
      linkInserter?(query, target.id, target.title)
    }
  }

  func chooseSlash(_ item: InsertItem) {
    guard let query = slashQuery else { return }
    slashQuery = nil
    slashRemover?(query)
    insert(item.insertion)
  }

  /// Opens a doc a link points at.
  func openLink(_ url: URL) -> Bool {
    guard let id = DocLink.docID(url) else { return false }
    onAction(.openDoc(id))
    return true
  }

  func openDoc(_ id: Doc.ID) {
    onAction(.openDoc(id))
  }

  /// A block's text as shown: doc links carry their target's current title.
  func displayText(_ block: DocBlock) -> String {
    DocLink.retitle(block.text, titles: linkedTitles) { DocLink.markdown(title: $0, id: $1) }
  }

  /// Looks up the linked docs' titles when the set of links changes. A newer lookup replaces an
  /// older one still running.
  private func refreshLinkedTitles(force: Bool = false) {
    let ids = Set(blocks.flatMap { DocLink.docIDs(in: $0.text) })
    guard force || ids != requestedTitles else { return }
    requestedTitles = ids
    titleLookup?.cancel()
    guard !ids.isEmpty else {
      if !linkedTitles.isEmpty { linkedTitles = [:] }
      return
    }
    titleLookup = Task { [weak self, database] in
      let docs = (try? await database.read { db in try Doc.where { $0.id.in(Array(ids)) }.fetchAll(db) }) ?? []
      guard !Task.isCancelled, let self else { return }
      let titles = Dictionary(docs.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
      if titles != self.linkedTitles { self.linkedTitles = titles }
    }
  }

  /// Linked docs renamed elsewhere show their new titles.
  func refreshLinks() {
    refreshLinkedTitles(force: true)
  }

  // MARK: Undo

  private struct StepStart {
    let blocks: [DocBlock.ID: DocBlock]
    let title: String
    let coalescing: String?
    /// The cursor before the step, for undo to return to.
    var caret: Caret?
    /// What the step's deletes took with them, kept so undo can put it back.
    var removed = DocSnapshot()
    /// Docs the step made (a `[[` link to a new doc), which undo deletes.
    var createdDocs: [Doc.ID] = []
    /// Set when the step inserted or moved blocks, which can renumber every place in the doc.
    var placesChanged = false
  }

  private struct Change {
    var before: DocBlock?
    var after: DocBlock?
  }

  struct Caret {
    let blockID: DocBlock.ID
    let offset: Int?
  }

  private struct UndoStep {
    /// Only the blocks this step changed; undo and redo leave every other block alone, so edits
    /// synced in from another device in the meantime stay.
    var changes: [DocBlock.ID: Change]
    var caretBefore: Caret?
    var titleBefore: String
    var titleAfter: String
    /// Rows to put back when going to `before`; refilled each time the step is redone.
    var restoreForUndo: DocSnapshot
    /// Rows to put back when going to `after`; filled when the step is undone.
    var restoreForRedo = DocSnapshot()
    var createdDocs: [Doc.ID]
    var createdSnapshot = DocSnapshot()
    var coalescing: String?
    var at: Date
  }

  /// Runs an edit as one undo step. Edits made inside another edit join its step; typing in one
  /// block, or in the title, keeps adding to the last step until something else happens.
  @discardableResult
  private func perform<T>(coalescing key: String? = nil, _ edit: () -> T) -> T {
    guard openStep == nil else { return edit() }
    let start = beginStep(coalescing: key)
    let result = edit()
    endStep(start)
    return result
  }

  private func beginStep(coalescing key: String? = nil) -> StepStart {
    // Anything but more typing in the same block writes what was typed first.
    let typingIn = key.flatMap { $0.hasPrefix("text ") ? UUID(uuidString: String($0.dropFirst(5))) : nil }
    if unsaved.keys.contains(where: { $0 != typingIn }) { flushTyping() }
    let start = StepStart(
      blocks: Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }), title: title, coalescing: key,
      caret: editStart ?? focusedBlockID.map { Caret(blockID: $0, offset: caretOffset) }
    )
    editStart = nil
    openStep = start
    return start
  }

  private func endStep(_ start: StepStart) {
    let open = openStep ?? start
    openStep = nil
    // Edits are written as they are made, so the blocks here are as stored, except for places
    // after an insert or move, which may have renumbered the doc; only then is it read back.
    let stored =
      open.placesChanged ? withErrorReporting { try database.read { try Mutations.docBlocks($0, docID: docID) } } ?? blocks : blocks
    let current = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var changes: [DocBlock.ID: Change] = [:]
    for id in Set(start.blocks.keys).union(current.keys) where start.blocks[id] != current[id] {
      changes[id] = Change(before: start.blocks[id], after: current[id])
    }
    guard !changes.isEmpty || title != start.title || !open.createdDocs.isEmpty else { return }
    if let key = start.coalescing, var last = undoStack.last, last.coalescing == key, now.timeIntervalSince(last.at) < 2 {
      for (id, change) in changes {
        last.changes[id] = Change(before: last.changes[id].map(\.before) ?? change.before, after: change.after)
      }
      last.titleAfter = title
      last.restoreForUndo.merge(open.removed)
      last.at = now
      undoStack[undoStack.count - 1] = last
    } else {
      undoStack.append(
        UndoStep(
          changes: changes, caretBefore: start.caret, titleBefore: start.title, titleAfter: title, restoreForUndo: open.removed,
          createdDocs: open.createdDocs, coalescing: start.coalescing, at: now
        )
      )
      if undoStack.count > 100 { undoStack.removeFirst() }
    }
    redoStack.removeAll()
    updateUndoState()
  }

  func undo() {
    flushTyping()
    guard var step = undoStack.popLast() else { return }
    step.restoreForRedo = apply(
      step.changes.mapValues(\.before), title: step.titleBefore, restoring: step.restoreForUndo, caret: step.caretBefore
    )
    if !step.createdDocs.isEmpty {
      withErrorReporting {
        step.createdSnapshot = try snapshot(docs: step.createdDocs)
        for id in step.createdDocs { try store.deleteDoc(id) }
      }
    }
    // Typing after an undo starts a new step.
    step.coalescing = nil
    redoStack.append(step)
    updateUndoState()
  }

  func redo() {
    flushTyping()
    guard var step = redoStack.popLast() else { return }
    if !step.createdSnapshot.docs.isEmpty { withErrorReporting { try store.restore(step.createdSnapshot) } }
    step.restoreForUndo = apply(step.changes.mapValues(\.after), title: step.titleAfter, restoring: step.restoreForRedo)
    undoStack.append(step)
    updateUndoState()
  }

  private func snapshot(docs ids: [Doc.ID]) throws -> DocSnapshot {
    try database.read { db in
      var snapshot = DocSnapshot()
      snapshot.docs = try Doc.where { $0.id.in(ids) }.fetchAll(db)
      snapshot.blocks = try DocBlock.where { $0.docID.in(ids) }.fetchAll(db)
      return snapshot
    }
  }

  private func updateUndoState() {
    canUndo = !undoStack.isEmpty
    canRedo = !redoStack.isEmpty
  }

  /// Puts the step's blocks into the given states (nil: deleted), returning what the deletes
  /// took with them; `snapshot` brings back what earlier deletes took.
  private func apply(
    _ states: [DocBlock.ID: DocBlock?], title targetTitle: String, restoring snapshot: DocSnapshot, caret: Caret? = nil
  ) -> DocSnapshot {
    let gone = states.compactMap { id, state in state == nil && block(id) != nil ? id : nil }
    let written = states.values.compactMap { $0 }
    var removed = DocSnapshot()
    withErrorReporting {
      if !gone.isEmpty {
        removed = try store.snapshot(blockIDs: gone)
        try store.deleteBlocks(gone)
      }
      if !snapshot.blocks.isEmpty || !snapshot.docs.isEmpty { try store.restore(snapshot) }
      if !written.isEmpty { try store.restoreBlocks(written) }
      if targetTitle != title { try store.renameDoc(docID, title: targetTitle) }
    }
    for id in gone { pending[id] = Pending(block: nil, since: now) }
    blocks.removeAll { gone.contains($0.id) }
    for block in written { keep(block) }
    title = targetTitle
    merge()
    closeLinkQuery()
    slashQuery = nil
    if let caret, block(caret.blockID) != nil {
      requestFocus(caret.blockID, at: caret.offset)
    } else if let first = written.sorted(by: { $0.position < $1.position }).first(where: \.kind.isEditable) {
      requestFocus(first.id)
    }
    return removed
  }

  // MARK: Pages, tables, files, links

  /// A link block's preview, if one has been fetched for the link it now holds.
  func linkPreview(_ id: DocBlock.ID) -> DocLinkPreview? {
    guard let block = block(id), let preview = previews.first(where: { $0.blockID == id }), preview.url == block.text
    else { return nil }
    return preview
  }

  /// Fetches a link block's preview unless it already has one for its link (or `force`).
  /// Failures are kept as a bare preview, so a dead link is not fetched again on every open.
  func loadPreview(_ id: DocBlock.ID, force: Bool = false) async {
    guard let block = block(id), block.kind == .link, !fetchingPreviews.contains(id),
      force || linkPreview(id) == nil,
      let url = URL(string: block.text), url.scheme == "http" || url.scheme == "https"
    else { return }
    fetchingPreviews.insert(id)
    defer { fetchingPreviews.remove(id) }
    let metadata = (try? await linkPreviewer.preview(for: url)) ?? LinkMetadata(title: url.absoluteString, siteName: url.host() ?? "")
    // A fetch cut short (the doc closed) is not a dead link; the link may also have changed
    // while the page loaded.
    guard !Task.isCancelled, self.block(id)?.text == block.text else { return }
    withErrorReporting {
      try store.saveLinkPreview(DocLinkPreview(blockID: id, url: block.text, metadata: metadata, fetchedAt: now))
    }
  }

  /// Turns an empty line into a link card for `url`.
  func makeLink(_ id: DocBlock.ID, url: String) {
    edit([id]) { block in
      block.kind = .link
      block.text = url
    }
    if let after = blocks.firstIndex(where: { $0.id == id }).flatMap({ blocks[safe: $0 + 1] }), after.kind == .text {
      requestFocus(after.id)
    } else {
      perform { if let line = insertBlocks([DocBlock(docID: docID)], after: id).first { requestFocus(line.id) } }
    }
  }

  /// Reads an image, scales it to a cover's size off the main thread, and sets it as the cover.
  func setCover(from url: URL) async {
    let docID = docID
    await withErrorReporting {
      let file = try await DocFileReader.read(url)
      let image = await Task.detached { NativeLinkPreviewer.thumbnail(file.data, maxPixels: 2_000) }.value
      guard let image else { throw DocsStoreError.notAnImage(file.name) }
      try await store.setCover(docID, image: image)
    }
  }

  func removeCover() async {
    let docID = docID
    await withErrorReporting { try await store.setCover(docID, image: nil) }
  }

  /// Changes a link block's address.
  func setLink(_ id: DocBlock.ID, _ url: String) {
    let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
    edit([id]) { $0.text = url }
  }

  /// Opens the doc inside a page or card block.
  func open(_ id: DocBlock.ID) {
    withErrorReporting {
      if let pageID = try store.docInside(id) { onAction(.openDoc(pageID)) }
    }
  }

  func goBack() {
    onAction(.back)
  }

  /// The title of the doc inside a page or card block.
  func pageTitle(_ id: DocBlock.ID) -> String {
    let title = pages.first { $0.parentBlockID == id }?.title ?? block(id)?.text ?? ""
    return title.isEmpty ? "Untitled" : title
  }

  func table(_ id: DocBlock.ID) -> DocTable {
    DocTable(json: block(id)?.text ?? "")
  }

  func setCell(_ id: DocBlock.ID, row: Int, column: Int, _ text: String) {
    editTable(id, coalescing: "cell \(id) \(row) \(column)") { table in
      guard table.rows.indices.contains(row), table.rows[row].indices.contains(column) else { return }
      table.rows[row][column] = text
    }
  }

  func addRow(_ id: DocBlock.ID) {
    editTable(id) { $0.rows.append(Array(repeating: "", count: $0.columnCount)) }
  }

  func addColumn(_ id: DocBlock.ID) {
    editTable(id) { table in table.rows = table.rows.map { $0 + [""] } }
  }

  func removeRow(_ id: DocBlock.ID, _ row: Int) {
    editTable(id) { table in
      if table.rows.count > 1, table.rows.indices.contains(row) { table.rows.remove(at: row) }
    }
  }

  func removeColumn(_ id: DocBlock.ID, _ column: Int) {
    editTable(id) { table in
      guard table.columnCount > 1, column < table.columnCount else { return }
      table.rows = table.rows.map { row in
        var row = row
        row.remove(at: column)
        return row
      }
    }
  }

  /// Writes a file block's contents to a temporary file and shows it in Quick Look.
  func preview(_ id: DocBlock.ID) {
    withErrorReporting {
      guard let file = try database.read({ try DocFile.find(id).fetchOne($0) }) else { return }
      let directory = FileManager.default.temporaryDirectory.appending(path: id.uuidString, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let url = directory.appending(path: file.name.isEmpty ? "file" : file.name)
      try file.data.write(to: url)
      previewURL = url
    }
  }

  /// An image file block's picture, scaled down off the main thread; nil for any other file.
  /// Only images load their data.
  func image(_ id: DocBlock.ID) async -> Image? {
    let data = await withErrorReporting {
      try await database.read { db -> Data? in
        guard let type = try DocFile.find(id).select(\.contentType).fetchOne(db),
          UTType(type)?.conforms(to: .image) == true
        else { return nil }
        return try DocFile.find(id).select(\.data).fetchOne(db)
      }
    }
    guard let data = data ?? nil else { return nil }
    let thumbnail = await Task.detached { NativeLinkPreviewer.thumbnail(data, maxPixels: 1600) }.value
    return thumbnail.flatMap(PlatformImage.make)
  }

  // MARK: Reading

  /// The blocks on screen: everything but what sits folded under a closed toggle.
  var visibleBlocks: [DocBlock] {
    var visible: [DocBlock] = []
    var foldIndent: Int?
    for block in blocks {
      if let fold = foldIndent {
        if block.indent > fold { continue }
        foldIndent = nil
      }
      visible.append(block)
      if block.kind == .toggle, block.isCollapsed { foldIndent = block.indent }
    }
    return visible
  }

  /// The doc as Markdown; links to other docs become `[[Title]]`.
  var markdown: String {
    let titles = Dictionary(
      blocks.enumerated().filter { $0.element.kind.holdsDoc }.map { ($0.offset, pageTitle($0.element.id)) },
      uniquingKeysWith: { first, _ in first }
    )
    let contents = blocks.map { block in
      var content = block.content
      content.text = DocLink.retitle(block.text, titles: linkedTitles) { title, _ in "[[\(title)]]" }
      return content
    }
    return DocMarkdown.markdown(title: title, blocks: contents, pageTitles: titles)
  }

  /// Words and characters in the doc's text, for the Info panel.
  var counts: (words: Int, characters: Int) {
    let text = blocks.filter(\.kind.isEditable).map { DocInline.plainText($0.text) }.joined(separator: "\n")
    let words = text.split { $0.isWhitespace || $0.isNewline }.count
    return (words, text.count)
  }

  // MARK: Helpers

  func block(_ id: DocBlock.ID) -> DocBlock? {
    blocks.first { $0.id == id }
  }

  private func edit(_ ids: [DocBlock.ID], coalescing key: String? = nil, _ change: (inout DocBlock) -> Void) {
    let edited = ids.compactMap(block).map { block -> DocBlock in
      var block = block
      change(&block)
      return block
    }
    guard !edited.isEmpty else { return }
    perform(coalescing: key) {
      for block in edited {
        save(block)
        if block.kind.holdsDoc { withErrorReporting { _ = try store.docInside(block.id) } }
      }
    }
  }

  private func editTable(_ id: DocBlock.ID, coalescing key: String? = nil, _ change: (inout DocTable) -> Void) {
    edit([id], coalescing: key) { block in
      var table = DocTable(json: block.text)
      change(&table)
      block.text = table.json
    }
  }

  /// Shows a block as changed here until the database reflects it.
  private func keep(_ block: DocBlock) {
    if let index = blocks.firstIndex(where: { $0.id == block.id }) {
      blocks[index] = block
    } else {
      blocks.append(block)
      blocks.sort { ($0.position, $0.id.uuidString) < ($1.position, $1.id.uuidString) }
    }
    pending[block.id] = Pending(block: block, since: now)
  }

  private func save(_ block: DocBlock) {
    keep(block)
    // This write carries any typing still waiting for the block; the later save must not undo it.
    unsaved[block.id] = nil
    withErrorReporting { try store.updateBlock(block) }
  }

  @discardableResult
  private func insertBlocks(_ templates: [DocBlock], after id: DocBlock.ID?) -> [DocBlock] {
    openStep?.placesChanged = true
    let inserted = withErrorReporting { try store.insertBlocks(docID: docID, after: id, templates: templates) } ?? []
    for block in inserted { keep(block) }
    merge()
    return inserted
  }
}

/// A block being dragged within a doc travels as text with this prefix.
enum DocBlockDrag {
  static let prefix = "bento-block:"

  static func payload(_ id: DocBlock.ID) -> String { prefix + id.uuidString }

  static func blockID(_ text: String) -> DocBlock.ID? {
    guard text.hasPrefix(prefix) else { return nil }
    return UUID(uuidString: String(text.dropFirst(prefix.count)))
  }
}

extension DocBlock {
  /// Takes another block's looks, keeping this one's identity, place and text.
  mutating func copyLooks(from other: DocBlock) {
    kind = other.kind
    isChecked = other.isChecked
    isCollapsed = other.isCollapsed
    indent = other.indent
    alignment = other.alignment
    decoration = other.decoration
    color = other.color
    font = other.font
    language = other.language
    lineWeight = other.lineWeight
  }
}

extension DocSnapshot {
  mutating func merge(_ other: DocSnapshot) {
    docs += other.docs.filter { doc in !docs.contains { $0.id == doc.id } }
    blocks += other.blocks.filter { block in !blocks.contains { $0.id == block.id } }
    files += other.files.filter { file in !files.contains { $0.id == file.id } }
    previews += other.previews.filter { preview in !previews.contains { $0.id == preview.id } }
  }
}
