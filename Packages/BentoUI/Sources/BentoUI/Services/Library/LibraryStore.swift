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
  func addFeed(channelID: Channel.ID, url: URL) throws
  func updateSource(_ source: Source) throws
  func deleteSource(_ id: Source.ID) throws
  func setBookmarked(_ itemID: FeedItem.ID, _ bookmarked: Bool) throws
  func setRead(_ itemIDs: [FeedItem.ID], _ read: Bool) throws
  func markAllRead(channelID: Channel.ID?) throws
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

  public func addFeed(channelID: Channel.ID, url: URL) throws {
    try database.write { db in
      try Mutations.addSource(
        db, channelID: channelID, pluginID: "rss", name: url.host() ?? url.absoluteString, query: url.absoluteString
      )
    }
  }

  public func updateSource(_ source: Source) throws {
    try database.write { try Mutations.updateSource($0, source) }
  }

  public func deleteSource(_ id: Source.ID) throws {
    try database.write { try Mutations.deleteSource($0, id: id) }
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
}
