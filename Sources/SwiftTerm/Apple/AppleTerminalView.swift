//
//  AppleTerminalView.swift
//
// Shared code for UIKit and Appkit for the terminal view
//
//  Created by Miguel de Icaza on 4/21/20.
//
#if os(macOS) || os(iOS) || os(visionOS)
import Foundation
import CoreGraphics
import CoreText
#if canImport(ImageIO)
import ImageIO
#endif
import SwiftUI

#if os(iOS) || os(visionOS)
import UIKit
typealias TTColor = UIColor
typealias TTFont = UIFont
typealias TTRect = CGRect
typealias TTBezierPath = UIBezierPath
public typealias TTImage = UIImage
#endif

#if os(macOS)
import AppKit
typealias TTColor = NSColor
typealias TTFont = NSFont
typealias TTRect = CGRect
typealias TTBezierPath = NSBezierPath
public typealias TTImage = NSImage
#endif

extension TerminalView {
    typealias CellDimension = CGSize
    
    func resetCaches ()
    {
        self.cellStyles = [:]
        self.colors = Array(repeating: nil, count: 256)
        self.trueColors = [:]
    }
    
    // This is invoked when the font changes to recompute state
    func resetFont()
    {
        resetCaches()
        self.cellDimension = computeFontDimensions ()
        let newCols = Int(frame.width / cellDimension.width)
        let newRows = Int(frame.height / cellDimension.height)
        resize(cols: newCols, rows: newRows)
        updateCaretView()
    }
    
    func updateCaretView ()
    {
        guard let caretView else { return }
        caretView.frame.size = CGSize(width: cellDimension.width, height: cellDimension.height)
        caretView.updateCursorStyle()
    }
    
    /// The frame used by the caretView
    public var caretFrame: CGRect {
        return caretView?.frame ?? CGRect.zero
    }
    
    func setupOptions(width: CGFloat, height: CGFloat)
    {
        resetCaches ()
        // Calculation assume that all glyphs in the font have the same advancement.
        // Get the ascent + descent + leading from the font, already scaled for the font's size
        self.cellDimension = computeFontDimensions ()
        
        let terminalOptions = TerminalOptions(cols: Int(width / cellDimension.width),
                                              rows: Int(height / cellDimension.height))
        
        if terminal == nil {
            terminal = Terminal(delegate: self, options: terminalOptions)
        } else {
            terminal.options = terminalOptions
            terminal.setup(isReset: false)
        }
        terminal.backgroundColor = Color.defaultBackground
        terminal.foregroundColor = Color.defaultForeground

        selection = SelectionService(terminal: terminal)
        
        // Install carret view
        if caretView == nil {
            let v = CaretView(frame: CGRect(origin: .zero, size: CGSize(width: cellDimension.width, height: cellDimension.height)), cursorStyle: terminal.options.cursorStyle, terminal: self)
            addSubview(v)
            caretView = v
        } else {
            updateCaretView ()
        }
        
        search = SearchService (terminal: terminal)
        
        #if os(macOS)
        needsDisplay = true
        #else
        setNeedsDisplay(frame)
        #endif
    }

    /// Returns the underlying terminal emulator that the `TerminalView` is a view for
    public func getTerminal () -> Terminal
    {
        return terminal
    }
    
    /// This function computes the new columns and rows for the terminal when a pixel-size changes
    /// Returns true if this changed the number of columns/rows, false otherwise
    @discardableResult
    func processSizeChange (newSize: CGSize) -> Bool {
        // Clamp to the same minimums Terminal.resize enforces internally, so
        // degenerate sizes (mid-drag transients, zero-size layout passes) never
        // produce a 0×0 grid in delegate callbacks, PTY winsize, or caret math.
        let newRows = max (Int (newSize.height / cellDimension.height), terminal.MINIMUM_ROWS)
        let newCols = max (Int (getEffectiveWidth (size: newSize) / cellDimension.width), terminal.MINIMUM_COLS)

        if newCols != terminal.cols || newRows != terminal.rows {
            selection.active = false
            terminal.resize (cols: newCols, rows: newRows)
            
            // These used to be outside
            accessibility.invalidate ()
            search.invalidate ()
            
            terminalDelegate?.sizeChanged (source: self, newCols: newCols, newRows: newRows)
           
            updateScroller()
            return true
        }
        return false
    }
    
    // Computes the font dimensions once font.normal has been set.
    //
    // The cell is a whole number of device pixels wide and tall. Every column then
    // starts on a pixel boundary, so text, backgrounds, box drawing, the cursor and
    // the selection all land on the same grid instead of drifting apart along a row.
    func computeFontDimensions () -> CellDimension
    {
        let lineAscent = CTFontGetAscent (fontSet.normal)
        let lineDescent = CTFontGetDescent (fontSet.normal)
        let lineLeading = CTFontGetLeading (fontSet.normal)
        let cellHeight = ceil(lineAscent + lineDescent + lineLeading)
        #if os(macOS)
        // The following is a more robust way of getting the largest ascii character width, but comes with a performance hit.
        // See: https://github.com/migueldeicaza/SwiftTerm/issues/286
        // var sizes = UnsafeMutablePointer<NSSize>.allocate(capacity: 95)
        // let ctFont = (font as CTFont)
        // var glyphs = (32..<127).map { CTFontGetGlyphWithName(ctFont, String(Unicode.Scalar($0)) as CFString) }
        // withUnsafePointer(to: glyphs[0]) { glyphsPtr in
        //     fontSet.normal.getAdvancements(NSSizeArray(sizes), forCGGlyphs: glyphsPtr, count: 95)
        // }
        // let cellWidth = (0..<95).reduce(into: 0) { partialResult, idx in
        //     partialResult = max(partialResult, sizes[idx].width)
        // }
        let glyph = fontSet.normal.glyph(withName: "W")
        let advance = fontSet.normal.advancement(forGlyph: glyph).width
        #else
        let fontAttributes = [NSAttributedString.Key.font: fontSet.normal]
        let advance = "W".size(withAttributes: fontAttributes).width
        #endif
        let scale = max (1, backingScaleFactor ())
        // Round up so glyphs never overlap their neighbors; the tolerance keeps an
        // advance that is already pixel aligned (up to float noise) from growing.
        let cellWidth = ((advance * scale) - 0.01).rounded (.up) / scale
        return CellDimension(width: max (1 / scale, cellWidth), height: max (min (cellHeight, 8192), 1))
    }
    
    func mapColor (color: Attribute.Color, isFg: Bool, isBold: Bool, useBrightColors: Bool = true) -> TTColor
    {
        switch color {
        case .defaultColor:
            if isFg {
                return nativeForegroundColor
            } else {
                return nativeBackgroundColor
            }
        case .defaultInvertedColor:
            // Inverse video of the default colors: the default background is the
            // foreground and the default foreground is the background
            if isFg {
                return nativeBackgroundColor
            } else {
                return nativeForegroundColor
            }
        case .ansi256(let ansi):
            var midx: Int
            // if high - bright colors are enabled we will represent bold text by using more intense colors
            // otherwise we will reduce colors but use bold fonts
            // Only the 16 color palette has normal/bright pairs
            if useBrightColors {
                midx = ansi < 8 && isBold ? Int (ansi) + 8 : Int (ansi)
            } else {
                midx = (8..<16).contains (ansi) ? Int (ansi) - 8 : Int (ansi)
            }
            if let c = colors [midx] {
                return c
            }
            let tcolor = terminal.ansiColors [midx]
            let newColor = TTColor.make (color: tcolor)
            colors [midx] = newColor
            return newColor
        case .trueColor(let r, let g, let b):
            if let tc = trueColors [color] {
                return tc
            }
            let newColor = TTColor.make(red: CGFloat (r) / 255.0,
                                        green: CGFloat (g) / 255.0,
                                        blue: CGFloat (b) / 255.0,
                                        alpha: 1.0)
            
            trueColors [color] = newColor
            return newColor
        }
    }

