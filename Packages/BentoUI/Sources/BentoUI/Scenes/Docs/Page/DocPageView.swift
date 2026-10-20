import BentoData
import SwiftUI
import UniformTypeIdentifiers

/// A doc read as an article. Editing (⌘E) keeps the article on the left as a live preview, opens
/// the Markdown on the right, and puts a ribbon of styles and inserts across the top, as a word
/// processor does. In the editor, `/` opens the same inserts at the cursor and `[[` links a doc.
struct DocPageView: View {
  @Bindable var model: DocPageViewModel
  @Environment(\.scenePhase) private var scenePhase
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif
  @State private var exporting = false
  @State private var export: MarkdownFile?
  /// What the open file picker adds, kept as `model.importing` is cleared when the picker closes.
  @State private var picking: DocPageViewModel.ImportKind?

  var body: some View {
    Group {
      if !model.isReady {
        Color.clear
      } else if model.exists {
        if model.isEditing { editing } else { reader }
      } else {
        ContentUnavailableView("Doc not found", systemImage: "questionmark.circle")
      }
    }
    .toolbar { toolbar }
    .task { await model.load() }
    .onChange(of: model.doc) { model.storedDocChanged() }
    .onChange(of: model.cover) { Task { await model.coverChanged() } }
    // A linked doc renamed, deleted or synced in shows in the links at once.
    .onChange(of: model.otherDocs) { model.refreshPreview(now: true) }
    .onChange(of: model.importing) { if let kind = model.importing { picking = kind } }
    .onDisappear {
      model.flush()
      model.removeUnusedAssets()
    }
    .onChange(of: scenePhase) { if scenePhase != .active { model.flush() } }
    .fileImporter(
      isPresented: Binding(get: { model.importing != nil }, set: { if !$0 { model.importing = nil } }),
      allowedContentTypes: model.importing?.types ?? [.item],
      allowsMultipleSelection: model.importing != .cover
    ) { result in
      guard case .success(let urls) = result else { return }
      switch model.importing ?? picking {
      case .cover: if let url = urls.first { Task { await model.setCover(from: url) } }
      case .image: Task { await model.attach(urls, asImages: true) }
      case .file, nil: Task { await model.attach(urls, asImages: false) }
      }
    }
    .fileExporter(
      isPresented: $exporting, document: export ?? MarkdownFile(text: ""), contentType: MarkdownFile.markdown,
      defaultFilename: model.title.isEmpty ? "Untitled" : model.title
    ) { _ in export = nil }
    .environment(\.openDocLink) { model.openDoc($0) }
    .environment(\.docLinkExists) { model.docExists($0) }
    .environment(\.setLinkStyle) { model.setLinkStyle($0, $1) }
  }

  // MARK: Reading

  private var reader: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 0) {
        if let image = model.coverImage {
          Image(decorative: image, scale: 1).resizable().scaledToFill()
            .frame(maxWidth: .infinity).frame(height: 240).clipped()
        } else if model.coverPending {
          Rectangle().fill(.quaternary.opacity(0.4)).frame(maxWidth: .infinity).frame(height: 240)
        }
        VStack(alignment: .leading, spacing: 20) {
          Text(model.title.isEmpty ? "Untitled" : model.title)
            .font(.system(size: 34, weight: .bold))
            .foregroundStyle(model.title.isEmpty ? .secondary : .primary)
            .textSelection(.enabled)
          if !model.preview.isEmpty {
            DocMarkdownSections(markdown: model.preview).equatable()
          } else if model.isEditing {
            Text("The preview shows here as you write.").foregroundStyle(.secondary)
          } else {
            Button("Start writing") { model.toggleEditing() }.buttonStyle(.borderless)
          }
        }
        .frame(maxWidth: 720, alignment: .leading)
        .padding(.horizontal, 32)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
      }
    }
  }

  // MARK: Editing

  private var showsPreview: Bool {
    #if os(iOS)
      sizeClass != .compact
    #else
      true
    #endif
  }

  private var editing: some View {
    VStack(spacing: 0) {
      DocRibbon(model: model)
      Divider()
      HStack(spacing: 0) {
        if showsPreview {
          reader.frame(maxWidth: .infinity)
          Divider()
        }
        source.frame(maxWidth: .infinity)
      }
    }
  }

  private var source: some View {
    VStack(alignment: .leading, spacing: 0) {
      TextField("Title", text: $model.title, axis: .vertical)
        .font(.system(size: 26, weight: .bold))
        .textFieldStyle(.plain)
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .onChange(of: model.title) { model.edited() }
      MarkdownSourceEditor(text: $model.body, controller: model.editor)
        .onChange(of: model.body) { model.edited() }
        .overlay(alignment: .topLeading) { menu }
        .dropDestination(for: String.self) { items, _ in model.linkDocs(DocDrag.docIDs(items)) }
    }
    .background(.background.secondary)
  }

  /// The `/` or `[[` menu, under the caret.
  @ViewBuilder
  private var menu: some View {
    if let menu = model.menu, !model.menuItems.isEmpty {
      VStack(alignment: .leading, spacing: 0) {
        ForEach(Array(model.menuItems.enumerated()), id: \.element.id) { index, item in
          Button {
            model.choose(item)
          } label: {
            HStack(spacing: 8) {
              switch item {
              case .insert(let insert):
                Image(systemName: insert.symbol).frame(width: 18)
                Text(insert.name)
              case .doc(let doc):
                Image(systemName: "doc.text").frame(width: 18)
                Text(doc.title.isEmpty ? "Untitled" : doc.title).lineLimit(1)
              }
              Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(index == menu.selected ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 6))
          }
          .buttonStyle(.plain)
        }
      }
      .padding(4)
      .frame(width: 240)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .shadow(radius: 8, y: 2)
      .offset(x: max(menu.caret.minX, 8), y: menu.caret.maxY + 6)
    }
  }

  // MARK: Toolbar

  @ToolbarContentBuilder
  private var toolbar: some ToolbarContent {
    ToolbarItemGroup {
      Button(model.isEditing ? "Done" : "Edit", systemImage: model.isEditing ? "checkmark" : "pencil") {
        model.toggleEditing()
      }
      .keyboardShortcut("e")
      .help(model.isEditing ? "Read (⌘E)" : "Edit as Markdown (⌘E)")
      Button(model.isStarred ? "Unstar" : "Star", systemImage: model.isStarred ? "star.fill" : "star") { model.toggleStarred() }
      Menu("More", systemImage: "ellipsis.circle") {
        Button(model.cover == nil ? "Add Cover…" : "Change Cover…", systemImage: "photo") { model.importing = .cover }
        if model.cover != nil {
          Button("Remove Cover", systemImage: "xmark.circle") { Task { await model.removeCover() } }
        }
        Divider()
        Button("Export Markdown…", systemImage: "square.and.arrow.up") {
          model.flush()
          export = MarkdownFile(text: model.markdown)
          exporting = true
        }
        Divider()
        Text("\(model.wordCount) words")
      }
    }
  }
}

