import BentoData

/// Collector status per source. The Mac app provides it from the collector daemon; iOS has no
/// collector and uses `NoSourceStatus`. Implementations should be `@Observable` so views update.
@MainActor
public protocol SourceStatusProviding: AnyObject {
  func status(for sourceID: Source.ID) -> SourceStatus?
}

public final class NoSourceStatus: SourceStatusProviding {
  public init() {}
  public func status(for sourceID: Source.ID) -> SourceStatus? { nil }
}
