/// A coordinator owns presentation and the lifetime of the view models it shows. View models never
/// reach for it; they report through `onAction`, and the coordinator handles the result.
@MainActor
public protocol Coordinatable: AnyObject {
  func handle(_ action: Action)
}
