#if os(iOS)
  @testable import BentoData
  import Dependencies
  import DependenciesTestSupport
  import Foundation
  import SwiftUI
  import Testing
  import UIKit

  @testable import BentoUI

  /// The real iOS text view in a window, typed into the way the keyboard does.
  @MainActor
  @Suite(
    .serialized,
    .dependency(\.defaultDatabase, try makeDatabase()),
    .dependency(\.date.now, Date(timeIntervalSince1970: 1_800_000_000))
  )
  struct DocTextEditorIOSTests {
    func pump(_ seconds: Double = 0.2) {
      RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    func editor(_ blocks: [DocContent]) async throws -> (DocEditorViewModel, DocUITextView, UIWindow) {
      @Dependency(\.defaultDatabase) var database
      let docID = try await database.write { try Mutations.addDoc($0, folderID: nil, title: "Doc", blocks: blocks) }
      let model = DocEditorViewModel(docID: docID, store: NativeDocsStore(database: database))
      await model.load()
      let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
      window.rootViewController = UIHostingController(rootView: DocTextEditor(model: model))
      window.makeKeyAndVisible()
      pump(0.6)
      func find(_ view: UIView) -> DocUITextView? {
        if let match = view as? DocUITextView { return match }
        for sub in view.subviews { if let match = find(sub) { return match } }
        return nil
      }
      let textView = try #require(find(window))
      textView.becomeFirstResponder()
      return (model, textView, window)
    }

    @Test func typingUpdatesTheBlockAndAPrefixMakesAList() async throws {
      let (model, textView, window) = try await editor([DocContent(text: "Hello"), DocContent(text: "World")])
      defer { window.isHidden = true }
      let range = try #require(textView.controller?.range(of: model.blocks[0].id))
      textView.selectedRange = NSRange(location: NSMaxRange(range) - 1, length: 0)

      textView.insertText(" there")
      pump()
      #expect(model.blocks[0].text == "Hello there")

      textView.insertText("\n")
      textView.insertText("- item")
      pump()
      #expect(model.blocks.map(\.kind) == [.text, .bullet, .text])
      #expect(model.blocks[1].text == "item")
    }

    @Test func embeddedBlocksShow() async throws {
      let (_, textView, window) = try await editor([
        DocContent(text: "Above"), DocContent(kind: .divider),
        DocContent(kind: .table, text: DocTable(rows: [["a", "b"]]).json), DocContent(text: "Below"),
      ])
      defer { window.isHidden = true }
      let embedded = textView.subviews.filter { String(describing: type(of: $0)).contains("Hosting") }

      #expect(embedded.count == 2)
      #expect(embedded.allSatisfy { !$0.isHidden && $0.frame.height > 0 })
    }
  }
#endif
