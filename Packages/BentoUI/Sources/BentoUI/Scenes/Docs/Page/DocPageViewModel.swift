import BentoData
import Dependencies
import Foundation
import ImageIO
import Observation
import SQLiteData
import SwiftUI
import UniformTypeIdentifiers

/// One doc: its title, cover and Markdown body, read rendered or edited as Markdown beside a live
/// preview. A new, empty doc opens for editing. Typing is saved after a short pause and when the
/// doc closes.
@MainActor
@Observable
public final class DocPageViewModel: Identifiable {
  public enum Action: Equatable {
    /// Go to a doc a link points at.
    case openDoc(Doc.ID)
  }

  enum ImportKind: Identifiable {
    case image, file, cover
    var id: Self { self }
    var types: [UTType] { self == .file ? [.item] : [.image] }
  }

  /// The `/` or `[[` menu open at the cursor.
  struct Menu: Equatable {
    var trigger: MarkdownEditing.MenuTrigger
    /// The caret, in the editor's visible area, to show the menu under.
    var caret: CGRect
    var selected = 0
  }

  /// A row of an open menu: something to insert, or a doc to link.
  enum MenuItem: Identifiable, Equatable {
    case insert(MarkdownInsert)
    case doc(Doc)

    var id: String {
      switch self {
      case .insert(let item): "insert-\(item.id)"
      case .doc(let doc): "doc-\(doc.id)"
      }
    }
  }

  public let docID: Doc.ID
  public nonisolated var id: Doc.ID { docID }
  @ObservationIgnored public var onAction: (Action) -> Void = { _ in }

  @ObservationIgnored @FetchOne var doc: Doc?
  @ObservationIgnored @FetchOne var cover: DocCover?
  /// Docs to link to, by title: every doc but this one, most recently edited first.
  @ObservationIgnored @FetchAll var otherDocs: [DocTitle]

  var title = ""
  var body = ""
  var isEditing = false
  var importing: ImportKind?
  var menu: Menu?
  /// Whether the Markdown editor has the keyboard focus: the ribbon writes into it only then, so a
  /// click in the preview never sends an insert to a cursor out of sight.
  private(set) var editorFocused = false
  /// Set once the first load is done, so the view shows nothing for that moment rather than its
  /// empty state flashing up before the content.
  private(set) var hasLoaded = false
  /// The cover, decoded once per image rather than on every redraw.
  private(set) var coverImage: CGImage?
  /// The body the preview shows: the text a moment after typing pauses, its doc links under their
  /// docs' current titles.
  private(set) var preview = ""

  @ObservationIgnored let editor = MarkdownEditorController()
  @ObservationIgnored private let store: any DocsStoring
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  @ObservationIgnored private var previewTask: Task<Void, Never>?
  @ObservationIgnored private var unsaved = false
  /// Whether the text was changed here since the last clean-up of unused images and files: only
  /// an edit can unlink one, and reading a doc must never delete what another device just added.
  @ObservationIgnored private var editedSinceCleanup = false
  @ObservationIgnored private var decodedCover: Data?

  init(docID: Doc.ID, store: any DocsStoring) {
    self.docID = docID
    self.store = store
    editor.onMenu = { [weak self] trigger, caret in self?.menuChanged(trigger, caret: caret) }
    editor.onMenuKey = { [weak self] key in self?.menuKey(key) ?? false }
    editor.onFiles = { [weak self] urls in Task { await self?.attach(urls) } }
    editor.onFocus = { [weak self] focused in self?.editorFocused = focused }
    showFirstFrame()
  }

  /// The doc's title and text, read at once (one row, well under a millisecond), so the page's
  /// first frame shows them rather than a blank column; `load` then watches it for changes.
  private func showFirstFrame() {
    @Dependency(\.defaultDatabase) var database
    let found = try? database.read { db in
      (try Doc.find(docID).fetchOne(db), try DocCover.where { $0.docID.eq(docID) }.fetchCount(db) > 0)
    }
    guard let (doc, hasCover) = found, let doc else { return }
    title = doc.title
    body = doc.body
    preview = body
    coverPending = hasCover
    if title.isEmpty, body.isEmpty { isEditing = true }
    shownFirst = true
  }

  /// Whether the first frame was filled from a quick read, before `load`.
  @ObservationIgnored private var shownFirst = false
  /// Whether the doc has a cover still being decoded: its space is kept so the text does not jump.
  private(set) var coverPending = false

  /// Whether there is anything to show yet: the quick first read, or the loaded doc.
  var isReady: Bool { hasLoaded || shownFirst }
  /// Whether the doc is there: once loaded, as the database says; before, as the first read found.
  var exists: Bool { hasLoaded ? doc != nil : shownFirst }