    // Clears the cached state for colors and triggers a full display
    func colorsChanged ()
    {
        cellStyles = [:]
        
        terminal.updateFullScreen ()
        queuePendingDisplay()
    }
    
    public func hostCurrentDirectoryUpdated (source: Terminal)
    {
        terminalDelegate?.hostCurrentDirectoryUpdate(source: self, directory: terminal.hostCurrentDirectory)
    }

    
    /// Installs the new colors as the default colors and recomputes the
    /// current and ansi palette.   This installs both the colors into the terminal
    /// engine and updates the UI accordingly.
    /// 
    /// - Parameter colors: this should be an array of 16 values that correspond to the 16 ANSI colors,
    /// if the array does not contain 16 elements, it will not do anything
    public func installColors (_ colors: [Color])
    {
        terminal.installPalette(colors: colors)
        self.colors = Array(repeating: nil, count: 256)
        self.colorsChanged()
    }
    
    public func colorChanged (source: Terminal, idx: Int?)
    {
        if let index = idx {
            colors [index] = nil
        } else {
            colors = Array(repeating: nil, count: 256)
        }
        colorsChanged ()
    }

    public func synchronizedOutputChanged (source: Terminal, active: Bool)
    {
        updateScroller()
        queuePendingDisplay()
    }

    public func setBackgroundColor(source: Terminal, color: Color) {
        // Can not implement this until I change the color to not be this struct
        nativeBackgroundColor = TTColor.make (color: color)
        colorsChanged()
    }
    
    public func setForegroundColor(source: Terminal, color: Color) {
        nativeForegroundColor = TTColor.make (color: color)
        colorsChanged()
    }
    
    /// Sets the color for the cursor block, and the text when it is under that cursor in block mode
    public func setCursorColor(source: Terminal, color: Color?, textColor: Color?) {
        if let setColor = color {
            caretColor = TTColor.make (color: setColor)
        } else {
            if let caretView {
                caretColor = caretView.defaultCaretColor
            }
        }
        if let setColor = textColor {
            caretTextColor = TTColor.make (color: setColor)
        } else {
            if let caretView {
                caretTextColor = caretView.defaultCaretTextColor
            }
        }
    }
    
    func getAttributedValue (_ attribute: Attribute, usingFg: TTColor, andBg: TTColor) -> [NSAttributedString.Key:Any]?
    {
        let flags = attribute.style
        var bg = andBg
        var fg = usingFg
        
        if flags.contains (.inverse) {
            swap (&bg, &fg)
        }
        
        var tf: TTFont
        let isBold = flags.contains(.bold)
        if isBold {
            if flags.contains (.italic) {
                tf = fontSet.boldItalic
            } else {
                tf = fontSet.bold
            }
        } else if flags.contains (.italic) {
            tf = fontSet.italic
        } else {
            tf = fontSet.normal
        }
        
        var nsattr: [NSAttributedString.Key:Any] = [
            .font: tf,
            .foregroundColor: fg,
            .backgroundColor: bg
        ]
        if flags.contains (.underline) {
            let underlineColor = attribute.underlineColor.map {
                mapColor(color: $0, isFg: true, isBold: flags.contains(.bold), useBrightColors: useBrightColors)
            } ?? fg
            nsattr [.underlineColor] = underlineColor
            nsattr [.underlineStyle] = NSUnderlineStyle.single.rawValue
        }
        if flags.contains (.crossedOut) {
            nsattr [.strikethroughColor] = fg
            nsattr [.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        return nsattr
    }
    
    //
    // Given a vt100 attribute, returns how cells using it render: font, colors and decorations
    //
    func cellStyle (for attribute: Attribute) -> CellStyle
    {
        if let cached = cellStyles [attribute] {
            return cached
        }
        let flags = attribute.style
        var bg = attribute.bg
        var fg = attribute.fg
        
        if flags.contains (.inverse) {
            swap (&bg, &fg)
            
            if fg == .defaultColor {
                fg = .defaultInvertedColor
            }
            if bg == .defaultColor {
                bg = .defaultInvertedColor
            }
        }
        
        // If bright colors are disabled in settings, the bright half of the 16 color
        // palette is rendered with a bold font instead
        var useBoldForBrightColor = false
        if case .ansi256(let code) = fg, (8..<16).contains (code), !useBrightColors {
            useBoldForBrightColor = true
        }
        let isBold = flags.contains(.bold)
        let font: TTFont
        if isBold || useBoldForBrightColor {
            font = flags.contains (.italic) ? fontSet.boldItalic : fontSet.bold
        } else {
            font = flags.contains (.italic) ? fontSet.italic : fontSet.normal
        }
        
        var fgColor = mapColor (color: fg, isFg: true, isBold: isBold, useBrightColors: useBrightColors)
        // Apply dim/faint attribute (SGR 2) - reduce color intensity
        if flags.contains(.dim) {
            fgColor = fgColor.dimmedColor()
        }
        // A transparent default background cannot be painted as a text color, so
        // inverse video erases the glyphs out of their background instead
        let foreground: CellInk = fg == .defaultInvertedColor && nativeBackgroundColor.cgColor.alpha < 1
            ? .knockout
            : .color (fgColor)
        let underlineInk = attribute.underlineColor.map {
            CellInk.color (mapColor(color: $0, isFg: true, isBold: isBold, useBrightColors: useBrightColors))
        } ?? foreground
        let style = CellStyle (
            textAttributes: [.font: font, .cellInk: foreground],
            foreground: foreground,
            background: bg == .defaultColor ? nil : mapColor (color: bg, isFg: false, isBold: false),
            underline: flags.contains (.underline) ? attribute.underlineStyle : nil,
            underlineInk: underlineInk,
            strikethrough: flags.contains (.crossedOut),
            overline: attribute.overline,
            hidden: flags.contains (.invisible))
        cellStyles [attribute] = style
        return style
    }

    private func kittyImageFromRgba(bytes: [UInt8], width: Int, height: Int) -> TTImage? {
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let data = Data(bytes)
        guard let providerRef = CGDataProvider(data: data as CFData) else {
            return nil
        }
        guard let cgimage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: width * 4,
                                    space: rgbColorSpace,
                                    bitmapInfo: bitmapInfo,
                                    provider: providerRef,
                                    decode: nil,
                                    shouldInterpolate: true,
                                    intent: .defaultIntent) else {
            return nil
        }
        return TTImage(cgImage: cgimage, size: CGSize(width: width, height: height))
    }

    private func kittyPlaceholderImage(imageId: UInt32, cache: inout [UInt32: TTImage]) -> TTImage? {
        if let cached = cache[imageId] {
            return cached
        }
        guard let kittyImage = terminal.kittyGraphicsState.imagesById[imageId] else {
            return nil
        }
        let image: TTImage?
        switch kittyImage.payload {
        case .png(let data):
            image = TTImage(data: data)
        case .rgba(let bytes, let width, let height):
            image = kittyImageFromRgba(bytes: bytes, width: width, height: height)
        }
        if let image {
            cache[imageId] = image
        }
        return image
    }

    private func kittyAspectFitRect(imageSize: CGSize, in rect: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0, rect.width > 0, rect.height > 0 else {
            return rect
        }
        let scale = min(rect.width / imageSize.width, rect.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(x: rect.origin.x + (rect.width - width) / 2,
                      y: rect.origin.y + (rect.height - height) / 2,
                      width: width,
                      height: height)
    }
    
    //
    // Lays out one row for drawing: the text CoreText shapes, which cell every
    // UTF-16 offset belongs to, and the background, decoration and custom glyph
    // spans in column coordinates.
    //
    func buildLineInfo (row: Int, line: BufferLine, cols: Int) -> ViewLineInfo
    {
        var builder = ViewLineInfoBuilder (columns: cols)
        var previousPlaceholder: KittyPlaceholderCell?
        var previousPlaceholderAttribute: Attribute?
        var col = 0
        
        while col < cols {
            let ch: CharData = line[col]
            let width = min (max (1, Int (ch.width)), cols - col)
            let attribute = ch.attribute
            let style = cellStyle (for: attribute)
            
            if let background = style.background {
                builder.appendBackground (background, column: col, width: width)
            }
            let character = ch.code == 0 ? " " : terminal.getCharacter (for: ch)
            var glyphText = style.hidden ? " " : String (character)
            
            if !style.hidden {
                if let underline = style.underline {
                    builder.appendDecoration (.underline (underline), ink: style.underlineInk, column: col, width: width)
                } else if ch.hasPayload {
                    builder.appendDecoration (.link, ink: style.foreground, column: col, width: width)
                }
                if style.strikethrough {
                    builder.appendDecoration (.strikethrough, ink: style.foreground, column: col, width: width)
                }
                if style.overline {
                    builder.appendDecoration (.overline, ink: style.foreground, column: col, width: width)
                }
            }
            
            if !style.hidden, customBlockGlyphs, ch.code != 0,
               let glyph = CustomGlyph.lookup (character) {
                builder.appendCustomGlyph (CustomGlyphRenderItem (column: col, columnWidth: width, glyph: glyph, ink: style.foreground))
                glyphText = " "
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            } else if let placeholder = KittyPlaceholderDecoder.decode(character: character,
                                                                       attribute: attribute,
                                                                       row: row,
                                                                       col: col,
                                                                       previous: previousPlaceholder,
                                                                       previousAttribute: previousPlaceholderAttribute) {
                builder.appendKittyPlaceholder (placeholder)
                glyphText = " "
                previousPlaceholder = placeholder
                previousPlaceholderAttribute = attribute
            } else {
                previousPlaceholder = nil
                previousPlaceholderAttribute = nil
            }
            
            // Blank cells have no ink, so they are left out of the shaped text
            if glyphText != " " {
                builder.appendText (glyphText, column: col, attribute: attribute, style: style)
            }
            col += width
        }
        
        return builder.build (selection: selectedColumnsRange (row: row, cols: cols), images: line.images)
    }
    
    /// Returns the selection range for the specified row, if any.
    func selectedColumnsRange(row: Int, cols: Int) -> Range<Int>? {
        guard let selection = self.selection, selection.active else {
            return nil
        }

        let startRow = selection.start.row
        let endRow = selection.end.row
        let startCol = selection.start.col
        let endCol = selection.end.col

        var selectionRange: NSRange = .empty

        // single row
        if endRow == startRow && startRow == row {
            if startCol < endCol {
                let extra = endCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: startCol, length: endCol - startCol + extra)
            } else if startCol > endCol {
                selectionRange = NSRange(location: endCol, length: startCol - endCol)
            }
        } else if endRow > startRow {
            // first row
            if startRow == row && endRow > row {
                selectionRange = NSRange(location: startCol, length: cols - startCol)
            }

            // in between
            if startRow < row && endRow > row {
                selectionRange = NSRange(location: 0, length: cols)
            }

            // last row
            if startRow < row && endRow == row {
                let extra = endCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: 0, length: endCol + extra)
            }
        } else if endRow < startRow {
            // first row
            if endRow == row && startRow > row {
                selectionRange = NSRange(location: endCol, length: cols - endCol)
            }

            // in between
            if startRow > row && endRow < row {
                selectionRange = NSRange(location: 0, length: cols)
            }

            // last row
            if endRow < row && startRow == row {
                let extra = startCol == terminal.cols-1 ? 1 : 0
                selectionRange = NSRange(location: 0, length: startCol + extra)
            }
        }

        if selectionRange == .empty || selectionRange.length == 0 {
            return nil
        }

        let lowerBound = max(0, min(selectionRange.location, cols))
        let upperBound = max(lowerBound, min(cols, selectionRange.location + selectionRange.length))
        if lowerBound == upperBound {
            return nil
        }
        return lowerBound..<upperBound
    }
    
