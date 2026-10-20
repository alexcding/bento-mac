import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
  typealias PlatformFont = NSFont
#else
  import UIKit
  typealias PlatformFont = UIFont
#endif

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
