import BentoData
import QuickLook
import SwiftUI
import UniformTypeIdentifiers

/// A doc: one continuous text with Craft's Insert, Format and Info panels beside it, a format bar
/// over selected text, and the `/` and `[[` menus at the cursor. Files dropped on it are attached.
struct DocEditorView: View {
  @Bindable var model: DocEditorViewModel
  @Environment(\.scenePhase) private var scenePhase
  @State private var showsInspector = true
  @State private var exporting = false

  var body: some View {
    Group {
      if model.doc != nil {
        DocTextEditor(model: model)
          .overlay(alignment: .topLeading) { overlays }
          .background { shortcuts }
          .toolbar { toolbar }
          .inspector(isPresented: $showsInspector) {
            DocInspectorView(model: model)
              .inspectorColumnWidth(min: 260, ideal: 290, max: 360)
          }
      } else {
        ContentUnavailableView("Doc not found", systemImage: "questionmark.circle")
      }
    }
    .task { await model.load() }
    // Typing waiting to be saved is written when the doc closes or the app steps away.
    .onDisappear { model.flushTyping() }
    .onChange(of: scenePhase) { if scenePhase != .active { model.flushTyping() } }
    #if os(macOS)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
        model.flushTyping()
      }
    #endif
    .onChange(of: model.storedBlocks) { model.merge() }
    .onChange(of: model.doc?.title) { model.mergeTitle() }
    .onChange(of: model.pages) { model.refreshLinks() }
    .fileImporter(
      isPresented: Binding(get: { model.importing != nil }, set: { if !$0 { model.importing = nil } }),
      allowedContentTypes: model.importing?.types ?? [.item],
      allowsMultipleSelection: true
    ) { result in
      if case .success(let urls) = result { Task { await model.attach(urls) } }
    }
    .fileExporter(
      isPresented: $exporting,
      document: MarkdownFile(text: model.markdown),
      contentType: MarkdownFile.markdown,
      defaultFilename: model.title.isEmpty ? "Untitled" : model.title
    ) { _ in }
    .quickLookPreview($model.previewURL)
    // Doc links inside embedded blocks open in the editor; web links open as usual.
    .environment(\.openURL, OpenURLAction { model.openLink($0) ? .handled : .systemAction })
  }

  /// The menus at the cursor and the bar over selected text.
  @ViewBuilder
  private var overlays: some View {
    if let caret = model.caretRect, model.linkQuery != nil, !model.linkChoices.isEmpty {
      CaretMenu(
        rows: model.linkChoices.map(MenuRow.init),
        selected: model.linkQuery?.selected ?? 0,
        choose: { model.chooseLink(model.linkChoices[$0]) }
      )
      .offset(x: caret.minX, y: caret.maxY + 6)
    } else if let caret = model.caretRect, model.slashQuery != nil, !model.slashChoices.isEmpty {
      CaretMenu(
        rows: model.slashChoices.map { MenuRow(title: $0.name, symbol: $0.symbol) },
        selected: model.slashQuery?.selected ?? 0,
        choose: { model.chooseSlash(model.slashChoices[$0]) }
      )
      .offset(x: caret.minX, y: caret.maxY + 6)
    } else if let selection = model.selectionRect {
      FormatBar(model: model)
        .offset(x: max(selection.minX, 8), y: max(selection.minY - 46, 4))
    }
  }

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    if let parent = model.parentTitle {
      ToolbarItem(placement: .navigation) {
        Button {
          model.goBack()
        } label: {
          Label(parent.isEmpty ? "Back" : parent, systemImage: "chevron.backward")
            .labelStyle(.titleAndIcon)
        }
        .help("Back to \(parent.isEmpty ? "the parent doc" : parent)")
      }
    }
    ToolbarItemGroup {
      #if os(iOS)
        Button("Undo", systemImage: "arrow.uturn.backward") { model.undo() }
          .disabled(!model.canUndo)
        Button("Redo", systemImage: "arrow.uturn.forward") { model.redo() }
          .disabled(!model.canRedo)
      #endif
      Button("Export Markdown", systemImage: "square.and.arrow.up") { exporting = true }
      Button("Format", systemImage: "sidebar.right") { showsInspector.toggle() }
        .help(showsInspector ? "Hide Insert, Format and Info" : "Show Insert, Format and Info")
    }
  }

  /// Keyboard shortcuts for inline and block styles, there whether or not the inspector is open.
  private var shortcuts: some View {
    Group {
      Button("Bold") { model.toggleInline(.bold) }.keyboardShortcut("b")
      Button("Italic") { model.toggleInline(.italic) }.keyboardShortcut("i")
      Button("Strikethrough") { model.toggleInline(.strike) }.keyboardShortcut("x", modifiers: [.command, .shift])
      Button("Code") { model.toggleInline(.code) }.keyboardShortcut("e")
      Button("Link") { if model.selectionRect != nil { model.askingForLink = true } }.keyboardShortcut("k")
      Button("Title") { model.setKind(.title) }.keyboardShortcut("1", modifiers: [.command, .option])
      Button("Subtitle") { model.setKind(.subtitle) }.keyboardShortcut("2", modifiers: [.command, .option])
      Button("Heading") { model.setKind(.heading) }.keyboardShortcut("3", modifiers: [.command, .option])
      Button("Strong") { model.setKind(.strong) }.keyboardShortcut("4", modifiers: [.command, .option])
      Button("Body") { model.setKind(.text) }.keyboardShortcut("0", modifiers: [.command, .option])
      Button("To-do") { model.setKind(.todo) }.keyboardShortcut("t", modifiers: [.command, .shift])
      Button("Move Block Up") { model.moveFocusedBlock(by: -1) }.keyboardShortcut(.upArrow, modifiers: [.command, .option])
      Button("Move Block Down") { model.moveFocusedBlock(by: 1) }.keyboardShortcut(.downArrow, modifiers: [.command, .option])
    }
    .buttonStyle(.plain)
    .opacity(0)
    .frame(width: 0, height: 0)
    .accessibilityHidden(true)
  }
}

