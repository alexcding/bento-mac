#if os(macOS)
  import AppKit
  @testable import BentoData
  import Dependencies
  import DependenciesTestSupport
  import SwiftUI
  import Testing

  @testable import BentoUI

  /// The Markdown editor hosted in a window and driven as the keyboard drives it.
  @MainActor
  @Suite(.serialized, .dependency(\.defaultDatabase, try makeDatabase()))
  struct MarkdownEditorTests {
    func pump(_ seconds: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    func open(_ body: String) async throws -> (DocPageViewModel, MarkdownNSTextView, NSWindow) {
      @Dependency(\.defaultDatabase) var database
      let other = try await database.write { try Mutations.addDoc($0, folderID: nil, title: "Physics") }
      _ = other
      let docID = try await database.write { try Mutations.addDoc($0, folderID: nil, title: "Notes", body: body) }
      let page = DocPageViewModel(docID: docID, store: NativeDocsStore(database: database))
      await page.load()
      page.isEditing = true
      let host = NSHostingView(rootView: MarkdownSourceEditor(text: Binding(get: { page.body }, set: { page.body = $0 }), controller: page.editor)
        .frame(width: 600, height: 400))
      host.frame = CGRect(x: 0, y: 0, width: 600, height: 400)
      let window = NSWindow(contentRect: host.frame, styleMask: [.titled], backing: .buffered, defer: false)
      window.contentView = host
      window.makeKeyAndOrderFront(nil)
      pump(0.3)
      let textView = try #require(page.editor.textView)
      window.makeFirstResponder(textView)
      textView.setSelectedRange(NSRange(location: (body as NSString).length, length: 0))
      pump(0.05)
      return (page, textView, window)
    }

    func type(_ text: String, into textView: NSTextView) {
      for character in text {
        if character == "\n" {
          textView.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        } else {
          textView.insertText(String(character), replacementRange: textView.selectedRange())
        }
      }
      pump(0.05)
    }

    @Test func slashOpensTheMenuAndChoosingWritesTheMarkdown() async throws {
      let (page, textView, window) = try await open("")
      defer { window.orderOut(nil) }

      type("/head", into: textView)
      #expect(page.menu?.trigger.kind == .insert)
      #expect(page.menuItems.first == .insert(.named("Heading 1")))
      type("\n", into: textView)
      type("Ideas", into: textView)

      #expect(page.body == "# Ideas")
      #expect(page.menu == nil)
    }

    @Test func returnContinuesAListAndTabNestsIt() async throws {
      let (page, textView, window) = try await open("- one")
      defer { window.orderOut(nil) }

      type("\ntwo", into: textView)
      textView.doCommand(by: #selector(NSResponder.insertTab(_:)))
      type("\n\n", into: textView)

      #expect(page.body == "- one\n  - two\n")
    }

    @Test func doubleBracketLinksADoc() async throws {
      let (page, textView, window) = try await open("See ")
      defer { window.orderOut(nil) }

      type("[[phy", into: textView)
      #expect(page.menu?.trigger.kind == .docLink)
      type("\n", into: textView)

      #expect(page.body.hasPrefix("See [Physics](bento-doc://"))
    }

    @Test func toolsInsertAtTheCursorAndWrapTheSelection() async throws {
      let (page, textView, window) = try await open("word")
      defer { window.orderOut(nil) }

      textView.setSelectedRange(NSRange(location: 0, length: 4))
      page.wrap("**")
      page.perform(MarkdownInsert.all.first { $0.name == "Divider" }!)
      pump(0.05)

      #expect(page.body == "**word**\n---\n")
    }

    @Test func theRibbonWritesOnlyWhileTheEditorHasTheFocus() async throws {
      let (page, textView, window) = try await open("word")
      defer { window.orderOut(nil) }
      #expect(page.editorFocused)

      window.makeFirstResponder(nil)
      pump(0.05)
      page.perform(.named("Divider"))
      page.wrap("**")
      #expect(!page.editorFocused)
      #expect(page.body == "word")

      window.makeFirstResponder(textView)
      pump(0.05)
      page.perform(.named("Divider"))
      #expect(page.body == "word\n---\n")
    }
  }
#endif
