import SwiftUI

/// A source type's icon: a white symbol on the source's color, in a rounded tile. Plugins without
/// one here get a grey puzzle piece.
struct SourceIcon: View {
  let pluginID: String
  var size: CGFloat = 32

  var body: some View {
    let style = Self.styles[pluginID] ?? Self.fallback
    RoundedRectangle(cornerRadius: size / 4, style: .continuous)
      .fill(style.color)
      .frame(width: size, height: size)
      .overlay {
        Image(systemName: style.symbol)
          .font(.system(size: size * 0.5, weight: .semibold))
          .foregroundStyle(.white)
      }
      .accessibilityHidden(true)
  }

  /// The order sources are listed in. Plugins not named here follow, by name.
  static let order = ["rss", "telegram", "youtube", "reddit", "x", "bilibili", "xiaohongshu"]

  private struct Style {
    let symbol: String
    let color: Color
  }

  private static let fallback = Style(symbol: "puzzlepiece.extension.fill", color: .gray)

  private static let styles: [String: Style] = [
    "rss": Style(symbol: "dot.radiowaves.up.forward", color: Color(hex: 0xF26522)),
    "telegram": Style(symbol: "paperplane.fill", color: Color(hex: 0x2AABEE)),
    "youtube": Style(symbol: "play.fill", color: Color(hex: 0xE62117)),
    "reddit": Style(symbol: "bubble.left.and.bubble.right.fill", color: Color(hex: 0xFF4500)),
    "x": Style(symbol: "xmark", color: .black),
    "bilibili": Style(symbol: "tv.fill", color: Color(hex: 0x00A1D6)),
    "xiaohongshu": Style(symbol: "book.closed.fill", color: Color(hex: 0xFF2442)),
  ]
}

extension Color {
  fileprivate init(hex: UInt32) {
    self.init(
      red: Double((hex >> 16) & 0xFF) / 255,
      green: Double((hex >> 8) & 0xFF) / 255,
      blue: Double(hex & 0xFF) / 255
    )
  }
}