    private func alignToPixel(_ value: CGFloat, scale: CGFloat, rule: FloatingPointRoundingRule) -> CGFloat {
        guard scale > 0 else {
            return value
        }
        return (value * scale).rounded(rule) / scale
    }

    private func pixelAlignedRect(_ rect: CGRect, scale: CGFloat) -> CGRect {
        let minX = alignToPixel(rect.minX, scale: scale, rule: .down)
        let maxX = alignToPixel(rect.maxX, scale: scale, rule: .up)
        let minY = alignToPixel(rect.minY, scale: scale, rule: .down)
        let maxY = alignToPixel(rect.maxY, scale: scale, rule: .up)
        return CGRect(x: minX,
                      y: minY,
                      width: max(0, maxX - minX),
                      height: max(0, maxY - minY))
    }

    /// Distance from the bottom of a cell to the text baseline.
    var baselineOffset: CGFloat {
        ceil(CTFontGetDescent(fontSet.normal) + CTFontGetLeading(fontSet.normal))
    }

    /// The rectangle covering columns `[start, end)` of a row; spans that reach the
    /// last column extend to the right edge of the view.
    private func columnsRect(start: Int, end: Int, lineOrigin: CGPoint) -> CGRect {
        let minX = lineOrigin.x + CGFloat(start) * cellDimension.width
        let maxX = end >= terminal.cols ? frame.width : lineOrigin.x + CGFloat(end) * cellDimension.width
        return CGRect(x: minX, y: lineOrigin.y, width: max(0, maxX - minX), height: cellDimension.height)
    }

    private func drawBackgrounds(_ info: ViewLineInfo, lineOrigin: CGPoint, in context: CGContext) {
        guard !info.backgrounds.isEmpty || info.selection != nil else {
            return
        }
        context.saveGState()
        context.setShouldAntialias(false)
        for run in info.backgrounds {
            context.setFillColor(run.color.cgColor)
            context.fill(columnsRect(start: run.start, end: run.end, lineOrigin: lineOrigin))
        }
        if let selection = info.selection {
            context.setFillColor(selectedTextBackgroundColor.cgColor)
            context.fill(columnsRect(start: selection.lowerBound, end: selection.upperBound, lineOrigin: lineOrigin))
        }
        context.restoreGState()
    }

    private func drawCustomGlyphs(_ items: [CustomGlyphRenderItem], lineOrigin: CGPoint, in context: CGContext) {
        guard !items.isEmpty else {
            return
        }
        let scale = backingScaleFactor()
        let lineThicknessPx = max(max(1, Int(round(scale))),
                                  Int(round(scale * fontSet.underlineThickness() * 1.35)))
        for item in items {
            let cell = CGRect(x: lineOrigin.x + CGFloat(item.column) * cellDimension.width,
                              y: lineOrigin.y,
                              width: cellDimension.width * CGFloat(item.columnWidth),
                              height: cellDimension.height)
            context.saveGState()
            item.ink.apply(to: context)
            let color = item.ink.paintColor
            switch item.glyph {
            case .box(let codePoint):
                context.setShouldAntialias(false)
                context.setAllowsAntialiasing(false)
                BoxDrawingRenderer.draw(codePoint: codePoint,
                                        in: context,
                                        cellOrigin: cell.origin,
                                        cellSize: cell.size,
                                        scale: scale,
                                        color: color,
                                        baseThicknessPx: lineThicknessPx)
            case .rects(let rects):
                drawBlockRects(rects, cell: cell, color: color, scale: scale, in: context)
            case .powerline(let codePoint):
                PowerlineRenderer.draw(codePoint: codePoint,
                                       in: context,
                                       cell: cell,
                                       color: color.cgColor,
                                       strokeWidth: CGFloat(lineThicknessPx) / scale)
            }
            context.restoreGState()
        }
    }

