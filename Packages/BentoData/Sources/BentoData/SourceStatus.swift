import Foundation

/// The collector's view of one source, read from `source_state` in `collector.sqlite`.
public struct SourceStatus: Hashable, Sendable {
  public var lastRunAt: Date?
  public var nextRunAt: Date
  public var consecutiveFailures: Int
  public var lastError: String?
  public var lastNewItems: Int

  public init(
    lastRunAt: Date?,
    nextRunAt: Date,
    consecutiveFailures: Int,
    lastError: String?,
    lastNewItems: Int
  ) {
    self.lastRunAt = lastRunAt
    self.nextRunAt = nextRunAt
    self.consecutiveFailures = consecutiveFailures
    self.lastError = lastError
    self.lastNewItems = lastNewItems
  }
}
