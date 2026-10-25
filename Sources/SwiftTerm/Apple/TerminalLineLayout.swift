#if os(macOS) || os(iOS) || os(visionOS)
import CoreGraphics
import CoreText
import Foundation
#if os(iOS) || os(visionOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Characters drawn from the cell geometry instead of a font glyph, so that
/// lines and fills meet exactly at cell edges.
enum CustomGlyph {
    case box(UInt32)
    case rects([BlockElementRect])
    case powerline(UInt32)

    /// The custom glyph for a cell's character; clusters with more than one scalar
    /// (for example a box character followed by a combining mark) use the font.
    static func lookup(_ character: Character) -> CustomGlyph? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first else {
            return nil
        }
        return lookup(scalar.value)
    }

    static func lookup(_ codePoint: UInt32) -> CustomGlyph? {
        if codePoint >= UInt32(BoxDrawingRenderer.lowerBoundary) && codePoint <= UInt32(BoxDrawingRenderer.upperBoundary) {
            return .box(codePoint)
        }
        if let rects = BlockElementMapping.rects(for: codePoint) {
            return .rects(rects)
        }
        if PowerlineRenderer.handles(codePoint) {
            return .powerline(codePoint)
        }
        return nil
    }
}

/// How a cell's foreground (glyphs, decorations and custom glyphs) is painted.
enum CellInk: Hashable {
    case color(TTColor)
    /// Paints by erasing to whatever is behind the view. Inverse video uses the
    /// default background as its foreground; when that background is transparent,
    /// erasing shows exactly the color behind the terminal.
    case knockout

    /// An opaque color for drawing APIs that take one; `apply(to:)` decides
    /// whether it paints or erases.
    var paintColor: TTColor {
        switch self {
        case .color(let color):
            return color
        case .knockout:
            return TTColor.black
        }
    }

    /// Sets up the context's fill, stroke and blend mode to paint with this ink.
    func apply(to context: CGContext) {
        let color = paintColor.cgColor
        context.setBlendMode(self == .knockout ? .destinationOut : .normal)
        context.setFillColor(color)
        context.setStrokeColor(color)
    }
}

struct CustomGlyphRenderItem {
    let column: Int
    let columnWidth: Int
    let glyph: CustomGlyph
    let ink: CellInk
}

/// A span of columns `[start, end)` that share a color.
struct CellColorRun {
    var start: Int
    var end: Int
    let color: TTColor
}

enum CellDecorationKind: Equatable {
    case underline(UnderlineStyle)
    case link
    case strikethrough
    case overline
}

/// A span of columns `[start, end)` that share a text decoration.
struct CellDecorationRun {
    var start: Int
    var end: Int
    let kind: CellDecorationKind
    let ink: CellInk
}

/// How a terminal `Attribute` renders, resolved against the view's fonts and
/// palette. Cached per attribute by the view.
struct CellStyle {
    /// Font and ink (`.cellInk`) for the glyphs.
    let textAttributes: [NSAttributedString.Key: Any]
    let foreground: CellInk
    /// The cell background, nil when the cell uses the default background.
    let background: TTColor?
    let underline: UnderlineStyle?
    let underlineInk: CellInk
    let strikethrough: Bool
    let overline: Bool
    /// SGR 8: only the background is drawn.
    let hidden: Bool
}

/// Everything needed to draw one terminal row: the row text for CoreText with a
/// map from each UTF-16 offset to the cell it belongs to, plus the background,
/// decoration and custom glyph spans in column coordinates.
struct ViewLineInfo {
    let text: NSAttributedString
    let columnForUTF16: [Int]
    let backgrounds: [CellColorRun]
    let selection: Range<Int>?
    let decorations: [CellDecorationRun]
    let customGlyphs: [CustomGlyphRenderItem]
    var images: [TerminalImage]?
    var kittyPlaceholders: [KittyPlaceholderCell]
}

/// Accumulates a row cell by cell, merging adjacent cells that share a style
/// into single attributed ranges, background runs and decoration runs.
struct ViewLineInfoBuilder {
    private var text = ""
    private var columnForUTF16: [Int] = []
    private var textRuns: [(range: NSRange, attributes: [NSAttributedString.Key: Any])] = []
    private var currentTextAttribute: Attribute?
    private var backgrounds: [CellColorRun] = []
    private var decorations: [CellDecorationRun] = []
    private(set) var customGlyphs: [CustomGlyphRenderItem] = []
    private(set) var kittyPlaceholders: [KittyPlaceholderCell] = []

    init(columns: Int) {
        columnForUTF16.reserveCapacity(columns)
    }

    /// Adds the text drawn for the cell at `column`.
    mutating func appendText(_ string: String, column: Int, attribute: Attribute, style: CellStyle) {
        let length = string.utf16.count
        guard length > 0 else {
            return
        }
        let location = columnForUTF16.count
        text += string
        columnForUTF16.append(contentsOf: repeatElement(column, count: length))
        if currentTextAttribute == attribute, let last = textRuns.last {
            textRuns[textRuns.count - 1].range = NSRange(location: last.range.location, length: last.range.length + length)
        } else {
            textRuns.append((NSRange(location: location, length: length), style.textAttributes))
            currentTextAttribute = attribute
        }
    }

    mutating func appendBackground(_ color: TTColor, column: Int, width: Int) {
        if let last = backgrounds.last, last.end == column, last.color == color {
            backgrounds[backgrounds.count - 1].end = column + width
        } else {
            backgrounds.append(CellColorRun(start: column, end: column + width, color: color))
        }
    }

    mutating func appendDecoration(_ kind: CellDecorationKind, ink: CellInk, column: Int, width: Int) {
        if let index = decorations.lastIndex(where: { $0.end == column && $0.kind == kind && $0.ink == ink }) {
            decorations[index].end = column + width
        } else {
            decorations.append(CellDecorationRun(start: column, end: column + width, kind: kind, ink: ink))
        }
    }

    mutating func appendCustomGlyph(_ item: CustomGlyphRenderItem) {
        customGlyphs.append(item)
    }

    mutating func appendKittyPlaceholder(_ placeholder: KittyPlaceholderCell) {
        kittyPlaceholders.append(placeholder)
    }

    func build(selection: Range<Int>?, images: [TerminalImage]?) -> ViewLineInfo {
        let attributed = NSMutableAttributedString(string: text)
        for run in textRuns {
            attributed.setAttributes(run.attributes, range: run.range)
        }
        return ViewLineInfo(text: attributed,
                            columnForUTF16: columnForUTF16,
                            backgrounds: backgrounds,
                            selection: selection,
                            decorations: decorations,
                            customGlyphs: customGlyphs,
                            images: images,
                            kittyPlaceholders: kittyPlaceholders)
    }
}
#endif
