#if os(macOS)
import AppKit
import ArgumentParser
import SwiftTerm

/// Renders the SwiftTerm macOS view to PNGs without a host app, so rendering
/// changes can be checked by eye against built-in scenarios, captured byte
/// streams, or real CLIs running in a PTY.
struct TerminalFixture: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal-fixture",
        abstract: "Render SwiftTerm's macOS terminal view to PNG images.",
        subcommands: [Scenario.self, Feed.self, Run.self, Serve.self, Ctl.self, Bench.self, List.self]
    )
}

struct RenderOptions: ParsableArguments {
    @Option(help: "Font family name. Defaults to the system monospaced font.")
    var font: String?

    @Option(help: "Font size in points.")
    var size: Double = 12

    @Option(help: "Backing scale factor (1 or 2). Defaults to the main screen's.")
    var scale: Double?

    @Flag(help: "Paint an opaque terminal background instead of drawing transparently over the pane.")
    var opaque = false

    @Flag(help: "Use Addy's light theme.")
    var light = false

    @Option(help: "Directory that receives the PNGs.")
    var out: String = "/tmp/terminal-fixture"

    var resolvedFont: NSFont {
        let pointSize = CGFloat(size)
        if let font, let resolved = NSFont(name: font, size: pointSize) {
            return resolved
        }
        return NSFont.monospacedSystemFont(ofSize: pointSize, weight: .regular)
    }

    var theme: FixtureTheme {
        var theme = light ? FixtureTheme.addyLight : FixtureTheme.addyDark
        theme.opaqueTerminalBackground = opaque
        return theme
    }

    func makeHost(cols: Int, rows: Int) -> FixtureTerminalHost {
        FixtureTerminalHost(cols: cols, rows: rows, font: resolvedFont, theme: theme,
                            scale: scale.map { CGFloat($0) })
    }

    func outputURL(_ name: String) throws -> URL {
        let directory = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("\(name).png")
    }
}

extension TerminalFixture {
    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the built-in scenarios.")

        func run() {
            for scenario in FixtureScenarios.all {
                print("\(scenario.name.padding(toLength: 18, withPad: " ", startingAt: 0)) \(scenario.summary)")
            }
        }
    }

    struct Scenario: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Render built-in scenarios (all when none are named).")

        @Argument(help: "Scenario names, see `list`.")
        var names: [String] = []

        @OptionGroup var render: RenderOptions

        func run() throws {
            let scenarios = try names.isEmpty ? FixtureScenarios.all : names.map { name in
                guard let scenario = FixtureScenarios.named(name) else {
                    throw FixtureError.unknownScenario(name)
                }
                return scenario
            }
            for scenario in scenarios {
                let host = render.makeHost(cols: scenario.cols, rows: scenario.rows)
                host.feed(scenario.bytes)
                let url = try render.outputURL(scenario.name)
                try host.snapshot(to: url)
                print(url.path)
            }
        }
    }

    struct Feed: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Render a raw byte stream (for example a `script` capture).")

        @Argument(help: "File containing the bytes to feed to the terminal.")
        var file: String

        @Option var cols: Int = 100
        @Option var rows: Int = 30
        @OptionGroup var render: RenderOptions

        func run() throws {
            let data = try Data(contentsOf: URL(fileURLWithPath: file))
            let host = render.makeHost(cols: cols, rows: rows)
            host.feed([UInt8](data))
            let url = try render.outputURL(URL(fileURLWithPath: file).deletingPathExtension().lastPathComponent)
            try host.snapshot(to: url)
            print(url.path)
        }
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a real command in a PTY and snapshot the screen.")

        @Argument(help: "Shell command, run with `zsh -lc`.")
        var command: String

        @Option var cols: Int = 100
        @Option var rows: Int = 30
        @Option(help: "Seconds to wait before the first snapshot.")
        var wait: Double = 2
        @Option(help: "Text sent after the wait (\\r, \\e and \\t escapes are expanded); a second snapshot is taken after --after seconds.")
        var keys: String?
        @Option(help: "Seconds to wait after sending keys.")
        var after: Double = 1
        @Option(help: "TERM for the child process.")
        var term: String = "xterm-256color"
        @Option(help: "Snapshot name.")
        var name: String = "run"
        @Option(help: "Working directory for the command.")
        var directory: String?
        @OptionGroup var render: RenderOptions

        func run() throws {
            let host = render.makeHost(cols: cols, rows: rows)
            host.start(command: command, environment: Run.environment(term: term), directory: directory)
            host.pump(wait)
            try snapshot(host, suffix: "")
            if let keys {
                host.send(Run.expandEscapes(keys))
                host.pump(after)
                try snapshot(host, suffix: "-after")
            }
        }

        private func snapshot(_ host: FixtureTerminalHost, suffix: String) throws {
            let url = try render.outputURL(name + suffix)
            try host.snapshot(to: url)
            print(url.path)
        }

        /// The child environment: the caller's, minus agent nesting guards and the
        /// host's pane identity (so a CLI started here never acts as the caller's
        /// pane), with the requested TERM and truecolor advertised.
        static func environment(term: String) -> [String] {
            var environment = ProcessInfo.processInfo.environment.filter { key, _ in
                !key.hasPrefix("ADDY_") && !key.hasPrefix("CLAUDE_CODE_") && key != "CLAUDECODE"
            }
            environment["TERM"] = term
            environment["COLORTERM"] = "truecolor"
            return environment.map { "\($0.key)=\($0.value)" }
        }

        static func expandEscapes(_ text: String) -> String {
            text.replacingOccurrences(of: "\\r", with: "\r")
                .replacingOccurrences(of: "\\e", with: "\u{1b}")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\n", with: "\n")
        }
    }
}

