import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct DocCoverTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  @Test func aCoverIsSetReplacedRemovedAndGoesWithItsDoc() throws {
    try database.write { db in
      let doc = try Mutations.addDoc(db, folderID: nil, title: "D")
      try Mutations.setDocCover(db, docID: doc, image: Data([1]))
      try Mutations.setDocCover(db, docID: doc, image: Data([2]))
      #expect(try DocCover.find(doc).fetchOne(db)?.image == Data([2]))
      try Mutations.setDocCover(db, docID: doc, image: nil)
      #expect(try DocCover.count().fetchOne(db) == 0)
      try Mutations.setDocCover(db, docID: doc, image: Data([3]))
      try Mutations.deleteDoc(db, id: doc)
      #expect(try DocCover.count().fetchOne(db) == 0)
    }
  }
}
