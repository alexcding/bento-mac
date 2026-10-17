import Dependencies
import Foundation
import OSLog
import SQLiteData

let logger = Logger(subsystem: "Bento", category: "Database")

public enum BentoDatabase {
  /// `~/Library/Application Support/Bento`, shared with `bento-collector`.
  public static func defaultDirectory() throws -> URL {
    let directory = try FileManager.default
      .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
      .appending(path: "Bento", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  /// Opens and migrates `bento.sqlite`. Pass `iCloudContainer` to prepare it for sync.
  public static func open(at url: URL, iCloudContainer: String?) throws -> any DatabaseWriter {
    var configuration = Configuration()
    configuration.foreignKeysEnabled = true
    configuration.prepareDatabase { db in
      if let iCloudContainer {
        try db.attachMetadatabase(containerIdentifier: iCloudContainer)
      }
    }
    let database = try SQLiteData.defaultDatabase(path: url.path, configuration: configuration)
    logger.debug("Bento database: \(database.path)")
    try migrator.migrate(database)
    return database
  }

  static var migrator: DatabaseMigrator {
    var migrator = DatabaseMigrator()
    migrator.registerMigration("Create tables") { db in
      try #sql(
        """
        CREATE TABLE "channels" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "isEnabled" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1,
          "maxItems" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 10,
          "position" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "sources" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "pluginID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "query" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "settingsJSON" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '{}',
          "intervalMinutes" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 30,
          "translate" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
          "summarize" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
          "fetchDetail" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
          "isEnabled" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "channelSources" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "channelID" TEXT NOT NULL REFERENCES "channels"("id") ON DELETE CASCADE,
          "sourceID" TEXT NOT NULL REFERENCES "sources"("id") ON DELETE CASCADE,
          "position" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "destinations" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "channelID" TEXT NOT NULL REFERENCES "channels"("id") ON DELETE CASCADE,
          "kind" TEXT NOT NULL,
          "name" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "chatID" TEXT,
          "postDelaySeconds" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 20,
          "isEnabled" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 1
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "feedItems" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "sourceID" TEXT NOT NULL,
          "externalID" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "url" TEXT,
          "title" TEXT,
          "text" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "translatedTitle" TEXT,
          "summary" TEXT,
          "authorName" TEXT,
          "authorHandle" TEXT,
          "authorAvatarURL" TEXT,
          "media" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
          "referenceItemID" TEXT,
          "publishedAt" TEXT NOT NULL,
          "isPublishedAtEstimated" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
          "language" TEXT,
          "fetchedAt" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "feedItemDetails" (
          "feedItemID" TEXT PRIMARY KEY NOT NULL REFERENCES "feedItems"("id") ON DELETE CASCADE,
          "markdown" BLOB NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "bookmarks" (
          "id" TEXT PRIMARY KEY NOT NULL ON CONFLICT REPLACE DEFAULT (uuid()),
          "sourceID" TEXT NOT NULL,
          "url" TEXT,
          "title" TEXT,
          "text" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '',
          "translatedTitle" TEXT,
          "summary" TEXT,
          "authorName" TEXT,
          "authorHandle" TEXT,
          "authorAvatarURL" TEXT,
          "media" TEXT NOT NULL ON CONFLICT REPLACE DEFAULT '[]',
          "publishedAt" TEXT NOT NULL,
          "isPublishedAtEstimated" INTEGER NOT NULL ON CONFLICT REPLACE DEFAULT 0,
          "createdAt" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "bookmarkDetails" (
          "bookmarkID" TEXT PRIMARY KEY NOT NULL REFERENCES "bookmarks"("id") ON DELETE CASCADE,
          "markdown" BLOB NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "readStates" (
          "feedItemID" TEXT PRIMARY KEY NOT NULL REFERENCES "feedItems"("id") ON DELETE CASCADE,
          "readAt" TEXT NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(
        """
        CREATE TABLE "outboxCursors" (
          "instanceID" TEXT PRIMARY KEY NOT NULL,
          "seq" INTEGER NOT NULL
        ) STRICT
        """
      )
      .execute(db)
      try #sql(#"CREATE INDEX "index_bookmarks_on_createdAt" ON "bookmarks"("createdAt")"#)
        .execute(db)
      try #sql(#"CREATE INDEX "index_feedItems_on_publishedAt" ON "feedItems"("publishedAt")"#)
        .execute(db)
      try #sql(
        #"CREATE INDEX "index_feedItems_on_sourceID_publishedAt" ON "feedItems"("sourceID", "publishedAt")"#
      )
      .execute(db)
      try #sql(#"CREATE INDEX "index_channelSources_on_channelID" ON "channelSources"("channelID")"#)
        .execute(db)
      try #sql(#"CREATE INDEX "index_channelSources_on_sourceID" ON "channelSources"("sourceID")"#)
        .execute(db)
      try #sql(#"CREATE INDEX "index_destinations_on_channelID" ON "destinations"("channelID")"#)
        .execute(db)
    }
    return migrator
  }
}

extension DependencyValues {
  /// Sets up `defaultDatabase`, and `defaultSyncEngine` when an iCloud container is configured.
  public mutating func bootstrapBento(databaseURL: URL, iCloudContainer: String?) throws {
    defaultDatabase = try BentoDatabase.open(at: databaseURL, iCloudContainer: iCloudContainer)
    guard let iCloudContainer else {
      logger.info("iCloud sync off: no container configured")
      return
    }
    defaultSyncEngine = try SyncEngine(
      for: defaultDatabase,
      tables: Channel.self,
      Source.self,
      ChannelSource.self,
      Destination.self,
      FeedItem.self,
      FeedItemDetail.self,
      Bookmark.self,
      BookmarkDetail.self,
      ReadState.self,
      containerIdentifier: iCloudContainer
    )
  }
}
