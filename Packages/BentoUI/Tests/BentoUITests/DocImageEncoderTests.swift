import CoreGraphics
import Foundation
import ImageIO
import JxlCoder
import Testing
import UniformTypeIdentifiers

@testable import BentoUI

/// Images kept in docs become JPEG XL without losing what they had.
@Suite struct DocImageEncoderTests {
  static let width = 640
  static let height = 480

  /// A photo-like test image: gradients with noise.
  static let image: CGImage = {
    var pixels = [UInt8](repeating: 0, count: width * height * 4)
    var seed: UInt32 = 7
    for y in 0..<height {
      for x in 0..<width {
        seed = seed &* 1_664_525 &+ 1_013_904_223
        let noise = UInt8(truncatingIfNeeded: seed >> 24) / 10
        let i = (y * width + x) * 4
        pixels[i] = UInt8(x * 255 / width) &+ noise
        pixels[i + 1] = UInt8(y * 255 / height)
        pixels[i + 2] = UInt8((x + y) * 255 / (width + height)) &+ noise
        pixels[i + 3] = 255
      }
    }
    let context = CGContext(
      data: &pixels, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    return context.makeImage()!
  }()

  static func data(_ type: UTType, frames: Int = 1, options: [CFString: Any] = [:]) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, frames, nil)!
    for _ in 0..<frames { CGImageDestinationAddImage(destination, image, options as CFDictionary) }
    CGImageDestinationFinalize(destination)
    return data as Data
  }

  static func pixels(_ data: Data) -> [UInt8] {
    let source = CGImageSourceCreateWithData(data as CFData, nil)!
    let decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)!
    var out = [UInt8](repeating: 0, count: width * height * 4)
    let context = CGContext(
      data: &out, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )!
    context.draw(decoded, in: CGRect(x: 0, y: 0, width: width, height: height))
    return out
  }

  @Test func aPNGBecomesLosslessJPEGXLWithTheSamePixels() {
    let png = Self.data(.png)
    let stored = DocImageEncoder.encode(DocFileData(name: "shot.png", type: .png, data: png))

    #expect(stored.type == DocImageEncoder.jpegXL)
    #expect(stored.name == "shot.jxl")
    #expect(Self.pixels(stored.data) == Self.pixels(png))
    print("SIZE png \(png.count) → jxl lossless \(stored.data.count)")
    #expect(stored.data.count < png.count)
  }

  @Test func aJPEGIsRepackedSoTheOriginalComesBackExactly() throws {
    let jpeg = Self.data(.jpeg, options: [kCGImageDestinationLossyCompressionQuality: 0.85])
    let stored = DocImageEncoder.encode(DocFileData(name: "photo.jpg", type: .jpeg, data: jpeg))

    #expect(stored.type == DocImageEncoder.jpegXL)
    #expect(try JXLCoder.inverse(jxlData: stored.data) == jpeg)
    print("SIZE jpeg \(jpeg.count) → jxl repacked \(stored.data.count)")
    #expect(stored.data.count < jpeg.count)
  }

  @Test func whatTheEncoderWouldLoseKeepsItsFile() throws {
    // HEIC (iPhone photos are wide colour), 16 bits, and wide colour all keep their original.
    let heic = Self.data(.heic, options: [kCGImageDestinationLossyCompressionQuality: 0.8])
    #expect(DocImageEncoder.encode(DocFileData(name: "photo.heic", type: .heic, data: heic)).data == heic)
    let p3 = try #require(Self.image.copy(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!))
    let widePNG = Self.encoded(p3, as: .png)
    #expect(DocImageEncoder.encode(DocFileData(name: "p3.png", type: .png, data: widePNG)).data == widePNG)
    let deep = try #require(Self.sixteenBit())
    let deepPNG = Self.encoded(deep, as: .png)
    #expect(DocImageEncoder.encode(DocFileData(name: "deep.png", type: .png, data: deepPNG)).data == deepPNG)
    // Translucent pixels would change colour through premultiplied alpha.
    let translucent = try #require(Self.translucent())
    let alphaPNG = Self.encoded(translucent, as: .png)
    #expect(DocImageEncoder.encode(DocFileData(name: "a.png", type: .png, data: alphaPNG)).data == alphaPNG)
  }

  @Test func aJPEGTooLargeToDecodeKeepsItsFile() throws {
    // 7000 × 7000 is 49 MP, over the limit; a flat image keeps the file small.
    let side = 7000
    let context = try #require(CGContext(
      data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ))
    let jpeg = Self.encoded(try #require(context.makeImage()), as: .jpeg)
    #expect(DocImageEncoder.encode(DocFileData(name: "big.jpg", type: .jpeg, data: jpeg)).data == jpeg)
  }

  @Test func aCoverIsScaledUprightAndStaysSmall() throws {
    // A JPEG turned on its side by its orientation tag, as cameras write them.
    let jpeg = Self.data(.jpeg, options: [kCGImageDestinationLossyCompressionQuality: 0.85, kCGImagePropertyOrientation: 6])
    let cover = try #require(DocImageEncoder.encodeScaled(DocFileData(name: "c.jpg", type: .jpeg, data: jpeg), maxPixelSize: 320))
    #expect(cover.type == DocImageEncoder.jpegXL)
    let decoded = try #require(CGImageSourceCreateWithData(cover.data as CFData, nil).flatMap { CGImageSourceCreateImageAtIndex($0, 0, nil) })
    #expect((decoded.width, decoded.height) == (240, 320))
    // Wide colour keeps its colours: a JPEG with its profile, repacked.
    let p3 = try #require(Self.image.copy(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!))
    let heic = Self.encoded(p3, as: .heic)
    let wide = try #require(DocImageEncoder.encodeScaled(DocFileData(name: "w.heic", type: .heic, data: heic), maxPixelSize: 320))
    let jpegBack = try JXLCoder.inverse(jxlData: wide.data)
    let profile = CGImageSourceCreateWithData(jpegBack as CFData, nil)
      .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [CFString: Any] }?[kCGImagePropertyProfileName] as? String
    #expect(profile?.contains("P3") == true)
    #expect(DocImageEncoder.encodeScaled(DocFileData(name: "a.pdf", type: .pdf, data: Data("%PDF-1.4".utf8)), maxPixelSize: 320) == nil)
  }

  @Test func onlyFilesAddedAsImagesAreConverted() async throws {
    let url = FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).png")
    let png = Self.data(.png)
    try png.write(to: url)
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(try await DocFileReader.read(url).data == png)
    #expect(try await DocFileReader.read(url, asImage: true).type == DocImageEncoder.jpegXL)
  }

  static func encoded(_ image: CGImage, as type: UTType) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
  }

  static func translucent() -> CGImage? {
    let context = CGContext(
      data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )
    context?.setFillColor(CGColor(srgbRed: 0.8, green: 0.2, blue: 0.4, alpha: 0.3))
    context?.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
    return context?.makeImage()
  }

  static func sixteenBit() -> CGImage? {
    let context = CGContext(
      data: nil, width: width, height: height, bitsPerComponent: 16, bytesPerRow: 0,
      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    )
    context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return context?.makeImage()
  }

  @Test func animatedImagesAndOtherFilesAreKeptAsTheyCame() {
    let gif = Self.data(.gif, frames: 2)
    #expect(DocImageEncoder.encode(DocFileData(name: "a.gif", type: .gif, data: gif)).data == gif)
    let pdf = Data("%PDF-1.4".utf8)
    #expect(DocImageEncoder.encode(DocFileData(name: "a.pdf", type: .pdf, data: pdf)).type == .pdf)
  }
}

