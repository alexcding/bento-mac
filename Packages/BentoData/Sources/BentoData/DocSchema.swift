import Foundation
import SQLiteData

// Docs: the user's own reading and study material, synced like the rest of the library. A doc is
// a list of blocks, one row each, so two devices editing different paragraphs never collide.
// Positions are fractional: a block inserted between two others takes the midpoint, so no other
// row is rewritten.
//
// The sync engine refuses foreign-key cycles, a table referencing itself included, so a folder's
// parent and a page's parent block are plain columns; `Mutations` deletes what hangs off them.

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

/// One document. `folderID` nil keeps it at the top level; a page or card block's doc has
/// `parentBlockID` set and shows inside its parent instead of in lists.
@Table("docs")
public nonisolated struct Doc: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var folderID: DocFolder.ID?
  /// The page or card block that holds this doc. Not a foreign key (see above).
  public var parentBlockID: DocBlock.ID?
  /// For a daily note, its day as `yyyy-MM-dd`: the same on every device and in every language,
  /// whatever the note is titled or wherever it is moved.
  public var dailyNoteDay: String?
  public var title = ""
  public var isStarred = false
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(), folderID: DocFolder.ID? = nil, parentBlockID: DocBlock.ID? = nil, title: String,
    isStarred: Bool = false, createdAt: Date = .now, updatedAt: Date = .now
  ) {
    self.id = id
    self.folderID = folderID
    self.parentBlockID = parentBlockID
    self.title = title
    self.isStarred = isStarred
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

@Table("docBlocks")
public nonisolated struct DocBlock: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var docID: Doc.ID
  public var kind = Kind.text
  /// The block's text with inline Markdown (`**bold**`, `*italic*`, `~~struck~~`, `` `code` ``);
  /// for `.link` the URL, for `.file` the file name, for `.table` the cells as JSON.
  public var text = ""
  /// A to-do's check.
  public var isChecked = false
  /// A toggle's fold: when set, the blocks nested under it are hidden.
  public var isCollapsed = false
  /// Nesting depth, from 0.
  public var indent = 0
  public var alignment = Alignment.leading
  public var decoration = Decoration.none
  public var color = BlockColor.standard
  public var font = BlockFont.system
  /// A code block's language, such as `swift`, `mermaid` or `latex`.
  public var language = ""
  /// A divider's weight.
  public var lineWeight = LineWeight.regular
  public var position = 0.0

  public init(
    id: UUID = UUID(), docID: Doc.ID, kind: Kind = .text, text: String = "", isChecked: Bool = false,
    isCollapsed: Bool = false, indent: Int = 0, alignment: Alignment = .leading, decoration: Decoration = .none,
    color: BlockColor = .standard, font: BlockFont = .system, language: String = "",
    lineWeight: LineWeight = .regular, position: Double = 0
  ) {
    self.id = id
    self.docID = docID
    self.kind = kind
    self.text = text
    self.isChecked = isChecked
    self.isCollapsed = isCollapsed
    self.indent = indent
    self.alignment = alignment
    self.decoration = decoration
    self.color = color
    self.font = font
    self.language = language
    self.lineWeight = lineWeight
    self.position = position
  }

  /// Craft's block styles. `text` is Body.
  public enum Kind: String, CaseIterable, QueryBindable, Sendable {
    case text, title, subtitle, heading, strong, caption
    case bullet, numbered, todo, toggle
    case code, divider, link, file, page, card, table

    /// List kinds keep their kind on Return.
    public var isList: Bool { self == .bullet || self == .numbered || self == .todo || self == .toggle }
    /// Kinds whose text is typed in a field.
    public var isEditable: Bool { !(self == .divider || self == .file || self == .table || self == .page || self == .card) }
    /// Page and card blocks each hold a doc of their own.
    public var holdsDoc: Bool { self == .page || self == .card }
  }

  public enum Alignment: String, CaseIterable, QueryBindable, Sendable {
    case leading, center, trailing, justified
  }

  /// Focus puts a bar beside the block (a Markdown quote); Block puts it on a tinted plate.
  public enum Decoration: String, CaseIterable, QueryBindable, Sendable {
    case none, focus, block
  }

  public enum BlockColor: String, CaseIterable, QueryBindable, Sendable {
    case standard, gray, lightGray, purple, blue, cyan, teal, green, yellow, orange, red
  }

  public enum BlockFont: String, CaseIterable, QueryBindable, Sendable {
    case system, serif, mono, rounded
  }

  public enum LineWeight: String, CaseIterable, QueryBindable, Sendable {
    case extraLight, light, regular, strong
  }

  /// The parts Markdown carries.
  public var content: DocContent {
    DocContent(kind: kind, text: text, isChecked: isChecked, indent: indent, decoration: decoration, language: language)
  }
}

