import Foundation
import SQLiteData
import UniformTypeIdentifiers

/// Turns docs kept as blocks into Markdown bodies, for the "Docs as Markdown" migration. Files
/// become assets linked from the text; a page or card becomes a link to its doc, which then lists
/// like any other doc in its parent's folder; a toggle becomes a bullet with its contents below.
/// Colours, fonts and alignment have no Markdown form and are left behind.
enum DocBodyMigration {
  static func run(_ db: Database) throws {
    // Each page or card doc goes to the folder of the doc it was nested in at the top, worked out
    // before any are moved; one whose block is gone (an orphan left by sync) goes there too, or to
    // the top level.
    let pages = try LegacyDocPage.where { $0.parentBlockID.isNot(nil) }.fetchAll(db)
    let folders = try Dictionary(uniqueKeysWithValues: pages.map { ($0.id, try topFolder(db, of: $0)) })
    for page in pages {
      try LegacyDocPage.find(page.id).update {
        $0.parentBlockID = #bind(nil as DocBlock.ID?)
        $0.folderID = #bind(folders[page.id] ?? nil)
      }
      .execute(db)
    }
    for doc in try Doc.all.fetchAll(db) {
      let blocks = try DocBlock.where { $0.docID.eq(doc.id) }.order { $0.position }.fetchAll(db)
      guard !blocks.isEmpty else { continue }
      var contents: [DocContent] = []
      for block in blocks {
        var content = DocContent(
          kind: block.kind, text: block.text, isChecked: block.isChecked, indent: block.indent,
          decoration: block.decoration, language: block.language
        )
        switch block.kind {
        case .file:
          content.kind = .text
          if let file = try DocFile.find(block.id).fetchOne(db) {
            let asset = DocAsset(docID: doc.id, name: file.name, contentType: file.contentType, data: file.data)
            try DocAsset.insert { asset }.execute(db)
            let isImage = UTType(file.contentType)?.conforms(to: .image) == true
            content.text = DocAsset.markdown(id: asset.id, name: file.name, isImage: isImage)
          } else {
            // An article image never fetched: it stays where it is on the web.
            content.text = "![](\(block.text))"
          }
        case .page, .card:
          content.kind = .text
          if let page = pages.first(where: { $0.parentBlockID == block.id }) {
            content.text = DocLink.markdown(title: page.title, id: page.id)
          }
        case .toggle: content.kind = .bullet
        case .caption: content.kind = .text
        default: break
        }
        contents.append(content)
      }
      let body = DocMarkdown.markdown(title: "", blocks: contents).trimmingCharacters(in: .newlines)
      try Doc.find(doc.id).update { $0.body = #bind(body) }.execute(db)
    }
  }

  /// The folder of the outermost doc a page is nested in, following its blocks up.
  private static func topFolder(_ db: Database, of page: LegacyDocPage) throws -> DocFolder.ID? {
    var folder = page.folderID
    var blockID = page.parentBlockID
    var seen: Set<UUID> = []
    while let id = blockID, seen.insert(id).inserted, let block = try DocBlock.find(id).fetchOne(db),
      let parent = try LegacyDocPage.find(block.docID).fetchOne(db)
    {
      folder = parent.folderID
      blockID = parent.parentBlockID
    }
    return folder
  }
}
