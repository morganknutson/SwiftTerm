#if os(macOS)
import AppKit
import Testing
@testable import SwiftTerm

/// Covers how a row is laid out for drawing: which cell every character lands
/// in, which spans get backgrounds and decorations, and which characters are
/// drawn from the cell geometry instead of the font.
final class LineLayoutTests {
    private let esc = "\u{1b}"

    private func layout(_ text: String, cols: Int = 20) -> ViewLineInfo {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        view.resize(cols: cols, rows: 2)
        view.feed(text: text)
        let terminal = view.getTerminal()
        return view.buildLineInfo(row: 0, line: terminal.buffer.lines[0], cols: terminal.cols)
    }

    /// The column of the cell that holds the first UTF-16 unit of `substring`.
    private func column(of substring: String, in info: ViewLineInfo) -> Int? {
        let range = (info.text.string as NSString).range(of: substring)
        guard range.location != NSNotFound else { return nil }
        return info.columnForUTF16[range.location]
    }

    @Test func testGlyphsMapToCellsAcrossWideClusters() {
        // Flags and ZWJ sequences are several scalars but one two-column cell
        let info = layout("a🇺🇸b👨‍👩‍👧c日d")
        #expect(column(of: "a", in: info) == 0)
        #expect(column(of: "🇺🇸", in: info) == 1)
        #expect(column(of: "b", in: info) == 3)
        #expect(column(of: "c", in: info) == 6)
        #expect(column(of: "日", in: info) == 7)
        #expect(column(of: "d", in: info) == 9)
    }

    @Test func testCombiningMarksStayInTheirCell() {
        let info = layout("e\u{301}x")
        #expect(column(of: "x", in: info) == 1)
    }

    @Test func testHiddenTextHasNoGlyphsButKeepsBackground() {
        let info = layout("\(esc)[8;41mSECRET\(esc)[0m")
        #expect(info.text.length == 0)
        #expect(info.backgrounds.count == 1)
        #expect(info.backgrounds.first?.start == 0)
        #expect(info.backgrounds.first?.end == 6)
    }

    @Test func testAdjacentBackgroundsMerge() {
        let info = layout("\(esc)[44mab\(esc)[1mcd\(esc)[0m  \(esc)[44mef")
        // Bold changes the text attribute but not the background color
        #expect(info.backgrounds.map { $0.start..<$0.end } == [0..<4, 6..<8])
    }

    @Test func testDecorationsSpanTheirCells() {
        let info = layout("x\(esc)[4:3mcurly\(esc)[4:0m \(esc)[9;53mso\(esc)[0m")
        let curly = info.decorations.first { $0.kind == .underline(.curly) }
        #expect(curly.map { $0.start..<$0.end } == 1..<6)
        #expect(info.decorations.contains { $0.kind == .strikethrough && $0.start == 7 && $0.end == 9 })
        #expect(info.decorations.contains { $0.kind == .overline && $0.start == 7 && $0.end == 9 })
    }

    @Test func testCustomGlyphRouting() {
        // Box drawing, both ends of the block element range, braille, sextants
        // (outside the BMP) and powerline are drawn from the cell geometry
        let info = layout("─▀▟⣿🬀\u{E0B0}a")
        #expect(info.customGlyphs.map { $0.column } == [0, 1, 2, 3, 4, 5])
        #expect(column(of: "a", in: info) == 6)
        #expect(!info.text.string.contains("▀"))
    }

    @Test func testCellWidthIsPixelAligned() {
        let view = TerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 100))
        let scale = view.backingScaleFactor()
        for size in [11.0, 12.0, 13.0, 14.5] {
            view.font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
            let pixels = view.cellDimension.width * scale
            #expect(abs(pixels - pixels.rounded()) < 0.0001)
            #expect(view.cellDimension.width >= view.font.advancement(forGlyph: view.font.glyph(withName: "W")).width - 0.01)
        }
    }
}
#endif
