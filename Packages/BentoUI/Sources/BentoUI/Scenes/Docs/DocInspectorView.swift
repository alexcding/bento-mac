import BentoData
import SwiftUI

/// Craft's side panel: Insert adds blocks after the current one, Format styles the selected
/// blocks, Info shows the docs linking here and the doc's size.
struct DocInspectorView: View {
  let model: DocEditorViewModel
  @State private var tab = Tab.format
  @State private var search = ""
  @State private var coverPicking = false

  enum Tab: String, CaseIterable {
    case insert = "Insert"
    case format = "Format"
    case info = "Info"
  }

  var body: some View {
    VStack(spacing: 0) {
      Picker("Panel", selection: $tab) {
        ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(12)
      Divider()
      ScrollView {
        VStack(alignment: .leading, spacing: 18) {
          switch tab {
          case .insert: insertPanel
          case .format: formatPanel
          case .info: infoPanel
          }
        }
        .padding(14)
      }
    }
  }

  // MARK: Insert

  @ViewBuilder
  private var insertPanel: some View {
    Text("Adds after the current block. Type / in the doc for the same list, or drop files on it.")
      .font(.caption)
      .foregroundStyle(.secondary)
    TextField("Search", text: $search)
      .textFieldStyle(.roundedBorder)
    let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
    ForEach(DocEditorViewModel.insertSections, id: \.0) { title, items in
      let shown = needle.isEmpty ? items : items.filter { item in
        item.name.lowercased().contains(needle) || item.keywords.contains { $0.hasPrefix(needle) }
      }
      if !shown.isEmpty {
        PanelSection(title) {
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
            ForEach(shown) { item in
              Button {
                model.insert(item.insertion)
              } label: {
                VStack(spacing: 6) {
                  Image(systemName: item.symbol)
                    .font(.title3)
                    .frame(width: 52, height: 44)
                    .background(.background, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                  Text(item.name).font(.caption).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
              }
              .buttonStyle(.plain)
            }
          }
        }
      }
    }
  }

  // MARK: Format

  @ViewBuilder
  private var formatPanel: some View {
    let block = model.focusedBlock
    if block == nil {
      Text("Click into a block to style it.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    Group {
      PanelSection("Titles") {
        HStack(spacing: 6) {
          StyleButton("Title", font: .headline.weight(.heavy), on: block?.kind == .title) { model.setKind(.title) }
          StyleButton("Subtitle", font: .headline, on: block?.kind == .subtitle) { model.setKind(.subtitle) }
          StyleButton("Heading", font: .subheadline.weight(.semibold), on: block?.kind == .heading) { model.setKind(.heading) }
        }
      }
      PanelSection("Content") {
        HStack(spacing: 6) {
          StyleButton("Strong", font: .body.weight(.semibold), on: block?.kind == .strong) { model.setKind(.strong) }
          StyleButton("Body", font: .body, on: block?.kind == .text) { model.setKind(.text) }
          StyleButton("Caption", font: .caption, on: block?.kind == .caption) { model.setKind(.caption) }
        }
      }
      PanelSection("Groups") {
        HStack(spacing: 6) {
          StyleButton("Page", symbol: "doc.text", on: block?.kind == .page) { model.setKind(.page) }
          StyleButton("Card", symbol: "rectangle.portrait.on.rectangle.portrait", on: block?.kind == .card) { model.setKind(.card) }
        }
      }
      VStack(spacing: 6) {
        SegmentRow {
          SymbolButton("bold", help: "Bold (⌘B)") { model.toggleInline(.bold) }
          SymbolButton("italic", help: "Italic (⌘I)") { model.toggleInline(.italic) }
          SymbolButton("strikethrough", help: "Strikethrough (⇧⌘X)") { model.toggleInline(.strike) }
          SymbolButton("chevron.left.forwardslash.chevron.right", help: "Inline code (⌘E)") { model.toggleInline(.code) }
        }
        SegmentRow {
          SymbolButton("checkmark.square", help: "To-do", on: block?.kind == .todo) { model.setKind(.todo) }
          SymbolButton("play.fill", help: "Toggle", on: block?.kind == .toggle) { model.setKind(.toggle) }
          SymbolButton("list.bullet", help: "Bulleted list", on: block?.kind == .bullet) { model.setKind(.bullet) }
          SymbolButton("list.number", help: "Numbered list", on: block?.kind == .numbered) { model.setKind(.numbered) }
        }
        HStack(spacing: 6) {
          SegmentRow {
            SymbolButton("decrease.indent", help: "Outdent (⇧Tab)") { indent(-1) }
              .disabled((block?.indent ?? 0) == 0)
            SymbolButton("increase.indent", help: "Indent (Tab)") { indent(1) }
          }
          .frame(maxWidth: 110)
          SegmentRow {
            ForEach(DocBlock.Alignment.allCases, id: \.self) { alignment in
              SymbolButton(alignment.symbol, help: alignment.name, on: block?.alignment == alignment) {
                model.setAlignment(alignment)
              }
            }
          }
        }
      }
      PanelSection("Decorations") {
        HStack(spacing: 6) {
          StyleButton("Focus", symbol: "rectangle.portrait.fill", on: block?.decoration == .focus) { model.toggleDecoration(.focus) }
          StyleButton("Block", on: block?.decoration == .block) { model.toggleDecoration(.block) }
        }
      }
      PanelSection("Color") {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 6), spacing: 8) {
          ForEach(DocBlock.BlockColor.allCases, id: \.self) { color in
            Button {
              model.setColor(color)
            } label: {
              Circle()
                .fill(color == .standard ? AnyShapeStyle(.primary) : AnyShapeStyle(color.tint))
                .frame(width: 26, height: 26)
                .overlay {
                  if block?.color == color {
                    Circle().strokeBorder(.background, lineWidth: 3).padding(2)
                  }
                }
            }
            .buttonStyle(.plain)
            .help(color.name)
          }
        }
      }
      PanelSection("Font") {
        HStack(spacing: 6) {
          ForEach(DocBlock.BlockFont.allCases, id: \.self) { font in
            Button {
              model.setFont(font)
            } label: {
              VStack(spacing: 2) {
                Text(font.sample).font(.system(.title3, design: font.design))
                Text(font.name).font(.caption2).foregroundStyle(.secondary)
              }
              .frame(maxWidth: .infinity, minHeight: 48)
              .background(PanelPlate(on: block?.font == font))
            }
            .buttonStyle(.plain)
          }
        }
      }
    }
    .disabled(block == nil)
  }

  private func indent(_ offset: Int) {
    let ids = model.selectedBlockIDs.isEmpty ? model.focusedBlockID.map { [$0] } ?? [] : model.selectedBlockIDs
    model.indent(ids, by: offset)
  }

  // MARK: Info

  @ViewBuilder
  private var infoPanel: some View {
    let counts = model.counts
    PanelSection("Cover") {
      HStack(spacing: 8) {
        Button(model.cover == nil ? "Add Cover…" : "Change Cover…") { coverPicking = true }
        if model.cover != nil {
          Button("Remove", role: .destructive) { Task { await model.removeCover() } }
        }
      }
      .fileImporter(isPresented: $coverPicking, allowedContentTypes: [.image]) { result in
        if case .success(let url) = result { Task { await model.setCover(from: url) } }
      }
    }
    PanelSection("Linked from") {
      if model.backlinks.isEmpty {
        Text("No docs link here yet. Type [[ in another doc to link to this one.")
          .font(.caption)
          .foregroundStyle(.secondary)
      } else {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(model.backlinks) { doc in
            Button {
              model.openDoc(doc.id)
            } label: {
              Label(doc.title.isEmpty ? "Untitled" : doc.title, systemImage: "arrow.turn.up.left")
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tint)
          }
        }
      }
    }
    PanelSection("Doc") {
      Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
        GridRow {
          Text("Words").foregroundStyle(.secondary)
          Text(counts.words.formatted())
        }
        GridRow {
          Text("Characters").foregroundStyle(.secondary)
          Text(counts.characters.formatted())
        }
        if let doc = model.doc {
          GridRow {
            Text("Created").foregroundStyle(.secondary)
            Text(doc.createdAt.formatted(date: .abbreviated, time: .shortened))
          }
          GridRow {
            Text("Edited").foregroundStyle(.secondary)
            Text(doc.updatedAt.formatted(.relative(presentation: .named)))
          }
        }
      }
      .font(.callout)
    }
  }
}

