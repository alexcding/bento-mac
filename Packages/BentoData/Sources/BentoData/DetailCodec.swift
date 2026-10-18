import Foundation

/// An item's long-form content in the format it was written in.
public struct DetailContent: Equatable, Sendable {
  public enum Format: UInt8, Sendable {
    case markdown = 0
    case html = 1
    case text = 2
    /// A web address to open.
    case link = 3
  }

  public var format: Format
  public var body: String

  public init(format: Format, body: String) {
    self.format = format
    self.body = body
  }
}

/// Compressed detail, identical to `bento_domain::detail`: one codec byte, then the payload. `0x01`
/// is raw DEFLATE of Markdown, which `NSData.CompressionAlgorithm.zlib` reads and writes; `0x02` is
/// a format byte, then raw DEFLATE of the body.
public enum DetailCodec {
  public enum Error: Swift.Error, Equatable {
    case empty
    case unknownCodec(UInt8)
    case unknownFormat(UInt8)
    case corrupt
    case notUTF8
  }

  static let deflate: UInt8 = 0x01
  static let deflateFormatted: UInt8 = 0x02

  public static func encode(_ markdown: String) throws -> Data {
    try encode(DetailContent(format: .markdown, body: markdown))
  }

  /// Compresses as is: the collector (`bento_domain::detail`) applies the length limits. Markdown
  /// keeps the original codec, so older apps still read it.
  public static func encode(_ detail: DetailContent) throws -> Data {
    let compressed = try (Data(detail.body.utf8) as NSData).compressed(using: .zlib) as Data
    let header = detail.format == .markdown ? Data([deflate]) : Data([deflateFormatted, detail.format.rawValue])
    return header + compressed
  }

  public static func decode(_ blob: Data) throws -> DetailContent {
    guard let codec = blob.first else { throw Error.empty }
    let format: DetailContent.Format
    let payload: Data
    switch codec {
    case deflate:
      format = .markdown
      payload = blob.dropFirst()
    case deflateFormatted:
      guard let byte = blob.dropFirst().first else { throw Error.empty }
      guard let parsed = DetailContent.Format(rawValue: byte) else { throw Error.unknownFormat(byte) }
      format = parsed
      payload = blob.dropFirst(2)
    default:
      throw Error.unknownCodec(codec)
    }
    guard let bytes = try? (Data(payload) as NSData).decompressed(using: .zlib) as Data else {
      throw Error.corrupt
    }
    guard let text = String(data: bytes, encoding: .utf8) else { throw Error.notUTF8 }
    return DetailContent(format: format, body: text)
  }
}