/// The attached file of a `.file` block: a PDF, image, EPUB or anything else the user keeps. Kept
/// apart from DocBlock so loading a doc never loads the blob.
@Table("docFiles")
public nonisolated struct DocFile: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let blockID: DocBlock.ID
  public var name: String
  /// Uniform type identifier, such as `com.adobe.pdf`.
  public var contentType: String
  public var data: Data
  public var id: DocBlock.ID { blockID }

  public init(blockID: DocBlock.ID, name: String, contentType: String, data: Data) {
    self.blockID = blockID
    self.name = name
    self.contentType = contentType
    self.data = data
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

/// What a `.link` block shows: the page's title, description, site and image, fetched once and
/// synced so other devices show it without fetching again. `url` is the link it was made for; a
/// different link in the block means it is out of date.
@Table("docLinkPreviews")
public nonisolated struct DocLinkPreview: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let blockID: DocBlock.ID
  public var url = ""
  public var title = ""
  public var summary = ""
  public var siteName = ""
  /// The page's preview image, scaled down; empty when it has none.
  public var image = Data()
  public var fetchedAt: Date
  public var id: DocBlock.ID { blockID }

  public init(blockID: DocBlock.ID, url: String, metadata: LinkMetadata, fetchedAt: Date = .now) {
    self.blockID = blockID
    self.url = url
    self.title = metadata.title
    self.summary = metadata.summary
    self.siteName = metadata.siteName
    self.image = metadata.image
    self.fetchedAt = fetchedAt
  }
}

/// A block's content without its identity, place or looks, as Markdown parsing produces it.
public struct DocContent: Hashable, Sendable {
  public var kind: DocBlock.Kind
  public var text: String
  public var isChecked: Bool
  public var indent: Int
  public var decoration: DocBlock.Decoration
  public var language: String

  public init(
    kind: DocBlock.Kind = .text, text: String = "", isChecked: Bool = false, indent: Int = 0,
    decoration: DocBlock.Decoration = .none, language: String = ""
  ) {
    self.kind = kind
    self.text = text
    self.isChecked = isChecked
    self.indent = indent
    self.decoration = decoration
    self.language = language
  }
}

/// Rows saved before blocks are deleted, so undo can restore them with everything that hung off
/// them.
public struct DocSnapshot: Hashable, Sendable {
  public var docs: [Doc] = []
  public var blocks: [DocBlock] = []
  public var files: [DocFile] = []
  public var previews: [DocLinkPreview] = []

  public init() {}
}

/// Links from one doc to another, kept in block text as Markdown links with a `bento-doc` URL:
/// `[Title](bento-doc://<id>)`. The title is shown as the target's current title.
public enum DocLink {
  public static let scheme = "bento-doc"

  public static func url(_ id: Doc.ID) -> URL {
    URL(string: "\(scheme)://\(id.uuidString)")!
  }

  public static func markdown(title: String, id: Doc.ID) -> String {
    let title = title.isEmpty ? "Untitled" : title
    return "[\(title.replacingOccurrences(of: "]", with: "\\]"))](\(url(id).absoluteString))"
  }

  /// The doc a `bento-doc` URL points at.
  public static func docID(_ url: URL) -> Doc.ID? {
    guard url.scheme == scheme, let host = url.host() else { return nil }
    return UUID(uuidString: host)
  }

  /// The docs linked to in `text`, in order, without repeats.
  public static func docIDs(in text: String) -> [Doc.ID] {
    guard text.contains(scheme) else { return [] }
    var ids: [Doc.ID] = []
    var rest = text[...]
    while let range = rest.range(of: "\(scheme)://") {
      let id = UUID(uuidString: String(rest[range.upperBound...].prefix(36)))
      if let id, !ids.contains(id) { ids.append(id) }
      rest = rest[range.upperBound...]
    }
    return ids
  }

  /// `text` with each doc link's title replaced by `titles[id]`, as `transform` writes it.
  public static func retitle(_ text: String, titles: [Doc.ID: String], as transform: (String, Doc.ID) -> String) -> String {
    guard text.contains(scheme), let regex = try? NSRegularExpression(pattern: #"\[((?:\\\]|[^\]])*)\]\(bento-doc://([0-9A-Fa-f-]{36})\)"#)
    else { return text }
    var result = text
    for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
      guard let range = Range(match.range, in: result), let titleRange = Range(match.range(at: 1), in: result),
        let idRange = Range(match.range(at: 2), in: result), let id = UUID(uuidString: String(result[idRange]))
      else { continue }
      let stored = String(result[titleRange]).replacingOccurrences(of: "\\]", with: "]")
      result.replaceSubrange(range, with: transform(titles[id] ?? stored, id))
    }
    return result
  }
}

/// A table block's cells, stored as JSON in its text. The first row is the header.
public struct DocTable: Hashable, Sendable {
  public var rows: [[String]]

  public init(rows: [[String]]) {
    let width = max(rows.map(\.count).max() ?? 0, 1)
    self.rows = (rows.isEmpty ? [[""]] : rows).map { $0 + Array(repeating: "", count: width - $0.count) }
  }

  public init(json: String) {
    self.init(rows: (try? JSONDecoder().decode([[String]].self, from: Data(json.utf8))) ?? [["", ""], ["", ""]])
  }

  public static let empty = DocTable(rows: Array(repeating: ["", "", ""], count: 3))

  public var json: String {
    (try? JSONEncoder().encode(rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
  }

  public var columnCount: Int { rows.first?.count ?? 0 }
}
