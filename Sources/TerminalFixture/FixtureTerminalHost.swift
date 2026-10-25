#if os(macOS)
import AppKit
import SwiftTerm

/// Visual configuration that mirrors how a host app (Addy) styles the terminal:
/// a transparent terminal over an opaque pane background, a custom ANSI palette,
/// and a fixed cursor color.
struct FixtureTheme {
    var paneBackground: NSColor
    var foreground: NSColor
    var cursor: NSColor
    var selection: NSColor
    var ansi: [NSColor]
    /// When true, the terminal paints its own opaque background instead of
    /// drawing transparently over `paneBackground`.
    var opaqueTerminalBackground: Bool = false

    static let addyDark = FixtureTheme(
        paneBackground: NSColor(hex: 0x1C1C20),
        foreground: .white,
        cursor: NSColor(hex: 0xD8A24C),
        selection: NSColor.white.withAlphaComponent(0.15),
        ansi: [0x3B3B40, 0xE5534B, 0x59C77A, 0xE0B04A, 0x5B9BD5, 0xB57EDC, 0x4FB8C8, 0xD9D9DE,
               0x55555C, 0xF0716A, 0x7ADB95, 0xF2C766, 0x7DB4E8, 0xCC9AEE, 0x6ED0DE, 0xFFFFFF].map { NSColor(hex: $0) })

    static let addyLight = FixtureTheme(
        paneBackground: NSColor(hex: 0xF3F3F5),
        foreground: .black,
        cursor: NSColor(hex: 0xD8A24C),
        selection: NSColor.black.withAlphaComponent(0.12),
        ansi: addyDark.ansi)
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                  green: CGFloat((hex >> 8) & 0xff) / 255,
                  blue: CGFloat(hex & 0xff) / 255,
                  alpha: 1)
    }
}

/// Hosts a terminal view in an off-screen window so it renders exactly like it
/// does on screen (real backing scale, real layer tree), and captures PNGs.
final class FixtureTerminalHost: NSObject, LocalProcessTerminalViewDelegate {
    let terminalView: RecordingTerminalView
    private let window: NSWindow
    private let container: NSView
    private let theme: FixtureTheme
    private var canvas: IncrementalCanvas?
    private(set) var processExited = false

    init(cols: Int, rows: Int, font: NSFont, theme: FixtureTheme, scale: CGFloat?) {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        self.theme = theme
        terminalView = RecordingTerminalView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        terminalView.font = font
        let cell = FixtureTerminalHost.cellSize(of: terminalView, cols: cols, rows: rows)
        let contentRect = CGRect(origin: .zero, size: cell)

        window = NSWindow(contentRect: contentRect.offsetBy(dx: -20_000, dy: -20_000),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        if let scale {
            window.setValue(scale, forKey: "_backingScaleFactorOverride")
        }
        container = NSView(frame: contentRect)
        container.wantsLayer = true
        container.layer?.backgroundColor = theme.paneBackground.cgColor
        window.contentView = container

        super.init()

        terminalView.frame = contentRect
        terminalView.autoresizingMask = [.width, .height]
        container.addSubview(terminalView)
        terminalView.processDelegate = self
        // An off-screen window never becomes key; draw the caret as in a focused pane.
        terminalView.caretViewTracksFocus = false
        apply(theme: theme)
        window.orderFrontRegardless()
        window.makeFirstResponder(terminalView)
        pump(0.05)
        resetCanvas()
    }

    /// Starts tracking partial redraws from the current state.
    private func resetCanvas() {
        canvas = IncrementalCanvas(view: terminalView, scale: window.backingScaleFactor)
    }

    /// Compares the partially redrawn canvas with a full render, writing both
    /// images next to `url`. Returns the number of mismatched pixels.
    func verifyIncrementalRedraw(writingTo url: URL) throws -> Int {
        guard let result = canvas?.compareWithFullRender() else {
            throw FixtureError.renderFailed
        }
        let base = url.deletingPathExtension().path
        if let incremental = result.incremental, let composited = composite(terminalImage: incremental) {
            try FixtureTerminalHost.writePNG(composited, to: URL(fileURLWithPath: base + "-incremental.png"))
        }
        if let diff = result.diff {
            try FixtureTerminalHost.writePNG(diff, to: URL(fileURLWithPath: base + "-diff.png"))
        }
        return result.mismatchedPixels
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        guard let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
            throw FixtureError.renderFailed
        }
        try data.write(to: url)
    }

    /// The view size that holds exactly `cols` x `rows` cells.
    private static func cellSize(of view: TerminalView, cols: Int, rows: Int) -> CGSize {
        view.resize(cols: cols, rows: rows)
        return view.getOptimalFrameSize().size
    }

