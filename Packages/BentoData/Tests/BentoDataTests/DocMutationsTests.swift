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

  @Test func aNewDocHoldsItsTitleAndMarkdown() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D", body: "# Hi")
      let stored = try #require(try Doc.find(doc).fetchOne(db))
      #expect(stored.title == "D")
      #expect(stored.body == "# Hi")
    }
  }

  @Test func deletingFolderCascadesToSubfoldersDocsAndAssets() throws {
    try database.write { db in
      let parent = try Mutations.addDocFolder(db, name: "P", parentID: nil)
      let child = try Mutations.addDocFolder(db, name: "C", parentID: parent)
      try Mutations.addDoc(db, folderID: parent, title: "A", body: "x")
      let inChild = try Mutations.addDoc(db, folderID: child, title: "B", body: "y")
      try Mutations.addDocAsset(db, docID: inChild, name: "a.png", contentType: "public.png", data: Data([1]))
      let keep = try Mutations.addDoc(db, folderID: nil, title: "Keep")

      try Mutations.deleteDocFolder(db, id: parent)

      #expect(try DocFolder.count().fetchOne(db) == 0)
      #expect(try Doc.count().fetchOne(db) == 1)
      #expect(try DocAsset.count().fetchOne(db) == 0)
      #expect(try Doc.all.fetchAll(db).map(\.id) == [keep])
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
