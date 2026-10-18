import BentoData
import SwiftUI
import UniformTypeIdentifiers

/// An embedded block inside the text: separator, file or image, page, card, table or link card.
/// It reports its height, so the text lays out around it.
struct DocAttachmentView: View {
  let model: DocEditorViewModel
  let blockID: DocBlock.ID
  let resized: (CGFloat) -> Void

  var body: some View {
    Group {
      if let block = model.block(blockID) {
        content(block)
          .frame(maxWidth: .infinity, alignment: block.alignment.frame)
          .contextMenu { menu(block) }
      }
    }
    .fixedSize(horizontal: false, vertical: true)
    .onGeometryChange(for: CGFloat.self, of: \.size.height) { resized($0) }
  }

  @ViewBuilder
  private func content(_ block: DocBlock) -> some View {
    switch block.kind {
    case .divider: SeparatorView(weight: block.lineWeight)
    case .file: DocFileView(model: model, block: block)
    case .page: PageRow(title: model.pageTitle(block.id)) { model.open(block.id) }
    case .card: CardView(title: model.pageTitle(block.id), color: block.color) { model.open(block.id) }
    case .table: DocTableView(model: model, blockID: block.id)
    case .link: LinkPreviewCard(model: model, block: block)
    default: EmptyView()
    }
  }

  @ViewBuilder
  private func menu(_ block: DocBlock) -> some View {
    if block.kind.holdsDoc { Button("Open") { model.open(block.id) } }
    if block.kind == .file { Button("Open File") { model.preview(block.id) } }
    Button("Move Up") { model.move(block.id, by: -1) }
    Button("Move Down") { model.move(block.id, by: 1) }
    Divider()
    Button("Delete", role: .destructive) { model.remove(block.id) }
  }

  /// A first guess at a block's height, before its view has measured itself.
  static func estimatedHeight(_ kind: DocBlock.Kind, table: DocTable) -> CGFloat {
    switch kind {
    case .divider: 24
    case .page: 30
    case .card: 118
    case .link: 116
    case .file: 64
    case .table: CGFloat(table.rows.count) * 33 + 36
    default: 44
    }
  }
}

/// Craft's four separator weights.
struct SeparatorView: View {
  let weight: DocBlock.LineWeight

  var body: some View {
    Group {
      switch weight {
      case .extraLight:
        Text("•  •  •").foregroundStyle(.tertiary).frame(maxWidth: .infinity)
      case .light:
        Line().stroke(.tertiary, style: StrokeStyle(lineWidth: 1, dash: [2, 3])).frame(height: 1)
      case .regular:
        Rectangle().fill(.separator).frame(height: 1)
      case .strong:
        Rectangle().fill(.primary.opacity(0.7)).frame(height: 2)
      }
    }
    .padding(.vertical, 10)
  }

  private struct Line: Shape {
    func path(in rect: CGRect) -> Path {
      Path { path in
        path.move(to: CGPoint(x: 0, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      }
    }
  }
}

/// A page block: a line that opens the doc inside it.
struct PageRow: View {
  let title: String
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 8) {
        Image(systemName: "doc.text").foregroundStyle(.secondary)
        Text(title).fontWeight(.medium).underline(color: .secondary.opacity(0.4))
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .padding(.vertical, 3)
  }
}

/// A card block: a tile that opens the doc inside it.
struct CardView: View {
  let title: String
  let color: DocBlock.BlockColor
  let open: () -> Void

