import BentoData
import Foundation
import SQLiteData
import UniformTypeIdentifiers

/// Every write the UI makes to docs and their folders. Reads are sqlite-data queries in the view
/// models, as for the library.
@MainActor
public protocol DocsStoring {
  func addFolder(name: String, parentID: DocFolder.ID?) throws -> DocFolder.ID
  func renameFolder(_ id: DocFolder.ID, name: String) throws
  func deleteFolder(_ id: DocFolder.ID) throws
  func addDoc(folderID: DocFolder.ID?, title: String, blocks: [DocContent]) throws -> Doc.ID
  /// Today's note in the Daily Notes folder, made if there is none yet.
  func dailyNote() throws -> (folderID: DocFolder.ID?, docID: Doc.ID)
  /// Sets or (with nil) removes a doc's cover image.
  func setCover(_ docID: Doc.ID, image: Data?) async throws
  func renameDoc(_ id: Doc.ID, title: String) throws
  func moveDoc(_ id: Doc.ID, folderID: DocFolder.ID?) throws
  func setStarred(_ id: Doc.ID, _ starred: Bool) throws
  func deleteDoc(_ id: Doc.ID) throws
  func insertBlocks(docID: Doc.ID, after: DocBlock.ID?, _ contents: [DocContent]) throws -> [DocBlock]
  func updateBlock(_ block: DocBlock) throws
  /// Inserts copies of `templates`, looks included, with new ids.
  func insertBlocks(docID: Doc.ID, after: DocBlock.ID?, templates: [DocBlock]) throws -> [DocBlock]
  func deleteBlocks(_ ids: [DocBlock.ID]) throws
  func moveBlock(_ id: DocBlock.ID, after: DocBlock.ID?) throws
  /// Moves blocks, in order, after `after`; returns them in their new places.
  func moveBlocks(_ ids: [DocBlock.ID], after: DocBlock.ID?) throws -> [DocBlock]
  /// What deleting these blocks would take with it, for undo.
  func snapshot(blockIDs: [DocBlock.ID]) throws -> DocSnapshot
  func restore(_ snapshot: DocSnapshot) throws
  /// Writes blocks back exactly as given, place included.
  func restoreBlocks(_ blocks: [DocBlock]) throws
  /// Adds a page or card block with a new doc inside it.
  func insertPage(docID: Doc.ID, after: DocBlock.ID?, kind: DocBlock.Kind) throws -> (block: DocBlock, pageID: Doc.ID)
  /// The doc a page or card block holds, made if it has none yet.
  func docInside(_ blockID: DocBlock.ID) throws -> Doc.ID?
  func saveLinkPreview(_ preview: DocLinkPreview) throws
  /// Attaches a file as a `.file` block after `after`.
  func insertFile(docID: Doc.ID, after: DocBlock.ID?, file: DocFileData) async throws -> DocBlock
  /// A new doc from a file: Markdown and plain text become blocks; anything else is attached.
  func importFile(_ url: URL, folderID: DocFolder.ID?) async throws -> Doc.ID
}

public enum DocsStoreError: LocalizedError {
  case fileTooLarge(String)
  case notAnImage(String)

  public var errorDescription: String? {
    switch self {
    case .fileTooLarge(let name): "\(name) is larger than 100 MB, more than iCloud keeps for one file."
    case .notAnImage(let name): "\(name) is not an image Bento can show."
    }
  }
}

public struct NativeDocsStore: DocsStoring {
  private let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  public func addFolder(name: String, parentID: DocFolder.ID?) throws -> DocFolder.ID {
    try database.write { try Mutations.addDocFolder($0, name: name, parentID: parentID) }
  }

  public func renameFolder(_ id: DocFolder.ID, name: String) throws {
    try database.write { try Mutations.renameDocFolder($0, id: id, name: name) }
  }

  public func deleteFolder(_ id: DocFolder.ID) throws {
    try database.write { try Mutations.deleteDocFolder($0, id: id) }
  }

  public func addDoc(folderID: DocFolder.ID?, title: String, blocks: [DocContent]) throws -> Doc.ID {
    try database.write { try Mutations.addDoc($0, folderID: folderID, title: title, blocks: blocks) }
  }

