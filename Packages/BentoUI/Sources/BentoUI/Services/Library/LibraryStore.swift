import BentoData
import Foundation
import SQLiteData

/// Every write the UI makes to the synced library. Reads go through sqlite-data queries in the
/// view models; writes go through here so tests can substitute a fake.
@MainActor
public protocol LibraryStoring {
  func addChannel(name: String) throws -> Channel.ID
  func updateChannel(_ channel: Channel) throws
  func deleteChannel(_ id: Channel.ID) throws
  /// Adds a source of `pluginID` to a channel; `name` defaults from the query.
  func addSource(channelID: Channel.ID, pluginID: String, query: String, name: String?, skipInitialBacklog: Bool) throws
  func updateSource(_ source: Source) throws
  func deleteSource(_ id: Source.ID) throws
  func addDestination(id: Destination.ID, channelID: Channel.ID, kind: Destination.Kind, name: String, chatID: String?) throws
  func updateDestination(_ destination: Destination) throws
  func deleteDestination(_ id: Destination.ID) throws
  func setBookmarked(_ itemID: FeedItem.ID, _ bookmarked: Bool) throws
  func setRead(_ itemIDs: [FeedItem.ID], _ read: Bool) throws
  func markAllRead(channelID: Channel.ID?) throws
  func saveAiProfile(_ profile: AiProfile) throws
  func deleteAiProfile(_ id: AiProfile.ID) throws
  func saveAiTask(_ task: AiTask) throws
  func deleteAiTask(_ id: AiTask.ID) throws
  func saveSettings(_ settings: AppSettings) throws
}

public struct NativeLibraryStore: LibraryStoring {
  private let database: any DatabaseWriter

  public init(database: any DatabaseWriter) {
    self.database = database
  }

  public func addChannel(name: String) throws -> Channel.ID {
    try database.write { try Mutations.addChannel($0, name: name) }
  }

  public func updateChannel(_ channel: Channel) throws {
    try database.write { try Mutations.updateChannel($0, channel) }
  }

  public func deleteChannel(_ id: Channel.ID) throws {
    try database.write { try Mutations.deleteChannel($0, id: id) }
  }

  public func addSource(
    channelID: Channel.ID,
    pluginID: String,
    query: String,
    name: String?,
    skipInitialBacklog: Bool
  ) throws {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    let name = name.flatMap { $0.isEmpty ? nil : $0 } ?? Self.defaultName(pluginID: pluginID, query: query)
    try database.write { db in
      _ = try Mutations.addSource(
        db, channelID: channelID, pluginID: pluginID, name: name, query: query, skipInitialBacklog: skipInitialBacklog
      )
    }
  }

  /// A feed's host, else the query, else the plugin.
  static func defaultName(pluginID: String, query: String) -> String {
    if let host = URL(string: query)?.host(), !host.isEmpty { return host }
    return query.isEmpty ? pluginID : query
  }

  public func updateSource(_ source: Source) throws {
    try database.write { try Mutations.updateSource($0, source) }
  }

  public func deleteSource(_ id: Source.ID) throws {
    try database.write { try Mutations.deleteSource($0, id: id) }
  }

  public func addDestination(id: Destination.ID, channelID: Channel.ID, kind: Destination.Kind, name: String, chatID: String?) throws {
    try database.write {
      _ = try Mutations.addDestination($0, id: id, channelID: channelID, kind: kind, name: name, chatID: chatID)
    }
  }

  public func updateDestination(_ destination: Destination) throws {
    try database.write { try Mutations.updateDestination($0, destination) }
  }

  public func deleteDestination(_ id: Destination.ID) throws {
    try database.write { try Mutations.deleteDestination($0, id: id) }
  }

  public func setBookmarked(_ itemID: FeedItem.ID, _ bookmarked: Bool) throws {
    try database.write { try Mutations.setBookmarked($0, itemID: itemID, bookmarked) }
  }

  public func setRead(_ itemIDs: [FeedItem.ID], _ read: Bool) throws {
    try database.write { try Mutations.setRead($0, itemIDs: itemIDs, read) }
  }

  public func markAllRead(channelID: Channel.ID?) throws {
    try database.write { try Mutations.markAllRead($0, channelID: channelID) }
  }

  public func saveAiProfile(_ profile: AiProfile) throws {
    try database.write { try Mutations.saveAiProfile($0, profile) }
  }

  public func deleteAiProfile(_ id: AiProfile.ID) throws {
    try database.write { try Mutations.deleteAiProfile($0, id: id) }
  }

  public func saveAiTask(_ task: AiTask) throws {
    try database.write { try Mutations.saveAiTask($0, task) }
  }

  public func deleteAiTask(_ id: AiTask.ID) throws {
    try database.write { try Mutations.deleteAiTask($0, id: id) }
  }

  public func saveSettings(_ settings: AppSettings) throws {
    try database.write { try Mutations.saveSettings($0, settings) }
  }
}