    private func drawBlockRects(_ rects: [BlockElementRect], cell: CGRect, color: TTColor, scale: CGFloat, in context: CGContext) {
        context.saveGState()
        let useAntialias = antiAliasCustomBlockGlyphs
        context.setShouldAntialias(useAntialias)
        context.setAllowsAntialiasing(useAntialias)
        let baseAlpha = color.cgColor.alpha
        for rect in rects {
            var drawRect = rect.rect(in: cell.origin, cellSize: cell.size)
            if !useAntialias {
                drawRect = pixelAlignedRect(drawRect, scale: scale)
            }
            if drawRect.width <= 0 || drawRect.height <= 0 {
                continue
            }
            let resolvedAlpha = max(0, min(1, baseAlpha * rect.alpha.rawValue))
            context.setFillColor(color.withAlphaComponent(resolvedAlpha).cgColor)
            context.fill(drawRect)
        }
        context.restoreGState()
    }

    /// Draws the row's glyphs. Every glyph is placed by the cell its characters
    /// belong to, not by the font's advances, so wide characters, emoji sequences,
    /// combining marks and fallback fonts all stay on the cell grid.
    private func drawText(_ info: ViewLineInfo, lineOrigin: CGPoint, in context: CGContext) {
        guard info.text.length > 0 else {
            return
        }
        let ctline = CTLineCreateWithAttributedString(info.text)
        guard let runs = CTLineGetGlyphRuns(ctline) as? [CTRun] else {
            return
        }
        let baseline = lineOrigin.y + baselineOffset
        let lastIndex = info.columnForUTF16.count - 1
        for run in runs {
            let count = CTRunGetGlyphCount(run)
            if count == 0 {
                continue
            }
            let runAttributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
            guard let runFont = runAttributes[.font] as? TTFont else {
                continue
            }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            CTRunGetGlyphs(run, CFRange(), &glyphs)
            var coreTextPositions = [CGPoint](repeating: .zero, count: count)
            CTRunGetPositions(run, CFRange(), &coreTextPositions)
            var stringIndices = [CFIndex](repeating: 0, count: count)
            CTRunGetStringIndices(run, CFRange(), &stringIndices)

            // Glyphs of one cell (a base and its marks, or a cluster the font does not
            // ligate) keep CoreText's offsets relative to the first glyph of that cell.
            var positions = [CGPoint](repeating: .zero, count: count)
            var anchorColumn = -1
            var anchorX: CGFloat = 0
            for i in 0..<count {
                let column = info.columnForUTF16[min(max(0, stringIndices[i]), lastIndex)]
                if column != anchorColumn {
                    anchorColumn = column
                    anchorX = coreTextPositions[i].x
                }
                positions[i] = CGPoint(x: lineOrigin.x + CGFloat(column) * cellDimension.width + coreTextPositions[i].x - anchorX,
                                       y: baseline + coreTextPositions[i].y)
            }
            let ink = runAttributes[.cellInk] as? CellInk ?? .color(nativeForegroundColor)
            ink.apply(to: context)
            CTFontDrawGlyphs(runFont, glyphs, positions, count, context)
        }
        context.setBlendMode(.normal)
    }

    /// Draws underlines (all SGR 4 styles), hyperlink underlines, strikethrough and
    /// overline as pixel-aligned spans across the cells they cover.
    private func drawDecorations(_ runs: [CellDecorationRun], lineOrigin: CGPoint, in context: CGContext) {
        guard !runs.isEmpty else {
            return
        }
        let scale = backingScaleFactor()
        let thickness = max(1, (fontSet.underlineThickness() * scale).rounded()) / scale
        let cellWidth = cellDimension.width
        let cellBottom = lineOrigin.y
        let cellTop = lineOrigin.y + cellDimension.height
        let baseline = lineOrigin.y + baselineOffset
        let underlineBottom = max(cellBottom,
                                  alignToPixel(baseline + fontSet.underlinePosition() - thickness / 2, scale: scale, rule: .down))
        let strikeBottom = alignToPixel(baseline + CTFontGetXHeight(fontSet.normal) / 2 - thickness / 2, scale: scale, rule: .down)

        func line(_ x0: CGFloat, _ x1: CGFloat, bottom: CGFloat) {
            context.fill(CGRect(x: x0, y: bottom, width: x1 - x0, height: thickness))
        }

        context.saveGState()
        context.setShouldAntialias(false)
        for run in runs {
            let x0 = lineOrigin.x + CGFloat(run.start) * cellWidth
            let x1 = lineOrigin.x + CGFloat(run.end) * cellWidth
            run.ink.apply(to: context)
            switch run.kind {
            case .underline(.single):
                line(x0, x1, bottom: underlineBottom)
            case .underline(.double):
                let lower = max(cellBottom, underlineBottom - 2 * thickness)
                line(x0, x1, bottom: lower)
                line(x0, x1, bottom: lower + 2 * thickness)
            case .underline(.curly):
                drawCurlyLine(from: x0, to: x1, cellBottom: cellBottom, thickness: thickness, in: context, ink: run.ink)
            case .underline(.dotted), .link:
                let dot = max(thickness, alignToPixel(1, scale: scale, rule: .up))
                var x = x0
                while x < x1 {
                    context.fill(CGRect(x: x, y: underlineBottom, width: min(dot, x1 - x), height: dot))
                    x += dot * 2
                }
            case .underline(.dashed):
                var cellX = x0
                while cellX < x1 {
                    let dashStart = alignToPixel(cellX + cellWidth * 0.2, scale: scale, rule: .toNearestOrAwayFromZero)
                    let dashEnd = alignToPixel(cellX + cellWidth * 0.8, scale: scale, rule: .toNearestOrAwayFromZero)
                    line(dashStart, dashEnd, bottom: underlineBottom)
                    cellX += cellWidth
                }
            case .strikethrough:
                line(x0, x1, bottom: strikeBottom)
            case .overline:
                line(x0, x1, bottom: cellTop - thickness)
            }
        }
        context.restoreGState()
    }

    /// The undercurl editors use for diagnostics: one wave per cell, kept between
    /// the bottom of the cell and the baseline.
    private func drawCurlyLine(from x0: CGFloat, to x1: CGFloat, cellBottom: CGFloat, thickness: CGFloat, in context: CGContext, ink: CellInk) {
        let room = baselineOffset
        let amplitude = max(thickness, room / 2 - thickness)
        let center = cellBottom + room / 2
        let halfWave = cellDimension.width / 2
        let path = CGMutablePath()
        path.move(to: CGPoint(x: x0, y: center))
        var x = x0
        var up = true
        while x < x1 {
            let next = x + halfWave
            path.addQuadCurve(to: CGPoint(x: next, y: center),
                              control: CGPoint(x: x + halfWave / 2, y: center + (up ? 2 : -2) * amplitude))
            x = next
            up.toggle()
        }
        context.saveGState()
        context.clip(to: CGRect(x: x0, y: cellBottom, width: x1 - x0, height: cellDimension.height))
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        ink.apply(to: context)
        context.setLineWidth(thickness)
        context.setLineCap(.round)
        context.addPath(path)
        context.strokePath()
        context.restoreGState()
    }

