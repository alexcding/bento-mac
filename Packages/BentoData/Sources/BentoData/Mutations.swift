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
    intervalMinutes: Int = 30,
    skipInitialBacklog: Bool = false
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
        isEnabled: true,
        skipInitialBacklog: skipInitialBacklog
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

  @discardableResult
  public static func addDestination(
    _ db: Database,
    id: Destination.ID = UUID(),
    channelID: Channel.ID,
    kind: Destination.Kind,
    name: String,
    chatID: String? = nil
  ) throws -> Destination.ID {
    try Destination.insert {
      Destination(id: id, channelID: channelID, kind: kind, name: name, chatID: chatID)
    }
    .execute(db)
    return id
  }

  public static func updateDestination(_ db: Database, _ destination: Destination) throws {
    try Destination.update(destination).execute(db)
  }

  public static func deleteDestination(_ db: Database, id: Destination.ID) throws {
    try Destination.find(id).delete().execute(db)
  }

  /// Bookmarking copies the item and its detail; removing deletes the copy.
  public static func setBookmarked(_ db: Database, itemID: FeedItem.ID, _ bookmarked: Bool, now: Date = .now) throws {
    guard bookmarked else {
      try Bookmark.find(itemID).delete().execute(db)
      return
    }
    guard try Bookmark.find(itemID).fetchOne(db) == nil,
      let item = try FeedItem.find(itemID).fetchOne(db)
    else { return }
    try Bookmark.insert { Bookmark(copying: item, createdAt: now) }.execute(db)
    if let detail = try FeedItemDetail.find(itemID).fetchOne(db) {
      try BookmarkDetail.insert { BookmarkDetail(bookmarkID: itemID, markdown: detail.markdown) }.execute(db)
    }
  }

  /// Marks items read or unread. Already-read items keep their original read time. IDs with no
  /// feed item (a bookmark whose original is gone) are skipped: read state belongs to feed items.
  public static func setRead(_ db: Database, itemIDs: [FeedItem.ID], _ read: Bool, now: Date = .now) throws {
    guard read else {
      try ReadState.where { $0.feedItemID.in(itemIDs) }.delete().execute(db)
      return
    }
    let existing = Set(try FeedItem.where { $0.id.in(itemIDs) }.select(\.id).fetchAll(db))
    let alreadyRead = Set(try ReadState.where { $0.feedItemID.in(itemIDs) }.select(\.feedItemID).fetchAll(db))
    for id in itemIDs where existing.contains(id) && !alreadyRead.contains(id) {
      try ReadState.insert { ReadState(feedItemID: id, readAt: now) }.execute(db)
    }
  }

  /// Marks every unread item read, in one channel or (with `nil`) everywhere.
  public static func markAllRead(_ db: Database, channelID: Channel.ID?, now: Date = .now) throws {
    let unread = try FeedItem
      .where {
        if let channelID {
          $0.sourceID.in(ChannelSource.where { $0.channelID.eq(channelID) }.select(\.sourceID))
        }
      }
      .where { !$0.id.in(ReadState.select(\.feedItemID)) }
      .select(\.id)
      .fetchAll(db)
    try setRead(db, itemIDs: unread, true, now: now)
  }

  public static func saveAiProfile(_ db: Database, _ profile: AiProfile) throws {
    try AiProfile.upsert { profile }.execute(db)
  }

  /// Deletes a profile and drops it from tasks that used it.
  public static func deleteAiProfile(_ db: Database, id: AiProfile.ID) throws {
    for var task in try AiTask.all.fetchAll(db) where task.profileID == id || task.fallback.contains(id) {
      if task.profileID == id { task.profileID = nil }
      task.fallback.removeAll { $0 == id }
      try saveAiTask(db, task)
    }
    try AiProfile.find(id).delete().execute(db)
  }

  public static func saveAiTask(_ db: Database, _ task: AiTask) throws {
    try AiTask.upsert { task }.execute(db)
  }

  /// Deletes a task and removes its key from sources.
  public static func deleteAiTask(_ db: Database, id: AiTask.ID) throws {
    guard let task = try AiTask.find(id).fetchOne(db) else { return }
    let key = task.sourceKey
    for var source in try Source.all.fetchAll(db) where source.aiTaskKeys.contains(key) {
      source.aiTaskKeys.removeAll { $0 == key }
      try updateSource(db, source)
    }
    try AiTask.find(id).delete().execute(db)
  }

  /// The settings row, or defaults when none exists yet.
  public static func settings(_ db: Database) throws -> AppSettings {
    try AppSettings.find(AppSettings.singletonID).fetchOne(db) ?? AppSettings()
  }

  public static func saveSettings(_ db: Database, _ settings: AppSettings) throws {
    try AppSettings.upsert { settings }.execute(db)
  }

  /// Makes a device the collector. With `onlyIfUnset`, does nothing when one is already set.
  /// Writes only the collector columns, so settings edited on another device are never reset.
  /// - Returns: Whether the device is now the collector.
  @discardableResult
  public static func claimCollector(
    _ db: Database,
    deviceID: UUID,
    deviceName: String,
    onlyIfUnset: Bool = false
  ) throws -> Bool {
    guard let existing = try AppSettings.find(AppSettings.singletonID).fetchOne(db) else {
      var settings = AppSettings()
      settings.collectorDeviceID = deviceID
      settings.collectorDeviceName = deviceName
      try AppSettings.insert { settings }.execute(db)
      return true
    }
    if onlyIfUnset, let current = existing.collectorDeviceID { return current == deviceID }
    try AppSettings.find(AppSettings.singletonID).update {
      $0.collectorDeviceID = #bind(deviceID)
      $0.collectorDeviceName = #bind(deviceName)
    }
    .execute(db)
    return true
  }

  /// Every item ID in the library, for a new collector to treat as already collected.
  public static func feedItemIDs(_ db: Database) throws -> [FeedItem.ID] {
    try FeedItem.select(\.id).fetchAll(db)
  }
}