/// The ribbon over the editor, in a word processor's groups: the line's style, inline styles,
/// lists, blocks to insert, and links and files.
struct DocRibbon: View {
  let model: DocPageViewModel

  var body: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(alignment: .top, spacing: 14) {
        group("Style") {
          Menu {
            ForEach(["Body", "Heading 1", "Heading 2", "Heading 3"], id: \.self) { name in
              Button(name) { model.perform(.named(name)) }
            }
          } label: {
            Text("Styles").frame(minWidth: 80, alignment: .leading)
          }
          .fixedSize()
          tool("Heading 1", "textformat.size.larger") { model.perform(.named("Heading 1")) }
          tool("Heading 2", "textformat.size") { model.perform(.named("Heading 2")) }
        }
        separator
        group("Font") {
          tool("Bold (⌘B)", "bold") { model.wrap("**") }.keyboardShortcut("b")
          tool("Italic (⌘I)", "italic") { model.wrap("_") }.keyboardShortcut("i")
          tool("Strikethrough", "strikethrough") { model.wrap("~~") }
          tool("Code", "chevron.left.forwardslash.chevron.right") { model.wrap("`") }
          tool("Link (⌘K)", "link") { model.link() }.keyboardShortcut("k")
        }
        separator
        group("Paragraph") {
          tool("Bulleted List", "list.bullet") { model.perform(.named("Bulleted List")) }
          tool("Numbered List", "list.number") { model.perform(.named("Numbered List")) }
          tool("Task List", "checklist") { model.perform(.named("Task List")) }
          tool("Quote", "text.quote") { model.perform(.named("Quote")) }
          tool("Toggle", "chevron.right.square") { model.perform(.named("Toggle")) }
        }
        separator
        group("Insert") {
          tool("Code Block", "curlybraces") { model.perform(.named("Code Block")) }
          tool("Table", "tablecells") { model.perform(.named("Table")) }
          tool("Divider", "minus") { model.perform(.named("Divider")) }
          tool("Link Preview", "rectangle.and.text.magnifyingglass") { model.perform(.named("Link Preview")) }
          tool("Link Card", "rectangle.portrait.and.arrow.right") { model.perform(.named("Link Card")) }
          tool("Link to Doc ([[)", "arrow.up.right.square") { model.perform(.named("Link to Doc")) }
          tool("Image", "photo") { model.perform(.named("Image")) }
          tool("File", "paperclip") { model.perform(.named("File")) }
        }
      }
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .background(.bar)
    // The ribbon writes at the editor's cursor, so it waits until the Markdown has the focus.
    .disabled(!model.editorFocused)
  }

  private var separator: some View {
    Divider().frame(height: 40)
  }

  private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    VStack(spacing: 4) {
      HStack(spacing: 2) { content() }
      Text(title).font(.caption2).foregroundStyle(.secondary)
    }
  }

  private func tool(_ name: String, _ symbol: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Image(systemName: symbol)
        .font(.system(size: 14))
        .frame(width: 28, height: 26)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .help(name)
    .accessibilityLabel(name)
  }
}
