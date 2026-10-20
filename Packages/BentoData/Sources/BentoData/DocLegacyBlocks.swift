import Foundation
import SQLiteData

// Docs were once lists of blocks, one row each. These types remain only so the "Docs as Markdown"
// migration can read those rows and write each doc's Markdown; nothing else uses them.

/// The docs table as it was read when docs held blocks: a page or card block's doc pointed back
/// at its block.
@Table("docs")
nonisolated struct LegacyDocPage: Identifiable {
  let id: UUID
  var folderID: DocFolder.ID?
  var parentBlockID: DocBlock.ID?
  var title = ""
}

/// A block as it was stored: only what Markdown can carry is read. Its looks (colour, font,
/// alignment) have no Markdown form and are left in the table.
@Table("docBlocks")
nonisolated struct DocBlock: Hashable, Identifiable, Sendable {
  let id: UUID
  var docID: Doc.ID
  var kind = Kind.text
  /// The block's text with inline Markdown; for `.link` the URL, for `.file` the file name, for
  /// `.table` the cells as JSON.
  var text = ""
  var isChecked = false
  var indent = 0
  var decoration = Decoration.none
  /// A code block's language.
  var language = ""
  var position = 0.0

  init(
    id: UUID = UUID(), docID: Doc.ID, kind: Kind = .text, text: String = "", isChecked: Bool = false, indent: Int = 0,
    decoration: Decoration = .none, language: String = "", position: Double = 0
  ) {
    self.id = id
    self.docID = docID
    self.kind = kind
    self.text = text
    self.isChecked = isChecked
    self.indent = indent
    self.decoration = decoration
    self.language = language
    self.position = position
  }

  enum Kind: String, QueryBindable, Sendable {
    case text, title, subtitle, heading, strong, caption
    case bullet, numbered, todo, toggle
    case code, divider, link, file, page, card, table

    var isList: Bool { self == .bullet || self == .numbered || self == .todo || self == .toggle }
  }

  /// Focus put a bar beside the block, which Markdown writes as a quote.
  enum Decoration: String, QueryBindable, Sendable {
    case none, focus, block
  }
}

/// The attached file of a `.file` block: a PDF, image, EPUB or anything else the user keeps. Kept
/// apart from DocBlock so loading a doc never loads the blob.
@Table("docFiles")
nonisolated struct DocFile: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  let blockID: DocBlock.ID
  var name: String
  /// Uniform type identifier, such as `com.adobe.pdf`.
  var contentType: String
  var data: Data
  var id: DocBlock.ID { blockID }

  init(blockID: DocBlock.ID, name: String, contentType: String, data: Data) {
    self.blockID = blockID
    self.name = name
    self.contentType = contentType
    self.data = data
  }
}

/// A block's content without its identity, place or looks, as Markdown parsing produces it.
struct DocContent: Hashable, Sendable {
  var kind: DocBlock.Kind
  var text: String
  var isChecked: Bool
  var indent: Int
  var decoration: DocBlock.Decoration
  var language: String

  init(
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

/// A table block's cells, stored as JSON in its text. The first row is the header.
struct DocTable: Hashable, Sendable {
  var rows: [[String]]

  init(rows: [[String]]) {
    let width = max(rows.map(\.count).max() ?? 0, 1)
    self.rows = (rows.isEmpty ? [[""]] : rows).map { $0 + Array(repeating: "", count: width - $0.count) }
  }

  init(json: String) {
    self.init(rows: (try? JSONDecoder().decode([[String]].self, from: Data(json.utf8))) ?? [["", ""], ["", ""]])
  }

  static let empty = DocTable(rows: Array(repeating: ["", "", ""], count: 3))

  var json: String {
    (try? JSONEncoder().encode(rows)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
  }

  var columnCount: Int { rows.first?.count ?? 0 }
}
