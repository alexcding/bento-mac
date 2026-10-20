import Foundation
import SQLiteData

// Docs: the user's own reading and study material, synced like the rest of the library. A doc is
// a title and Markdown; the images and files it keeps are rows of their own, so the text stays
// small to sync and search.
//
// The sync engine refuses foreign-key cycles, a table referencing itself included, so a folder's
// parent is a plain column; `Mutations` deletes what hangs off it.

/// A folder of docs; `parentID` nests it. Deleting a folder deletes what is in it.
@Table("docFolders")
public nonisolated struct DocFolder: Hashable, Identifiable, Sendable {
  public let id: UUID
  /// Not a foreign key (see above).
  public var parentID: DocFolder.ID?
  public var name = ""
  public var position = 0.0
  public var createdAt: Date

  public init(id: UUID = UUID(), parentID: DocFolder.ID? = nil, name: String, position: Double = 0, createdAt: Date = .now) {
    self.id = id
    self.parentID = parentID
    self.name = name
    self.position = position
    self.createdAt = createdAt
  }
}

/// One document: a title and its Markdown. `folderID` nil keeps it at the top level.
@Table("docs")
public nonisolated struct Doc: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var folderID: DocFolder.ID?
  public var title = ""
  /// The doc's text, as Markdown. Images and files kept with the doc are `DocAsset`s, linked as
  /// `bento-asset://<id>`; videos and posts stay links to where they are.
  public var body = ""
  public var isStarred = false
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), folderID: DocFolder.ID? = nil, title: String, body: String = "",
    isStarred: Bool = false, createdAt: Date = .now, updatedAt: Date = .now
  ) {
    self.id = id
    self.folderID = folderID
    self.title = title
    self.body = body
    self.isStarred = isStarred
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

/// A doc's cover image, shown wide above its title. Kept apart from Doc so lists of docs never
/// load the image.
@Table("docCovers")
public nonisolated struct DocCover: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let docID: Doc.ID
  public var image: Data
  public var id: Doc.ID { docID }

  public init(docID: Doc.ID, image: Data) {
    self.docID = docID
    self.image = image
  }
}

/// An image or file kept with a doc and synced with it, shown where the doc's Markdown links to
/// it: `![](bento-asset://<id>)` for an image, `[name](bento-asset://<id>)` for a file.
@Table("docAssets")
public nonisolated struct DocAsset: Hashable, Identifiable, Sendable {
  public static let scheme = "bento-asset"

  public let id: UUID
  public var docID: Doc.ID
  public var name = ""
  public var contentType = ""
  public var data: Data
  public var createdAt: Date

  public init(id: UUID = UUID(), docID: Doc.ID, name: String, contentType: String, data: Data, createdAt: Date = .now) {
    self.id = id
    self.docID = docID
    self.name = name
    self.contentType = contentType
    self.data = data
    self.createdAt = createdAt
  }

  public static func url(_ id: DocAsset.ID) -> URL {
    URL(string: "\(scheme)://\(id.uuidString)")!
  }

  /// The asset a `bento-asset` URL points at.
  public static func assetID(_ url: URL) -> DocAsset.ID? {
    guard url.scheme == scheme, let host = url.host() else { return nil }
    return UUID(uuidString: host)
  }

  /// The assets a doc's Markdown links to.
  public static func ids(in markdown: String) -> [DocAsset.ID] {
    guard let regex = try? NSRegularExpression(pattern: #"bento-asset://([0-9A-Fa-f-]{36})"#) else { return [] }
    return regex.matches(in: markdown, range: NSRange(markdown.startIndex..., in: markdown)).compactMap { match in
      Range(match.range(at: 1), in: markdown).flatMap { UUID(uuidString: String(markdown[$0])) }
    }
  }

  /// The Markdown that shows it: an image inline, anything else as a link named for the file.
  public static func markdown(id: DocAsset.ID, name: String, isImage: Bool) -> String {
    let label = DocLink.escaped(name)
    return isImage ? "![\(label)](\(url(id).absoluteString))" : "[\(label)](\(url(id).absoluteString))"
  }
}

/// Links from one doc to another, kept in block text as Markdown links with a `bento-doc` URL:
/// `[Title](bento-doc://<id>)`. The title is shown as the target's current title.
public enum DocLink {
  public static let scheme = "bento-doc"

  public static func url(_ id: Doc.ID) -> URL {
    URL(string: "\(scheme)://\(id.uuidString)")!
  }

  public static func markdown(title: String, id: Doc.ID) -> String {
    "[\(escaped(title.isEmpty ? "Untitled" : title))](\(url(id).absoluteString))"
  }

  /// Text with the characters Markdown would read as syntax escaped, to sit inside a link.
  static func escaped(_ text: String) -> String {
    var out = ""
    for character in text {
      if "\\[]*_`~".contains(character) { out.append("\\") }
      out.append(character)
    }
    return out
  }

  /// Link text as written, its escapes removed.
  static func unescaped(_ text: String) -> String {
    text.replacingOccurrences(of: #"\\([!-/:-@\[-`{-~])"#, with: "$1", options: .regularExpression)
  }

  /// The doc a `bento-doc` URL points at.
  public static func docID(_ url: URL) -> Doc.ID? {
    guard url.scheme == scheme, let host = url.host() else { return nil }
    return UUID(uuidString: host)
  }

  /// `text` with each doc link's title replaced by `titles[id]` (or its own, as plain text), as
  /// `transform` writes it.
  public static func retitle(_ text: String, titles: [Doc.ID: String], as transform: (String, Doc.ID) -> String) -> String {
    guard text.contains(scheme),
      let regex = try? NSRegularExpression(pattern: #"\[((?:\\.|[^\]\\])*)\]\(bento-doc://([0-9A-Fa-f-]{36})\)"#)
    else { return text }
    var result = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: result), let titleRange = Range(match.range(at: 1), in: result),
        let idRange = Range(match.range(at: 2), in: result), let id = UUID(uuidString: String(result[idRange]))
      else { continue }
      let stored = unescaped(String(result[titleRange]))
      result.replaceSubrange(range, with: transform(titles[id] ?? stored, id))
    }
    return result
  }

}

