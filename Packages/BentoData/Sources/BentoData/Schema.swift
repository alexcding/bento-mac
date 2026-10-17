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
}

/// Kept apart from `FeedItem` so feed queries never load the blob.
@Table("feedItemDetails")
public nonisolated struct FeedItemDetail: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let feedItemID: FeedItem.ID
  /// `DetailCodec` blob.
  public var markdown: Data
  public var id: FeedItem.ID { feedItemID }
}

/// Keyed by item, so an item is bookmarked at most once without a UNIQUE constraint.
@Table("bookmarks")
public nonisolated struct Bookmark: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let feedItemID: FeedItem.ID
  public var createdAt: Date
  public var id: FeedItem.ID { feedItemID }
}

@Table("readStates")
public nonisolated struct ReadState: Hashable, Identifiable, Sendable {
  @Column(primaryKey: true)
  public let feedItemID: FeedItem.ID
  public var readAt: Date
  public var id: FeedItem.ID { feedItemID }
}

// Local-only tables (never passed to the sync engine).

/// Last outbox `seq` saved, per collector database instance.
@Table("outboxCursors")
nonisolated struct OutboxCursor: Hashable, Sendable {
  @Column(primaryKey: true)
  let instanceID: String
  var seq: Int
}

// Memberwise initializers are internal; these are the ones other modules need.

extension Channel.Draft {
  public init(name: String, position: Int) {
    self.init(id: nil, name: name, isEnabled: true, maxItems: 10, position: position)
  }
}
