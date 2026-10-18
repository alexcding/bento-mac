import BentoData
import CoreText
import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// Shared between the text view and its layout: which block the cursor is in, for the hint an
/// empty line shows. Both run on the main thread; TextKit just does not say so.
final class DocTextState: @unchecked Sendable {
  var caretBlockID: DocBlock.ID?
}

/// Gives each paragraph a fragment that draws its margin and plate.
final class DocLayoutDelegate: NSObject, NSTextLayoutManagerDelegate {
  let state: DocTextState

  init(state: DocTextState) {
    self.state = state
  }

  func textLayoutManager(
    _ textLayoutManager: NSTextLayoutManager, textLayoutFragmentFor location: any NSTextLocation, in textElement: NSTextElement
  ) -> NSTextLayoutFragment {
    let fragment = DocParagraphFragment(textElement: textElement, range: textElement.elementRange)
    if let paragraph = textElement as? NSTextParagraph {
      let text = paragraph.attributedString
      if text.length > 0 {
        fragment.paragraph = text.attribute(.docParagraph, at: 0, effectiveRange: nil) as? DocParagraph
        fragment.isTitle = text.attribute(.docTitle, at: 0, effectiveRange: nil) as? Bool == true && fragment.paragraph == nil
      }
      fragment.isEmpty = text.string.trimmingCharacters(in: .newlines).isEmpty
      let caretHere = fragment.paragraph.map { $0.block.id == state.caretBlockID } ?? false
      fragment.showsHint = fragment.isEmpty && (fragment.isTitle || (caretHere && fragment.paragraph?.block.kind.isAttachment == false))
    }
    return fragment
  }
}

/// A paragraph's layout, which also draws what sits beside or behind its text: the bullet,
/// number, checkbox or toggle in the margin, the Focus bar, a Block or code plate, and the hint
/// on an empty line.
final class DocParagraphFragment: NSTextLayoutFragment {
  var paragraph: DocParagraph?
  var isTitle = false
  var isEmpty = false
  var showsHint = false

  // A fragment's frame starts where its text does, past the indent; the margin and plate are
  // placed from the text column's left edge instead.

  private var padding: CGFloat { textLayoutManager?.textContainer?.lineFragmentPadding ?? 5 }

  /// The text column's width, inside the container's padding.
  private var columnWidth: CGFloat {
    (textLayoutManager?.textContainer?.size.width ?? layoutFragmentFrame.maxX) - 2 * padding
  }

  /// The column's left edge, `x` from the fragment's origin.
  private var columnOffset: CGFloat { padding - layoutFragmentFrame.minX }

  /// Where a block's margin starts, `x` from the fragment's origin.
  private func marginOffset(_ block: DocBlock) -> CGFloat {
    columnOffset + CGFloat(block.indent) * DocMetrics.indentStep
  }

  override var renderingSurfaceBounds: CGRect {
    // The margin and plate reach outside the text.
    super.renderingSurfaceBounds.union(
      CGRect(x: columnOffset - 4, y: -DocMetrics.body, width: columnWidth + 8, height: layoutFragmentFrame.height + 2 * DocMetrics.body)
    )
  }

  /// Where the checkbox or toggle sits, in the fragment's own coordinates, for clicks.
  var markerRect: CGRect? {
    guard let block = paragraph?.block, block.kind == .todo || block.kind == .toggle, let line = textLineFragments.first else { return nil }
    let x = marginOffset(block) + (block.decoration == .focus ? DocMetrics.focusInset : 0)
    let bounds = line.typographicBounds
    return CGRect(x: x, y: bounds.minY, width: DocMetrics.markerWidth, height: bounds.height)
  }

  override func draw(at point: CGPoint, in context: CGContext) {
    context.saveGState()
    defer { context.restoreGState() }
    if let block = paragraph?.block {
      drawPlate(block, at: point, in: context)
      drawFocusBar(block, at: point, in: context)
      drawMarker(block, at: point, in: context)
    }
    if showsHint { drawHint(at: point, in: context) }
    super.draw(at: point, in: context)
  }

  private var textBounds: CGRect {
    textLineFragments.reduce(CGRect.null) { $0.union($1.typographicBounds) }
  }