  public func dailyNote() throws -> (folderID: DocFolder.ID?, docID: Doc.ID) {
    let title = Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day().year())
    return try database.write { try Mutations.dailyNote($0, title: title) }
  }

  public func setCover(_ docID: Doc.ID, image: Data?) async throws {
    try await database.write { try Mutations.setDocCover($0, docID: docID, image: image) }
  }

  public func renameDoc(_ id: Doc.ID, title: String) throws {
    try database.write { try Mutations.renameDoc($0, id: id, title: title) }
  }

  public func moveDoc(_ id: Doc.ID, folderID: DocFolder.ID?) throws {
    try database.write { try Mutations.moveDoc($0, id: id, folderID: folderID) }
  }

  public func setStarred(_ id: Doc.ID, _ starred: Bool) throws {
    try database.write { try Mutations.setDocStarred($0, id: id, starred) }
  }

  public func deleteDoc(_ id: Doc.ID) throws {
    try database.write { try Mutations.deleteDoc($0, id: id) }
  }

  public func insertBlocks(docID: Doc.ID, after: DocBlock.ID?, _ contents: [DocContent]) throws -> [DocBlock] {
    try database.write { try Mutations.insertDocBlocks($0, docID: docID, after: after, contents) }
  }

  public func insertBlocks(docID: Doc.ID, after: DocBlock.ID?, templates: [DocBlock]) throws -> [DocBlock] {
    try database.write { try Mutations.insertDocBlocks($0, docID: docID, after: after, templates: templates) }
  }

  public func updateBlock(_ block: DocBlock) throws {
    try database.write { try Mutations.updateDocBlock($0, block) }
  }

  public func deleteBlocks(_ ids: [DocBlock.ID]) throws {
    try database.write { try Mutations.deleteDocBlocks($0, ids: ids) }
  }

  public func moveBlock(_ id: DocBlock.ID, after: DocBlock.ID?) throws {
    try database.write { try Mutations.moveDocBlock($0, id: id, after: after) }
  }

  public func moveBlocks(_ ids: [DocBlock.ID], after: DocBlock.ID?) throws -> [DocBlock] {
    try database.write { try Mutations.moveDocBlocks($0, ids: ids, after: after) }
  }

  public func snapshot(blockIDs: [DocBlock.ID]) throws -> DocSnapshot {
    try database.read { try Mutations.docSnapshot($0, blockIDs: blockIDs) }
  }

  public func restore(_ snapshot: DocSnapshot) throws {
    try database.write { try Mutations.restore($0, snapshot) }
  }

  public func restoreBlocks(_ blocks: [DocBlock]) throws {
    try database.write { try Mutations.restoreDocBlocks($0, blocks) }
  }

  public func insertPage(docID: Doc.ID, after: DocBlock.ID?, kind: DocBlock.Kind) throws -> (block: DocBlock, pageID: Doc.ID) {
    try database.write { try Mutations.insertDocPage($0, docID: docID, after: after, kind: kind) }
  }

  public func docInside(_ blockID: DocBlock.ID) throws -> Doc.ID? {
    try database.write { try Mutations.docInside($0, blockID: blockID) }
  }

  public func saveLinkPreview(_ preview: DocLinkPreview) throws {
    try database.write { try Mutations.saveLinkPreview($0, preview) }
  }

  // Files of up to 100 MB are read and written off the main thread.

  public func insertFile(docID: Doc.ID, after: DocBlock.ID?, file: DocFileData) async throws -> DocBlock {
    try await database.write {
      try Mutations.insertDocFile(
        $0, docID: docID, after: after, name: file.name, contentType: file.type.identifier, data: file.data
      )
    }
  }

  public func importFile(_ url: URL, folderID: DocFolder.ID?) async throws -> Doc.ID {
    let file = try await DocFileReader.read(url)
    let title = url.deletingPathExtension().lastPathComponent
    if file.type.conforms(to: .plainText) || ["md", "markdown"].contains(url.pathExtension.lowercased()),
      let text = String(data: file.data, encoding: .utf8)
    {
      var blocks = DocMarkdown.blocks(from: text)
      // A leading top-level heading is the doc's title, as `DocMarkdown.markdown` writes it.
      let heading = blocks.first.flatMap { $0.kind == .title ? $0.text : nil }
      if heading != nil { blocks.removeFirst() }
      return try addDoc(folderID: folderID, title: heading ?? title, blocks: blocks)
    }
    return try await database.write { db in
      let docID = try Mutations.addDoc(db, folderID: folderID, title: title, blocks: [DocContent(kind: .file, text: file.name)])
      let blockID = try Mutations.docBlocks(db, docID: docID)[0].id
      try DocFile.insert {
        DocFile(blockID: blockID, name: file.name, contentType: file.type.identifier, data: file.data)
      }
      .execute(db)
      return docID
    }
  }

}

/// A file read for attaching: its name, type and contents.
public struct DocFileData: Sendable {
  public let name: String
  public let type: UTType
  public let data: Data
}

/// Reads files of up to 100 MB off the main thread.
enum DocFileReader {
  static let maxFileSize = 100_000_000

  static func read(_ url: URL) async throws -> DocFileData {
    try await Task.detached { try readNow(url) }.value
  }

  private nonisolated static func readNow(_ url: URL) throws -> DocFileData {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
    guard (values.fileSize ?? 0) <= maxFileSize else { throw DocsStoreError.fileTooLarge(url.lastPathComponent) }
    let type = values.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
    return DocFileData(name: url.lastPathComponent, type: type, data: try Data(contentsOf: url))
  }
}
