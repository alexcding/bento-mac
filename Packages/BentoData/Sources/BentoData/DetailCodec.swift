import Foundation

/// Compressed detail Markdown, identical to `bento_domain::detail`: one codec byte, then the
/// payload. `0x01` is raw DEFLATE, which `NSData.CompressionAlgorithm.zlib` reads and writes.
public enum DetailCodec {
  public enum Error: Swift.Error, Equatable {
    case empty
    case unknownCodec(UInt8)
    case corrupt
    case notUTF8
  }

  static let deflate: UInt8 = 0x01

  public static func encode(_ markdown: String) throws -> Data {
    let compressed = try (Data(markdown.utf8) as NSData).compressed(using: .zlib) as Data
    return Data([deflate]) + compressed
  }

  public static func decode(_ blob: Data) throws -> String {
    guard let codec = blob.first else { throw Error.empty }
    guard codec == deflate else { throw Error.unknownCodec(codec) }
    let payload = blob.dropFirst()
    guard let bytes = try? (Data(payload) as NSData).decompressed(using: .zlib) as Data else {
      throw Error.corrupt
    }
    guard let text = String(data: bytes, encoding: .utf8) else { throw Error.notUTF8 }
    return text
  }
}