  /// The doc shows as soon as its text is in; its cover and the other docs' titles (for links)
  /// follow, filling in where they show.
  func load() async {
    _ = await withErrorReporting { try await $doc.load(Doc.find(docID)) }
    // Typing that began from the first frame (a new doc opens for editing) is kept.
    if !unsaved {
      title = doc?.title ?? ""
      body = doc?.body ?? ""
      refreshPreview(now: true)
    }
    if title.isEmpty, body.isEmpty { isEditing = true }
    hasLoaded = true
    _ = await withErrorReporting {
      try await $cover.load(DocCover.find(docID))
      try await $otherDocs.load(
        Doc.where { $0.id.neq(docID) }.order { $0.updatedAt.desc() }.select { DocTitle.Columns(id: $0.id, title: $0.title) }
      )
    }
    await coverChanged()
    // Links now show under their docs' current titles, and those to docs that are gone, greyed.
    linkedDocsLoaded = true
    refreshPreview(now: true)
  }

  /// Whether the other docs' titles are in, before which every link counts as one to a doc that
  /// is here, rather than showing greyed for a moment.
  private(set) var linkedDocsLoaded = false

  /// Takes in a change from elsewhere (another device, say) while it is not being typed in here.
  func storedDocChanged() {
    guard let doc, !unsaved else { return }
    if !isEditing || title.isEmpty { title = doc.title }
    if !isEditing, body != doc.body {
      body = doc.body
      refreshPreview(now: true)
    }
  }

  func toggleEditing() {
    if isEditing {
      flush()
      removeUnusedAssets()
      menu = nil
      editorFocused = false
      isEditing = false
      // What another device saved while this one was editing shows now.
      storedDocChanged()
    } else {
      isEditing = true
    }
  }

  func coverChanged() async {
    let data = cover?.image
    guard data != decodedCover else { return coverPending = false }
    decodedCover = data
    coverImage = await Task.detached { data.flatMap { DocImage.decode($0, maxPixelSize: 2000) } }.value
    coverPending = false
  }

  // MARK: Saving

