import Foundation

/// An image or video attached to a feed item. The JSON shape matches `bento_domain::Media`, so the
/// same encoding is used in the outbox and in the synced `feedItems.media` column.
public nonisolated struct Media: Codable, Hashable, Sendable {
  public var kind: Kind
  public var url: String
  public var width: Int?
  public var height: Int?
  public var thumbnailURL: String?
  /// Seconds.
  public var duration: Double?
  public var embedURL: String?

  public enum Kind: String, Codable, Hashable, Sendable {
    case image
    case video
  }

  public init(
    kind: Kind,
    url: String,
    width: Int? = nil,
    height: Int? = nil,
    thumbnailURL: String? = nil,
    duration: Double? = nil,
    embedURL: String? = nil
  ) {
    self.kind = kind
    self.url = url
    self.width = width
    self.height = height
    self.thumbnailURL = thumbnailURL
    self.duration = duration
    self.embedURL = embedURL
  }

  enum CodingKeys: String, CodingKey {
    case kind = "type"
    case url
    case width
    case height
    case thumbnailURL = "thumbnail_url"
    case duration
    case embedURL = "embed_url"
  }
}
