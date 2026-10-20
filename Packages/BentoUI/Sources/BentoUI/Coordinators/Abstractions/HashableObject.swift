/// Reference types that hash and compare by identity, so a view model can sit inside a `Hashable`
/// `Destination` without exposing its state to equality.
public protocol HashableObject: AnyObject, Hashable {}

extension HashableObject {
  public nonisolated static func == (lhs: Self, rhs: Self) -> Bool { lhs === rhs }
  public nonisolated func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