extension TerminalFixture {
    struct Bench: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Time full-screen redraws of a dense, colorful screen.")

        @Option var cols: Int = 200
        @Option var rows: Int = 60
        @Option(help: "Number of redraws to time.")
        var frames: Int = 200
        @OptionGroup var render: RenderOptions

        func run() throws {
            let host = render.makeHost(cols: cols, rows: rows)
            host.feed(Array(Bench.denseScreen(cols: cols, rows: rows).utf8))
            let seconds = host.timeRedraws(frames)
            print(String(format: "%dx%d: %.2f ms per full redraw over %d frames", cols, rows, seconds * 1000 / Double(frames), frames))
        }

        /// Every cell styled, mixing truecolor runs, attributes, CJK, emoji and box drawing.
        static func denseScreen(cols: Int, rows: Int) -> String {
            let words = ["let", "value", "=", "日本", "🚀", "│", "func", "0x1F", "─┼─", "return"]
            var screen = ""
            for row in 0..<rows {
                var line = ""
                var width = 0
                var index = row
                while width < cols - 8 {
                    let word = words[index % words.count]
                    let r = (index * 37) % 256, g = (index * 91) % 256, b = (index * 53) % 256
                    let style = index % 4 == 0 ? "1;" : index % 4 == 1 ? "3;4;" : ""
                    line += "\u{1b}[\(style)38;2;\(r);\(g);\(b)m\(word) "
                    width += word.count * (word.unicodeScalars.first!.value > 0x2E80 ? 2 : 1) + 1
                    index += 1
                }
                screen += line + "\u{1b}[0m" + (row < rows - 1 ? "\r\n" : "")
            }
            return screen
        }
    }

    static let sessionRoot = "/tmp/terminal-fixture/sessions"

    struct Serve: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Keep a command running in a terminal and accept `ctl` requests until `ctl NAME quit`.")

        @Argument(help: "Session name used by `ctl`.")
        var session: String

        @Option(help: "Shell command, run with `zsh -lc`.")
        var command: String = "exec zsh -i"

        @Option var cols: Int = 100
        @Option var rows: Int = 30
        @Option(help: "TERM for the child process.")
        var term: String = "xterm-256color"
        @Option(help: "Working directory for the command.")
        var directory: String?
        @OptionGroup var render: RenderOptions

        func run() throws {
            let host = render.makeHost(cols: cols, rows: rows)
            host.start(command: command, environment: Run.environment(term: term), directory: directory)
            let paths = FixtureSessionPaths(name: session, root: TerminalFixture.sessionRoot)
            try FixtureSessionServer(host: host, paths: paths).run()
        }
    }

    struct Ctl: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Send one request to a running session.",
            discussion: "Requests: send TEXT | key NAME | wait SECONDS | snap NAME | text | verify NAME | resize COLS ROWS | status | quit")

        @Argument(help: "Session name given to `serve`.")
        var session: String

        @Argument(parsing: .captureForPassthrough, help: "The request words.")
        var request: [String]

        func run() throws {
            let paths = FixtureSessionPaths(name: session, root: TerminalFixture.sessionRoot)
            let socket = try FixtureSocket.connect(to: paths.socket.path)
            socket.writeAll(request.joined(separator: " "))
            socket.finishWriting()
            print(socket.readAll(), terminator: "")
            socket.close()
        }
    }
}

TerminalFixture.main()
#else
print("terminal-fixture requires macOS")
#endif
