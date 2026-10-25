#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import Foundation

/// Draws the Powerline separators (U+E0B0-U+E0BF) from the cell geometry.
///
/// Prompts such as starship and powerlevel10k butt these glyphs against cells
/// with colored backgrounds, so they must span the full cell height exactly.
/// Patched fonts size them to their own metrics instead, and without one the
/// private-use code points render as missing-glyph boxes.
struct PowerlineRenderer {
    static func handles(_ codePoint: UInt32) -> Bool {
        (0xE0B0...0xE0BF).contains(codePoint)
    }

    static func draw(codePoint: UInt32, in context: CGContext, cell: CGRect, color: CGColor, strokeWidth: CGFloat) {
        let left = cell.minX
        let right = cell.maxX
        let top = cell.maxY
        let bottom = cell.minY
        let midY = cell.midY

        let path = CGMutablePath()
        var filled = true
        switch codePoint {
        case 0xE0B0: // solid right-pointing triangle
            path.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: right, y: midY), CGPoint(x: left, y: bottom)])
        case 0xE0B1: // right-pointing chevron
            filled = false
            path.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: right, y: midY), CGPoint(x: left, y: bottom)])
        case 0xE0B2: // solid left-pointing triangle
            path.addLines(between: [CGPoint(x: right, y: top), CGPoint(x: left, y: midY), CGPoint(x: right, y: bottom)])
        case 0xE0B3: // left-pointing chevron
            filled = false
            path.addLines(between: [CGPoint(x: right, y: top), CGPoint(x: left, y: midY), CGPoint(x: right, y: bottom)])
        case 0xE0B4, 0xE0B5: // right half circle, solid and outline
            filled = codePoint == 0xE0B4
            path.move(to: CGPoint(x: left, y: top))
            path.addCurve(to: CGPoint(x: left, y: bottom),
                          control1: CGPoint(x: left + cell.width * 1.33, y: top),
                          control2: CGPoint(x: left + cell.width * 1.33, y: bottom))
        case 0xE0B6, 0xE0B7: // left half circle, solid and outline
            filled = codePoint == 0xE0B6
            path.move(to: CGPoint(x: right, y: top))
            path.addCurve(to: CGPoint(x: right, y: bottom),
                          control1: CGPoint(x: right - cell.width * 1.33, y: top),
                          control2: CGPoint(x: right - cell.width * 1.33, y: bottom))
        case 0xE0B8: // lower-left triangle
            path.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)])
        case 0xE0B9, 0xE0BF: // backslash separator
            filled = false
            path.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: right, y: bottom)])
        case 0xE0BA: // lower-right triangle
            path.addLines(between: [CGPoint(x: right, y: top), CGPoint(x: right, y: bottom), CGPoint(x: left, y: bottom)])
        case 0xE0BB, 0xE0BD: // forward slash separator
            filled = false
            path.addLines(between: [CGPoint(x: left, y: bottom), CGPoint(x: right, y: top)])
        case 0xE0BC: // upper-left triangle
            path.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: left, y: bottom)])
        case 0xE0BE: // upper-right triangle
            path.addLines(between: [CGPoint(x: left, y: top), CGPoint(x: right, y: top), CGPoint(x: right, y: bottom)])
        default:
            return
        }

        context.saveGState()
        context.clip(to: cell)
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        if filled {
            path.closeSubpath()
            context.setFillColor(color)
            context.addPath(path)
            context.fillPath()
        } else {
            context.setStrokeColor(color)
            context.setLineWidth(strokeWidth)
            context.setLineJoin(.miter)
            context.addPath(path)
            context.strokePath()
        }
        context.restoreGState()
    }
}
#endif
