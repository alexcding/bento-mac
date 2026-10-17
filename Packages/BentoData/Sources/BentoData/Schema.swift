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
  /// IDs of extra AI tasks (`AiTask.key`) run on new items, as a JSON array.
  public var aiTaskKeysJSON = "[]"
  /// On the first fetch, mark existing posts as seen instead of storing them.
  public var skipInitialBacklog = false

  public var aiTaskKeys: [String] {
    get { (try? JSONDecoder().decode([String].self, from: Data(aiTaskKeysJSON.utf8))) ?? [] }
    set { aiTaskKeysJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
  }

  /// `settingsJSON["limit"]`, the items per fetch the plugin asks for.
  public var limit: Int? {
    get { settings["limit"] as? Int }
    set {
      var settings = settings
      settings["limit"] = newValue
      let data = (try? JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])) ?? Data("{}".utf8)
      settingsJSON = String(decoding: data, as: UTF8.self)
    }
  }

  private var settings: [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(settingsJSON.utf8))) as? [String: Any] ?? [:]
  }
}

/// A saved connection to an AI service. The API key of an HTTP profile is a Keychain secret
/// (`ai.<id>`) on the Mac, never synced.
@Table("aiProfiles")
public nonisolated struct AiProfile: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var name = ""
  public var kind: Kind = .cli
  /// `codex`, `claude` or `custom`, for CLI profiles.
  public var preset = "claude"
  /// For HTTP profiles: an OpenAI-compatible endpoint.
  public var baseURL = ""
  public var model = ""
  /// For custom CLI profiles: the command as a JSON array.
  public var commandJSON = "[]"
  public var timeoutSeconds = 240
  public var position = 0

  public init(id: UUID = UUID()) {
    self.id = id
  }

  public enum Kind: String, QueryBindable, Sendable, CaseIterable {
    case cli
    case http
  }
}

/// One use of AI. `key` is what sources refer to: `translate` and `summarize` override the
/// presets; other tasks use their ID.
@Table("aiTasks")
public nonisolated struct AiTask: Hashable, Identifiable, Sendable {
  public let id: UUID
  public var key = ""
  public var name = ""
  /// `AiProfile.id`; nil means the first profile.
  public var profileID: AiProfile.ID?
  /// Fallback profile IDs as a JSON array.
  public var fallbackJSON = "[]"
  public var instructions = ""
  /// `[{name, target, description}]` as JSON; targets: translated_title, summary, text, detail.
  public var outputsJSON = "[]"
  public var maxInputChars = 6_500
  public var batchSize = 2
  public var position = 0

  public init(id: UUID = UUID()) {
    self.id = id
  }

  /// What sources store to turn this task on: `key`, or the ID for tasks without one. Also the
  /// task's ID in the collector config.
  public var sourceKey: String {
    key.isEmpty ? id.uuidString.lowercased() : key
  }

  /// Output targets a task can fill.
  public static let targets = ["translated_title", "summary", "text", "detail"]

  public struct Output: Codable, Hashable, Sendable {
    public var name: String
    public var target: String
    public var description: String

    public init(name: String, target: String, description: String) {
      self.name = name
      self.target = target
      self.description = description
    }
  }

  public var outputs: [Output] {
    get { (try? JSONDecoder().decode([Output].self, from: Data(outputsJSON.utf8))) ?? [] }
    set { outputsJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
  }

  public var fallback: [AiProfile.ID] {
    get { (try? JSONDecoder().decode([UUID].self, from: Data(fallbackJSON.utf8))) ?? [] }
    set { fallbackJSON = String(decoding: (try? JSONEncoder().encode(newValue)) ?? Data("[]".utf8), as: UTF8.self) }
  }
}

/// App-wide collector settings. One row, with `AppSettings.singletonID`.
@Table("appSettings")
public nonisolated struct AppSettings: Hashable, Identifiable, Sendable {
  public static let singletonID = UUID(uuidString: "00000000-0000-4000-8000-0000000000a1")!
  public let id: UUID
  public var maxItemAgeHours = 72
  public var skipWeekends = false
  /// The one Mac that collects and publishes; every other device only reads. Set by
  /// `Mutations.claimCollector`.
  public var collectorDeviceID: UUID?
  public var collectorDeviceName: String?

  public init(id: UUID = AppSettings.singletonID) {
    self.id = id
  }
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
  /// Telegram chat: a numeric ID or `@channel`. Webhook URLs and bot tokens live in the collector
  /// Mac's Keychain, never here.
  public var chatID: String?
  public var postDelaySeconds = 20
  public var isEnabled = true

  /// Where the webhook URL or bot token is kept: the collector's secret store under this
  /// namespace, keyed by `secretKey`.
  public static let secretNamespace = "destination"
  public var secretKey: String { id.uuidString.lowercased() }

  public enum Kind: String, QueryBindable, Sendable {
    case discord
    case telegramBot
    case telegramAccount
    case x
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
