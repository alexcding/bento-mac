import SwiftUI

#if os(macOS)
  import AppKit

  /// Sidebar colors and metrics on the Mac. Text keeps the system fonts; only colors and spacing
  /// are set here.
  enum SidebarStyle {
    static let iconSlot: CGFloat = 24
    static let iconSize: CGFloat = 17
    static let iconGap: CGFloat = 3

    static let icon = Color(light: 0x9298A3, dark: 0xB4B8BF)
    static let heading = Color(light: 0x9298A3, dark: 0x6E6E6E).opacity(0.8)
  }

  /// Icon in a fixed slot so titles line up, tinted grey until the row is selected.
  struct SidebarLabelStyle: LabelStyle {
    @Environment(\.sidebarRowSelected) private var selected

    func makeBody(configuration: Configuration) -> some View {
      HStack(spacing: SidebarStyle.iconGap) {
        configuration.icon
          .font(.system(size: SidebarStyle.iconSize))
          .foregroundStyle(selected ? AnyShapeStyle(.primary) : AnyShapeStyle(SidebarStyle.icon))
          .frame(width: SidebarStyle.iconSlot, height: SidebarStyle.iconSlot)
        configuration.title
      }
    }
  }

  /// Keeps the sidebar selection the quiet grey plate instead of the accent color it takes while
  /// the list has focus. SwiftUI has no API for this, so a probe finds the list's table and marks
  /// it, and the rows of a marked table never turn emphasized.
  struct QuietSelectionProbe: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class Probe: NSView {
      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        _ = NSTableRowView.quietSelectionInstalled
        var view: NSView? = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view as? NSTableView, !table.hasQuietSelection else { return }
        table.hasQuietSelection = true
        table.enumerateAvailableRowViews { row, _ in row.isEmphasized = false }
      }
    }
  }

  @MainActor private var quietSelectionKey: UInt8 = 0

  extension NSTableView {
    fileprivate var hasQuietSelection: Bool {
      get { objc_getAssociatedObject(self, &quietSelectionKey) != nil }
      set { objc_setAssociatedObject(self, &quietSelectionKey, newValue ? true : nil, .OBJC_ASSOCIATION_RETAIN) }
    }
  }

  extension NSTableRowView {
    fileprivate static let quietSelectionInstalled: Void = {
      guard
        let original = class_getInstanceMethod(NSTableRowView.self, #selector(setter: isEmphasized)),
        let quiet = class_getInstanceMethod(NSTableRowView.self, #selector(setQuietEmphasized(_:)))
      else { return }
      method_exchangeImplementations(original, quiet)
    }()

    // After the exchange this name calls the original setter.
    @objc private func setQuietEmphasized(_ emphasized: Bool) {
      let quiet = (superview as? NSTableView)?.hasQuietSelection == true
      setQuietEmphasized(quiet ? false : emphasized)
    }
  }

  extension Color {
    fileprivate init(light: UInt32, dark: UInt32) {
      self.init(
        nsColor: NSColor(name: nil) { appearance in
          let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
          return NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
          )
        }
      )
    }
  }
#endif

extension EnvironmentValues {
  /// Whether the sidebar row is the selected one. The selection stays the quiet grey plate, so the
  /// row cannot read it from the list's background prominence.
  @Entry var sidebarRowSelected = false
}

extension View {
  /// The Mac sidebar look: grey icons in a fixed slot, muted section headings, medium rows. A no-op
  /// on iOS, which keeps the system sidebar.
  func sidebarStyle() -> some View {
    #if os(macOS)
      self
        .labelStyle(SidebarLabelStyle())
        .environment(\.sidebarRowSize, .medium)
        .contentMargins(.bottom, 8, for: .scrollContent)
    #else
      self
    #endif
  }

  /// Tags a sidebar row and tells its label whether it is selected, so the icon can follow.
  func sidebarRow(_ destination: SidebarDestination, selection: SidebarDestination) -> some View {
    tag(destination).environment(\.sidebarRowSelected, destination == selection)
  }

  /// Muted section heading color on the Mac.
  func sidebarHeading() -> some View {
    #if os(macOS)
      foregroundStyle(SidebarStyle.heading)
    #else
      self
    #endif
  }
}

/// Put on one row of the sidebar list: keeps its selection grey on the Mac. Empty on iOS.
struct QuietSelection: View {
  var body: some View {
    #if os(macOS)
      QuietSelectionProbe().frame(width: 0, height: 0)
    #else
      EmptyView()
    #endif
  }
}