  private func drawPlate(_ block: DocBlock, at point: CGPoint, in context: CGContext) {
    guard block.decoration == .block || block.kind == .code else { return }
    let inset = CGFloat(block.indent) * DocMetrics.indentStep
    let lines = textBounds
    guard !lines.isNull else { return }
    let rect = CGRect(
      x: point.x + marginOffset(block), y: point.y + lines.minY - DocMetrics.body * 0.45,
      width: columnWidth - inset, height: lines.height + DocMetrics.body * 0.9
    )
    let color: PlatformColor =
      if block.kind == .code {
        .secondaryLabelColor.withAlphaComponent(0.08)
      } else if block.color == .standard {
        .secondaryLabelColor.withAlphaComponent(0.1)
      } else {
        DocTextStyle.color(for: block).withAlphaComponent(0.14)
      }
    context.setFillColor(color.cgColor)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 8, cornerHeight: 8, transform: nil))
    context.fillPath()
  }

  private func drawFocusBar(_ block: DocBlock, at point: CGPoint, in context: CGContext) {
    guard block.decoration == .focus else { return }
    let lines = textBounds
    guard !lines.isNull else { return }
    let x = point.x + marginOffset(block) + 2
    let rect = CGRect(x: x, y: point.y + lines.minY + 2, width: 3, height: max(lines.height - 4, 4))
    let color: PlatformColor = block.color == .standard ? .controlAccentColor : DocTextStyle.color(for: block)
    context.setFillColor(color.cgColor)
    context.addPath(CGPath(roundedRect: rect, cornerWidth: 1.5, cornerHeight: 1.5, transform: nil))
    context.fillPath()
  }

  private func drawMarker(_ block: DocBlock, at point: CGPoint, in context: CGContext) {
    guard block.kind.hasMarker, let line = textLineFragments.first else { return }
    let bounds = line.typographicBounds
    let x = point.x + marginOffset(block) + (block.decoration == .focus ? DocMetrics.focusInset : 0)
    // Centred on the first line's x-height, where the eye reads the line.
    let font = DocTextStyle.font(for: block)
    let midY = point.y + bounds.minY + line.glyphOrigin.y - font.xHeight / 2
    let secondary = PlatformColor.secondaryLabelColor.cgColor
    switch block.kind {
    case .bullet:
      let size: CGFloat = block.indent % 2 == 0 ? 5.5 : 5
      let rect = CGRect(x: x + 8, y: midY - size / 2, width: size, height: size)
      if block.indent % 2 == 0 {
        context.setFillColor(PlatformColor.labelColor.withAlphaComponent(0.75).cgColor)
        context.fillEllipse(in: rect)
      } else {
        context.setStrokeColor(PlatformColor.labelColor.withAlphaComponent(0.75).cgColor)
        context.setLineWidth(1.2)
        context.strokeEllipse(in: rect.insetBy(dx: 0.6, dy: 0.6))
      }
    case .numbered:
      let label = NSAttributedString(
        string: "\(paragraph?.listNumber ?? 1).",
        attributes: [
          .font: PlatformFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .regular),
          .foregroundColor: PlatformColor.secondaryLabelColor,
        ]
      )
      let ctLine = CTLineCreateWithAttributedString(label)
      let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
      context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
      context.textPosition = CGPoint(x: x + DocMetrics.markerWidth - 6 - width, y: point.y + bounds.minY + line.glyphOrigin.y)
      CTLineDraw(ctLine, context)
    case .todo:
      let size: CGFloat = 15
      let rect = CGRect(x: x + 3, y: midY - size / 2, width: size, height: size)
      let path = CGPath(roundedRect: rect, cornerWidth: 4, cornerHeight: 4, transform: nil)
      if block.isChecked {
        context.setFillColor(PlatformColor.controlAccentColor.cgColor)
        context.addPath(path)
        context.fillPath()
        context.setStrokeColor(PlatformColor.white.cgColor)
        context.setLineWidth(1.8)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: rect.minX + 4, y: rect.midY + 0.5))
        context.addLine(to: CGPoint(x: rect.minX + 6.5, y: rect.maxY - 4))
        context.addLine(to: CGPoint(x: rect.maxX - 3.5, y: rect.minY + 4))
        context.strokePath()
      } else {
        context.setStrokeColor(secondary)
        context.setLineWidth(1.4)
        context.addPath(CGPath(roundedRect: rect.insetBy(dx: 0.7, dy: 0.7), cornerWidth: 3.5, cornerHeight: 3.5, transform: nil))
        context.strokePath()
      }
    case .toggle:
      let size: CGFloat = 8
      let center = CGPoint(x: x + 10, y: midY)
      context.setFillColor(secondary)
      if block.isCollapsed {
        context.move(to: CGPoint(x: center.x - size * 0.35, y: center.y - size / 2))
        context.addLine(to: CGPoint(x: center.x + size * 0.55, y: center.y))
        context.addLine(to: CGPoint(x: center.x - size * 0.35, y: center.y + size / 2))
      } else {
        context.move(to: CGPoint(x: center.x - size / 2, y: center.y - size * 0.35))
        context.addLine(to: CGPoint(x: center.x + size / 2, y: center.y - size * 0.35))
        context.addLine(to: CGPoint(x: center.x, y: center.y + size * 0.55))
      }
      context.closePath()
      context.fillPath()
    default:
      break
    }
  }

  /// "Untitled" in an empty title; a hint on the empty line being typed in, as Craft shows.
  private func drawHint(at point: CGPoint, in context: CGContext) {
    let block = paragraph?.block
    let hint: String =
      if isTitle {
        "Untitled"
      } else {
        switch block?.kind {
        case .title: "Title"
        case .subtitle: "Subtitle"
        case .heading: "Heading"
        case .strong: "Strong"
        case .caption: "Caption"
        case .code: "Code"
        case .bullet, .numbered, .todo, .toggle: "List"
        default: "Type / for blocks, [[ to link a doc"
        }
      }
    let font = isTitle ? DocTextStyle.titleFont : block.map { DocTextStyle.font(for: $0) } ?? DocTextStyle.font(for: DocBlock(docID: UUID()))
    let label = NSAttributedString(string: hint, attributes: [.font: font, .foregroundColor: PlatformColor.tertiaryLabelColor])
    let ctLine = CTLineCreateWithAttributedString(label)
    let line = textLineFragments.first
    let x = point.x + (line?.typographicBounds.minX ?? 0)
    let baseline = point.y + (line.map { $0.typographicBounds.minY + $0.glyphOrigin.y } ?? font.ascender)
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    context.textPosition = CGPoint(x: x, y: baseline)
    CTLineDraw(ctLine, context)
  }
}

