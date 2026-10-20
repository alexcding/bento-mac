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
  func addDoc(folderID: DocFolder.ID?, title: String, body: String) throws -> Doc.ID
  /// Sets or (with nil) removes a doc's cover image.
  func setCover(_ docID: Doc.ID, image: Data?) async throws
  func renameDoc(_ id: Doc.ID, title: String) throws
  /// Saves a doc's Markdown.
  func setBody(_ id: Doc.ID, body: String) throws
  /// Keeps an image or file with a doc, off the main thread; its Markdown links to the asset.
  func addAsset(docID: Doc.ID, file: DocFileData) async throws -> DocAsset.ID
  /// Deletes the images and files kept with a doc that no doc links to any more.
  func removeUnusedAssets(docID: Doc.ID) async throws
  func moveDoc(_ id: Doc.ID, folderID: DocFolder.ID?) throws
  func setStarred(_ id: Doc.ID, _ starred: Bool) throws
  func deleteDoc(_ id: Doc.ID) throws
  /// Keeps the web images of a saved article with its doc (as JPEG XL where that loses nothing);
  /// one that cannot be fetched is shown from where it is.
  func fetchImages(docID: Doc.ID) async
  /// A new doc from a file: Markdown and plain text become its text; anything else is kept with
  /// it and linked.
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

  public func addDoc(folderID: DocFolder.ID?, title: String, body: String) throws -> Doc.ID {
    try database.write { try Mutations.addDoc($0, folderID: folderID, title: title, body: body) }
  }

  public func setCover(_ docID: Doc.ID, image: Data?) async throws {
    try await database.write { try Mutations.setDocCover($0, docID: docID, image: image) }
  }

  public func renameDoc(_ id: Doc.ID, title: String) throws {
    try database.write { try Mutations.renameDoc($0, id: id, title: title) }
  }

  public func setBody(_ id: Doc.ID, body: String) throws {
    try database.write { try Mutations.setDocBody($0, id: id, body: body) }
  }

  public func addAsset(docID: Doc.ID, file: DocFileData) async throws -> DocAsset.ID {
    try await database.write {
      try Mutations.addDocAsset($0, docID: docID, name: file.name, contentType: file.type.identifier, data: file.data)
    }
  }

  public func removeUnusedAssets(docID: Doc.ID) async throws {
    // Ten minutes covers a picture still being read and stored, or another device's edit that
    // links it arriving after the picture itself. The newer unused ones left are looked at again
    // once they are that old, while the app runs; nothing else is touched then.
    let cutoff = Date.now.addingTimeInterval(-600)
    let result = try await database.write { try Mutations.removeUnusedDocAssets($0, docID: docID, madeBefore: cutoff) }
    guard !result.newer.isEmpty else { return }
    let (database, newer) = (database, result.newer)
    Task.detached {
      try? await Task.sleep(for: .seconds(600))
      _ = try? await database.write { try Mutations.removeUnusedDocAssets($0, ids: newer) }
    }
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

  // Files of up to 100 MB are read and written off the main thread.
  public func fetchImages(docID: Doc.ID) async {
    let body = (try? await database.read { try Doc.find(docID).select(\.body).fetchOne($0) }) ?? nil
    let addresses = Array(DocMarkdown.webImageURLs(body ?? "").prefix(DocImageDownloader.maxImages))
    // A few at a time: quicker than one by one, without opening thirty connections at once.
    await withTaskGroup(of: Void.self) { group in
      var next = addresses.makeIterator()
      func add() -> Bool {
        guard let address = next.next() else { return false }
        group.addTask { await fetchImage(docID: docID, address: address) }
        return true
      }
      for _ in 0..<4 where add() {}
      for await _ in group { _ = add() }
    }
  }

  private nonisolated func fetchImage(docID: Doc.ID, address: String) async {
    let key = "\(docID) \(address)"
    guard DocImageDownloader.start(key) else { return }
    defer { DocImageDownloader.finish(key) }
    guard let file = try? await DocImageDownloader.download(address) else { return }
    _ = try? await database.write {
      try Mutations.attachWebImage(
        $0, docID: docID, address: address, name: file.name, contentType: file.type.identifier, data: file.data
      )
    }
  }


  public func importFile(_ url: URL, folderID: DocFolder.ID?) async throws -> Doc.ID {
    let file = try await DocFileReader.read(url)
    let title = url.deletingPathExtension().lastPathComponent
    if file.type.conforms(to: .plainText) || ["md", "markdown"].contains(url.pathExtension.lowercased()),
      let text = String(data: file.data, encoding: .utf8)
    {
      // A leading top-level heading is the doc's title, as an exported doc writes it.
      var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
      var heading: String?
      if let first = lines.first, first.hasPrefix("# ") {
        heading = String(first.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
      }
      let body = lines.joined(separator: "\n").trimmingCharacters(in: .newlines)
      return try addDoc(folderID: folderID, title: heading ?? title, body: body)
    }
    return try await database.write { db in
      let docID = try Mutations.addDoc(db, folderID: folderID, title: title)
      let id = try Mutations.addDocAsset(db, docID: docID, name: file.name, contentType: file.type.identifier, data: file.data)
      try Mutations.setDocBody(db, id: docID, body: DocAsset.markdown(id: id, name: file.name, isImage: file.type.conforms(to: .image)))
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

/// Reads files of up to 100 MB off the main thread. A file added as an image is stored as JPEG XL
/// where that loses nothing (`DocImageEncoder`); any other file is kept byte for byte.
enum DocFileReader {
  static let maxFileSize = 100_000_000

  static func read(_ url: URL, asImage: Bool = false) async throws -> DocFileData {
    try await Task.detached {
      let file = try readNow(url)
      return asImage ? DocImageEncoder.encode(file) : file
    }.value
  }

  /// A cover: the image at most `maxPixelSize` on its long side, as it is shown as a banner.
  static func readCover(_ url: URL, maxPixelSize: Int = 2000) async throws -> DocFileData {
    try await Task.detached {
      let file = try readNow(url)
      guard let cover = DocImageEncoder.encodeScaled(file, maxPixelSize: maxPixelSize) else {
        throw DocsStoreError.notAnImage(file.name)
      }
      return cover
    }.value
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
