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
  func addSource(channelID: Channel.ID, pluginID: String, query: String, name: String?, skipInitialBacklog: Bool) throws {
    calls.append("addSource(\(pluginID),\(query),\(skipInitialBacklog))")
  }
  func updateSource(_ source: Source) throws { calls.append("updateSource") }
  func deleteSource(_ id: Source.ID) throws { calls.append("deleteSource") }
  func addDestination(id: Destination.ID, channelID: Channel.ID, kind: Destination.Kind, name: String, chatID: String?) throws {
    calls.append("addDestination(\(kind.rawValue),\(name),\(chatID ?? "-"))")
  }
  func updateDestination(_ destination: Destination) throws { calls.append("updateDestination") }
  func deleteDestination(_ id: Destination.ID) throws { calls.append("deleteDestination") }
  func setBookmarked(_ itemID: FeedItem.ID, _ bookmarked: Bool) throws { calls.append("setBookmarked(\(bookmarked))") }
  func setRead(_ itemIDs: [FeedItem.ID], _ read: Bool) throws { calls.append("setRead(\(itemIDs.count),\(read))") }
  func markAllRead(channelID: Channel.ID?) throws { calls.append("markAllRead(\(channelID == nil ? "all" : "channel"))") }
  func saveAiProfile(_ profile: AiProfile) throws { calls.append("saveAiProfile(\(profile.name))") }
  func deleteAiProfile(_ id: AiProfile.ID) throws { calls.append("deleteAiProfile") }
  func saveAiTask(_ task: AiTask) throws { calls.append("saveAiTask(\(task.key))") }
  func deleteAiTask(_ id: AiTask.ID) throws { calls.append("deleteAiTask") }
  func saveSettings(_ settings: AppSettings) throws { calls.append("saveSettings(\(settings.skipWeekends))") }
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

/// A collector with fixed plugins that records calls and plays back login events.
@MainActor
final class FakeCollector: CollectorControlling {
  var plugins: [PluginInfo]
  var calls: [String] = []
  var summary = RunSummary(fetched: 3, new: 2)
  var events: [LoginEvent] = []
  var sentInputs: [String] = []
  var isThisMacCollector = true
  var secretsSynced = false

  init(plugins: [PluginInfo]) {
    self.plugins = plugins
  }

  func secretStatus(pluginID: String) async throws -> [String: Bool] { ["auth_token": true, "ct0": false] }
  func setSecret(pluginID: String, key: String, value: String) async throws { calls.append("set(\(pluginID).\(key))") }
  func deleteSecret(pluginID: String, key: String) async throws { calls.append("delete(\(pluginID).\(key))") }
  func startLogin(pluginID: String) -> any LoginSession { FakeLoginSession(events: events, collector: self) }
  func becomeCollector() async throws {
    calls.append("becomeCollector")
    isThisMacCollector = true
  }
  func fetchNow(sourceID: Source.ID) async throws -> RunSummary { summary }
  func preview(sourceID: Source.ID) async throws -> PreviewResult { PreviewResult(items: [item()], aiFailures: []) }
}

@MainActor
final class FakeLoginSession: LoginSession {
  let events: AsyncStream<LoginEvent>
  private weak var collector: FakeCollector?

  init(events: [LoginEvent], collector: FakeCollector) {
    self.collector = collector
    self.events = AsyncStream { continuation in
      for event in events { continuation.yield(event) }
      continuation.finish()
    }
  }

  func send(_ input: String) { collector?.sentInputs.append(input) }
  func cancel() { collector?.calls.append("cancel") }
}

func plugin(_ id: String, manifest: String, requirements: String = "[]") -> PluginInfo {
  PluginInfo(id: id, name: id.uppercased(), version: "1", manifest: Data(manifest.utf8), requirements: Data(requirements.utf8), error: nil)
}