  var body: some View {
    let tint = color == .standard ? Color.accentColor : color.tint
    Button(action: open) {
      VStack(alignment: .leading, spacing: 0) {
        LinearGradient(colors: [tint, tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
          .frame(height: 54)
        HStack {
          Text(title).font(.headline).lineLimit(2)
          Spacer(minLength: 0)
          Image(systemName: "chevron.forward").foregroundStyle(.tertiary)
        }
        .padding(12)
      }
      .background(.background)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
      .frame(maxWidth: 420)
    }
    .buttonStyle(.plain)
    .padding(.vertical, 4)
  }
}

/// A table block: a grid of cells, the first row the header.
struct DocTableView: View {
  let model: DocEditorViewModel
  let blockID: DocBlock.ID

  var body: some View {
    let table = model.table(blockID)
    VStack(alignment: .leading, spacing: 6) {
      Grid(horizontalSpacing: 0, verticalSpacing: 0) {
        ForEach(table.rows.indices, id: \.self) { row in
          GridRow {
            ForEach(table.rows[row].indices, id: \.self) { column in
              TextField(
                "",
                text: Binding(
                  get: { model.table(blockID).rows[safe: row]?[safe: column] ?? "" },
                  set: { model.setCell(blockID, row: row, column: column, $0) }
                ),
                axis: .vertical
              )
              .textFieldStyle(.plain)
              .fontWeight(row == 0 ? .semibold : .regular)
              .padding(6)
              .frame(minWidth: 80, maxWidth: .infinity, alignment: .leading)
              .background(row == 0 ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
              .border(.separator, width: 0.5)
              .contextMenu {
                Button("Delete Row") { model.removeRow(blockID, row) }
                Button("Delete Column") { model.removeColumn(blockID, column) }
              }
            }
          }
        }
      }
      HStack(spacing: 12) {
        Button("Row", systemImage: "plus") { model.addRow(blockID) }
        Button("Column", systemImage: "plus") { model.addColumn(blockID) }
      }
      .buttonStyle(.borderless)
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
  }
}

/// An attached file: an image shows inline; anything else is a card that opens in Quick Look.
struct DocFileView: View {
  let model: DocEditorViewModel
  let block: DocBlock
  @State private var image: Image?

  var body: some View {
    Group {
      if let image {
        image
          .resizable()
          .scaledToFit()
          .frame(maxHeight: 460)
          .clipShape(RoundedRectangle(cornerRadius: 8))
      } else {
        HStack(spacing: 10) {
          Image(systemName: symbol).font(.title2).foregroundStyle(.secondary)
          Text(block.text).lineLimit(1)
          Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: 360, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      }
    }
    .contentShape(Rectangle())
    .onTapGesture(count: 2) { model.preview(block.id) }
    .help("Double-click to open \(block.text)")
    // Keyed on the file being there: it can sync in after its block.
    .task(id: model.fileBlockIDs.contains(block.id)) { image = await model.image(block.id) }
  }

  private var symbol: String {
    guard let type = UTType(filenameExtension: (block.text as NSString).pathExtension) else { return "doc" }
    if type.conforms(to: .pdf) { return "doc.richtext" }
    if type.conforms(to: .audio) { return "waveform" }
    if type.conforms(to: .movie) { return "film" }
    if type.conforms(to: .text) { return "doc.text" }
    return "doc"
  }
}

/// A link as Craft's smart link shows it: the page's image, title, description and site. Clicking
/// it opens the page; the preview is fetched the first time the link is shown.
struct LinkPreviewCard: View {
  let model: DocEditorViewModel
  let block: DocBlock
  @Environment(\.openURL) private var openURL
  @State private var editing = false
  @State private var draft = ""

  var body: some View {
    let preview = model.linkPreview(block.id)
    let url = URL(string: block.text)
    Button {
      if let url, url.host() != nil { openURL(url) } else { startEditing() }
    } label: {
      HStack(alignment: .top, spacing: 0) {
        VStack(alignment: .leading, spacing: 4) {
          Text(preview?.title.nonEmpty ?? url?.host() ?? (block.text.isEmpty ? "Paste a link" : block.text))
            .font(.headline)
            .lineLimit(2)
          if let summary = preview?.summary.nonEmpty {
            Text(summary).font(.subheadline).foregroundStyle(.secondary).lineLimit(3)
          }
          Spacer(minLength: 0)
          HStack(spacing: 5) {
            if model.fetchingPreviews.contains(block.id) {
              ProgressView().controlSize(.mini)
            } else {
              Image(systemName: "globe").imageScale(.small)
            }
            Text(preview?.siteName.nonEmpty ?? url?.host() ?? "").lineLimit(1)
          }
          .font(.caption)
          .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        if let image = preview.flatMap({ PlatformImage.make($0.image) }) {
          image.resizable().scaledToFill().frame(width: 150, height: 108).clipped()
        }
      }
      .frame(maxWidth: 560, alignment: .leading)
      .background(.background)
      .clipShape(RoundedRectangle(cornerRadius: 10))
      .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
      .contentShape(RoundedRectangle(cornerRadius: 10))
    }
    .buttonStyle(.plain)
    .help(block.text)
    .padding(.vertical, 4)
    .contextMenu {
      Button("Edit Link") { startEditing() }
      Button("Refresh Preview") { Task { await model.loadPreview(block.id, force: true) } }
      Button("Copy Link") { copyToPasteboard(block.text) }
    }
    .popover(isPresented: $editing) {
      HStack {
        TextField("https://", text: $draft)
          .textFieldStyle(.roundedBorder)
          .frame(minWidth: 280)
          .onSubmit(commit)
        Button("Done", action: commit)
      }
      .padding()
    }
    .task(id: block.text) {
      // Wait out a link still being pasted or typed before fetching.
      try? await Task.sleep(for: .milliseconds(300))
      guard !Task.isCancelled else { return }
      await model.loadPreview(block.id)
    }
    .onAppear { if block.text.isEmpty { startEditing() } }
  }

  private func startEditing() {
    draft = block.text
    editing = true
  }

  private func commit() {
    editing = false
    model.setLink(block.id, draft)
  }
}

/// Builds a SwiftUI image from image data on either platform.
enum PlatformImage {
  static func make(_ data: Data) -> Image? {
    guard !data.isEmpty else { return nil }
    #if os(macOS)
      return NSImage(data: data).map(Image.init(nsImage:))
    #else
      return UIImage(data: data).map(Image.init(uiImage:))
    #endif
  }
}

func copyToPasteboard(_ text: String) {
  #if os(macOS)
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  #else
    UIPasteboard.general.string = text
  #endif
}

extension String {
  var nonEmpty: String? { isEmpty ? nil : self }
}

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

extension DocBlock.Alignment {
  var frame: SwiftUI.Alignment {
    switch self {
    case .leading, .justified: .leading
    case .center: .center
    case .trailing: .trailing
    }
  }
}

extension DocBlock.BlockFont {
  var design: Font.Design {
    switch self {
    case .system: .default
    case .serif: .serif
    case .mono: .monospaced
    case .rounded: .rounded
    }
  }
}

extension DocBlock.BlockColor {
  var tint: Color {
    switch self {
    case .standard: .primary
    case .gray: .gray
    case .lightGray: Color.gray.opacity(0.55)
    case .purple: .purple
    case .blue: .blue
    case .cyan: .cyan
    case .teal: .teal
    case .green: .green
    case .yellow: .yellow
    case .orange: .orange
    case .red: .red
    }
  }
}