/// Answers every request with a PNG, so downloads are tested without the network.
final class StubImageProtocol: URLProtocol {
  nonisolated(unsafe) static var body = Data()
  nonisolated(unsafe) static var mimeType = "image/png"
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": Self.mimeType])!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Self.body)
    client?.urlProtocolDidFinishLoading(self)
  }
  override func stopLoading() {}
}

@MainActor
@Suite(.serialized) struct DocImageDownloaderTests {
  var session: URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubImageProtocol.self]
    return URLSession(configuration: configuration)
  }

  @Test func anArticleImageIsDownloadedAsJPEGXL() async throws {
    StubImageProtocol.body = DocImageEncoderTests.data(.png)
    StubImageProtocol.mimeType = "image/png"
    let file = try await DocImageDownloader.download("https://example.com/figure.png", session: session)
    #expect(file.type == DocImageEncoder.jpegXL)
    #expect(file.name == "figure.jxl")
  }

  @Test func anImageServedAsAnyFileIsStillAnImage() async throws {
    StubImageProtocol.body = DocImageEncoderTests.data(.png)
    StubImageProtocol.mimeType = "application/octet-stream"
    let file = try await DocImageDownloader.download("https://cdn.example.com/f/abc123", session: session)
    #expect(file.type == DocImageEncoder.jpegXL)
  }

  @Test func localAddressesAndNonImagesAreRefused() async {
    StubImageProtocol.body = Data("<html></html>".utf8)
    StubImageProtocol.mimeType = "text/html"
    await #expect(throws: (any Error).self) { try await DocImageDownloader.download("http://localhost/a.png", session: session) }
    await #expect(throws: (any Error).self) { try await DocImageDownloader.download("file:///etc/hosts", session: session) }
    await #expect(throws: (any Error).self) { try await DocImageDownloader.download("https://example.com/page", session: session) }
    // An image's address that answers with a page is refused too.
    await #expect(throws: (any Error).self) { try await DocImageDownloader.download("https://example.com/a.png", session: session) }
  }
}
