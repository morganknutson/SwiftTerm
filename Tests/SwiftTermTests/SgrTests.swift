import Testing
@testable import SwiftTerm

final class SgrTests {
    private let esc = "\u{1b}"

    @Test func testBoldItalicUnderline() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[1;3;4mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.style.contains(.bold))
        #expect(cell.attribute.style.contains(.italic))
        #expect(cell.attribute.style.contains(.underline))
    }

    @Test func testResetBold() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[1mX\(esc)[22mY")

        let boldCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let resetCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(boldCell != nil)
        #expect(resetCell != nil)
        guard let boldCell, let resetCell else { return }
        #expect(boldCell.attribute.style.contains(.bold))
        #expect(!resetCell.attribute.style.contains(.bold))
    }

    @Test func testEightColorFgBg() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[31;44mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .ansi256(code: 1))
        #expect(cell.attribute.bg == .ansi256(code: 4))
    }

    @Test func test256ColorFgBg() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38;5;200;48;5;100mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .ansi256(code: 200))
        #expect(cell.attribute.bg == .ansi256(code: 100))
    }

    @Test func testTrueColorFgBgSemicolon() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38;2;1;2;3;48;2;4;5;6mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .trueColor(red: 1, green: 2, blue: 3))
        #expect(cell.attribute.bg == .trueColor(red: 4, green: 5, blue: 6))
    }

    @Test func testTrueColorFgColon() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[38:2:0:10:20:30mX")

        let cell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        #expect(cell != nil)
        guard let cell else { return }
        #expect(cell.attribute.fg == .trueColor(red: 10, green: 20, blue: 30))
    }

    @Test func testUnderlineColorSetAndReset() {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 5, rows: 1)
        terminal.feed(text: "\(esc)[4;58;2;9;8;7mX\(esc)[59mY")

        let setCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 0)
        let resetCell = TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: 1)
        #expect(setCell != nil)
        #expect(resetCell != nil)
        guard let setCell, let resetCell else { return }
        #expect(setCell.attribute.underlineColor == .trueColor(red: 9, green: 8, blue: 7))
        #expect(resetCell.attribute.underlineColor == nil)
    }

    private func cells(_ sequence: String, count: Int) -> [CharData] {
        let (terminal, _) = TerminalTestHarness.makeTerminal(cols: 20, rows: 1)
        terminal.feed(text: sequence)
        return (0..<count).compactMap { TerminalTestHarness.charData(buffer: terminal.buffer, row: 0, col: $0) }
    }

    @Test func testUnderlineStyleSubParameters() {
        let row = cells("\(esc)[4mA\(esc)[4:2mB\(esc)[4:3mC\(esc)[4:4mD\(esc)[4:5mE\(esc)[4:0mF", count: 6)
        #expect(row.count == 6)
        guard row.count == 6 else { return }
        let expected: [UnderlineStyle] = [.single, .double, .curly, .dotted, .dashed]
        for (cell, style) in zip(row, expected) {
            #expect(cell.attribute.style.contains(.underline))
            #expect(cell.attribute.underlineStyle == style)
        }
        #expect(!row[5].attribute.style.contains(.underline))
    }

    @Test func testUnderlineSubParameterIsNotAnAttribute() {
        // 4:3 is a curly underline, not underline + italic; 4:2 is double, not dim
        let row = cells("\(esc)[4:3mA\(esc)[0;4:2mB", count: 2)
        #expect(row.count == 2)
        guard row.count == 2 else { return }
        #expect(!row[0].attribute.style.contains(.italic))
        #expect(!row[1].attribute.style.contains(.dim))
        #expect(row[1].attribute.underlineStyle == .double)
    }

    @Test func testDoubleUnderlineAndOverline() {
        let row = cells("\(esc)[21mA\(esc)[24;53mB\(esc)[55mC", count: 3)
        #expect(row.count == 3)
        guard row.count == 3 else { return }
        #expect(row[0].attribute.style.contains(.underline))
        #expect(row[0].attribute.underlineStyle == .double)
        #expect(!row[1].attribute.style.contains(.underline))
        #expect(row[1].attribute.overline)
        #expect(!row[2].attribute.overline)
    }

    @Test func testUnderlineStyleResetsWithUnderline() {
        // "Not underlined" has a single representation so equal cells compare equal
        let row = cells("\(esc)[4:3mA\(esc)[24mB\(esc)[0mC", count: 3)
        #expect(row.count == 3)
        guard row.count == 3 else { return }
        #expect(row[1].attribute == row[2].attribute)
    }
}
