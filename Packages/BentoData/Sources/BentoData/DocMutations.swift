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

  /// A new doc with `body` as its Markdown.
  @discardableResult
  public static func addDoc(
    _ db: Database, folderID: DocFolder.ID?, title: String, body: String = "", now: Date = .now
  ) throws -> Doc.ID {
    let doc = Doc(folderID: folderID, title: title, body: body, createdAt: now, updatedAt: now)
    try Doc.insert { doc }.execute(db)
    return doc.id
  }

  /// Sets a doc's cover image, or removes it when `image` is nil.
  public static func setDocCover(_ db: Database, docID: Doc.ID, image: Data?, now: Date = .now) throws {
    if let image {
      try DocCover.upsert { DocCover(docID: docID, image: image) }.execute(db)
    } else {
      try DocCover.find(docID).delete().execute(db)
    }
    try touchDoc(db, id: docID, now: now)
  }

  /// Saves a doc's Markdown.
  public static func setDocBody(_ db: Database, id: Doc.ID, body: String, now: Date = .now) throws {
    try Doc.find(id).update {
      $0.body = #bind(body)
      $0.updatedAt = #bind(now)
    }
    .execute(db)
  }

  /// Keeps an image or file with a doc; its Markdown links to the returned asset.
  public static func addDocAsset(
    _ db: Database, docID: Doc.ID, name: String, contentType: String, data: Data, now: Date = .now
  ) throws -> DocAsset.ID {
    let asset = DocAsset(docID: docID, name: name, contentType: contentType, data: data, createdAt: now)
    try DocAsset.insert { asset }.execute(db)
    return asset.id
  }

  /// Deletes the images and files kept with a doc that no doc's Markdown links to any more (a
  /// link copied into another doc still counts); returns how many went. Run when editing ends
  /// rather than on every save, so an undo that brings an image back finds it still there. Only
  /// assets made before `cutoff` go: a newer one may still be on its way into the text, here or
  /// on another device whose edit has not synced yet.
  /// Returns how many went, and the newer unused ones left for a later pass.
  @discardableResult
  public static func removeUnusedDocAssets(
    _ db: Database, docID: Doc.ID, madeBefore cutoff: Date
  ) throws -> (removed: Int, newer: [DocAsset.ID]) {
    let assets = try DocAsset.where { $0.docID.eq(docID) }.select { ($0.id, $0.createdAt) }.fetchAll(db)
    guard !assets.isEmpty else { return (0, []) }
    let linked = try linkedAssets(db)
    let unused = assets.filter { !linked.contains($0.0) }
    let old = unused.filter { $0.1 < cutoff }.map(\.0)
    if !old.isEmpty { try DocAsset.where { $0.id.in(old) }.delete().execute(db) }
    return (old.count, unused.filter { $0.1 >= cutoff }.map(\.0))
  }

  /// Deletes those of `ids` that no doc links to still: the later pass over the newer files a
  /// clean-up left, which touches nothing else.
  @discardableResult
  public static func removeUnusedDocAssets(_ db: Database, ids: [DocAsset.ID]) throws -> Int {
    guard !ids.isEmpty else { return 0 }
    let linked = try linkedAssets(db)
    let unused = ids.filter { !linked.contains($0) }
    if !unused.isEmpty { try DocAsset.where { $0.id.in(unused) }.delete().execute(db) }
    return unused.count
  }

  private static func linkedAssets(_ db: Database) throws -> Set<DocAsset.ID> {
    let bodies = try Doc.where { $0.body.contains(DocAsset.scheme) }.select(\.body).fetchAll(db)
    return Set(bodies.flatMap(DocAsset.ids(in:)))
  }

  /// Keeps a downloaded web image with its doc and points the doc's Markdown at it, if the doc
  /// still shows that image; returns whether it did. An edit made meanwhile is kept.
  @discardableResult
  public static func attachWebImage(
    _ db: Database, docID: Doc.ID, address: String, name: String, contentType: String, data: Data, now: Date = .now
  ) throws -> Bool {
    guard let body = try Doc.find(docID).select(\.body).fetchOne(db),
      let regex = try? NSRegularExpression(
        pattern: #"(!\[[^\]]*\]\(\s*<?)"# + NSRegularExpression.escapedPattern(for: address) + #"(?=>?(?:\s+"[^"]*")?\s*\))"#
      ),
      regex.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    else { return false }
    let id = try addDocAsset(db, docID: docID, name: name, contentType: contentType, data: data, now: now)
    // Only images whose address is exactly this one; links and longer addresses are left alone.
    let updated = regex.stringByReplacingMatches(
      in: body, range: NSRange(body.startIndex..., in: body),
      withTemplate: "$1" + NSRegularExpression.escapedTemplate(for: DocAsset.url(id).absoluteString)
    )
    try Doc.find(docID).update { $0.body = #bind(updated) }.execute(db)
    return true
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

  /// Deletes the doc, with the images and files kept with it.
  public static func deleteDoc(_ db: Database, id: Doc.ID) throws {
    try Doc.find(id).delete().execute(db)
  }

  private static func touchDoc(_ db: Database, id: Doc.ID, now: Date) throws {
    try Doc.find(id).update { $0.updatedAt = #bind(now) }.execute(db)
  }
}
