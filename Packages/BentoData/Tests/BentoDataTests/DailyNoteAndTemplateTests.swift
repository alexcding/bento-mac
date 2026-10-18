import Foundation
import SQLiteData
import Testing

@testable import BentoData

@Suite struct DailyNoteTests {
  let database: any DatabaseWriter

  init() throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite")
    database = try BentoDatabase.open(at: url, iCloudContainer: nil)
  }

  @Test func oneNotePerDayInOneFolder() throws {
    let calendar = Calendar(identifier: .gregorian)
    let morning = Date(timeIntervalSince1970: 1_800_000_000)
    let evening = morning.addingTimeInterval(6 * 3600)
    let tomorrow = calendar.date(byAdding: .day, value: 1, to: morning)!
    try database.write { db in
      let first = try Mutations.dailyNote(db, title: "Day 1", now: morning, calendar: calendar)
      let again = try Mutations.dailyNote(db, title: "第一天", now: evening, calendar: calendar)
      let next = try Mutations.dailyNote(db, title: "Day 2", now: tomorrow, calendar: calendar)

      #expect(first == again)
      #expect(next.folderID == first.folderID)
      #expect(next.docID != first.docID)
      #expect(try DocFolder.count().fetchOne(db) == 1)
      #expect(try Doc.find(first.docID).fetchOne(db)?.title == "Day 1")
      #expect(try Mutations.docBlocks(db, docID: next.docID).map(\.kind) == [.todo])
    }
  }

  @Test func anotherDocMadeTodayIsNotTheDailyNote() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try database.write { db in
      let note = try Mutations.dailyNote(db, title: "Today", now: now)
      let other = try Mutations.addDoc(db, folderID: note.folderID, title: "Something else", now: now.addingTimeInterval(60))
      let again = try Mutations.dailyNote(db, title: "Today", now: now.addingTimeInterval(120))
      #expect(again.docID == note.docID)
      #expect(again.docID != other)
    }
  }

  @Test func newNotesGoInTheOldestDailyNotesFolder() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try database.write { db in
      let older = try Mutations.addDocFolder(db, name: Mutations.dailyNotesFolder, parentID: nil, now: now.addingTimeInterval(-60))
      _ = try Mutations.addDocFolder(db, name: Mutations.dailyNotesFolder, parentID: nil, now: now)
      #expect(try Mutations.dailyNote(db, title: "Today", now: now).folderID == older)
    }
  }

  @Test func aRenamedOrMovedNoteIsStillTodaysNote() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    try database.write { db in
      let note = try Mutations.dailyNote(db, title: "Today", now: now)
      try Mutations.renameDoc(db, id: note.docID, title: "Exam prep")
      try Mutations.moveDoc(db, id: note.docID, folderID: nil)
      let again = try Mutations.dailyNote(db, title: "Today", now: now.addingTimeInterval(60))
      #expect(again.docID == note.docID)
      #expect(again.folderID == nil)
    }
  }

  @Test func theDayKeyIsGregorianWhateverTheCalendar() {
    var buddhist = Calendar(identifier: .buddhist)
    buddhist.timeZone = TimeZone(identifier: "UTC")!
    #expect(Mutations.dailyNoteDay(Date(timeIntervalSince1970: 1_800_000_000), calendar: buddhist) == "2027-01-15")
  }

}

@Suite struct DocTemplateTests {
  @Test func everyTemplateHasBlocks() {
    for template in DocTemplate.all {
      #expect(!template.blocks.isEmpty, "\(template.name)")
    }
  }

  @Test func flashcardsAreTogglesWithTheAnswerInside() {
    let blocks = DocTemplate.flashcards.blocks.filter { $0.kind == .toggle || $0.indent > 0 }
    #expect(blocks.map(\.kind) == [.toggle, .text, .toggle, .text])
    #expect(blocks.map(\.indent) == [0, 1, 0, 1])
  }
}

@Suite struct BareListMarkerTests {
  @Test func importedMarkersWithoutTextAreEmptyItems() {
    let blocks = DocMarkdown.blocks(from: "-\n- [ ]\n- [x]\n▸")
    #expect(blocks.map(\.kind) == [.bullet, .todo, .todo, .toggle])
    #expect(blocks.map(\.isChecked) == [false, false, true, false])
    #expect(blocks.allSatisfy { $0.text.isEmpty })
  }

  @Test func aLoneYearOrStarStaysText() {
    let blocks = DocMarkdown.blocks(from: "2024.\n*\n+")
    #expect(blocks.map(\.kind) == [.text, .text, .text])
    #expect(blocks.map(\.text) == ["2024.", "*", "+"])
  }

  @Test func aTypedMarkerWaitsForItsSpace() {
    #expect(DocMarkdown.shortcut("-") == nil)
    #expect(DocMarkdown.shortcut("1.") == nil)
    #expect(DocMarkdown.shortcut("[]") == nil)
    #expect(DocMarkdown.shortcut("- ")?.kind == .bullet)
    #expect(DocMarkdown.shortcut("1. ")?.kind == .numbered)
    #expect(DocMarkdown.shortcut("[] ")?.kind == .todo)
    #expect(DocMarkdown.shortcut("---")?.kind == .divider)
  }

  @Test func plainTextEndingInAPeriodStaysText() {
    #expect(DocMarkdown.blocks(from: "Version 2.").map(\.kind) == [.text])
  }
}

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
