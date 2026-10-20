import BentoData
import Foundation
import ImageIO
import Synchronization
import UniformTypeIdentifiers

/// Downloads the images of saved articles: public web addresses only, at most `maxBytes` each,
/// stored as JPEG XL like any other image in a doc. Runs off the main thread.
enum DocImageDownloader {
  static let maxImages = 30
  static let maxBytes = 15 * 1024 * 1024

  /// Images downloading, by doc and address, so a second fetch meanwhile does not fetch them twice.
  private static let inFlight = Mutex<Set<String>>([])

  static func start(_ key: String) -> Bool { inFlight.withLock { $0.insert(key).inserted } }
  static func finish(_ key: String) { _ = inFlight.withLock { $0.remove(key) } }

  /// The image at `address`, as JPEG XL where that loses nothing unless `encode` is off (for one
  /// only shown, not kept). It downloads to a file rather than into memory, so the size limit is
  /// checked before the image is read.
  static func download(_ address: String, encode: Bool = true, session: URLSession = .shared) async throws -> DocFileData {
    guard let url = URL(string: address), await NativeLinkPreviewer.isPublicWebResolved(url) else {
      throw URLError(.unsupportedURL)
    }
    var request = URLRequest(url: url, timeoutInterval: 30)
    request.setValue("image/*", forHTTPHeaderField: "Accept")
    let (file, response) = try await session.download(for: request, delegate: PublicWebRedirects())
    defer { try? FileManager.default.removeItem(at: file) }
    // Storage services often call any file `application/octet-stream`, so what the server says
    // only rules out pages; the data itself tells what the image is.
    let served = response.mimeType.flatMap { UTType(mimeType: $0) }
    let declared = [served, UTType(filenameExtension: url.pathExtension)].compactMap { $0 }.first { $0.conforms(to: .image) }
    let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
    guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
      declared != nil || served.map({ !$0.conforms(to: .text) }) ?? true
    else { throw URLError(.cannotDecodeContentData) }
    guard size <= maxBytes else { throw URLError(.dataLengthExceedsMaximum) }
    let data = try Data(contentsOf: file)
    guard let type = CGImageSourceCreateWithData(data as CFData, nil).flatMap(CGImageSourceGetType).flatMap({ UTType($0 as String) }),
      type.conforms(to: .image)
    else { throw URLError(.cannotDecodeContentData) }
    let name = url.lastPathComponent.isEmpty || url.lastPathComponent == "/" ? "image" : url.lastPathComponent
    let image = DocFileData(name: name, type: type, data: data)
    return encode ? DocImageEncoder.encode(image) : image
  }
}
