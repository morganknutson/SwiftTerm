import Foundation
import Testing
@testable import SwiftTerm

final class SynchronizedOutputTests {
    private class TestDelegate: TerminalDelegate {
        var syncChanges: [Bool] = []
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
        func synchronizedOutputChanged(source: Terminal, active: Bool) {
            syncChanges.append(active)
        }
    }

    private let esc = "\u{1b}"

    // Terminal holds its delegate weakly — keep it alive for the test's lifetime.
    private let delegate = TestDelegate()

    private func makeTerminal() -> Terminal {
        Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 20, rows: 5, scrollback: 0)
        )
    }

    private func topLineText(from buffer: Buffer, terminal: Terminal? = nil) -> String {
        let characterProvider: ((CharData) -> Character)?
        if let terminal {
            characterProvider = { terminal.getCharacter(for: $0) }
        } else {
            characterProvider = nil
        }
        return buffer.translateBufferLineToString(
            lineIndex: buffer.yDisp,
            trimRight: true,
            startCol: 0,
            endCol: -1,
            skipNullCellsFollowingWide: true,
            characterProvider: characterProvider
        ).replacingOccurrences(of: "\u{0}", with: " ")
    }

    @Test func testHoldsChunksThatArriveAfterFrameOpens() {
        let terminal = makeTerminal()

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        #expect(topLineText(from: terminal.buffer).hasPrefix("OLD"))

        terminal.feed(text: "\(esc)[?2026h")
        #expect(terminal.isSynchronizedOutputActive)

        // Bytes fed after the frame opened are held unparsed — the buffer must
        // still show the previous frame, with no partial state applied.
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")
        #expect(topLineText(from: terminal.buffer).hasPrefix("OLD"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
    }

    @Test func testSameChunkContentAppliesButRemainsActive() {
        let terminal = makeTerminal()

        terminal.feed(text: "\(esc)[2J\(esc)[HOLD")
        // Content in the same chunk as the opening sequence is applied directly;
        // atomicity is provided by the view holding redraws while active.
        terminal.feed(text: "\(esc)[?2026h\(esc)[2J\(esc)[HNEW")
        #expect(terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.isSynchronizedOutputActive)
    }

    @Test func testTerminatorSplitAcrossChunksIsFound() {
        let terminal = makeTerminal()

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW\(esc)[?20")
        #expect(terminal.isSynchronizedOutputActive)
        terminal.feed(text: "26")
        #expect(terminal.isSynchronizedOutputActive)
        terminal.feed(text: "l")

        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
    }

    @Test func testTerminatorInParameterListIsFound() {
        let terminal = makeTerminal()

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW\(esc)[?2026;25l")

        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
    }

    @Test func testBackToBackFramesStayHeldBetweenChunks() {
        let terminal = makeTerminal()

        // End of frame 1 and start of frame 2 arrive in one chunk while holding.
        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HONE\(esc)[?2026l\(esc)[?2026h\(esc)[2J\(esc)[HTWO")
        #expect(terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("TWO"))

        // The next chunk belongs to the still-open frame 2 and must be held.
        terminal.feed(text: " MORE")
        #expect(topLineText(from: terminal.buffer).hasPrefix("TWO"))
        #expect(!topLineText(from: terminal.buffer).contains("MORE"))

        terminal.feed(text: "\(esc)[?2026l")
        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).contains("MORE"))
    }

    @Test func testResizeFlushesHeldBytesAndClosesFrame() {
        let terminal = makeTerminal()

        terminal.feed(text: "\(esc)[?2026h")
        terminal.feed(text: "\(esc)[2J\(esc)[HNEW")
        terminal.resize(cols: 40, rows: 10)

        #expect(!terminal.isSynchronizedOutputActive)
        #expect(topLineText(from: terminal.buffer).hasPrefix("NEW"))
    }

    // Regression guard: synchronized frames must not scale with scrollback size.
    // The previous implementation deep-copied the entire buffer (screen +
    // scrollback) on every frame open, which made TUIs that wrap each repaint in
    // mode 2026 (e.g. Claude Code) unusably slow once scrollback filled up.
    @Test func testFramesWithLargeScrollbackAreCheap() {
        let delegate = TestDelegate()
        let terminal = Terminal(
            delegate: delegate,
            options: TerminalOptions(cols: 80, rows: 25, scrollback: 10_000)
        )
        for i in 0..<10_000 {
            terminal.feed(text: "scrollback line \(i)\r\n")
        }

        let frame = "\(esc)[?2026h\(esc)[8A\(esc)[J"
            + (0..<8).map { "frame line \($0)" }.joined(separator: "\r\n")
            + "\(esc)[?2026l"
        let start = Date()
        for _ in 0..<300 {
            terminal.feed(text: frame)
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "300 synchronized frames took \(elapsed)s")
        withExtendedLifetime(delegate) {}
    }

    @Test func testDelegateNotifiedOnOpenAndClose() {
        let terminal = makeTerminal()

        terminal.feed(text: "\(esc)[?2026h")
        // Nested opens must not re-notify.
        terminal.feed(text: "\(esc)[?2026h\(esc)[?2026l")
        #expect(delegate.syncChanges == [true, false])
    }
}