  func edited() {
    unsaved = true
    editedSinceCleanup = true
    refreshPreview()
    saveTask?.cancel()
    saveTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(500))
      guard !Task.isCancelled else { return }
      self?.flush()
    }
  }

  /// Writes what was typed, now.
  func flush() {
    saveTask?.cancel()
    guard unsaved else { return }
    unsaved = false
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    withErrorReporting {
      if title != doc?.title { try store.renameDoc(docID, title: title) }
      if body != doc?.body { try store.setBody(docID, body: body) }
    }
  }

  func refreshPreview(now: Bool = false) {
    previewTask?.cancel()
    guard !now else {
      preview = retitled(body)
      return
    }
    previewTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(150))
      guard !Task.isCancelled, let self else { return }
      preview = retitled(body)
    }
  }

  /// Doc links shown under their doc's current title, so a rename shows everywhere it is linked.
  /// A link to a doc that is gone keeps the title it was written with.
  private func retitled(_ markdown: String) -> String {
    var titles = Dictionary(otherDocs.map { ($0.id, $0.title) }, uniquingKeysWith: { first, _ in first })
    titles[docID] = title
    return DocLink.retitle(markdown, titles: titles) { DocLink.markdown(title: $0, id: $1) }
  }

  /// Shows every link line to `url` in `style`, as the card's context menu asks.
  func setLinkStyle(_ url: String, _ style: DocEmbeds.LinkStyle) {
    let restyled = DocEmbeds.restyleLinks(body, url: url, style: style)
    guard restyled != body else { return }
    body = restyled
    edited()
    refreshPreview(now: true)
  }

  /// Whether a doc a link points at is here to open; a link to one that is gone (deleted, or not
  /// synced here yet) shows greyed out and goes nowhere.
  func docExists(_ id: Doc.ID) -> Bool {
    !linkedDocsLoaded || id == docID || otherDocs.contains { $0.id == id }
  }

  /// Once editing is over (Done, or the doc closing), images and files the text no longer links
  /// to are deleted, from iCloud too. Not on every save: an undo may still bring one back.
  func removeUnusedAssets() {
    guard editedSinceCleanup else { return }
    editedSinceCleanup = false
    let (store, docID) = (store, docID)
    Task { await withErrorReporting { try await store.removeUnusedAssets(docID: docID) } }
  }

  // MARK: Inserting

  /// Inserts from the ribbon, at the editor's cursor; nothing while the editor is not focused.
  func perform(_ item: MarkdownInsert) {
    guard isEditing, editorFocused else { return }
    switch item.action {
    case .block(let markdown, let cursor): editor.insert(markdown, block: true, cursor: cursor)
    case .inline(let markdown, let cursor): editor.insert(markdown, block: false, cursor: cursor)
    case .line(let prefix): editor.restyleLine(prefix)
    case .docLink: editor.insert("[[", block: false)
    case .image: importing = .image
    case .file: importing = .file
    }
  }

  func wrap(_ marker: String) {
    if isEditing, editorFocused { editor.wrap(marker) }
  }

  func link() {
    if isEditing, editorFocused { editor.link() }
  }

  /// Images and files kept with the doc, read off the main thread, linked where the cursor is.
  /// Pictures added as images are stored as JPEG XL where that loses nothing.
  func attach(_ urls: [URL], asImages: Bool) async {
    for url in urls {
      await withErrorReporting {
        let file = try await DocFileReader.read(url, asImage: asImages)
        let id = try await store.addAsset(docID: docID, file: file)
        let markdown = DocAsset.markdown(id: id, name: file.name, isImage: file.type.conforms(to: .image))
        if isEditing, editor.textView != nil {
          editor.insert(markdown, block: true)
        } else {
          body += (body.isEmpty || body.hasSuffix("\n") ? "" : "\n") + markdown + "\n"
          edited()
        }
      }
    }
  }

  /// Files dropped or pasted on the doc: pictures are kept as images, anything else as a file.
  func attach(_ urls: [URL]) async {
    for url in urls {
      let isImage = (try? url.resourceValues(forKeys: [.contentTypeKey]).contentType)??.conforms(to: .image) ?? false
      await attach([url], asImages: isImage)
    }
  }

  /// Links to docs dragged in from the list, each on a line of its own.
  func linkDocs(_ ids: [Doc.ID]) -> Bool {
    let docs = ids.compactMap { id in otherDocs.first { $0.id == id } }
    guard !docs.isEmpty else { return false }
    editor.insert(docs.map { DocLink.markdown(title: $0.title, id: $0.id) }.joined(separator: "\n"), block: true)
    return true
  }

  // MARK: The `/` and `[[` menus

  var menuItems: [MenuItem] {
    guard let menu else { return [] }
    let query = menu.trigger.query
    switch menu.trigger.kind {
    case .insert:
      return MarkdownInsert.all.filter { $0.matches(query) }.map(MenuItem.insert)
    case .docLink:
      return otherDocs
        .filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }
        .prefix(8)
        .map { MenuItem.doc(Doc(id: $0.id, title: $0.title)) }
    }
  }

  private func menuChanged(_ trigger: MarkdownEditing.MenuTrigger?, caret: CGRect) {
    guard let trigger else { return menu = nil }
    let selected = menu?.trigger.query == trigger.query && menu?.trigger.kind == trigger.kind ? menu?.selected ?? 0 : 0
    menu = Menu(trigger: trigger, caret: caret, selected: selected)
    // A `/` with nothing matching is just a slash.
    if trigger.kind == .insert, menuItems.isEmpty { menu = nil }
  }

  private func menuKey(_ key: MarkdownEditorController.MenuKey) -> Bool {
    guard var menu else { return false }
    let count = menuItems.count
    switch key {
    case .up: menu.selected = (menu.selected - 1 + max(count, 1)) % max(count, 1)
    case .down: menu.selected = (menu.selected + 1) % max(count, 1)
    case .dismiss:
      self.menu = nil
      return true
    case .choose:
      guard menuItems.indices.contains(menu.selected) else { return false }
      choose(menuItems[menu.selected])
      return true
    }
    self.menu = menu
    return true
  }

  /// Puts the chosen item in place of the typed `/query` or `[[query`.
  func choose(_ item: MenuItem) {
    guard let trigger = menu?.trigger else { return }
    menu = nil
    switch item {
    case .doc(let doc):
      editor.replace(trigger.range, with: DocLink.markdown(title: doc.title, id: doc.id))
    case .insert(let insert):
      editor.replace(trigger.range, with: "")
      switch insert.action {
      case .block(let markdown, let cursor):
        // At the start of a line it replaces the slash; after text it starts a new line.
        let ns = editor.text as NSString
        let atLineStart = trigger.range.location == 0 || ns.character(at: trigger.range.location - 1) == 10
        editor.replace(
          NSRange(location: trigger.range.location, length: 0), with: (atLineStart ? "" : "\n") + markdown,
          cursor: cursor + (atLineStart ? 0 : 1)
        )
      case .inline(let markdown, let cursor):
        editor.replace(NSRange(location: trigger.range.location, length: 0), with: markdown, cursor: cursor)
      case .line(let prefix): editor.restyleLine(prefix)
      case .docLink: editor.replace(NSRange(location: trigger.range.location, length: 0), with: "[[")
      case .image: importing = .image
      case .file: importing = .file
      }
    }
  }

  // MARK: The doc

  func setCover(from url: URL) async {
    let docID = docID
    await withErrorReporting {
      let file = try await DocFileReader.readCover(url)
      try await store.setCover(docID, image: file.data)
    }
  }

  func removeCover() async {
    let docID = docID
    await withErrorReporting { try await store.setCover(docID, image: nil) }
  }

  var isStarred: Bool { doc?.isStarred ?? false }

  func toggleStarred() {
    withErrorReporting { try store.setStarred(docID, !isStarred) }
  }

  func openDoc(_ id: Doc.ID) {
    guard docExists(id) else { return }
    flush()
    onAction(.openDoc(id))
  }

  /// Words in the body, for the tools panel.
  var wordCount: Int {
    body.split { $0.isWhitespace || $0.isNewline }.count
  }

  /// The doc as one Markdown file, its title as the first heading.
  var markdown: String {
    let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
    return (title.isEmpty ? "" : "# \(title)\n\n") + body + (body.hasSuffix("\n") ? "" : "\n")
  }
}

/// A doc's id and title, all a link needs; lists of them never load the docs' text.
@Selection
struct DocTitle: Identifiable, Hashable {
  let id: Doc.ID
  let title: String
}
