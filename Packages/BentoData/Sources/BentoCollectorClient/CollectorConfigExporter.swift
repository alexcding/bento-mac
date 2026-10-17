import BentoData
import Foundation
import SQLiteData

/// Writes `collector-config.json` for `bento-collector`, which reloads it when it changes.
/// Contract: `bento_domain::CollectorConfig`, fixture `services/testdata/collector-config.json`.
public enum CollectorConfigExporter {
  public static let defaultMaxItemAgeHours = 72

  /// The config as JSON with sorted keys, so unchanged settings produce identical bytes.
  public static func json(_ db: Database, maxItemAgeHours: Int = defaultMaxItemAgeHours) throws -> Data {
    let channels = try Channel.all.fetchAll(db)
    let links = try ChannelSource.all.fetchAll(db)
    let enabledChannels = Set(channels.filter(\.isEnabled).map(\.id))
    let sourcesInEnabledChannels = Set(links.filter { enabledChannels.contains($0.channelID) }.map(\.sourceID))
    let sources = try Source.order(by: \.id).fetchAll(db).map { source -> [String: Any] in
      [
        "id": source.id.uuidString.lowercased(),
        "plugin_id": source.pluginID,
        "name": source.name,
        "query": source.query,
        "settings": settingsObject(source.settingsJSON),
        "interval_minutes": max(source.intervalMinutes, 1),
        "enabled": source.isEnabled && sourcesInEnabledChannels.contains(source.id),
        "translate": source.translate,
        "summarize": source.summarize,
        "fetch_detail": source.fetchDetail,
        "ai_tasks": [String](),
      ]
    }
    let config: [String: Any] = [
      "version": 1,
      "max_item_age_hours": maxItemAgeHours,
      "sources": sources,
      // AI profiles and tasks are edited in Settings (phase 2d); until then the presets apply.
      "ai": ["profiles": [Any](), "tasks": [Any]()],
    ]
    return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted])
  }

  /// Writes the config atomically, only when it differs from what is on disk.
  /// - Returns: Whether the file was written.
  @discardableResult
  public static func write(_ data: Data, to url: URL) throws -> Bool {
    if (try? Data(contentsOf: url)) == data { return false }
    try data.write(to: url, options: .atomic)
    return true
  }

  private static func settingsObject(_ json: String) -> Any {
    (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [String: Any]()
  }
}