    /// Runs `body` with the context set up for the row's DEC line size (DECDWL / DECDHL).
    private func withLineTransform(_ renderMode: BufferLine.RenderLineMode, lineOrigin: CGPoint, width: CGFloat, context: CGContext, _ body: () -> Void) {
        let lineRect = CGRect(origin: lineOrigin, size: CGSize(width: width, height: cellDimension.height))
        switch renderMode {
        case .single:
            body()
            return
        case .doubledDown:
            context.saveGState()
            let pivot = lineOrigin.y
            context.clip(to: [lineRect])
            context.translateBy(x: 0, y: pivot)
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: 0, y: -pivot)
        case .doubledTop:
            context.saveGState()
            let pivot = lineOrigin.y + cellDimension.height
            context.clip(to: [lineRect])
            context.translateBy(x: 0, y: pivot)
            context.scaleBy(x: 2, y: 2)
            context.translateBy(x: 0, y: -pivot)
        case .doubleWidth:
            context.saveGState()
            context.scaleBy(x: 2, y: 1)
        }
        body()
        context.restoreGState()
    }

    private struct RowLayout {
        let row: Int
        let lineOrigin: CGPoint
        let renderMode: BufferLine.RenderLineMode
        let info: ViewLineInfo
    }

    // TODO: this should not render any lines outside the dirtyRect
    func drawTerminalContents (dirtyRect: TTRect, context: CGContext, bufferOffset: Int)
    {
        let displayBuffer = terminal.displayBuffer

        func calcLineOffset (forRow: Int) -> CGFloat {
            cellDimension.height * CGFloat (forRow-bufferOffset+1)
        }
        // draw lines
        #if os(iOS) || os(visionOS)
        // On iOS, we are drawing the exposed region
        let cellHeight = cellDimension.height
        let firstRow = Int (dirtyRect.minY/cellHeight)
        let lastRow = Int(dirtyRect.maxY/cellHeight)
        #else
        // On Mac, we are drawing the terminal buffer
        let cellHeight = cellDimension.height
        let boundsMaxY = bounds.maxY
        let firstRow = displayBuffer.yDisp+Int ((boundsMaxY-dirtyRect.maxY)/cellHeight)
        let lastRow = displayBuffer.yDisp+Int((boundsMaxY-dirtyRect.minY)/cellHeight)
        #endif

        let isAltBuffer = terminal.isCurrentBufferAlternate
        var virtualPlacementsByImageId: [UInt32: [KittyPlacementRecord]] = [:]
        if !terminal.kittyGraphicsState.placementsByKey.isEmpty {
            for record in terminal.kittyGraphicsState.placementsByKey.values where record.isVirtual && record.isAlternateBuffer == isAltBuffer {
                virtualPlacementsByImageId[record.imageId, default: []].append(record)
            }
        }
        var placeholderImageCache: [UInt32: TTImage] = [:]

        // The neighbors of the exposed rows are laid out too: their glyphs can overhang
        // into the exposed area, and drawing is clipped to the dirty region anyway.
        var layouts: [RowLayout] = []
        #if os(macOS)
        // Rows past the screen would show in the partial-row gap at the bottom of the view
        let lastDrawableRow = min(displayBuffer.lines.count, bufferOffset + displayBuffer.rows) - 1
        #else
        let lastDrawableRow = displayBuffer.lines.count - 1
        #endif
        let firstLaidOutRow = max(0, firstRow - 1)
        let lastLaidOutRow = min(lastDrawableRow, lastRow + 1)
        if firstLaidOutRow <= lastLaidOutRow {
            for row in firstLaidOutRow...lastLaidOutRow {
                let line = displayBuffer.lines [row]
                layouts.append(RowLayout(row: row,
                                         lineOrigin: CGPoint(x: 0, y: frame.height - calcLineOffset(forRow: row)),
                                         renderMode: line.renderMode,
                                         info: buildLineInfo(row: row, line: line, cols: displayBuffer.cols)))
            }
        }

        // Every background goes down before any glyph, so glyphs that overhang
        // their cell (italics, tall fallback glyphs) are not cut by the next row.
        for layout in layouts {
            withLineTransform(layout.renderMode, lineOrigin: layout.lineOrigin, width: dirtyRect.width, context: context) {
                drawBackgrounds(layout.info, lineOrigin: layout.lineOrigin, in: context)
            }
        }

        for layout in layouts {
            let lineOrigin = layout.lineOrigin
            let lineInfo = layout.info
            let rowBase = lineOrigin.y + cellDimension.height
            withLineTransform(layout.renderMode, lineOrigin: lineOrigin, width: dirtyRect.width, context: context) {
                var underTextImages: [AppleImage] = []
                var overTextKittyImages: [AppleImage] = []
                var otherImages: [AppleImage] = []
                if let images = lineInfo.images {
                    for basicImage in images {
                        guard let image = basicImage as? AppleImage else {
                            continue
                        }
                        if image.kittyIsKitty {
                            if image.kittyZIndex < 0 {
                                underTextImages.append(image)
                            } else {
                                overTextKittyImages.append(image)
                            }
                        } else {
                            otherImages.append(image)
                        }
                    }
                    let sortKitty: (AppleImage, AppleImage) -> Bool = { lhs, rhs in
                        if lhs.kittyZIndex != rhs.kittyZIndex {
                            return lhs.kittyZIndex < rhs.kittyZIndex
                        }
                        let leftId = lhs.kittyImageId ?? 0
                        let rightId = rhs.kittyImageId ?? 0
                        return leftId < rightId
                    }
                    underTextImages.sort(by: sortKitty)
                    overTextKittyImages.sort(by: sortKitty)
                }

                if !underTextImages.isEmpty {
                    let offsetScale = getImageScale()
                    for image in underTextImages {
                        let col = image.col
                        let offsetX = CGFloat(image.kittyPixelOffsetX) / offsetScale
                        let offsetY = CGFloat(image.kittyPixelOffsetY) / offsetScale
                        let rect = CGRect(x: CGFloat (col)*cellDimension.width + offsetX,
                                          y: rowBase - CGFloat (image.pixelHeight) + offsetY,
                                          width: CGFloat (image.pixelWidth),
                                          height: CGFloat (image.pixelHeight))
                        image.image.draw (in: rect)
                    }
                }

                drawCustomGlyphs(lineInfo.customGlyphs, lineOrigin: lineOrigin, in: context)

                context.setShouldAntialias(true)
                context.setAllowsAntialiasing(true)
                #if os(macOS)
                context.setShouldSmoothFonts(true)
                context.setAllowsFontSmoothing(true)
                #endif
                drawText(lineInfo, lineOrigin: lineOrigin, in: context)
                drawDecorations(lineInfo.decorations, lineOrigin: lineOrigin, in: context)

                if !lineInfo.kittyPlaceholders.isEmpty {
                    for placeholder in lineInfo.kittyPlaceholders {
                        guard let records = virtualPlacementsByImageId[placeholder.imageId] else {
                            continue
                        }
                        guard let record = records.first(where: { record in
                            if placeholder.placementId != 0 && record.placementId != placeholder.placementId {
                                return false
                            }
                            return record.cols > placeholder.placeholderCol &&
                                record.rows > placeholder.placeholderRow &&
                                record.cols > 0 &&
                                record.rows > 0
                        }) else {
                            continue
                        }
                        guard let image = kittyPlaceholderImage(imageId: placeholder.imageId, cache: &placeholderImageCache) else {
                            continue
                        }

                        let offsetScale = getImageScale()
                        let offsetX = CGFloat(record.pixelOffsetX) / offsetScale
                        let offsetY = CGFloat(record.pixelOffsetY) / offsetScale
                        let placementOriginX = lineOrigin.x + CGFloat(placeholder.col - placeholder.placeholderCol) * cellDimension.width + offsetX
                        let placementTopY = lineOrigin.y + CGFloat(placeholder.placeholderRow) * cellDimension.height
                        let placementOriginY = placementTopY - CGFloat(record.rows - 1) * cellDimension.height + offsetY
                        let placementRect = CGRect(x: placementOriginX,
                                                   y: placementOriginY,
                                                   width: CGFloat(record.cols) * cellDimension.width,
                                                   height: CGFloat(record.rows) * cellDimension.height)
                        if placementRect.width <= 0 || placementRect.height <= 0 {
                            continue
                        }
                        let imageRect = kittyAspectFitRect(imageSize: image.size, in: placementRect)
                        let cellRect = CGRect(x: lineOrigin.x + CGFloat(placeholder.col) * cellDimension.width,
                                              y: lineOrigin.y,
                                              width: cellDimension.width,
                                              height: cellDimension.height)
                        context.saveGState()
                        context.clip(to: cellRect)
                        image.draw(in: imageRect)
                        context.restoreGState()
                    }
                }

                if !overTextKittyImages.isEmpty {
                    let offsetScale = getImageScale()
                    for image in overTextKittyImages {
                        let col = image.col
                        let offsetX = CGFloat(image.kittyPixelOffsetX) / offsetScale
                        let offsetY = CGFloat(image.kittyPixelOffsetY) / offsetScale
                        let rect = CGRect(x: CGFloat (col)*cellDimension.width + offsetX,
                                          y: rowBase - CGFloat (image.pixelHeight) + offsetY,
                                          width: CGFloat (image.pixelWidth),
                                          height: CGFloat (image.pixelHeight))
                        image.image.draw (in: rect)
                    }
                }
                for image in otherImages {
                    let col = image.col
                    let rect = CGRect(x: CGFloat (col)*cellDimension.width,
                                      y: rowBase - CGFloat (image.pixelHeight),
                                      width: CGFloat (image.pixelWidth),
                                      height: CGFloat (image.pixelHeight))
                    image.image.draw (in: rect)
                }
            }
        }
        
#if os(iOS) || os(visionOS)
        if selection.active {
            let start, end: Position

            func drawSelectionHandle (drawStart: Bool, row: Int) {
                let lineOffset = calcLineOffset(forRow: row)
                let lineOrigin = frame.height - lineOffset
                
                context.saveGState ()
                let start = CGPoint (
                    x: CGFloat (drawStart ? start.col : end.col) * cellDimension.width,
                    y: lineOrigin)
                let end = CGPoint(x: start.x, y: start.y + cellDimension.height)
                
                context.move(to: end)
                context.addLine(to: start)
                let size = 12.0
                let location = drawStart ? end : start
                
                let rect = CGRect (origin:
                                    CGPoint (x: location.x-(size/2.0),
                                             y: location.y - (drawStart ? 0.0 : size)),
                                   size: CGSize (width: size, height: size))
                context.addEllipse(in: rect)
                context.closePath()
                context.setLineWidth(2)
                selectionHandleColor.set ()
                //TTColor.systemBlue.set ()
                context.drawPath(using: .fillStroke)
                context.restoreGState()
            }
            
            // Normalize the selection start/end, regardless of where it started
            let sstart = selection.start
            let send = selection.end
            if Position.compare (sstart, send) == .before {
                start = sstart
                end = send
            } else {
                start = send
                end = sstart
            }
            
            drawSelectionHandle (drawStart: true, row: start.row)
            drawSelectionHandle (drawStart: false, row: end.row)
        }
#endif
    }
    
    /// Update visible area
    func updateDisplay (notifyAccessibility: Bool)
    {
        if terminal.isSynchronizedOutputActive {
            // A synchronized-output frame (mode 2026) is open: hold the redraw and
            // keep the accumulated update range. synchronizedOutputChanged queues a
            // display update when the frame closes.
            pendingDisplay = false
            return
        }
        updateCursorPosition()
        guard let (rowStart, rowEnd) = terminal.getUpdateRange () else {
            if notifyUpdateChanges {
                let buffer = terminal.displayBuffer
                let y = buffer.yDisp+buffer.y
                terminalDelegate?.rangeChanged (source: self, startY: y, endY: y)
            }
            return
        }
        if notifyUpdateChanges {
            terminalDelegate?.rangeChanged (source: self, startY: rowStart, endY: rowEnd)
        }

        terminal.clearUpdateRange ()
                
        #if os(macOS)
        let baseLine = frame.height
        var region = CGRect (x: 0,
                             y: baseLine - (cellDimension.height + CGFloat(rowEnd) * cellDimension.height),
                             width: frame.width,
                             height: CGFloat(rowEnd-rowStart + 1) * cellDimension.height)
        
        // If we are the last line, we should also queue a refresh for the "remaining" bits at the
        // end which can be redrawn by large unicode
        if rowEnd == terminal.rows - 1 {
            let oh = region.height
            let oy = region.origin.y
            region = CGRect (x: 0, y: 0, width: frame.width, height: oh + oy)
        }
        setNeedsDisplay(region)
        #else
        // TODO iOS: need to update the code above, but will do that when I get some real
        // life data being fed into it.
        setNeedsDisplay(bounds)
        #endif
        
        pendingDisplay = false
        updateDebugDisplay ()
        
        if (notifyAccessibility) {
            accessibility.invalidate ()
            #if os(macOS)
            NSAccessibility.post (element: self, notification: .valueChanged)
            NSAccessibility.post (element: self, notification: .selectedTextChanged)
            #endif
        }
    }
    
    func updateCursorPosition()
    {
        guard let caretView else { return }
        //let lineOrigin = CGPoint(x: 0, y: frame.height - (cellDimension.height * (CGFloat(terminal.buffer.y - terminal.buffer.yDisp + 1))))
        //caretView.frame.origin = CGPoint(x: lineOrigin.x + (cellDimension.width * CGFloat(terminal.buffer.x)), y: lineOrigin.y)
        let buffer = terminal.displayBuffer
        let vy = buffer.yBase + buffer.y
        
        if vy >= buffer.yDisp + buffer.rows {
            caretView.removeFromSuperview()
            return
        } else if terminal.cursorHidden == false && caretView.superview != self {
            addSubview(caretView)
        } else if terminal.cursorHidden == true && !neverHideCaret && caretView.superview == self {
            caretView.removeFromSuperview()
        }
        let doublePosition = buffer.lines [vy].renderMode == .single ? 1.0 : 2.0
        #if os(iOS) || os(visionOS)
        let offset = (cellDimension.height * (CGFloat(buffer.y+(buffer.yBase))))
        let lineOrigin = CGPoint(x: 0, y: offset)
        #else
        let offset = (cellDimension.height * (CGFloat(buffer.y-(buffer.yDisp-buffer.yBase)+1)))
        let lineOrigin = CGPoint(x: 0, y: frame.height - offset)
        #endif
        let cell = buffer.lines [vy][buffer.x]
        // The caret covers the whole character under it, two cells for wide characters
        let cellColumns = CGFloat (max (1, Int (cell.width)))
        caretView.frame = CGRect (x: lineOrigin.x + (cellDimension.width * doublePosition * CGFloat(buffer.x)),
                                  y: lineOrigin.y,
                                  width: cellDimension.width * doublePosition * cellColumns,
                                  height: cellDimension.height)
        caretView.setText (ch: cell)
    }
    
    // Does not use a default argument and merge, because it is called back
    func updateDisplay ()
    {
        updateDisplay (notifyAccessibility: true)
        updateDebugDisplay()
        pendingDisplay = false
    }
    
    //
    // The code below is intended to not repaint too often, which can produce flicker, for example
    // when the user refreshes the display, and this repains the screen, as dispatch delivers data
    // in blocks of 1024 bytes, which is not enough to cover the whole screen, so this delays
    // the update for a 1/600th of a second.
    //
    // It is also cheap, so should be called when new data has been posted or received.
    func queuePendingDisplay ()
    {
        // throttle
        if !pendingDisplay {
            let fps60 = 16670000
            // let fps30 = 16670000*2
            let fpsDelay = fps60
            pendingDisplay = true
            DispatchQueue.main.asyncAfter(
                deadline: DispatchTime (uptimeNanoseconds: DispatchTime.now().uptimeNanoseconds + UInt64 (fpsDelay)),
                execute: updateDisplay)
        }
    }
    
    ///
    /// This takes a string returned by events (NSEvent or UIKey) as the 'charactersIngoringModifiers'
    /// and returns the control-version of that, and only applies to a handful of characters
    ///
    func applyControlToEventCharacters (_ ch: String) -> [UInt8]
    {
        let arr = [UInt8](ch.utf8)
        if arr.count == 1 {
            let ch = Character (UnicodeScalar (arr [0]))
            var value: UInt8
            switch ch {
            case "A"..."Z":
                value = (ch.asciiValue! - 0x40 /* - 'A' + 1 */)
            case "a"..."z":
                value = (ch.asciiValue! - 0x60 /* - 'a' + 1 */)
            case "\\":
                value = 0x1c
            case "_":
                value = 0x1f
            case "]":
                value = 0x1d
            case "[":
                value = 0x1b
            case "^", "6":
                value = 0x1e
            case " ":
                value = 0
            default:
                return []
            }
            return [value]
        }
        return []
    }
    /**
     * Returns the thumb size in proportion to the visible content of the entire content, alternate buffers are not scrollable, so this returns 0
     */
    public var scrollThumbsize: CGFloat {
        get {
            let displayBuffer = terminal.displayBuffer
            if terminal.isDisplayBufferAlternate {
                return 0
            }
            
            // the thumb size is the proportion of the visible content of the
            // entire content but don't make it too small
            return max (CGFloat (displayBuffer.rows) / CGFloat (displayBuffer.lines.count), 0.01)
        }
    }
    
    /**
     * Gets a value indicating the relative position of the terminal viewport
     */
    public var scrollPosition: Double {
        get {
            let displayBuffer = terminal.displayBuffer
            if terminal.isDisplayBufferAlternate || displayBuffer.yDisp <= 0 {
                return 0
            }
            
            let maxScrollback = displayBuffer.lines.count - displayBuffer.rows
            if displayBuffer.yDisp >= maxScrollback {
                return 1
            }
            
            return Double (displayBuffer.yDisp) / Double (maxScrollback)
        }
    }
    
    /// <summary>
    /// Gets a value indicating whether or not the user can scroll the terminal contents
    /// </summary>
    public var canScroll: Bool {
        get {
            let displayBuffer = terminal.displayBuffer
            return !terminal.isDisplayBufferAlternate &&
                displayBuffer.hasScrollback &&
                displayBuffer.lines.count > displayBuffer.rows
        }
    }
    
    public func scroll (toPosition: Double)
    {
        userScrolling = true
        let displayBuffer = terminal.displayBuffer
        let oldPosition = displayBuffer.yDisp

        let maxScrollback = displayBuffer.lines.count - displayBuffer.rows
        var newScrollPosition = Int (Double (maxScrollback) * toPosition)

        if newScrollPosition < 0 {
            newScrollPosition = 0
        }
        if newScrollPosition > maxScrollback {
            newScrollPosition = maxScrollback
        }

        if newScrollPosition != oldPosition {
            scrollTo(row: newScrollPosition)
        }
        userScrolling = false
        terminal.userScrolling = displayBuffer.yDisp < displayBuffer.yBase
    }
    
    func scrollTo (row: Int, notifyAccessibility: Bool = true)
    {
        let displayBuffer = terminal.displayBuffer
        if row != displayBuffer.yDisp {
            terminal.setViewYDisp (row)
            
            // tell the terminal we want to refresh all the rows
            terminal.refresh (startRow: 0, endRow: terminal.rows)
            
            // do the display update
            updateDisplay (notifyAccessibility: notifyAccessibility)
            //selectionView.notifyScrolled(source: terminal)
            terminalDelegate?.scrolled (source: self, position: scrollPosition)
            updateScroller()
            setNeedsDisplay(frame)
        }
    }
    
    /// Scrolls the content of the terminal one page up
    public func pageUp()
    {
        if terminal.isDisplayBufferAlternate {
            send (EscapeSequences.cmdPageUp)
        } else {
            scrollUp (lines: terminal.rows)
        }
    }
    
    /// Scrolls the content of the terminal one page down
    public func pageDown ()
    {
        if terminal.isDisplayBufferAlternate {
            send (EscapeSequences.cmdPageDown)
        } else {
            scrollDown (lines: terminal.rows)
        }
    }

    /// Scrolls up the content of the terminal the specified number of lines
    public func scrollUp (lines: Int)
    {
        let newPosition = max (terminal.displayBuffer.yDisp - lines, 0)
        scrollTo (row: newPosition)
    }
    
    /// Scrolls down the content of the terminal the specified number of lines
    public func scrollDown (lines: Int)
    {
        let displayBuffer = terminal.displayBuffer
        let newPosition = max (0, min (displayBuffer.yDisp + lines, displayBuffer.lines.count - displayBuffer.rows))
        scrollTo (row: newPosition)
    }
      
    func feedPrepare()
    {
        search.invalidate()
        selection.active = false
        startDisplayUpdates()
    }
    
    func feedFinish ()
    {
        suspendDisplayUpdates ()
        queuePendingDisplay()
    }
    
    /// Sends data to the terminal emulator for interpretation, this can be invoked from a background thread
    public func feed (byteArray: ArraySlice<UInt8>)
    {
        feedPrepare()
        terminal.feed (buffer: byteArray)
        feedFinish()
    }
    
    /// Sends data to the terminal emulator for interpretation, this can be invoked from a background thread
    public func feed (text: String)
    {
        feedPrepare()
        terminal.feed (text: text)
        feedFinish()
    }
         
    /**
     * Triggers a resize of the underlying terminal to the desired columsn and rows
     */
    public func resize (cols: Int, rows: Int)
    {
        terminal.resize (cols: cols, rows: rows)
        sizeChanged (source: terminal)
        terminal.softReset()
    }
    
    /**
     * Sends the specified slice of byte arrays to the program running under the terminal emulator
     * - Parameter data: the slice of an array to send to the client
     */
    public func send(data: ArraySlice<UInt8>)
    {
        if scrollToBottomOnInput {
            ensureCaretIsVisible ()
        }
        #if os(iOS) || os(visionOS)
        if TerminalView.textInputDebugEnabled {
            let previewBytes = data.prefix(32).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("UITextInput[\(TerminalView.textInputLogCounter + 1)]: send bytes=\(data.count) [\(previewBytes)]")
            TerminalView.textInputLogCounter += 1
        }
        #endif
        terminalDelegate?.send (source: self, data: data)
    }
    
    /**
     * Sends the specified string encoded at utf8 to the program running under the terminal emulator
     * - Parameter txt: the string to send to the client
     */
    public func send (txt: String) {
        #if os(iOS) || os(visionOS)
        if TerminalView.textInputDebugEnabled {
            print("UITextInput[\(TerminalView.textInputLogCounter + 1)]: send txt=\(txt.debugDescription)")
            TerminalView.textInputLogCounter += 1
        }
        #endif
        let array = [UInt8] (txt.utf8)
        send (data: array[...])
    }
    
    /**
     * Sends the specified array of bytes to the program running under the terminal emulator
     * - Parameter bytes: the bytes to send to the client
     */
    public func send (_ bytes: [UInt8]) {
        send (data: (bytes)[...])
    }
    
    func sendKeyUp ()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal)
    }
    
    func sendKeyDown ()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal)
    }
    
    func sendKeyLeft()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal)
    }
    
    func sendKeyRight ()
    {
        send (terminal.applicationCursor ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal)
    }
    
    class AppleImage: TerminalImage, KittyPlacementImage {
        var image: TTImage
        var pixelWidth: Int
        var pixelHeight: Int
        var col: Int
        var kittyIsKitty: Bool = false
        var kittyImageId: UInt32?
        var kittyImageNumber: UInt32?
        var kittyPlacementId: UInt32?
        var kittyZIndex: Int = 0
        var kittyCol: Int = 0
        var kittyRow: Int = 0
        var kittyCols: Int = 0
        var kittyRows: Int = 0
        var kittyPixelOffsetX: Int = 0
        var kittyPixelOffsetY: Int = 0
        
        init (image: TTImage, width: Int, height: Int, onCol: Int) {
            self.image = image
            self.pixelWidth = width
            self.pixelHeight = height
            self.col = onCol
        }
    }
    // Computes the number of columns and rows used by the image
    func computeCellRows (_ size: CGSize) -> (cols: Int, rows: Int) {
        return (cols: Int ((size.width+cellDimension.width-1)/cellDimension.width),
                rows: Int ((size.height+cellDimension.height-1)/cellDimension.height))
    }
    
    public func createImageFromBitmap(source: Terminal, bytes: inout [UInt8], width: Int, height: Int) {
        let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let pixelData = NSData(bytes: bytes, length: bytes.count)
        guard let providerRef: CGDataProvider = CGDataProvider(data: pixelData) else {
            return
        }
        guard let cgimage: CGImage = CGImage(
                width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: width * 4, space: rgbColorSpace, bitmapInfo: bitmapInfo,
                provider: providerRef, decode: nil, shouldInterpolate: true,
                intent: .defaultIntent) else {
            return
        }
        
        let image = TTImage (cgImage: cgimage, size: CGSize (width: width, height: height))
        if let context = terminal.kittyPlacementContext {
            insertImage (image, width: context.widthRequest, height: context.heightRequest, preserveAspectRatio: context.preserveAspectRatio)
        } else {
            insertImage (image, width: CGFloat (width) > frame.width ? .percent(100) : .auto, height: .auto, preserveAspectRatio: true)
        }
    }
   
    public func createImage (source: Terminal, data: Data, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        guard let img = TTImage(data: data) else {
            return
        }
        insertImage (img, width: widthRequest, height: heightRequest, preserveAspectRatio: preserveAspectRatio)
    }
    
    // Inserts the specified image at the current buffer position (x, y) using the specified size requests
    // and aspect ratio request.   The insertion is done by adding slices of the image, one per line
    // to the buffer.
    func insertImage (_ image: TTImage, width widthRequest: ImageSizeRequest, height heightRequest: ImageSizeRequest, preserveAspectRatio: Bool)
    {
        let buffer = terminal.buffer
        var img = image
        let displayScale = getImageScale ()
        let placementContext = terminal.kittyPlacementContext
        
        // Converts a size request in a single dimension into an absolute pixel value, where
        // the `dim` is the request, `regionSize` is the available view space, and `imageSize` is
        // the size of the image along the dimension being requested
        func getPixels (fromDim dim: ImageSizeRequest, regionSize: CGFloat, imageSize: CGFloat, cellSize: CGFloat) -> CGFloat {
            switch dim {
            case .auto:
                return imageSize/displayScale
            case .cells(let n):
                return cellSize * CGFloat (n)
            case .pixels(let n):
                return CGFloat (n)
            case .percent(let pct):
                return CGFloat (pct) * 0.01 * regionSize
            }
        }

        func pixelSizeForImage (_ image: TTImage) -> CGSize? {
            #if os(macOS)
            for rep in image.representations {
                if rep.pixelsWide > 0 && rep.pixelsHigh > 0 {
                    return CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                }
            }
            return nil
            #else
            if let cgImage = image.cgImage {
                return CGSize(width: cgImage.width, height: cgImage.height)
            }
            let scale = image.scale
            if scale > 0 {
                return CGSize(width: image.size.width * scale, height: image.size.height * scale)
            }
            return nil
            #endif
        }

        let pixelSize = placementContext == nil ? nil : pixelSizeForImage(img)
        let widthImageSize: CGFloat
        let heightImageSize: CGFloat
        switch widthRequest {
        case .auto:
            widthImageSize = pixelSize?.width ?? img.size.width
        default:
            widthImageSize = img.size.width
        }
        switch heightRequest {
        case .auto:
            heightImageSize = pixelSize?.height ?? img.size.height
        default:
            heightImageSize = img.size.height
        }

        var width = getPixels (fromDim: widthRequest, regionSize: frame.width, imageSize: widthImageSize, cellSize: cellDimension.width)
        var height = getPixels (fromDim: heightRequest, regionSize: frame.height, imageSize: heightImageSize, cellSize: cellDimension.height)
        
        if preserveAspectRatio {
            switch (widthRequest, heightRequest) {
            case (.auto, .auto):
                break
            case (_, .auto):
                height = (width * img.size.height) / img.size.width
            case (.auto, _):
                width = (height * img.size.width) / img.size.height
            case (_, _):
                img = scale (image: img, size: CGSize (width: width, height: height))
            }
        }
        
        let rows = Int (ceil (height/cellDimension.height))
        let cols = Int (ceil (width/cellDimension.width))
        let placementRow = buffer.y + buffer.yBase
        let placementCol = buffer.x
        if let context = placementContext,
           let imageId = context.imageId,
           let placementId = context.placementId {
            terminal.registerKittyPlacement(imageId: imageId,
                                            placementId: placementId,
                                            parentImageId: context.parentImageId,
                                            parentPlacementId: context.parentPlacementId,
                                            parentOffsetH: context.parentOffsetH,
                                            parentOffsetV: context.parentOffsetV,
                                            pixelOffsetX: context.pixelOffsetX,
                                            pixelOffsetY: context.pixelOffsetY,
                                            col: placementCol,
                                            row: placementRow,
                                            cols: cols,
                                            rows: rows,
                                            zIndex: context.zIndex,
                                            isVirtual: false)
        }
        
        let stripeSize = CGSize (width: width, height: cellDimension.height)
        var didScroll = false
        #if os(iOS) || os(visionOS)
        var srcY: CGFloat = 0
        #else
        var srcY: CGFloat = img.size.height
        #endif
        
        let heightRatio = img.size.height/height
        for _ in 0..<rows {
            #if os(macOS)
            srcY -= cellDimension.height * heightRatio
            #endif
            guard let stripe = drawImageInStripe (image: img, srcY: srcY, width: width, srcHeight: cellDimension.height * heightRatio, dstHeight: cellDimension.height, size: stripeSize) else {
                continue
            }
            #if os(iOS) || os(visionOS)
            srcY += cellDimension.height * heightRatio
            #endif
            
            let attachedImage = AppleImage (image: stripe, width: Int (stripeSize.width), height: Int (cellDimension.height), onCol: terminal.buffer.x)
            if let context = placementContext {
                attachedImage.kittyIsKitty = true
                attachedImage.kittyImageId = context.imageId
                attachedImage.kittyImageNumber = context.imageNumber
                attachedImage.kittyPlacementId = context.placementId
                attachedImage.kittyZIndex = context.zIndex
                attachedImage.kittyCol = placementCol
                attachedImage.kittyRow = placementRow
                attachedImage.kittyCols = cols
                attachedImage.kittyRows = rows
                attachedImage.kittyPixelOffsetX = context.pixelOffsetX
                attachedImage.kittyPixelOffsetY = context.pixelOffsetY
            }
            
            buffer.attachImage(attachedImage, toLineAt: buffer.y+buffer.yBase)

            terminal.updateRange (buffer.y)

            // The buffer.x position would have changed depending on the lineFeedMode (LNM)
            // for image rendering, we want the x to remain the same
            let savedX = buffer.x
            let previousYBase = buffer.yBase
            let previousLinesTop = buffer.linesTop
            terminal.cmdLineFeed()
            if buffer.yBase != previousYBase || buffer.linesTop != previousLinesTop {
                didScroll = true
            }
            buffer.x = savedX
        }
        if didScroll {
            terminal.updateFullScreen()
        }
        if let context = placementContext,
           context.cursorPolicy == 0,
           !context.isRelative {
            let moveCols = max(1, cols)
            let moveRows = max(1, rows)
            let targetCol = placementCol + moveCols
            let targetRow = placementRow + moveRows
            buffer.x = targetCol
            buffer.y = targetRow - buffer.yBase
            terminal.restrictCursor()
        }
    }
    
    /// Set to true if the selection is active, false otherwise
    public var selectionActive: Bool {
        get {
            selection.active
        }
    }
    
    
    /// Returns the contents of the selection, if active, or nil otherwise
    public func getSelection () -> String?
    {
        if selection.active {
            return selection.getSelectedText()
        }
        return nil
    }
    
    /// Selects the entire buffer
    public func selectAll () {
        selection.selectAll()
    }
    
    /// Clears the selection
    public func selectNone () {
        selection.selectNone()
    }
    
}

#if canImport(UIKit) && DEBUG
#Preview {
    SwiftUITerminalView { t in
        t.nativeBackgroundColor = UIColor.black
        t.selectedTextBackgroundColor = UIColor.red
        t.caretColor = UIColor.blue
        t.feed(text: "م اَلْفِرَاق\n\rbbفِaa\n\r123456\n\r🖐🏾 or 👩‍👩‍👦‍👦")
    }
}
#endif

#endif
