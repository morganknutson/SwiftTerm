import Testing
@testable import SwiftTerm

final class EraseScrollbackTests {
    private class TestDelegate: TerminalDelegate {
        func showCursor(source: Terminal) {}
        func hideCursor(source: Terminal) {}
        func setTerminalTitle(source: Terminal, title: String) {}
        func setTerminalIconTitle(source: Terminal, title: String) {}
        func windowCommand(source: Terminal, command: Terminal.WindowManipulationCommand) -> [UInt8]? { return nil }
        func sizeChanged(source: Terminal) {}
        func send(source: Terminal, data: ArraySlice<UInt8>) {}
        func scrolled(source: Terminal, yDisp: Int) {}
        func linefeed(source: Terminal) {}
        func bufferActivated(source: Terminal) {}
        func bell(source: Terminal) {}
    }

    // Terminal holds its delegate weakly — keep it alive for the test's lifetime.
    private let delegate = TestDelegate()

    private func makeTerminalWithScrollback() -> Terminal {
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 100)
        )
        for i in 0..<30 {
            terminal.feed(text: "line \(i)\r\n")
        }
        return terminal
    }

    @Test func testEraseScrollbackClearsWhenAtBottom() {
        let terminal = makeTerminalWithScrollback()
        #expect(terminal.buffer.yBase > 0)

        terminal.feed(text: "\u{1b}[3J")

        #expect(terminal.buffer.lines.count == terminal.rows)
        #expect(terminal.buffer.yBase == 0)
        #expect(terminal.buffer.yDisp == 0)
    }

    @Test func testEraseScrollbackSkippedWhileUserIsScrolledUp() {
        let terminal = makeTerminalWithScrollback()
        let lineCount = terminal.buffer.lines.count
        let scrolledTo = terminal.buffer.yBase - 3
        terminal.setViewYDisp(scrolledTo)
        terminal.userScrolling = true

        terminal.feed(text: "\u{1b}[3J")

        #expect(terminal.buffer.lines.count == lineCount)
        #expect(terminal.buffer.yDisp == scrolledTo)

        // Back at the bottom, the next 3J clears as usual.
        terminal.setViewYDisp(terminal.buffer.yBase)
        terminal.userScrolling = false
        terminal.feed(text: "\u{1b}[3J")
        #expect(terminal.buffer.lines.count == terminal.rows)
    }
}
