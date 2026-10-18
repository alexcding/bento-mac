import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct DocMutationsTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  func texts(_ db: Database, _ docID: Doc.ID) throws -> [String] {
    try Mutations.docBlocks(db, docID: docID).map(\.text)
  }

  @Test func addDocWithoutBlocksCreatesOneEmptyTextBlock() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")
      let blocks = try Mutations.docBlocks(db, docID: doc)
      #expect(blocks.count == 1)
      #expect(blocks[0].kind == .text)
      #expect(blocks[0].text == "")
    }
  }

  @Test func insertPlacesBlocksTopBetweenAndEnd() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "a"), DocContent(text: "d")])
      let first = try #require(try Mutations.docBlocks(db, docID: doc).first)

      try Mutations.insertDocBlocks(db, docID: doc, after: nil, [DocContent(text: "top")])
      #expect(try texts(db, doc) == ["top", "a", "d"])

      try Mutations.insertDocBlocks(db, docID: doc, after: first.id, [DocContent(text: "b"), DocContent(text: "c")])
      #expect(try texts(db, doc) == ["top", "a", "b", "c", "d"])

      let last = try #require(try Mutations.docBlocks(db, docID: doc).last)
      try Mutations.insertDocBlocks(db, docID: doc, after: last.id, [DocContent(text: "end")])
      #expect(try texts(db, doc) == ["top", "a", "b", "c", "d", "end"])
    }
  }

  @Test func repeatedInsertsAfterOneBlockKeepOrder() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "first"), DocContent(text: "last")])
      let first = try #require(try Mutations.docBlocks(db, docID: doc).first)
      for index in 0..<60 {
        try Mutations.insertDocBlocks(db, docID: doc, after: first.id, [DocContent(text: "\(index)")])
      }
      let expected = ["first"] + (0..<60).reversed().map(String.init) + ["last"]
      #expect(try texts(db, doc) == expected)
    }
  }

  @Test func moveBlockToTopAndAfterAnother() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(
        db, folderID: nil, title: "D", blocks: [DocContent(text: "a"), DocContent(text: "b"), DocContent(text: "c")]
      )
      let ids = try Mutations.docBlocks(db, docID: doc).map(\.id)

      try Mutations.moveDocBlock(db, id: ids[2], after: nil)
      #expect(try texts(db, doc) == ["c", "a", "b"])

      try Mutations.moveDocBlock(db, id: ids[2], after: ids[1])
      #expect(try texts(db, doc) == ["a", "b", "c"])

      try Mutations.moveDocBlock(db, id: ids[0], after: ids[1])
      #expect(try texts(db, doc) == ["b", "a", "c"])
    }
  }

  @Test func updateBlockChangesContentAndBumpsDoc() throws {
    try database.write { db in
      let created = Date(timeIntervalSince1970: 1000)
      let later = Date(timeIntervalSince1970: 2000)
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "a")], now: created)
      var block = try #require(try Mutations.docBlocks(db, docID: doc).first)
      block.kind = .subtitle
      block.text = "changed"

      try Mutations.updateDocBlock(db, block, now: later)

      let saved = try #require(try Mutations.docBlocks(db, docID: doc).first)
      #expect(saved.kind == .subtitle)
      #expect(saved.text == "changed")
      #expect(try Doc.find(doc).fetchOne(db)?.updatedAt == later)
    }
  }

  @Test func deletingFolderCascadesToSubfoldersDocsAndBlocks() throws {
    try database.write { db in
      let parent = try Mutations.addDocFolder(db, name: "P", parentID: nil)
      let child = try Mutations.addDocFolder(db, name: "C", parentID: parent)
      try Mutations.addDoc(db, folderID: parent, title: "A", blocks: [DocContent(text: "x")])
      try Mutations.addDoc(db, folderID: child, title: "B", blocks: [DocContent(text: "y"), DocContent(text: "z")])
      let keep = try Mutations.addDoc(db, folderID: nil, title: "Keep")

      try Mutations.deleteDocFolder(db, id: parent)

      #expect(try DocFolder.count().fetchOne(db) == 0)
      #expect(try Doc.count().fetchOne(db) == 1)
      #expect(try DocBlock.count().fetchOne(db) == 1)
      #expect(try Doc.all.fetchAll(db).map(\.id) == [keep])
    }
  }

  @Test func updateBlockPersistsLooks() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "a")])
      var block = try #require(try Mutations.docBlocks(db, docID: doc).first)
      block.alignment = .center
      block.decoration = .block
      block.color = .red
      block.font = .mono
      block.language = "py"
      block.lineWeight = .light
      block.isCollapsed = true

      try Mutations.updateDocBlock(db, block)

      let saved = try #require(try Mutations.docBlocks(db, docID: doc).first)
      #expect(saved.alignment == .center)
      #expect(saved.decoration == .block)
      #expect(saved.color == .red)
      #expect(saved.font == .mono)
      #expect(saved.language == "py")
      #expect(saved.lineWeight == .light)
      #expect(saved.isCollapsed)
    }
  }

  @Test func insertingAPageCreatesItsDoc() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")

      let (block, pageID) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "P")

      #expect(block.kind == .page)
      #expect(try Doc.find(pageID).fetchOne(db)?.parentBlockID == block.id)
    }
  }

  @Test func deletingAPageBlockDeletesItsDocAndBlocks() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")
      let (block, _) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "P")
      #expect(try Doc.count().fetchOne(db) == 2)
      #expect(try DocBlock.count().fetchOne(db) == 3)

      try Mutations.deleteDocBlocks(db, ids: [block.id])

      #expect(try Doc.count().fetchOne(db) == 1)
      #expect(try DocBlock.count().fetchOne(db) == 1)
    }
  }

  @Test func deletingADocDeletesNestedPagesTwoLevelsDeep() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")
      let (_, first) = try Mutations.insertDocPage(db, docID: doc, after: nil, kind: .page, title: "P1")
      try Mutations.insertDocPage(db, docID: first, after: nil, kind: .card, title: "P2")
      #expect(try Doc.count().fetchOne(db) == 3)

      try Mutations.deleteDoc(db, id: doc)

      #expect(try Doc.count().fetchOne(db) == 0)
      #expect(try DocBlock.count().fetchOne(db) == 0)
    }
  }

  @Test func deletingFolderCascadesThroughSubSubfolders() throws {
    try database.write { db in
      let root = try Mutations.addDocFolder(db, name: "R", parentID: nil)
      let child = try Mutations.addDocFolder(db, name: "C", parentID: root)
      let grandchild = try Mutations.addDocFolder(db, name: "G", parentID: child)
      for folder in [root, child, grandchild] {
        try Mutations.addDoc(db, folderID: folder, title: "doc")
      }
      try Mutations.addDoc(db, folderID: nil, title: "Keep")

      try Mutations.deleteDocFolder(db, id: root)

      #expect(try DocFolder.count().fetchOne(db) == 0)
      #expect(try Doc.count().fetchOne(db) == 1)
      #expect(try DocBlock.count().fetchOne(db) == 1)
    }
  }

  @Test func turningTextIntoAPageCreatesADocTitledByIt() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "Notes")])
      var block = try #require(try Mutations.docBlocks(db, docID: doc).first)
      block.kind = .page

      try Mutations.updateDocBlock(db, block)

      let inside = try Doc.where { $0.parentBlockID.eq(block.id) }.fetchAll(db)
      #expect(inside.map(\.title) == ["Notes"])
      #expect(try Mutations.docInside(db, blockID: block.id) == inside.first?.id)
    }
  }

  @Test func deletingDocCascadesToBlocks() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", blocks: [DocContent(text: "a"), DocContent(text: "b")])
      #expect(try DocBlock.count().fetchOne(db) == 2)

      try Mutations.deleteDoc(db, id: doc)

      #expect(try Doc.count().fetchOne(db) == 0)
      #expect(try DocBlock.count().fetchOne(db) == 0)
    }
  }

  @Test func folderPositionsIncreaseWithinAParent() throws {
    try database.write { db in
      let parent = try Mutations.addDocFolder(db, name: "P", parentID: nil)
      let a = try Mutations.addDocFolder(db, name: "A", parentID: parent)
      let b = try Mutations.addDocFolder(db, name: "B", parentID: parent)
      let c = try Mutations.addDocFolder(db, name: "C", parentID: parent)
      let positions = try [a, b, c].map { try #require(try DocFolder.find($0).fetchOne(db)).position }
      #expect(positions[0] < positions[1])
      #expect(positions[1] < positions[2])
    }
  }

  @Test func moveDocSetsFolder() throws {
    try database.write { db in
      let folder = try Mutations.addDocFolder(db, name: "F", parentID: nil)
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")

      try Mutations.moveDoc(db, id: doc, folderID: folder)
      #expect(try Doc.find(doc).fetchOne(db)?.folderID == folder)

      try Mutations.moveDoc(db, id: doc, folderID: nil)
      #expect(try Doc.find(doc).fetchOne(db)?.folderID == nil)
    }
  }
}
