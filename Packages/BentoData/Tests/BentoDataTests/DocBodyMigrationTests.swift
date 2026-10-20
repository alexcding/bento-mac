import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct DocBodyMigrationTests {
  @Test func blocksBecomeMarkdownAndFilesBecomeAssets() throws {
    let database = try DatabaseQueue()
    try BentoDatabase.migrator.migrate(database, upTo: "Complete docs")
    let docID = UUID()
    let pageID = UUID()
    let (fileBlock, pageBlock) = (UUID(), UUID())
    try database.write { db in
      // Docs before this migration have no body column, so they go in as plain SQL.
      for (id, title, parent) in [(docID, "Notes", nil), (pageID, "Child", pageBlock)] as [(UUID, String, UUID?)] {
        try db.execute(
          sql: #"INSERT INTO "docs" ("id", "parentBlockID", "title", "createdAt", "updatedAt") VALUES (?, ?, ?, ?, ?)"#,
          arguments: [id.uuidString.lowercased(), parent?.uuidString.lowercased(), title, "2026-01-01 00:00:00.000", "2026-01-01 00:00:00.000"]
        )
      }
      let blocks = [
        DocBlock(docID: docID, kind: .heading, text: "Ideas", position: 0),
        DocBlock(docID: docID, kind: .bullet, text: "**one**", position: 1),
        DocBlock(id: fileBlock, docID: docID, kind: .file, text: "a.png", position: 2),
        DocBlock(docID: docID, kind: .file, text: "https://a.com/b.jpg", position: 3),
        DocBlock(id: pageBlock, docID: docID, kind: .page, text: "", position: 4),
        DocBlock(docID: docID, text: "Key", decoration: .focus, position: 5),
      ]
      for block in blocks { try DocBlock.insert { block }.execute(db) }
      try DocFile.insert { DocFile(blockID: fileBlock, name: "a.png", contentType: "public.png", data: Data([1, 2])) }.execute(db)
    }

    try BentoDatabase.migrator.migrate(database)

    try database.read { db in
      let asset = try #require(try DocAsset.all.fetchOne(db))
      #expect(asset.docID == docID && asset.data == Data([1, 2]) && asset.name == "a.png")
      let body = try #require(try Doc.find(docID).fetchOne(db)?.body)
      #expect(
        body == """
          ### Ideas

          - **one**

          ![a.png](bento-asset://\(asset.id.uuidString))

          ![](https://a.com/b.jpg)

          [Child](bento-doc://\(pageID.uuidString))

          > Key
          """
      )
      // The page's doc is an ordinary doc now, beside its parent.
      #expect(try LegacyDocPage.find(pageID).fetchOne(db)?.parentBlockID == nil)
    }
  }

  @Test func nestedAndOrphanedPagesLandInTheirTopDocsFolder() throws {
    let database = try DatabaseQueue()
    try BentoDatabase.migrator.migrate(database, upTo: "Complete docs")
    let (folder, top, child, grandchild, orphan) = (UUID(), UUID(), UUID(), UUID(), UUID())
    let (childBlock, grandchildBlock) = (UUID(), UUID())
    try database.write { db in
      try DocFolder.insert { DocFolder(id: folder, name: "F") }.execute(db)
      func doc(_ id: UUID, folder: UUID?, parent: UUID?) throws {
        try db.execute(
          sql: #"INSERT INTO "docs" ("id", "folderID", "parentBlockID", "title", "createdAt", "updatedAt") VALUES (?, ?, ?, 'x', '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000')"#,
          arguments: [id.uuidString.lowercased(), folder?.uuidString.lowercased(), parent?.uuidString.lowercased()]
        )
      }
      try doc(top, folder: folder, parent: nil)
      try doc(child, folder: nil, parent: childBlock)
      try doc(grandchild, folder: nil, parent: grandchildBlock)
      try doc(orphan, folder: nil, parent: UUID())
      try DocBlock.insert { DocBlock(id: childBlock, docID: top, kind: .page) }.execute(db)
      try DocBlock.insert { DocBlock(id: grandchildBlock, docID: child, kind: .page) }.execute(db)
    }

    try BentoDatabase.migrator.migrate(database)

    let (childFolder, grandchildFolder, orphanFolder, stillNested) = try database.read { db in
      (
        try Doc.find(child).fetchOne(db)?.folderID, try Doc.find(grandchild).fetchOne(db)?.folderID,
        try Doc.find(orphan).fetchOne(db)?.folderID, try LegacyDocPage.where { $0.parentBlockID.isNot(nil) }.fetchCount(db)
      )
    }
    #expect(childFolder == folder && grandchildFolder == folder)
    #expect(orphanFolder == nil)
    #expect(stillNested == 0)
  }

  @Test func aBodyIsSavedAndAnAssetKeptWithItsDoc() throws {
    let database = try DatabaseQueue()
    try BentoDatabase.migrator.migrate(database)
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", body: "# Hi")
      let asset = try Mutations.addDocAsset(db, docID: doc, name: "a.jxl", contentType: "public.jpeg-xl", data: Data([9]))
      try Mutations.setDocBody(db, id: doc, body: DocAsset.markdown(id: asset, name: "a [1].jxl", isImage: true), now: Date(timeIntervalSince1970: 5))
      let stored = try #require(try Doc.find(doc).fetchOne(db))
      #expect(stored.body == "![a \\[1\\].jxl](bento-asset://\(asset.uuidString))")
      #expect(stored.updatedAt == Date(timeIntervalSince1970: 5))
      #expect(DocAsset.assetID(DocAsset.url(asset)) == asset)
      // Deleting the doc deletes what it keeps.
      try Mutations.deleteDoc(db, id: doc)
      #expect(try DocAsset.count().fetchOne(db) == 0)
    }
  }

  @Test func assetsNoDocLinksToAreRemovedAndOthersKept() throws {
    let database = try DatabaseQueue()
    try BentoDatabase.migrator.migrate(database)
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")
      let old = Date.now.addingTimeInterval(-3600)
      let kept = try Mutations.addDocAsset(db, docID: doc, name: "a.png", contentType: "public.png", data: Data([1]), now: old)
      let copied = try Mutations.addDocAsset(db, docID: doc, name: "b.png", contentType: "public.png", data: Data([2]), now: old)
      let removed = try Mutations.addDocAsset(db, docID: doc, name: "c.png", contentType: "public.png", data: Data([3]), now: old)
      try Mutations.setDocBody(db, id: doc, body: DocAsset.markdown(id: kept, name: "a.png", isImage: true))
      // Linked from another doc only: still in use.
      try Mutations.addDoc(db, folderID: nil, title: "E", body: "see \(DocAsset.markdown(id: copied, name: "b", isImage: false))")

      // A new one is left alone: it may still be on its way into the text.
      let fresh = try Mutations.addDocAsset(db, docID: doc, name: "d.png", contentType: "public.png", data: Data([4]), now: .now)
      let result = try Mutations.removeUnusedDocAssets(db, docID: doc, madeBefore: Date.now.addingTimeInterval(-60))
      #expect(result.removed == 1 && result.newer == [fresh])
      #expect(try DocAsset.find(fresh).fetchOne(db) != nil)
      // The later pass deletes just those, and only while still unused.
      #expect(try Mutations.removeUnusedDocAssets(db, ids: [fresh, kept]) == 1)
      #expect(try DocAsset.find(fresh).fetchOne(db) == nil)
      #expect(try Set(DocAsset.all.select(\.id).fetchAll(db)) == [kept, copied])
      #expect(try DocAsset.find(removed).fetchOne(db) == nil)
    }
  }
}
