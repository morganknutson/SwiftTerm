import Testing
@testable import SwiftTerm

/// Writing over either half of a wide character erases the whole character, so
/// no orphaned half is left behind for the renderer to draw.
final class WideCharacterOverwriteTests {
    private let esc = "\u{1b}"

    private func row(_ text: String, cols: Int = 10) -> (cells: [CharData], text: String) {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: cols, rows: 2)
        terminal.feed(text: text)
        let cells = (0..<cols).compactMap { TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: $0) }
        // Null (erased) cells read as spaces; the cell after a wide character is skipped
        let line = (TerminalTestHarness.lineText(buffer: terminal.buffer, terminal: terminal, row: 0) ?? "")
            .replacingOccurrences(of: "\u{0}", with: " ")
        return (cells, line)
    }

    @Test func testOverwritingFirstHalfErasesSecondHalf() {
        let result = row("日本\(esc)[1Gx")
        #expect(result.text == "x 本")
        #expect(result.cells[1].width == 1)
    }

    @Test func testOverwritingSecondHalfErasesFirstHalf() {
        let result = row("日本\(esc)[2Gx")
        #expect(result.text == " x本")
        #expect(result.cells[0].width == 1)
    }

    @Test func testWideOverStaggeredWideErasesBothNeighbors() {
        // A wide character written at column 1 covers the end of 日 and the start of 本
        let result = row("日本\(esc)[2G語")
        #expect(result.text == " 語")
        #expect(result.cells[0].width == 1)
        #expect(result.cells[1].width == 2)
        #expect(result.cells[3].width == 1)
    }

    @Test func testErasedHalfKeepsItsBackground() {
        let result = row("\(esc)[44m日\(esc)[0m\(esc)[1Gx")
        #expect(result.cells[1].attribute.bg == .ansi256(code: 4))
    }

    @Test func testEraseFromSecondHalfErasesWholeCharacter() {
        // EL starting on the second half of 日
        let result = row("ab日cd\(esc)[4G\(esc)[K")
        #expect(result.text == "ab")
        #expect(result.cells[2].width == 1)
    }

    @Test func testEraseCharsEndingInFirstHalfErasesWholeCharacter() {
        // ECH over "b" and the first half of 日
        let result = row("ab日cd\(esc)[2G\(esc)[2X")
        #expect(result.text == "a   cd")
    }

    @Test func testDeleteCharsInsideWideCharacter() {
        // DCH on the second half of 日 must not leave its first half behind
        let result = row("ab日cd\(esc)[4G\(esc)[P")
        #expect(result.text == "ab cd")
        #expect(result.cells[2].width == 1)
    }

    @Test func testInsertCharsInsideWideCharacter() {
        // ICH on the second half of 日 splits it, so it is erased
        let result = row("ab日cd\(esc)[4G\(esc)[@")
        #expect(result.text == "ab   cd")
        #expect(result.cells.allSatisfy { $0.width == 1 })
    }

    @Test func testInsertModeInsideWideCharacter() {
        let result = row("ab日cd\(esc)[4G\(esc)[4hx\(esc)[4l")
        #expect(result.text == "ab x cd")
    }

    @Test func testWideCharacterCoversItsCellsWithItsAttribute() {
        let result = row("\(esc)[44m日")
        #expect(result.cells[1].width == 0)
        #expect(result.cells[1].attribute.bg == .ansi256(code: 4))
    }
}
