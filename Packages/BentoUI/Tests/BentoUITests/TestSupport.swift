@testable import BentoData
import Dependencies
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

/// Records calls.
@MainActor
final class FakeLibraryStore: LibraryStoring {
  var calls: [String] = []

  let newSourceID = Source.ID()
  func createChannel(_ channel: Channel, sources: [Source], destinations: [Destination]) throws {
    calls.append(
      "createChannel(\(channel.name),\(channel.isEnabled),\(sources.map(\.pluginID)),\(destinations.map(\.name)))"
    )
  }
  func updateChannel(_ channel: Channel) throws { calls.append("updateChannel(\(channel.name),\(channel.isEnabled))") }
  func deleteChannel(_ id: Channel.ID) throws { calls.append("deleteChannel") }
  func addSource(
    channelID: Channel.ID, pluginID: String, query: String, name: String?, intervalMinutes: Int, skipInitialBacklog: Bool
  ) throws -> Source.ID {
    calls.append("addSource(\(pluginID),\(query),\(skipInitialBacklog))")
    return newSourceID
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
    @Dependency(\.defaultDatabase) var database
    return .native(store: store, docs: NativeDocsStore(database: database), statuses: NoSourceStatus())
  }
}

func item(
  sourceID: UUID = UUID(),
  title: String? = "Title",
  text: String = "",
  summary: String? = nil,
  translatedTitle: String? = nil,
  media: [Media] = [],
  publishedAt: Date = Date(timeIntervalSince1970: 1_792_141_200)
) -> FeedItem {
  FeedItem(
    id: UUID(), sourceID: sourceID, externalID: UUID().uuidString, title: title, text: text,
    translatedTitle: translatedTitle, summary: summary, media: media, publishedAt: publishedAt, fetchedAt: publishedAt
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

  var status: [String: Bool] = ["auth_token": true, "ct0": false]

  func secretStatus(pluginID: String) async throws -> [String: Bool] { status }
  func setSecret(pluginID: String, key: String, value: String) async throws {
    calls.append("set(\(pluginID).\(key))")
    status[key] = true
  }
  func refreshPlugins() async throws { calls.append("refreshPlugins") }
  func deleteSecret(pluginID: String, key: String) async throws { calls.append("delete(\(pluginID).\(key))") }
  func startLogin(pluginID: String) -> any LoginSession { FakeLoginSession(events: events, collector: self) }
  func becomeCollector() async throws {
    calls.append("becomeCollector")
    isThisMacCollector = true
  }
  func fetchNow(sourceID: Source.ID) async throws -> RunSummary {
    calls.append("fetchNow")
    return summary
  }
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
