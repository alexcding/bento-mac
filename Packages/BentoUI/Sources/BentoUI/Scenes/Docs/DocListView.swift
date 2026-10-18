import BentoData
import SwiftUI

/// The docs for the sidebar selection, with search, a new-doc button and file import. Files
/// dropped on the list are imported too.
struct DocListView: View {
  @Bindable var model: DocListViewModel
  @State private var importing = false

  var body: some View {
    Group {
      if model.docs.isEmpty {
        ContentUnavailableView {
          Label(model.search.isEmpty ? "No docs yet" : "No results", systemImage: model.search.isEmpty ? "doc.text" : "magnifyingglass")
        } description: {
          if model.search.isEmpty { Text("Write a doc, or import Markdown, PDFs and other files.") }
        } actions: {
          if model.search.isEmpty {
            Button("New Doc") { model.addDoc() }
            Button("Import…") { importing = true }
          }
        }
      } else {
        List(selection: $model.selectedDocID) {
          ForEach(model.docs) { doc in
            DocRow(doc: doc, snippet: model.snippets[doc.id])
              .draggable(DocDrag.payload(doc.id))
              .tag(doc.id)
              .contextMenu { rowMenu(doc) }
          }
        }
        .listStyle(.plain)
      }
    }
    .navigationTitle(model.title)
    .searchable(text: $model.search, prompt: "Search docs")
    .toolbar {
      ToolbarItemGroup {
        Button("Import", systemImage: "square.and.arrow.down") { importing = true }
        Menu {
          Button("Blank Doc", systemImage: "doc") { model.addDoc() }
          Divider()
          ForEach(DocTemplate.all) { template in
            Button(template.name, systemImage: template.symbol) { model.addDoc(from: template) }
          }
        } label: {
          Label("New Doc", systemImage: "square.and.pencil")
        } primaryAction: {
          model.addDoc()
        }
        .help("New doc (⌘N); hold for templates")
        .keyboardShortcut("n")
      }
    }
    .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
      if case .success(let urls) = result { Task { await model.importFiles(urls) } }
    }
    .dropDestination(for: URL.self) { urls, _ in
      let files = urls.filter(\.isFileURL)
      Task { await model.importFiles(files) }
      return !files.isEmpty
    }
    .task(id: model.search) { await model.reload() }
    .task(id: model.docs.map(\.updatedAt)) { await model.refreshSnippets() }
  }

  @ViewBuilder
  private func rowMenu(_ doc: Doc) -> some View {
    Button(doc.isStarred ? "Unstar" : "Star") { model.toggleStarred(doc) }
    Menu("Move To") {
      Button("No Folder") { model.move(doc, to: nil) }
        .disabled(doc.folderID == nil)
      ForEach(model.folders) { folder in
        Button(folder.name) { model.move(doc, to: folder.id) }
          .disabled(doc.folderID == folder.id)
      }
    }
    Divider()
    Button("Delete", role: .destructive) { model.delete(doc) }
  }
}

/// A doc in the list: its title, the start of its text, and when it was last edited.
private struct DocRow: View {
  let doc: Doc
  let snippet: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 4) {
        Text(doc.title.isEmpty ? "Untitled" : doc.title)
          .font(.body.weight(.semibold))
          .foregroundStyle(doc.title.isEmpty ? .secondary : .primary)
          .lineLimit(1)
        Spacer(minLength: 0)
        if doc.isStarred {
          Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small)
        }
      }
      Text(snippet?.nonEmpty ?? "No text yet")
        .font(.callout)
        .foregroundStyle(snippet?.isEmpty == false ? .secondary : .tertiary)
        .lineLimit(2)
      Text(doc.updatedAt.formatted(.relative(presentation: .named)))
        .font(.caption)
        .foregroundStyle(.tertiary)
    }
    .padding(.vertical, 6)
  }
}
