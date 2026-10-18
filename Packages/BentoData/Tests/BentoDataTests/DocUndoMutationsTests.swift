import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct DocUndoMutationsTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  func texts(_ db: Database, _ docID: Doc.ID) throws -> [String] {
    try Mutations.docBlocks(db, docID: docID).map(\.text)
  }

  @Test func movingTwoBlocksAfterATargetKeepsTheirOrder() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(
        db, folderID: nil, title: "D",
        blocks: ["a", "b", "c", "d"].map { DocContent(text: $0) }
      )
      let ids = try Mutations.docBlocks(db, docID: doc).map(\.id)

      let moved = try Mutations.moveDocBlocks(db, ids: [ids[0], ids[1]], after: ids[2])

      #expect(moved.map(\.id) == [ids[0], ids[1]])
      #expect(try texts(db, doc) == ["c", "a", "b", "d"])
    }
  }

  @Test func movingBlocksWithNilGoesToTheTop() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(
        db, folderID: nil, title: "D",
        blocks: ["a", "b", "c", "d"].map { DocContent(text: $0) }
      )
      let ids = try Mutations.docBlocks(db, docID: doc).map(\.id)

      try Mutations.moveDocBlocks(db, ids: [ids[2], ids[3]], after: nil)

      #expect(try texts(db, doc) == ["c", "d", "a", "b"])
    }
  }

  @Test func aSnapshotOfAPageBlockHoldsTheBlockItsDocAndEverythingInside() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")
      let (block, pageID) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "P")
      let inner = try #require(try Mutations.docBlocks(db, docID: pageID).first)
      try DocFile.insert { DocFile(blockID: block.id, name: "f", contentType: "public.data", data: Data([1])) }.execute(db)
      try DocFile.insert { DocFile(blockID: inner.id, name: "g", contentType: "public.data", data: Data([2])) }.execute(db)
      try DocLinkPreview.insert {
        DocLinkPreview(blockID: inner.id, url: "https://example.com", metadata: LinkMetadata(title: "T"))
      }
      .execute(db)

      let snapshot = try Mutations.docSnapshot(db, blockIDs: [block.id])

      #expect(Set(snapshot.blocks.map(\.id)) == [block.id, inner.id])
      #expect(snapshot.docs.map(\.id) == [pageID])
      #expect(Set(snapshot.files.map(\.blockID)) == [block.id, inner.id])
      #expect(snapshot.previews.map(\.blockID) == [inner.id])
    }
  }

  @Test func restoringASnapshotBringsEveryRowBack() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "keep")])
      let (block, pageID) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "P")
      let inner = try #require(try Mutations.docBlocks(db, docID: pageID).first)
      try DocFile.insert { DocFile(blockID: inner.id, name: "g", contentType: "public.data", data: Data([2])) }.execute(db)
      try DocLinkPreview.insert {
        DocLinkPreview(blockID: inner.id, url: "https://example.com", metadata: LinkMetadata(title: "T"))
      }
      .execute(db)
      let docs = try Doc.all.fetchAll(db)
      let blocks = try DocBlock.all.fetchAll(db)
      let files = try DocFile.all.fetchAll(db)
      let previews = try DocLinkPreview.all.fetchAll(db)
      let snapshot = try Mutations.docSnapshot(db, blockIDs: [block.id])

      try Mutations.deleteDocBlocks(db, ids: [block.id])
      #expect(try Doc.count().fetchOne(db) == 1)
      #expect(try DocBlock.count().fetchOne(db) == 1)
      #expect(try DocFile.count().fetchOne(db) == 0)
      #expect(try DocLinkPreview.count().fetchOne(db) == 0)

      try Mutations.restore(db, snapshot)

      #expect(try Doc.count().fetchOne(db) == docs.count)
      #expect(try DocBlock.count().fetchOne(db) == blocks.count)
      #expect(try DocFile.count().fetchOne(db) == 1)
      #expect(try DocLinkPreview.count().fetchOne(db) == 1)
      // The parent doc stays, marked edited by the delete; the page's doc comes back as it was.
      #expect(Set(try Doc.all.fetchAll(db).map(\.id)) == Set(docs.map(\.id)))
      #expect(try Doc.find(pageID).fetchOne(db) == docs.first { $0.id == pageID })
      #expect(Set(try DocBlock.all.fetchAll(db)) == Set(blocks))
      #expect(Set(try DocFile.all.fetchAll(db)) == Set(files))
      #expect(Set(try DocLinkPreview.all.fetchAll(db)) == Set(previews))
    }
  }

  @Test func restoringBlocksWritesThemBackWithTheirPlace() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "a"), DocContent(text: "b")])
      let before = try Mutations.docBlocks(db, docID: doc)
      try Mutations.moveDocBlock(db, id: before[1].id, after: nil)
      var changed = try #require(try DocBlock.find(before[0].id).fetchOne(db))
      changed.text = "changed"
      try Mutations.updateDocBlock(db, changed)

      try Mutations.restoreDocBlocks(db, before)

      #expect(try Mutations.docBlocks(db, docID: doc) == before)
    }
  }
}

@Suite struct DocLinkTests {
  @Test func markdownIDAndURLRoundTrip() {
    let id = UUID()

    let markdown = DocLink.markdown(title: "Physics", id: id)

    #expect(markdown == "[Physics](bento-doc://\(id.uuidString))")
    #expect(DocLink.docID(DocLink.url(id)) == id)
    #expect(DocLink.docIDs(in: "see \(markdown) and \(markdown)") == [id])
    #expect(DocLink.docID(URL(string: "https://example.com")!) == nil)
  }

  @Test func aTitleWithABracketSurvivesTheRoundTrip() {
    let id = UUID()

    let markdown = DocLink.markdown(title: "a]b", id: id)

    #expect(markdown == "[a\\]b](bento-doc://\(id.uuidString))")
    #expect(DocLink.docIDs(in: markdown) == [id])
    #expect(DocLink.retitle(markdown, titles: [:]) { DocLink.markdown(title: $0, id: $1) } == markdown)
  }

  @Test func docIDsKeepOrderAndSkipRepeats() {
    let (first, second) = (UUID(), UUID())
    let text = "\(DocLink.markdown(title: "A", id: first)) \(DocLink.markdown(title: "B", id: second)) \(DocLink.markdown(title: "A", id: first))"

    #expect(DocLink.docIDs(in: text) == [first, second])
    #expect(DocLink.docIDs(in: "no links") == [])
  }

  @Test func retitleReplacesKnownTitlesAndLeavesOtherLinksAlone() {
    let (first, second) = (UUID(), UUID())
    let text = "x \(DocLink.markdown(title: "Old", id: first)) y \(DocLink.markdown(title: "Keep", id: second))"

    let result = DocLink.retitle(text, titles: [first: "New"]) { DocLink.markdown(title: $0, id: $1) }

    #expect(result == "x \(DocLink.markdown(title: "New", id: first)) y \(DocLink.markdown(title: "Keep", id: second))")
  }
}
