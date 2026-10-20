import CoreGraphics
import Foundation
import ImageIO
import JxlCoder
import UniformTypeIdentifiers

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Stores images kept in docs (pictures added as images, covers, images of saved articles) as
/// JPEG XL, which Apple's frameworks show on every device Bento runs on, whenever that loses
/// nothing:
/// - a JPEG is repacked losslessly: the same pixels, about a fifth smaller, and the original
///   JPEG can be rebuilt exactly;
/// - an 8-bit sRGB or grey image stored losslessly (PNG, BMP, a still GIF) is encoded
///   losslessly; one stored lossily (WebP, AVIF) is encoded at libjxl's visually lossless
///   distance.
/// The encoder works in 8-bit sRGB with premultiplied alpha, so everything else keeps its
/// original file: wide colour (iPhone photos are Display P3), more than 8 bits, lossless images
/// with transparency, very large images, animations, HEIC, and formats this does not know. So
/// does anything the encoder fails on.
enum DocImageEncoder {
  /// libjxl's distance 1.0, its "visually lossless" setting.
  static let lossyQuality = 90
  /// Larger images keep their original file rather than being decoded whole into memory.
  static let maxPixels = 40_000_000

  static let jpegXL = UTType("public.jpeg-xl") ?? UTType(filenameExtension: "jxl") ?? .image

  /// Formats encoded losslessly; lossy ones are listed in `lossy`. Anything else is kept.
  private static let lossless: [UTType] = [.png, .bmp, .gif]
  private static let lossy: [UTType] = [.webP, UTType("public.avif")].compactMap { $0 }

  static func encode(_ file: DocFileData) -> DocFileData {
    guard let still = still(file) else { return file }
    let (source, properties) = still
    guard pixelCount(properties) <= maxPixels else { return file }
    if file.type.conforms(to: .jpeg) {
      // Repacking keeps the JPEG's own data, colour profile and orientation included.
      return (try? JXLCoder.transcode(jpegData: file.data)).map(jpegXLFile(named: file.name)) ?? file
    }
    let isLossless = lossless.contains { file.type.conforms(to: $0) }
    // Translucent pixels go through premultiplied alpha, which changes their stored colour.
    guard isLossless || lossy.contains(where: { file.type.conforms(to: $0) }), fitsEncoder(properties),
      !(isLossless && hasAlpha(properties)),
      let image = upright(source, maxPixelSize: longSide(properties))
    else { return file }
    return encode(image, properties: properties, lossless: isLossless).map(jpegXLFile(named: file.name)) ?? file
  }

  /// A cover: the image scaled to at most `maxPixelSize` on its long side, orientation applied.
  /// It is JPEG XL where the encoder takes it; otherwise a lossy source becomes a JPEG and a
  /// lossless one a PNG, keeping its colours and depth. `nil` when the file is not an image.
  static func encodeScaled(_ file: DocFileData, maxPixelSize: Int) -> DocFileData? {
    guard let frame = still(file) ?? firstFrame(file) else { return nil }
    let (source, properties) = frame
    // A JPEG that already fits, the right way up, is repacked rather than encoded again.
    if file.type.conforms(to: .jpeg), longSide(properties) <= maxPixelSize,
      (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    {
      let repacked = encode(file)
      if repacked.type == jpegXL { return repacked }
    }
    guard let image = upright(source, maxPixelSize: min(maxPixelSize, longSide(properties))) else { return nil }
    let isLossless = lossless.contains { file.type.conforms(to: $0) }
    if fitsEncoder(properties), !(isLossless && hasAlpha(properties)),
      let data = encode(image, properties: properties, lossless: isLossless)
    {
      return jpegXLFile(named: file.name)(data)
    }
    let type: UTType = isLossless ? .png : .jpeg
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, type.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { return nil }
    let base = (file.name as NSString).deletingPathExtension
    let name = (base.isEmpty ? "cover" : base) + "." + (type.preferredFilenameExtension ?? "img")
    // A JPEG of a wide-colour photo keeps its profile when repacked, so it still ends up JPEG XL.
    return encode(DocFileData(name: name, type: type, data: data as Data))
  }

  /// The image source of a single still image, with its properties.
  private static func still(_ file: DocFileData) -> (CGImageSource, [CFString: Any])? {
    guard let source = CGImageSourceCreateWithData(file.data as CFData, nil), CGImageSourceGetCount(source) == 1 else {
      return nil
    }
    return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).map { (source, $0) }
  }

  /// The first frame of an animation, for a cover.
  private static func firstFrame(_ file: DocFileData) -> (CGImageSource, [CFString: Any])? {
    guard let source = CGImageSourceCreateWithData(file.data as CFData, nil), CGImageSourceGetCount(source) > 0 else {
      return nil
    }
    return (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]).map { (source, $0) }
  }

  private static func pixelCount(_ properties: [CFString: Any]) -> Int {
    (properties[kCGImagePropertyPixelWidth] as? Int ?? 0) * (properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
  }

  private static func hasAlpha(_ properties: [CFString: Any]) -> Bool {
    properties[kCGImagePropertyHasAlpha] as? Bool == true
  }

  private static func longSide(_ properties: [CFString: Any]) -> Int {
    max(properties[kCGImagePropertyPixelWidth] as? Int ?? 0, properties[kCGImagePropertyPixelHeight] as? Int ?? 0)
  }

  /// Whether the encoder can take the image without losing anything: 8 bits, sRGB or grey, and
  /// not so large it would be decoded whole into memory.
  private static func fitsEncoder(_ properties: [CFString: Any]) -> Bool {
    let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
    let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
    guard width > 0, height > 0, width * height <= maxPixels, (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else {
      return false
    }
    let model = properties[kCGImagePropertyColorModel] as? String
    let profile = properties[kCGImagePropertyProfileName] as? String
    if model == (kCGImagePropertyColorModelGray as String) { return true }
    guard model == nil || model == (kCGImagePropertyColorModelRGB as String) else { return false }
    return profile == nil || profile?.localizedCaseInsensitiveContains("sRGB") == true
  }

  /// The image with its orientation applied (the encoder ignores the orientation tag), at most
  /// `maxPixelSize` on its long side.
  private static func upright(_ source: CGImageSource, maxPixelSize: Int) -> CGImage? {
    guard maxPixelSize > 0 else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }

  private static func encode(_ image: CGImage, properties: [CFString: Any], lossless: Bool) -> Data? {
    #if os(macOS)
      let platformImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
    #else
      let platformImage = UIImage(cgImage: image)
    #endif
    return try? JXLCoder.encode(
      image: platformImage, colorSpace: hasAlpha(properties) ? .rgba : .rgb,
      compressionOption: lossless ? .loseless : .lossy,  // (sic: the package's spelling)
      effort: 7, quality: lossless ? 100 : lossyQuality
    )
  }

  private static func jpegXLFile(named name: String) -> (Data) -> DocFileData {
    { data in DocFileData(name: renamed(name), type: jpegXL, data: data) }
  }

  /// The name with a `.jxl` extension, so the file opens as what it now is.
  private static func renamed(_ name: String) -> String {
    let base = (name as NSString).deletingPathExtension
    return (base.isEmpty ? "image" : base) + ".jxl"
  }
}
