@testable import BentoData
import Foundation
import SQLiteData

@testable import BentoUI

/// A migrated database in a temporary file.
func makeDatabase() throws -> any DatabaseWriter {
  try BentoDatabase.open(
    at: FileManager.default.temporaryDirectory.appending(path: "\(UUID().uuidString).sqlite"),
    iCloudContainer: nil
  )
}

/// Records calls; returns a fixed channel ID from `addChannel`.
@MainActor
final class FakeLibraryStore: LibraryStoring {
  var calls: [String] = []
  let newChannelID = UUID()

  func addChannel(name: String) throws -> Channel.ID {
    calls.append("addChannel(\(name))")
    return newChannelID
  }
  func updateChannel(_ channel: Channel) throws { calls.append("updateChannel(\(channel.name),\(channel.isEnabled))") }
  func deleteChannel(_ id: Channel.ID) throws { calls.append("deleteChannel") }
  func addFeed(channelID: Channel.ID, url: URL) throws { calls.append("addFeed(\(url.absoluteString))") }
  func updateSource(_ source: Source) throws { calls.append("updateSource") }
  func deleteSource(_ id: Source.ID) throws { calls.append("deleteSource") }
  func setBookmarked(_ itemID: FeedItem.ID, _ bookmarked: Bool) throws { calls.append("setBookmarked(\(bookmarked))") }
  func setRead(_ itemIDs: [FeedItem.ID], _ read: Bool) throws { calls.append("setRead(\(itemIDs.count),\(read))") }
  func markAllRead(channelID: Channel.ID?) throws { calls.append("markAllRead(\(channelID == nil ? "all" : "channel"))") }
}

extension AppContainer {
  @MainActor
  static func test(store: FakeLibraryStore) -> AppContainer {
    .native(store: store, statuses: NoSourceStatus())
  }
}

func item(
  sourceID: UUID = UUID(),
  title: String? = "Title",
  text: String = "",
  summary: String? = nil,
  translatedTitle: String? = nil,
  publishedAt: Date = Date(timeIntervalSince1970: 1_792_141_200)
) -> FeedItem {
  FeedItem(
    id: UUID(), sourceID: sourceID, externalID: UUID().uuidString, title: title, text: text,
    translatedTitle: translatedTitle, summary: summary, publishedAt: publishedAt, fetchedAt: publishedAt
  )
}

func channelRow(_ id: Channel.ID) -> Channel {
  Channel(id: id, name: "C", isEnabled: true, maxItems: 10, position: 0)
}
