import BentoData
import Foundation
import SQLiteData

/// Writes `collector-config.json` for `bento-collector`, which reloads it when it changes.
/// Contract: `bento_domain::CollectorConfig`, fixture `services/testdata/collector-config.json`.
public enum CollectorConfigExporter {
  /// The config as JSON with sorted keys, so unchanged settings produce identical bytes.
  /// `utcOffsetMinutes` is the Mac's time zone, for skipping weekends. Without `collecting` (this
  /// Mac is not the collector) every source is disabled.
  public static func json(
    _ db: Database,
    collecting: Bool = true,
    utcOffsetMinutes: Int = TimeZone.current.secondsFromGMT() / 60
  ) throws -> Data {
    let settings = try Mutations.settings(db)
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
        "enabled": collecting && source.isEnabled && sourcesInEnabledChannels.contains(source.id),
        "translate": source.translate,
        "summarize": source.summarize,
        "fetch_detail": source.fetchDetail,
        "ai_tasks": source.aiTaskKeys,
        "skip_initial_backlog": source.skipInitialBacklog,
      ]
    }
    let config: [String: Any] = [
      "version": 1,
      "max_item_age_hours": max(settings.maxItemAgeHours, 1),
      "skip_weekends": settings.skipWeekends,
      "utc_offset_minutes": utcOffsetMinutes,
      "sources": sources,
      "destinations": try destinations(db, links: links, enabledChannels: collecting ? enabledChannels : []),
      "ai": try ai(db),
    ]
    return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .prettyPrinted])
  }

  /// Destinations by ID, each with its channel's sources. Only those of enabled channels are
  /// enabled; contract: `bento_domain::publish::DestinationConfig`.
  private static func destinations(
    _ db: Database,
    links: [ChannelSource],
    enabledChannels: Set<Channel.ID>
  ) throws -> [[String: Any]] {
    try Destination.order(by: \.id).fetchAll(db).map { destination in
      var entry: [String: Any] = [
        "id": destination.id.uuidString.lowercased(),
        "kind": kind(destination.kind),
        "name": destination.name,
        "post_delay_seconds": max(destination.postDelaySeconds, 0),
        "enabled": destination.isEnabled && enabledChannels.contains(destination.channelID),
        "source_ids": links.filter { $0.channelID == destination.channelID }
          .map { $0.sourceID.uuidString.lowercased() }
          .sorted(),
      ]
      if let chatID = destination.chatID, !chatID.isEmpty { entry["chat_id"] = chatID }
      return entry
    }
  }

  private static func kind(_ kind: Destination.Kind) -> String {
    switch kind {
    case .discord: "discord"
    case .telegramBot: "telegram_bot"
    case .telegramAccount: "telegram_account"
    case .x: "x"
    }
  }

  /// Profiles by ID, tasks by key; contract: `bento_domain::ai::AiConfig`.
  private static func ai(_ db: Database) throws -> [String: Any] {
    let id = { (uuid: UUID) in uuid.uuidString.lowercased() }
    let profiles = try AiProfile.order(by: \.position).fetchAll(db).map { profile -> [String: Any] in
      var entry: [String: Any] = [
        "id": id(profile.id),
        "name": profile.name,
        "kind": profile.kind.rawValue,
        "timeout_seconds": max(profile.timeoutSeconds, 1),
      ]
      if !profile.model.isEmpty { entry["model"] = profile.model }
      switch profile.kind {
      case .http:
        entry["base_url"] = profile.baseURL
      case .cli:
        entry["preset"] = profile.preset
        entry["command"] = (try? JSONSerialization.jsonObject(with: Data(profile.commandJSON.utf8))) as? [String] ?? []
      }
      return entry
    }
    let tasks = try AiTask.order(by: \.position).fetchAll(db).map { task -> [String: Any] in
      [
        "id": task.sourceKey,
        "name": task.name,
        "profile": task.profileID.map(id) ?? "",
        "fallback": task.fallback.map(id),
        "instructions": task.instructions,
        "outputs": task.outputs.map { ["name": $0.name, "target": $0.target, "description": $0.description] },
        "max_input_chars": max(task.maxInputChars, 500),
        "batch_size": max(task.batchSize, 1),
      ]
    }
    return ["profiles": profiles, "tasks": tasks]
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
