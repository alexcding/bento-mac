import Foundation
import SQLiteData

extension Mutations {
  @discardableResult
  public static func addDocFolder(_ db: Database, name: String, parentID: DocFolder.ID?, now: Date = .now) throws -> DocFolder.ID {
    let last = try DocFolder
      .where { $0.parentID.is(parentID) }
      .select { $0.position.max() }
      .fetchOne(db) ?? nil
    let folder = DocFolder(parentID: parentID, name: name, position: (last ?? -1) + 1, createdAt: now)
    try DocFolder.insert { folder }.execute(db)
    return folder.id
  }

  public static func renameDocFolder(_ db: Database, id: DocFolder.ID, name: String) throws {
    try DocFolder.find(id).update { $0.name = #bind(name) }.execute(db)
  }

  /// Deletes the folder, its subfolders and every doc in them.
  public static func deleteDocFolder(_ db: Database, id: DocFolder.ID) throws {
    var folderIDs: [DocFolder.ID] = []
    var queue = [id]
    while let next = queue.popLast(), !folderIDs.contains(next) {
      folderIDs.append(next)
      queue += try DocFolder.where { $0.parentID.eq(next) }.select(\.id).fetchAll(db)
    }
    let docIDs = try Doc.where { $0.folderID.in(folderIDs.map(Optional.some)) }.select(\.id).fetchAll(db)
    for docID in docIDs {
      try deleteDoc(db, id: docID)
    }
    try DocFolder.where { $0.id.in(folderIDs) }.delete().execute(db)
  }

  /// A new doc with `blocks`, or one empty text block so there is somewhere to type.
  @discardableResult
  public static func addDoc(
    _ db: Database, folderID: DocFolder.ID?, parentBlockID: DocBlock.ID? = nil, title: String,
    blocks: [DocContent] = [], now: Date = .now
  ) throws -> Doc.ID {
    let doc = Doc(folderID: folderID, parentBlockID: parentBlockID, title: title, createdAt: now, updatedAt: now)
    try Doc.insert { doc }.execute(db)
    for (index, content) in (blocks.isEmpty ? [DocContent()] : blocks).enumerated() {
      try DocBlock.insert { DocBlock(docID: doc.id, content: content, position: Double(index)) }.execute(db)
    }
    return doc.id
  }

  /// The daily note for the day `now` falls on (in `calendar`'s time zone), found by its day
  /// wherever it is and whatever it is called; else a new one titled `title` in the oldest
  /// top-level Daily Notes folder, which is made the first time. The oldest, so devices that each
  /// made one while offline end up using the same folder.
  @discardableResult
  public static func dailyNote(
    _ db: Database, title: String, now: Date = .now, calendar: Calendar = .current
  ) throws -> (folderID: DocFolder.ID?, docID: Doc.ID) {
    let day = dailyNoteDay(now, calendar: calendar)
    let existing = try Doc
      .where { $0.dailyNoteDay.eq(day) && $0.parentBlockID.is(nil) }
      .order { ($0.createdAt, $0.id) }
      .fetchOne(db)
    if let existing { return (existing.folderID, existing.id) }
    let folderID = try DocFolder
      .where { $0.parentID.is(nil) && $0.name.eq(dailyNotesFolder) }
      .order { ($0.createdAt, $0.id) }
      .select(\.id)
      .fetchOne(db)
      ?? addDocFolder(db, name: dailyNotesFolder, parentID: nil, now: now)
    let docID = try addDoc(db, folderID: folderID, title: title, blocks: [DocContent(kind: .todo)], now: now)
    try Doc.find(docID).update { $0.dailyNoteDay = #bind(day) }.execute(db)
    return (folderID, docID)
  }

  /// A day as `yyyy-MM-dd` in the Gregorian calendar, whatever the device's calendar or language.
  public static func dailyNoteDay(_ date: Date, calendar: Calendar = .current) -> String {
    var gregorian = Calendar(identifier: .gregorian)
    gregorian.timeZone = calendar.timeZone
    let parts = gregorian.dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  public static let dailyNotesFolder = "Daily Notes"

  /// Sets a doc's cover image, or removes it when `image` is nil.
  public static func setDocCover(_ db: Database, docID: Doc.ID, image: Data?, now: Date = .now) throws {
    if let image {
      try DocCover.upsert { DocCover(docID: docID, image: image) }.execute(db)
    } else {
      try DocCover.find(docID).delete().execute(db)
    }
    try touchDoc(db, id: docID, now: now)
  }

  public static func renameDoc(_ db: Database, id: Doc.ID, title: String, now: Date = .now) throws {
    try Doc.find(id).update {
      $0.title = #bind(title)
      $0.updatedAt = #bind(now)
    }
    .execute(db)
  }

  public static func moveDoc(_ db: Database, id: Doc.ID, folderID: DocFolder.ID?) throws {
    try Doc.find(id).update { $0.folderID = #bind(folderID) }.execute(db)
  }

  public static func setDocStarred(_ db: Database, id: Doc.ID, _ starred: Bool) throws {
    try Doc.find(id).update { $0.isStarred = #bind(starred) }.execute(db)
  }

  /// Deletes the doc and the pages and cards inside it.
  public static func deleteDoc(_ db: Database, id: Doc.ID) throws {
    try deleteSubdocs(db, blockIDs: try DocBlock.where { $0.docID.eq(id) }.select(\.id).fetchAll(db))
    try Doc.find(id).delete().execute(db)
  }

  /// The docs held by page or card blocks among `blockIDs`, deleted with everything inside them.
  private static func deleteSubdocs(_ db: Database, blockIDs: [DocBlock.ID]) throws {
    let docIDs = try Doc.where { $0.parentBlockID.in(blockIDs.map(Optional.some)) }.select(\.id).fetchAll(db)
    for docID in docIDs {
      try deleteDoc(db, id: docID)
    }
  }

  /// Adds a page or card block after `afterID` with a new, empty doc inside it.
  @discardableResult
  public static func insertDocPage(
    _ db: Database, docID: Doc.ID, after afterID: DocBlock.ID?, kind: DocBlock.Kind, title: String = "",
    now: Date = .now
  ) throws -> (block: DocBlock, pageID: Doc.ID) {
    let block = try insertDocBlocks(db, docID: docID, after: afterID, [DocContent(kind: kind, text: title)], now: now)[0]
    let pageID = try addDoc(db, folderID: nil, parentBlockID: block.id, title: title, now: now)
    return (block, pageID)
  }

  /// The doc a page or card block holds, made from the block's text if it has none yet: turning
  /// a line into a page keeps the line as the page's title.
  @discardableResult
  public static func docInside(_ db: Database, blockID: DocBlock.ID, now: Date = .now) throws -> Doc.ID? {
    guard let block = try DocBlock.find(blockID).fetchOne(db), block.kind.holdsDoc else { return nil }
    if let existing = try Doc.where({ $0.parentBlockID.eq(blockID) }).select(\.id).fetchOne(db) { return existing }
    return try addDoc(db, folderID: nil, parentBlockID: blockID, title: block.text, now: now)
  }

  /// Inserts `contents` in order right after `afterID`, or at the top when it is nil.
  @discardableResult
  public static func insertDocBlocks(
    _ db: Database, docID: Doc.ID, after afterID: DocBlock.ID?, _ contents: [DocContent], now: Date = .now
  ) throws -> [DocBlock] {
    guard !contents.isEmpty else { return [] }
    var (lower, upper) = try gap(db, docID: docID, after: afterID)
    if upper - lower < 1e-6 * Double(contents.count + 1) {
      try renumberDocBlocks(db, docID: docID)
      (lower, upper) = try gap(db, docID: docID, after: afterID)
    }
    let step = (upper - lower) / Double(contents.count + 1)
    let blocks = contents.enumerated().map { index, content in
      DocBlock(docID: docID, content: content, position: lower + step * Double(index + 1))
    }
    for block in blocks { try DocBlock.insert { block }.execute(db) }
    try touchDoc(db, id: docID, now: now)
    return blocks
  }

  /// Adds a `.file` block holding `data` right after `afterID`, or at the top when it is nil.
  @discardableResult
  public static func insertDocFile(
    _ db: Database, docID: Doc.ID, after afterID: DocBlock.ID?, name: String, contentType: String, data: Data,
    now: Date = .now
  ) throws -> DocBlock {
    let block = try insertDocBlocks(db, docID: docID, after: afterID, [DocContent(kind: .file, text: name)], now: now)[0]
    try DocFile.insert { DocFile(blockID: block.id, name: name, contentType: contentType, data: data) }.execute(db)
    return block
  }

  /// Keeps a link block's preview, replacing any older one.
  public static func saveLinkPreview(_ db: Database, _ preview: DocLinkPreview) throws {
    try DocLinkPreview.upsert { preview }.execute(db)
  }

  /// Inserts copies of `templates` (looks and text, with new ids) in order right after `afterID`.
  @discardableResult
  public static func insertDocBlocks(
    _ db: Database, docID: Doc.ID, after afterID: DocBlock.ID?, templates: [DocBlock], now: Date = .now
  ) throws -> [DocBlock] {
    let inserted = try insertDocBlocks(db, docID: docID, after: afterID, templates.map(\.content), now: now)
    var result: [DocBlock] = []
    for (template, block) in zip(templates, inserted) {
      var block = block
      block.isCollapsed = template.isCollapsed
      block.alignment = template.alignment
      block.color = template.color
      block.font = template.font
      block.lineWeight = template.lineWeight
      if block != inserted[result.count] { try updateDocBlock(db, block, now: now) }
      result.append(block)
    }
    return result
  }

  /// Saves a block's content and looks. Its doc and place stay as they are. A page or card
  /// block gets its doc here if it has none.
  public static func updateDocBlock(_ db: Database, _ block: DocBlock, now: Date = .now) throws {
    try DocBlock.find(block.id).update {
      $0.kind = #bind(block.kind)
      $0.text = #bind(block.text)
      $0.isChecked = #bind(block.isChecked)
      $0.isCollapsed = #bind(block.isCollapsed)
      $0.indent = #bind(block.indent)
      $0.alignment = #bind(block.alignment)
      $0.decoration = #bind(block.decoration)
      $0.color = #bind(block.color)
      $0.font = #bind(block.font)
      $0.language = #bind(block.language)
      $0.lineWeight = #bind(block.lineWeight)
    }
    .execute(db)
    if block.kind.holdsDoc { try docInside(db, blockID: block.id, now: now) }
    try touchDoc(db, id: block.docID, now: now)
  }

  public static func deleteDocBlocks(_ db: Database, ids: [DocBlock.ID], now: Date = .now) throws {
    let docIDs = Set(try DocBlock.where { $0.id.in(ids) }.select(\.docID).fetchAll(db))
    try deleteSubdocs(db, blockIDs: ids)
    try DocBlock.where { $0.id.in(ids) }.delete().execute(db)
    for docID in docIDs { try touchDoc(db, id: docID, now: now) }
  }

  /// Moves a block right after `afterID`, or to the top when it is nil.
  public static func moveDocBlock(_ db: Database, id: DocBlock.ID, after afterID: DocBlock.ID?, now: Date = .now) throws {
    try moveDocBlocks(db, ids: [id], after: afterID, now: now)
  }

  /// Moves blocks of one doc, kept in the given order, right after `afterID` (or to the top when
  /// it is nil). Returns them with their new positions.
  @discardableResult
  public static func moveDocBlocks(
    _ db: Database, ids: [DocBlock.ID], after afterID: DocBlock.ID?, now: Date = .now
  ) throws -> [DocBlock] {
    guard afterID.map({ !ids.contains($0) }) ?? true,
      let first = try DocBlock.find(ids.first ?? UUID()).fetchOne(db)
    else { return [] }
    var (lower, upper) = try gap(db, docID: first.docID, after: afterID, excluding: Set(ids))
    if upper - lower < 1e-6 * Double(ids.count + 1) {
      try renumberDocBlocks(db, docID: first.docID)
      (lower, upper) = try gap(db, docID: first.docID, after: afterID, excluding: Set(ids))
    }
    let step = (upper - lower) / Double(ids.count + 1)
    var moved: [DocBlock] = []
    for (index, id) in ids.enumerated() {
      let position = lower + step * Double(index + 1)
      try DocBlock.find(id).update { $0.position = #bind(position) }.execute(db)
      if let block = try DocBlock.find(id).fetchOne(db) { moved.append(block) }
    }
    try touchDoc(db, id: first.docID, now: now)
    return moved
  }

  /// Everything that goes when these blocks are deleted: the blocks, their files and link
  /// previews, and the docs inside page and card blocks with all of theirs, so undo can put it all
  /// back.
  public static func docSnapshot(_ db: Database, blockIDs: [DocBlock.ID]) throws -> DocSnapshot {
    var snapshot = DocSnapshot()
    var blockIDs = blockIDs
    var seenDocs: Set<Doc.ID> = []
    while !blockIDs.isEmpty {
      snapshot.blocks += try DocBlock.where { $0.id.in(blockIDs) }.fetchAll(db)
      snapshot.files += try DocFile.where { $0.blockID.in(blockIDs) }.fetchAll(db)
      snapshot.previews += try DocLinkPreview.where { $0.blockID.in(blockIDs) }.fetchAll(db)
      let docs = try Doc.where { $0.parentBlockID.in(blockIDs.map(Optional.some)) }.fetchAll(db)
        .filter { seenDocs.insert($0.id).inserted }
      snapshot.docs += docs
      let docIDs = docs.map(\.id)
      blockIDs = docIDs.isEmpty ? [] : try DocBlock.where { $0.docID.in(docIDs) }.select(\.id).fetchAll(db)
    }
    return snapshot
  }

  /// Puts back what `docSnapshot` saved, as it was.
  public static func restore(_ db: Database, _ snapshot: DocSnapshot) throws {
    for doc in snapshot.docs { try Doc.upsert { doc }.execute(db) }
    for block in snapshot.blocks { try DocBlock.upsert { block }.execute(db) }
    for file in snapshot.files { try DocFile.upsert { file }.execute(db) }
    for preview in snapshot.previews { try DocLinkPreview.upsert { preview }.execute(db) }
  }

  /// Writes blocks back exactly as given, place included; for undo.
  public static func restoreDocBlocks(_ db: Database, _ blocks: [DocBlock], now: Date = .now) throws {
    for block in blocks { try DocBlock.upsert { block }.execute(db) }
    for docID in Set(blocks.map(\.docID)) { try touchDoc(db, id: docID, now: now) }
  }

  /// The doc's blocks in order.
  public static func docBlocks(_ db: Database, docID: Doc.ID) throws -> [DocBlock] {
    try DocBlock.where { $0.docID.eq(docID) }.order { ($0.position, $0.id) }.fetchAll(db)
  }

  /// Positions on either side of the slot after `afterID`. The end of the doc is open: one past
  /// the last block.
  private static func gap(
    _ db: Database, docID: Doc.ID, after afterID: DocBlock.ID?, excluding: Set<DocBlock.ID> = []
  ) throws -> (Double, Double) {
    let blocks = try docBlocks(db, docID: docID).filter { !excluding.contains($0.id) }
    let index = afterID.flatMap { id in blocks.firstIndex { $0.id == id } }
    let lower = index.map { blocks[$0].position } ?? ((blocks.first?.position ?? 1) - 1)
    let next = index.map { $0 + 1 } ?? 0
    let upper = next < blocks.count ? blocks[next].position : lower + 1
    return (lower, upper)
  }

  /// Spreads the doc's blocks back to whole-number positions when repeated inserts at one spot
  /// have used up the room between two of them.
  private static func renumberDocBlocks(_ db: Database, docID: Doc.ID) throws {
    for (index, block) in try docBlocks(db, docID: docID).enumerated() {
      try DocBlock.find(block.id).update { $0.position = #bind(Double(index)) }.execute(db)
    }
  }

  private static func touchDoc(_ db: Database, id: Doc.ID, now: Date) throws {
    try Doc.find(id).update { $0.updatedAt = #bind(now) }.execute(db)
  }
}

extension DocBlock {
  public init(id: UUID = UUID(), docID: Doc.ID, content: DocContent, position: Double) {
    self.init(
      id: id, docID: docID, kind: content.kind, text: content.text, isChecked: content.isChecked,
      indent: content.indent, decoration: content.decoration, language: content.language, position: position
    )
  }
}