private struct PanelSection<Content: View>: View {
  let title: String
  @ViewBuilder let content: Content

  init(_ title: String, @ViewBuilder content: () -> Content) {
    self.title = title
    self.content = content()
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      content
    }
  }
}

/// The plate behind a panel button, highlighted when its style is the block's.
private struct PanelPlate: View {
  let on: Bool

  var body: some View {
    RoundedRectangle(cornerRadius: 8)
      .fill(on ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.quaternary.opacity(0.6)))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear)))
  }
}

private struct StyleButton: View {
  let title: String
  var font: Font = .body
  var symbol: String?
  let on: Bool
  let action: () -> Void

  init(_ title: String, font: Font = .body, symbol: String? = nil, on: Bool, action: @escaping () -> Void) {
    self.title = title
    self.font = font
    self.symbol = symbol
    self.on = on
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      HStack(spacing: 6) {
        if let symbol { Image(systemName: symbol) }
        Text(title).font(font).lineLimit(1).minimumScaleFactor(0.8)
      }
      .frame(maxWidth: .infinity, minHeight: 36)
      .background(PanelPlate(on: on))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

private struct SegmentRow<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 0) { content }
      .frame(maxWidth: .infinity, minHeight: 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.6)))
  }
}

private struct SymbolButton: View {
  let symbol: String
  let help: String
  var on = false
  let action: () -> Void

  init(_ symbol: String, help: String, on: Bool = false, action: @escaping () -> Void) {
    self.symbol = symbol
    self.help = help
    self.on = on
    self.action = action
  }

  var body: some View {
    Button(action: action) {
      Image(systemName: symbol)
        .frame(maxWidth: .infinity, minHeight: 32)
        .background(on ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(help)
  }
}

extension DocBlock.Alignment {
  var symbol: String {
    switch self {
    case .leading: "text.alignleft"
    case .center: "text.aligncenter"
    case .trailing: "text.alignright"
    case .justified: "text.justify"
    }
  }

  var name: String {
    switch self {
    case .leading: "Align left"
    case .center: "Center"
    case .trailing: "Align right"
    case .justified: "Justify"
    }
  }
}

extension DocBlock.BlockColor {
  var name: String {
    switch self {
    case .standard: "Default"
    case .gray: "Gray"
    case .lightGray: "Light gray"
    case .purple: "Purple"
    case .blue: "Blue"
    case .cyan: "Cyan"
    case .teal: "Teal"
    case .green: "Green"
    case .yellow: "Yellow"
    case .orange: "Orange"
    case .red: "Red"
    }
  }
}

extension DocBlock.BlockFont {
  var name: String {
    switch self {
    case .system: "System"
    case .serif: "Serif"
    case .mono: "Mono"
    case .rounded: "Round"
    }
  }

  var sample: String {
    switch self {
    case .system: "Aa"
    case .serif: "Ss"
    case .mono: "00"
    case .rounded: "Rr"
    }
  }
}