    func apply(theme: FixtureTheme) {
        terminalView.installColors(theme.ansi.map { SwiftTerm.Color(nsColor: $0) })
        terminalView.nativeBackgroundColor = theme.opaqueTerminalBackground ? theme.paneBackground : .clear
        terminalView.nativeForegroundColor = theme.foreground
        terminalView.caretColor = theme.cursor
        terminalView.selectedTextBackgroundColor = theme.selection
    }

    func feed(_ bytes: [UInt8]) {
        terminalView.feed(byteArray: bytes[...])
        pump(0.05)
    }

    func start(command: String, environment: [String], directory: String?) {
        terminalView.startProcess(executable: "/bin/zsh",
                                  args: ["-lc", command],
                                  environment: environment,
                                  currentDirectory: directory)
    }

    func send(_ text: String) {
        terminalView.send(txt: text)
    }

    /// Resizes the window so the view holds exactly `cols` x `rows` cells.
    func resize(cols: Int, rows: Int) {
        let size = FixtureTerminalHost.cellSize(of: terminalView, cols: cols, rows: rows)
        var frame = window.frame
        frame.size = size
        window.setFrame(frame, display: false)
        container.frame = CGRect(origin: .zero, size: size)
        pump(0.05)
        resetCanvas()
    }

    /// The visible screen as plain text, one line per row, with the cursor
    /// position on the last line.
    func screenText() -> String {
        let terminal = terminalView.getTerminal()
        var lines: [String] = []
        for row in 0..<terminal.rows {
            lines.append(terminal.getLine(row: row)?.translateToString(trimRight: true, endCol: terminal.cols, skipNullCellsFollowingWide: true,
                                                                       characterProvider: { cell in
                let character = terminal.getCharacter(for: cell)
                return character == "\u{0}" ? " " : character
            }) ?? "")
        }
        let cursor = terminal.getCursorLocation()
        lines.append("[cursor \(cursor.x),\(cursor.y) size \(terminal.cols)x\(terminal.rows) caret \(terminalView.caretFrame)]")
        return lines.joined(separator: "\n")
    }

    /// Spins the main run loop so dispatch-queued redraws and PTY reads happen.
    func pump(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: min(deadline, Date().addingTimeInterval(0.01)))
            canvas?.update()
        }
    }

    /// Draws the whole terminal `frames` times into an off-screen context and
    /// returns the elapsed seconds.
    func timeRedraws(_ frames: Int) -> TimeInterval {
        guard let store = TerminalBackingStore(view: terminalView, scale: window.backingScaleFactor) else {
            return 0
        }
        store.redrawAll()
        let start = Date()
        for _ in 0..<frames {
            store.redrawAll()
        }
        return Date().timeIntervalSince(start)
    }

    /// Renders what the user sees: the terminal's transparent backing store
    /// composited over the pane, with the caret on top.
    func snapshot(to url: URL) throws {
        guard let store = TerminalBackingStore(view: terminalView, scale: window.backingScaleFactor) else {
            throw FixtureError.renderFailed
        }
        store.redrawAll()
        guard let terminalImage = store.image(), let image = composite(terminalImage: terminalImage) else {
            throw FixtureError.renderFailed
        }
        try FixtureTerminalHost.writePNG(image, to: url)
    }

    /// Composites a terminal backing store image over the pane background, the
    /// way Core Animation layers the terminal's layer over its superview's.
    private func composite(terminalImage: CGImage) -> CGImage? {
        let scale = window.backingScaleFactor
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int(container.bounds.width * scale), height: Int(container.bounds.height * scale),
                                      bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(theme.paneBackground.cgColor)
        context.fill(container.bounds)
        context.draw(terminalImage, in: terminalView.frame)
        drawCaret(in: context)
        return context.makeImage()
    }

    /// The caret is a separate layer that draws through its layer delegate.
    private func drawCaret(in context: CGContext) {
        let caretFrame = terminalView.caretFrame
        guard let caret = terminalView.subviews.first(where: { $0.frame == caretFrame && !$0.isHidden }),
              let caretLayer = caret.layer,
              let delegate = caret as? CALayerDelegate else {
            return
        }
        let origin = terminalView.convert(caretFrame.origin, to: container)
        context.saveGState()
        context.translateBy(x: origin.x, y: origin.y)
        delegate.draw?(caretLayer, in: context)
        context.restoreGState()
    }

    // MARK: LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) {
        processExited = true
    }
}

enum FixtureError: Error, CustomStringConvertible {
    case renderFailed
    case unknownScenario(String)

    var description: String {
        switch self {
        case .renderFailed: return "Could not render the terminal to an image"
        case .unknownScenario(let name): return "Unknown scenario '\(name)'"
        }
    }
}

extension SwiftTerm.Color {
    convenience init(nsColor: NSColor) {
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor
        func component(_ value: CGFloat) -> UInt16 {
            UInt16((min(1, max(0, value)) * CGFloat(UInt16.max)).rounded())
        }
        self.init(red: component(rgb.redComponent), green: component(rgb.greenComponent), blue: component(rgb.blueComponent))
    }
}
#endif
