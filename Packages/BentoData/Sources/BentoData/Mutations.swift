import Foundation
import SQLiteData

/// Writes the UI performs. Each takes the write transaction's database.
public enum Mutations {
  @discardableResult
  public static func addChannel(_ db: Database, name: String) throws -> Channel.ID {
    let id = UUID()
    let position = try Channel.count().fetchOne(db) ?? 0
    try Channel.insert { Channel(id: id, name: name, isEnabled: true, maxItems: 10, position: position) }
      .execute(db)
    return id
  }

  public static func updateChannel(_ db: Database, _ channel: Channel) throws {
    try Channel.update(channel).execute(db)
  }

  /// Deletes the channel and the sources that belong only to it.
  public static func deleteChannel(_ db: Database, id: Channel.ID) throws {
    let sourceIDs = try ChannelSource.where { $0.channelID.eq(id) }.select(\.sourceID).fetchAll(db)
    let shared = try ChannelSource
      .where { $0.sourceID.in(sourceIDs) && $0.channelID.neq(id) }
      .select(\.sourceID)
      .fetchAll(db)
    let owned = Set(sourceIDs).subtracting(shared)
    try Channel.find(id).delete().execute(db)
    try Source.where { $0.id.in(Array(owned)) }.delete().execute(db)
  }

  @discardableResult
  public static func addSource(
    _ db: Database,
    channelID: Channel.ID,
    pluginID: String,
    name: String,
    query: String,
    intervalMinutes: Int = 30
  ) throws -> Source.ID {
    let id = UUID()
    try Source.insert {
      Source(
        id: id,
        pluginID: pluginID,
        name: name,
        query: query,
        settingsJSON: "{}",
        intervalMinutes: intervalMinutes,
        translate: false,
        summarize: false,
        fetchDetail: false,
        isEnabled: true
      )
    }
    .execute(db)
    let position = try ChannelSource.where { $0.channelID.eq(channelID) }.count().fetchOne(db) ?? 0
    try ChannelSource.insert {
      ChannelSource(id: UUID(), channelID: channelID, sourceID: id, position: position)
    }
    .execute(db)
    return id
  }

  public static func updateSource(_ db: Database, _ source: Source) throws {
    try Source.update(source).execute(db)
  }

  public static func deleteSource(_ db: Database, id: Source.ID) throws {
    try Source.find(id).delete().execute(db)
  }

  public static func setBookmarked(_ db: Database, itemID: FeedItem.ID, _ bookmarked: Bool, now: Date = .now) throws {
    if bookmarked {
      try Bookmark.upsert { Bookmark(feedItemID: itemID, createdAt: now) }.execute(db)
    } else {
      try Bookmark.find(itemID).delete().execute(db)
    }
  }

  public static func markRead(_ db: Database, itemID: FeedItem.ID, now: Date = .now) throws {
    guard try ReadState.find(itemID).fetchOne(db) == nil else { return }
    try ReadState.insert { ReadState(feedItemID: itemID, readAt: now) }.execute(db)
  }
}