#if os(iOS)
  extension UIColor {
    static var controlAccentColor: UIColor { .tintColor }
  }
#endif

// MARK: Embedded blocks

/// A block shown as a view inside the text: a file or image, table, page, card, link card or
/// separator. The character holds the block's place and size; the editor puts the block's view
/// there (`DocTextController.layoutAttachments`), so the attachment itself draws nothing.
final class DocBlockAttachment: NSTextAttachment {
  let blockID: DocBlock.ID
  let kind: DocBlock.Kind
  /// The editor, which knows the view's height.
  weak var host: (any DocAttachmentHost)?

  init(blockID: DocBlock.ID, kind: DocBlock.Kind, host: (any DocAttachmentHost)?) {
    self.blockID = blockID
    self.kind = kind
    self.host = host
    super.init(data: nil, ofType: nil)
    #if os(macOS)
      image = NSImage(size: NSSize(width: 1, height: 1))
    #else
      image = UIImage()
    #endif
  }

  required init?(coder: NSCoder) {
    fatalError("not coded")
  }

  override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any], location: any NSTextLocation, textContainer: NSTextContainer?,
    proposedLineFragment: CGRect, position: CGPoint
  ) -> CGRect {
    let paragraph = attributes[.docParagraph] as? DocParagraph
    let inset = paragraph.map { DocTextStyle.textInset(for: $0.block) } ?? 0
    let padding = textContainer?.lineFragmentPadding ?? 5
    let width = max((textContainer?.size.width ?? proposedLineFragment.width) - inset - 2 * padding - 2, 120)
    let height = host?.height(for: blockID, kind: kind, width: width) ?? 44
    return CGRect(x: 0, y: -4, width: width, height: height)
  }
}

#if os(macOS)
  typealias PlatformView = NSView
#else
  typealias PlatformView = UIView
#endif

/// Knows how tall embedded blocks are. TextKit asks from the main thread without saying so, so
/// this is nonisolated and the editor checks.
protocol DocAttachmentHost: AnyObject, Sendable {
  func height(for blockID: DocBlock.ID, kind: DocBlock.Kind, width: CGFloat) -> CGFloat
}
