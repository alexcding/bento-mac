import BentoData
import Darwin
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
      (page, response) = try await fetch(url)
    } catch {
      // Sites like X refuse plain requests for their pages but answer their oEmbed endpoint.
      guard let known else { throw error }
      var metadata = LinkMetadata(siteName: url.host() ?? "")
      metadata.merge(oEmbed: try await fetch(known).0)
      if let imageURL = metadata.imageURL, let (data, _) = try? await fetch(imageURL, as: .image) {
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
      let (json, _) = try? await fetch(oEmbed)
    {
      metadata.merge(oEmbed: json)
    }
    if metadata.title.isEmpty { metadata.title = pageURL.host() ?? url.absoluteString }
    if let imageURL = metadata.imageURL,
      let (data, _) = try? await fetch(imageURL, as: .image)
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

  enum Expected { case page, image }

  /// Reads a page (as far as `maxPageBytes`, enough for its `<head>`) or an image (whole, up to
  /// `maxImageBytes`; a larger one is refused rather than cut off). An address may turn out to be
  /// an image whatever was expected; one fetched as an image is read whole whatever the server
  /// calls it. Only public web addresses are fetched, redirects included: a page cannot point
  /// Bento at a file on this device or at the local network. Many sites only serve their preview
  /// tags to a browser, so the request says it is one.
  private func fetch(_ url: URL, as expected: Expected = .page) async throws -> (Data, URLResponse) {
    guard await Self.isPublicWebResolved(url) else { throw URLError(.unsupportedURL) }
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.setValue(
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15",
      forHTTPHeaderField: "User-Agent"
    )
    request.setValue("text/html,application/xhtml+xml,image/*;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
    // An image is read whole: to a file first, so its size is checked before it is in memory.
    if expected == .image {
      let (file, response) = try await session.download(for: request, delegate: PublicWebRedirects())
      defer { try? FileManager.default.removeItem(at: file) }
      try Self.check(response)
      let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? .max
      guard size <= Self.maxImageBytes else { throw URLError(.dataLengthExceedsMaximum) }
      return (try Data(contentsOf: file), response)
    }
    let (bytes, response) = try await session.bytes(for: request, delegate: PublicWebRedirects())
    try Self.check(response)
    let isImage = expected == .image || response.mimeType.flatMap { UTType(mimeType: $0) }?.conforms(to: .image) == true
    let limit = isImage ? Self.maxImageBytes : Self.maxPageBytes
    if isImage, response.expectedContentLength > Int64(limit) {
      bytes.task.cancel()
      throw URLError(.dataLengthExceedsMaximum)
    }
    var data = Data()
    data.reserveCapacity(min(Int(max(response.expectedContentLength, 0)), limit))
    for try await byte in bytes {
      data.append(byte)
      if isImage, data.count > limit {
        bytes.task.cancel()
        throw URLError(.dataLengthExceedsMaximum)
      }
      if !isImage, data.count >= limit {
        bytes.task.cancel()
        break
      }
    }
    return (data, response)
  }

  /// An http or https address on a public host: not this device, not the local network. Numeric
  /// hosts are read as the network stack reads them, short, hex and octal forms included.
  static func isPublicWeb(_ url: URL?) -> Bool {
    guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      var host = url.host(percentEncoded: false)?.lowercased()
    else { return false }
    host = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    while host.hasSuffix(".") { host.removeLast() }
    guard !host.isEmpty else { return false }
    if host == "localhost" || [".localhost", ".local", ".internal", ".lan", ".home.arpa"].contains(where: host.hasSuffix) {
      return false
    }
    if let address = IPAddress(host) { return address.isPublic }
    // Not an address, so a name; one with a colon or only digits and dots is neither.
    return !host.contains(":") && host.contains(where: { !$0.isNumber && $0 != "." })
  }

  /// `isPublicWeb`, and the host's name does not lead to this device or the local network. A
  /// name that does not resolve here is left to the request, which then fails on its own. The
  /// request looks the name up again, so a server that answers differently the second time (DNS
  /// rebinding) is not caught; this keeps out names that simply point at the local network.
  static func isPublicWebResolved(_ url: URL?) async -> Bool {
    guard isPublicWeb(url), let host = url?.host(percentEncoded: false) else { return false }
    return await Task.detached { IPAddress.resolve(host).allSatisfy(\.isPublic) }.value
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

/// Follows a redirect only to another public web address.
final class PublicWebRedirects: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(
    _ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest
  ) async -> URLRequest? {
    await NativeLinkPreviewer.isPublicWebResolved(request.url) ? request : nil
  }
}

/// An IPv4 or IPv6 address, to tell public ones from this device's and the local network's.
struct IPAddress: Equatable {
  /// 4 bytes for IPv4, 16 for IPv6.
  let bytes: [UInt8]

  /// Reads a numeric host as the network stack does: `127.1`, `0x7f000001` and `2130706433` are
  /// all 127.0.0.1.
  init?(_ host: String) {
    var v4 = in_addr()
    var v6 = in6_addr()
    if !host.contains(":"), inet_aton(host, &v4) != 0 {
      bytes = withUnsafeBytes(of: &v4) { Array($0) }
    } else if inet_pton(AF_INET6, host, &v6) == 1 {
      bytes = withUnsafeBytes(of: &v6) { Array($0) }
    } else {
      return nil
    }
  }

  init(bytes: [UInt8]) { self.bytes = bytes }

  var isPublic: Bool {
    if bytes.count == 4 {
      // 198.18.0.0/15 is allowed: proxies that answer every name with an address of their own
      // ("fake IP") hand those out, so refusing it would refuse every name behind one.
      switch (bytes[0], bytes[1], bytes[2]) {
      case (0, _, _), (10, _, _), (127, _, _), (169, 254, _), (192, 168, _), (192, 0, 0), (172, 16...31, _),
        (100, 64...127, _), (224..., _, _):
        return false
      default: return true
      }
    }
    guard bytes.count == 16 else { return false }
    // An IPv4 address inside IPv6: mapped (::ffff:a.b.c.d), compatible (::a.b.c.d) or NAT64.
    let embedsV4 = bytes[0..<10].allSatisfy { $0 == 0 } && (bytes[10..<12].allSatisfy { $0 == 0xFF } || bytes[10..<12].allSatisfy { $0 == 0 })
    let nat64 = bytes[0..<12] == [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]
    if embedsV4 || nat64 { return IPAddress(bytes: Array(bytes[12..<16])).isPublic }
    // Unique local (fc00::/7), link-local (fe80::/10), site-local (fec0::/10), multicast (ff00::/8).
    return !(bytes[0] & 0xFE == 0xFC || bytes[0] == 0xFE || bytes[0] == 0xFF)
  }

  /// The addresses a name resolves to here; none when it does not resolve.
  static func resolve(_ host: String) -> [IPAddress] {
    var hints = addrinfo()
    hints.ai_socktype = SOCK_STREAM
    var list: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(host, nil, &hints, &list) == 0 else { return [] }
    defer { freeaddrinfo(list) }
    var addresses: [IPAddress] = []
    var entry = list
    while let info = entry?.pointee {
      if let address = info.ai_addr {
        switch Int32(address.pointee.sa_family) {
        case AF_INET:
          address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
            var v4 = $0.pointee.sin_addr
            addresses.append(IPAddress(bytes: withUnsafeBytes(of: &v4) { Array($0) }))
          }
        case AF_INET6:
          address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            var v6 = $0.pointee.sin6_addr
            addresses.append(IPAddress(bytes: withUnsafeBytes(of: &v6) { Array($0) }))
          }
        default: break
        }
      }
      entry = info.ai_next
    }
    return addresses
  }
}
