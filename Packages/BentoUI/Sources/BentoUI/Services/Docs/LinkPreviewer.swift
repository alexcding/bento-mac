import BentoData
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Fetches what a link block shows: the page's title, description, site and image.
public protocol LinkPreviewing: Sendable {
  func preview(for url: URL) async throws -> LinkMetadata
}

public struct NativeLinkPreviewer: LinkPreviewing {
  /// Enough of a page to reach the end of its `<head>`.
  static let maxPageBytes = 512 * 1024
  static let maxImageBytes = 8 * 1024 * 1024
  /// Preview images are scaled to fit this many pixels on the long side before they are kept.
  static let imagePixels = 900

  private let session: URLSession

  public init(session: URLSession = .shared) {
    self.session = session
  }

  public func preview(for url: URL) async throws -> LinkMetadata {
    let known = Self.knownOEmbed(for: url)
    let page: Data
    let response: URLResponse
    do {
      (page, response) = try await fetch(url, limit: Self.maxPageBytes)
    } catch {
      // Sites like X refuse plain requests for their pages but answer their oEmbed endpoint.
      guard let known else { throw error }
      var metadata = LinkMetadata(siteName: url.host() ?? "")
      metadata.merge(oEmbed: try await fetch(known, limit: Self.maxPageBytes).0)
      if let imageURL = metadata.imageURL, let (data, _) = try? await fetch(imageURL, limit: Self.maxImageBytes, wholeBody: true) {
        metadata.image = Self.thumbnail(data) ?? Data()
      }
      return metadata
    }
    let pageURL = response.url ?? url
    // A link straight to an image previews as that image.
    if let type = response.mimeType.flatMap({ UTType(mimeType: $0) }), type.conforms(to: .image) {
      return LinkMetadata(
        title: pageURL.lastPathComponent, siteName: pageURL.host() ?? "", image: Self.thumbnail(page) ?? Data()
      )
    }
    let html = String(decoding: page, as: UTF8.self)
    var metadata = LinkMetadata.parse(html: html, url: pageURL)
    // Some sites show a consent or sign-in wall instead of their tags; their oEmbed still answers.
    if let oEmbed = known ?? (metadata.summary.isEmpty || metadata.imageURL == nil ? metadata.oEmbedURL : nil),
      let (json, _) = try? await fetch(oEmbed, limit: Self.maxPageBytes)
    {
      metadata.merge(oEmbed: json)
    }
    if metadata.title.isEmpty { metadata.title = pageURL.host() ?? url.absoluteString }
    if let imageURL = metadata.imageURL,
      let (data, _) = try? await fetch(imageURL, limit: Self.maxImageBytes, wholeBody: true)
    {
      metadata.image = Self.thumbnail(data) ?? Data()
    }
    return metadata
  }

  /// The oEmbed endpoints of sites that hide their preview tags from a plain request.
  static func knownOEmbed(for url: URL) -> URL? {
    let host = url.host()?.lowercased().replacingOccurrences(of: "www.", with: "") ?? ""
    let endpoint: String? = switch host {
    case "youtube.com", "m.youtube.com", "youtu.be", "music.youtube.com": "https://www.youtube.com/oembed"
    case "x.com", "twitter.com", "mobile.twitter.com": "https://publish.twitter.com/oembed"
    default: nil
    }
    guard let endpoint, var components = URLComponents(string: endpoint) else { return nil }
    components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString), URLQueryItem(name: "format", value: "json")]
    return components.url
  }

  /// Reads at most `limit` bytes. Many sites only serve their preview tags to a browser, so the
  /// request says it is one.
  private func fetch(_ url: URL, limit: Int, wholeBody: Bool = false) async throws -> (Data, URLResponse) {
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("text/html,application/xhtml+xml,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    if wholeBody {
      // Images come in one read; most are far under the limit, and larger ones are not kept.
      let (data, response) = try await session.data(for: request)
      try Self.check(response)
      guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
      return (data, response)
    }
    // A page streams until enough of it has come for its `<head>`.
    let (bytes, response) = try await session.bytes(for: request)
    try Self.check(response)
    var data = Data()
    data.reserveCapacity(limit)
    for try await byte in bytes {
      data.append(byte)
      if data.count >= limit { break }
    }
    return (data, response)
  }

  private static func check(_ response: URLResponse) throws {
    if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
      throw URLError(.badServerResponse)
    }
  }

  /// The image scaled down and saved as JPEG, so a synced preview stays small.
  static func thumbnail(_ data: Data, maxPixels: Int = imagePixels) -> Data? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
      ] as CFDictionary)
    else { return nil }
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
    return CGImageDestinationFinalize(destination) ? output as Data : nil
  }
}
