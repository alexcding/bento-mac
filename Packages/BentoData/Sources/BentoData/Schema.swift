import Foundation
import SQLiteData

// Synced tables. sqlite-data rules: UUID primary keys, no UNIQUE constraints, additive
// migrations only, last edit wins per column, BLOB columns sync as CKAssets.

@Table("channels")
public nonisolated struct Channel: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name = ""
  public var isEnabled = true
  public var maxItems = 10
  public var position = 0
}

@Table("sources")
public nonisolated struct Source: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var pluginID = ""
  public var name = ""
  public var query = ""
  /// Plugin-specific settings, validated against the plugin's `settings.schema.json`.
  public var settingsJSON = "{}"
  public var intervalMinutes = 30
  public var translate = false
  public var summarize = false
  public var fetchDetail = false
  public var isEnabled = true
}

@Table("channelSources")
public nonisolated struct ChannelSource: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var channelID: Channel.ID
  public var sourceID: Source.ID
  public var position = 0
}

@Table("destinations")
public nonisolated struct Destination: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var channelID: Channel.ID
  public var kind: Kind
  public var name = ""
  /// Telegram chat. Webhook URLs and tokens live in the Keychain, never here.
  public var chatID: String?
  public var postDelaySeconds = 20
  public var isEnabled = true

  public enum Kind: String, QueryBindable, Sendable {
    case discord
    case telegramBot
    case telegramAccount
  }
}

@Table("feedItems")
public nonisolated struct FeedItem: Hashable, Identifiable, Sendable {
  /// `StableID.feedItem(sourceID:externalID:)`, identical on every device.
  public let id: UUID
  /// No foreign key: items outlive the source that collected them.
  public var sourceID: UUID
  public var externalID: String
  public var url: String?
  public var title: String?
  public var text = ""
  public var translatedTitle: String?
  public var summary: String?
  public var authorName: String?
  public var authorHandle: String?
  public var authorAvatarURL: String?
  @Column(as: [Media].JSONRepresentation.self)
  public var media: [Media] = []
  public var referenceItemID: UUID?
  public var publishedAt: Date
  public var isPublishedAtEstimated = false
  public var language: String?
  public var fetchedAt: Date

  public init(
    id: UUID,
    sourceID: UUID,
    externalID: String,
    url: String? = nil,
    title: String? = nil,
    text: String = "",
    translatedTitle: String? = nil,
    summary: String? = nil,
    authorName: String? = nil,
    authorHandle: String? = nil,
    authorAvatarURL: String? = nil,
    media: [Media] = [],
    referenceItemID: UUID? = nil,
    publishedAt: Date,
    isPublishedAtEstimated: Bool = false,
    language: String? = nil,
    fetchedAt: Date
  ) {
    self.id = id
    self.sourceID = sourceID
    self.externalID = externalID
    self.url = url
    self.title = title
    self.text = text
    self.translatedTitle = translatedTitle
    self.summary = summary
    self.authorName = authorName
    self.authorHandle = authorHandle
    self.authorAvatarURL = authorAvatarURL
    self.media = media
    self.referenceItemID = referenceItemID
    self.publishedAt = publishedAt
    self.isPublishedAtEstimated = isPublishedAtEstimated
    self.language = language
    self.fetchedAt = fetchedAt
  }
}

/// Kept apart from `FeedItem` so feed queries never load the blob.
@Table("feedItemDetails")
public nonisolated struct FeedItemDetail: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let feedItemID: FeedItem.ID
  /// `DetailCodec` blob.
  public var markdown: Data
  public var id: FeedItem.ID { feedItemID }

  public init(feedItemID: FeedItem.ID, markdown: Data) {
    self.feedItemID = feedItemID
    self.markdown = markdown
  }
}

/// A saved copy of a feed item. Independent of `feedItems` (no foreign key), so it survives the
/// item being purged or its source deleted. Its ID is the item's ID, so an item is bookmarked at
/// most once without a UNIQUE constraint.
@Table("bookmarks")
public nonisolated struct Bookmark: Hashable, Identifiable, Sendable {
  public let id: FeedItem.ID
  public var sourceID: UUID
  public var url: String?
  public var title: String?
  public var text = ""
  public var translatedTitle: String?
  public var summary: String?
  public var authorName: String?
  public var authorHandle: String?
  public var authorAvatarURL: String?
  @Column(as: [Media].JSONRepresentation.self)
  public var media: [Media] = []
  public var publishedAt: Date
  public var isPublishedAtEstimated = false
  public var createdAt: Date
}

/// The bookmarked item's detail, copied with it.
@Table("bookmarkDetails")
public nonisolated struct BookmarkDetail: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let bookmarkID: Bookmark.ID
  /// `DetailCodec` blob.
  public var markdown: Data
  public var id: Bookmark.ID { bookmarkID }
}

extension Bookmark {
  init(copying item: FeedItem, createdAt: Date) {
    self.init(
      id: item.id, sourceID: item.sourceID, url: item.url, title: item.title, text: item.text,
      translatedTitle: item.translatedTitle, summary: item.summary, authorName: item.authorName,
      authorHandle: item.authorHandle, authorAvatarURL: item.authorAvatarURL, media: item.media,
      publishedAt: item.publishedAt, isPublishedAtEstimated: item.isPublishedAtEstimated, createdAt: createdAt
    )
  }

  /// The saved copy shaped as a feed item, so the same card and detail views show it.
  public var asFeedItem: FeedItem {
    FeedItem(
      id: id, sourceID: sourceID, externalID: "", url: url, title: title, text: text,
      translatedTitle: translatedTitle, summary: summary, authorName: authorName,
      authorHandle: authorHandle, authorAvatarURL: authorAvatarURL, media: media,
      publishedAt: publishedAt, isPublishedAtEstimated: isPublishedAtEstimated, fetchedAt: createdAt
    )
  }
}

@Table("readStates")
public nonisolated struct ReadState: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let feedItemID: FeedItem.ID
  public var readAt: Date
  public var id: FeedItem.ID { feedItemID }
}

// Local-only tables (never passed to the sync engine).

/// Last outbox `seq` the Mac app saved, per collector database instance. Mac only in practice;
/// the table exists everywhere so the schema is identical on every device.
@Table("outboxCursors")
public nonisolated struct OutboxCursor: Hashable, Sendable {
  @Column(primaryKey: true)
  public let instanceID: String
  public var seq: Int

  public init(instanceID: String, seq: Int) {
    self.instanceID = instanceID
    self.seq = seq
  }
}

// Memberwise initializers are internal; these are the ones other modules need.

extension Channel.Draft {
  public init(name: String, position: Int) {
    self.init(id: nil, name: name, isEnabled: true, maxItems: 10, position: position)
  }
}