private struct MenuRow: Hashable {
  let title: String
  let symbol: String

  init(title: String, symbol: String) {
    self.title = title
    self.symbol = symbol
  }

  init(_ choice: DocEditorViewModel.LinkChoice) {
    switch choice {
    case .doc(let doc): self.init(title: doc.title.isEmpty ? "Untitled" : doc.title, symbol: "doc.text")
    case .create(let name): self.init(title: "New doc “\(name)”", symbol: "plus")
    }
  }
}

/// A list at the cursor: the docs a `[[` link could go to, or the blocks `/` can add. Up and
/// Down move the highlight, Return picks, Escape closes.
private struct CaretMenu: View {
  let rows: [MenuRow]
  let selected: Int
  let choose: (Int) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
            Button {
              choose(index)
            } label: {
              HStack(spacing: 8) {
                Image(systemName: row.symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(row.title).lineLimit(1)
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(
                index == selected ? AnyShapeStyle(.tint.opacity(0.2)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6)
              )
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .id(index)
          }
        }
        .padding(4)
      }
      .onChange(of: selected) { proxy.scrollTo(selected) }
    }
    .frame(width: 260)
    .frame(maxHeight: 280)
    .fixedSize(horizontal: false, vertical: true)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
    .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
  }
}

/// The bar over selected text: inline styles, the block style and colour.
private struct FormatBar: View {
  let model: DocEditorViewModel

  var body: some View {
    HStack(spacing: 2) {
      button("bold", "Bold") { model.toggleInline(.bold) }
      button("italic", "Italic") { model.toggleInline(.italic) }
      button("strikethrough", "Strikethrough") { model.toggleInline(.strike) }
      button("chevron.left.forwardslash.chevron.right", "Code") { model.toggleInline(.code) }
      button("link", "Link (⌘K)") { model.askingForLink = true }
        .popover(isPresented: Binding(get: { model.askingForLink }, set: { model.askingForLink = $0 })) {
          LinkPrompt { model.setLinkOnSelection($0) }
        }
      Divider().frame(height: 18)
      Menu {
        ForEach([DocBlock.Kind.title, .subtitle, .heading, .strong, .text, .caption], id: \.self) { kind in
          Button(kind.styleName) { model.setKind(kind) }
        }
        Divider()
        Button("To-do") { model.setKind(.todo) }
        Button("Bulleted List") { model.setKind(.bullet) }
        Button("Numbered List") { model.setKind(.numbered) }
        Button("Toggle") { model.setKind(.toggle) }
      } label: {
        Text(model.focusedBlock?.kind.styleName ?? "Style").font(.callout)
      }
      .menuIndicator(.visible)
      .fixedSize()
      Divider().frame(height: 18)
      Menu {
        ForEach(DocBlock.BlockColor.allCases, id: \.self) { color in
          Button(color.name) { model.setColor(color) }
        }
      } label: {
        Image(systemName: "paintpalette")
      }
      .menuIndicator(.hidden)
      .fixedSize()
    }
    .padding(.horizontal, 6)
    .padding(.vertical, 4)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.separator))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
  }

  private func button(_ symbol: String, _ help: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol).frame(width: 26, height: 24).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

/// Asks for the web address to put on selected text.
private struct LinkPrompt: View {
  let done: (String) -> Void
  @State private var url = ""

  var body: some View {
    HStack {
      TextField("https://", text: $url)
        .textFieldStyle(.roundedBorder)
        .frame(minWidth: 260)
        .onSubmit { done(url) }
      Button("Link") { done(url) }
        .disabled(url.trimmingCharacters(in: .whitespaces).isEmpty)
    }
    .padding()
  }
}

extension DocBlock.Kind {
  var styleName: String {
    switch self {
    case .title: "Title"
    case .subtitle: "Subtitle"
    case .heading: "Heading"
    case .strong: "Strong"
    case .caption: "Caption"
    case .bullet: "Bullets"
    case .numbered: "Numbers"
    case .todo: "To-do"
    case .toggle: "Toggle"
    case .code: "Code"
    default: "Body"
    }
  }
}

/// A doc exported as a Markdown file.
struct MarkdownFile: FileDocument {
  static let markdown = UTType(filenameExtension: "md", conformingTo: .plainText) ?? .plainText
  static var readableContentTypes: [UTType] { [markdown, .plainText] }

  var text: String

  init(text: String) {
    self.text = text
  }

  init(configuration: ReadConfiguration) throws {
    text = configuration.file.regularFileContents.flatMap { String(data: $0, encoding: .utf8) } ?? ""
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    FileWrapper(regularFileWithContents: Data(text.utf8))
  }
}
