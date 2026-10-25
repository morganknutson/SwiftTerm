#if os(macOS)
import Foundation

/// A named byte stream that exercises one area of terminal rendering.
struct FixtureScenario {
    let name: String
    let summary: String
    let cols: Int
    let rows: Int
    let output: String

    var bytes: [UInt8] { Array(output.utf8) }
}

/// Built-in scenarios modeled on what real CLIs emit: TUI frames, prompts,
/// diff viewers, progress bars and so on.
enum FixtureScenarios {
    static let esc = "\u{1b}"
    static let csi = "\u{1b}["

    static func sgr(_ params: String) -> String { "\(csi)\(params)m" }

    static let all: [FixtureScenario] = [
        boxDrawing, blockElements, colors, attributes, underlineStyles, unicodeWidth,
        powerline, claudeStyleFrame, backgroundRuns, cursorAndInverse
    ]

    static func named(_ name: String) -> FixtureScenario? {
        all.first { $0.name == name }
    }

    // MARK: - Scenarios

    static let boxDrawing = FixtureScenario(
        name: "box-drawing",
        summary: "Light/heavy/double/rounded boxes, tables and box lines at far columns",
        cols: 80, rows: 16,
        output: [
            "╭" + String(repeating: "─", count: 76) + "╮",
            "│ " + "rounded box spanning the full width, right edge must meet the corner".padding(toLength: 74, withPad: " ", startingAt: 0) + " │",
            "╰" + String(repeating: "─", count: 76) + "╯",
            "┌──────┬──────┐ ┏━━━━━━┳━━━━━━┓ ╔══════╦══════╗ ┌╌╌╌╌╌╌┐",
            "│ cell │ cell │ ┃ cell ┃ cell ┃ ║ cell ║ cell ║ ╎ dash ╎",
            "├──────┼──────┤ ┣━━━━━━╋━━━━━━┫ ╠══════╬══════╣ └╌╌╌╌╌╌┘",
            "│ cell │ cell │ ┃ cell ┃ cell ┃ ║ cell ║ cell ║ ╱╲╳ diag",
            "└──────┴──────┘ ┗━━━━━━┻━━━━━━┛ ╚══════╩══════╝",
            "git log --graph:",
            "* 1a2b3c4 \(sgr("33"))(HEAD -> main)\(sgr("0")) merge",
            "|\\",
            "| * 5d6e7f8 feature",
            "├─╮ tree:",
            "│ ├── Sources",
            "│ └── Tests",
            String(repeating: "─", count: 80),
        ].joined(separator: "\r\n"))

    static let blockElements = FixtureScenario(
        name: "block-elements",
        summary: "Full/partial blocks, shades and a stacked bar chart that must have no seams",
        cols: 70, rows: 10,
        output: [
            "\(sgr("32"))" + String(repeating: "█", count: 40) + "\(sgr("0")) full blocks, no gaps",
            "\(sgr("32"))" + String(repeating: "█", count: 40) + "\(sgr("0")) second row touches first",
            "▁▂▃▄▅▆▇█ ▏▎▍▌▋▊▉█ ▀▄▌▐ ░▒▓ ▖▗▘▙▚▛▜▝▞▟",
            "\(sgr("44"))" + String(repeating: " ", count: 40) + "\(sgr("0")) background run",
            "\(sgr("44"))" + String(repeating: " ", count: 40) + "\(sgr("0")) adjacent bg row",
            "\(sgr("41"))  \(sgr("42"))  \(sgr("43"))  \(sgr("44"))  \(sgr("45"))  \(sgr("46"))  \(sgr("47"))  \(sgr("0")) adjacent bg cells",
            "Braille: ⠁⠃⠇⡇⣇⣧⣷⣿ ⣀⣤⣶⣿ spinner ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏",
            "Sextants: 🬀🬁🬂🬃🬄🬅 🬋🬎🬹 legacy: 🭨🭩🭪🭫",
            "\(sgr("38;2;255;100;0"))▀\(sgr("38;2;0;200;255;48;2;80;0;160"))▀▀▀▀\(sgr("0")) half-block pixels",
        ].joined(separator: "\r\n"))

    static let colors: FixtureScenario = {
        var lines: [String] = []
        var normal = ""
        for i in 0..<8 { normal += "\(sgr("4\(i)"))  \(sgr("0"))" }
        var bright = ""
        for i in 0..<8 { bright += "\(sgr("10\(i)"))  \(sgr("0"))" }
        lines.append("16 colors: " + normal + " " + bright)
        var fg = ""
        for i in 0..<8 { fg += "\(sgr("3\(i)"))fg\(i)\(sgr("0")) " }
        lines.append(fg)
        var boldFg = ""
        for i in 0..<8 { boldFg += "\(sgr("1;3\(i)"))bo\(i)\(sgr("0")) " }
        lines.append(boldFg + " (bold)")
        for row in 0..<6 {
            var line = ""
            for col in 0..<36 {
                let index = 16 + row * 36 + col
                line += "\(sgr("48;5;\(index)")) "
            }
            lines.append(line + sgr("0"))
        }
        var ramp = ""
        for i in 232...255 { ramp += "\(sgr("48;5;\(i)"))  " }
        lines.append(ramp + sgr("0"))
        var gradient = ""
        for i in 0..<72 {
            let r = 255 - i * 255 / 71
            let g = i * 255 / 71
            gradient += "\(sgr("48;2;\(r);\(g);128")) "
        }
        lines.append(gradient + sgr("0"))
        return FixtureScenario(name: "colors", summary: "16/256/truecolor palettes and bold colors",
                               cols: 80, rows: 13, output: lines.joined(separator: "\r\n"))
    }()

    static let attributes = FixtureScenario(
        name: "attributes",
        summary: "Bold, dim, italic, inverse, hidden, strikethrough, overline, blink",
        cols: 70, rows: 10,
        output: [
            "normal \(sgr("1"))bold\(sgr("22")) \(sgr("2"))dim\(sgr("22")) \(sgr("3"))italic\(sgr("23")) \(sgr("1;3"))bold-italic\(sgr("0"))",
            "\(sgr("7"))inverse\(sgr("27")) \(sgr("7;31"))inverse red\(sgr("0")) \(sgr("9"))strikethrough\(sgr("29")) \(sgr("53"))overline\(sgr("55"))",
            "hidden:[\(sgr("8"))SECRET\(sgr("28"))] <- should be blank",
            "\(sgr("2;31"))dim red\(sgr("0")) \(sgr("1;2"))bold+dim\(sgr("0")) \(sgr("5"))blink\(sgr("25"))",
            "\(sgr("3"))italic overhang: fffff jjjjj\(sgr("23"))|",
            "underscores: ____ ___ (must be visible) gjpqy descenders",
            "\(sgr("30;47"))black on white\(sgr("0")) \(sgr("97;41"))bright white on red\(sgr("0"))",
            "\(sgr("38;5;244"))grey 244\(sgr("0")) \(sgr("90"))bright black\(sgr("0"))",
        ].joined(separator: "\r\n"))

    static let underlineStyles = FixtureScenario(
        name: "underline-styles",
        summary: "SGR 4 and the kitty/VTE extended underline styles plus colored underlines",
        cols: 70, rows: 8,
        output: [
            "\(sgr("4"))single\(sgr("24")) \(sgr("21"))double(21)\(sgr("24")) \(sgr("4:2"))double\(sgr("4:0")) \(sgr("4:3"))curly\(sgr("4:0")) \(sgr("4:4"))dotted\(sgr("4:0")) \(sgr("4:5"))dashed\(sgr("4:0"))",
            "\(sgr("4:3;58:2::255:0:0"))red curly (nvim diagnostic)\(sgr("59;4:0")) \(sgr("4;58;5;33"))blue underline\(sgr("59;24"))",
            "link: \(esc)]8;;https://example.com\(esc)\\example.com\(esc)]8;;\(esc)\\ after",
            "\(sgr("4"))underlined with descenders gjpqy\(sgr("24"))",
        ].joined(separator: "\r\n"))

    static let unicodeWidth = FixtureScenario(
        name: "unicode-width",
        summary: "Emoji, ZWJ, flags, VS16, CJK, combining marks: column alignment must hold",
        cols: 60, rows: 12,
        output: [
            "0123456789012345678901234567890123456789|",
            "日本語テキスト|<- 14 cols then bar at 14",
            "😀😃🚀🎉|<- 8 cols",
            "👨‍👩‍👧‍👦|<- family ZWJ is 2 cols",
            "🇺🇸🇯🇵|<- flags 4 cols",
            "❤️⚠️✔️|<- VS16 emoji",
            "e\u{301}a\u{308}n\u{303}|<- combining: 3 cols",
            "한국어 中文 ｆｕｌｌ|",
            "→ ← ↑ ↓ ✓ ✗ • … ⏺ ⎿ ● ○ ◆|",
            "mixed: a😀b日c🇺🇸d|",
            "\(sgr("44"))😀日本\(sgr("0"))|<- bg must cover wide cells",
        ].joined(separator: "\r\n"))

    static let powerline = FixtureScenario(
        name: "powerline",
        summary: "Powerline separators and Nerd Font icons as used by starship / p10k",
        cols: 70, rows: 6,
        output: [
            "\(sgr("30;44")) ~/Sites/addy \(sgr("34;42"))\u{E0B0}\(sgr("30;42")) \u{E0A0} main \(sgr("32;49"))\u{E0B0}\(sgr("0")) prompt",
            "\(sgr("34"))\u{E0B6}\(sgr("30;44"))rounded\(sgr("34;49"))\u{E0B4}\(sgr("0")) \(sgr("45")) thin \u{E0B1} sep \(sgr("0"))\u{E0B3}\u{E0B2}",
            "nerd icons:  \u{F07B} \u{E718} \u{F09B} \u{E7A8} \u{F120}",
        ].joined(separator: "\r\n"))

    /// Roughly what Claude Code / ink draws: a rounded input box with a dim
    /// placeholder, a status line, and spinner glyphs, redrawn in place.
    static let claudeStyleFrame: FixtureScenario = {
        let width = 78
        let border = sgr("38;2;136;136;136")
        let reset = sgr("0")
        var frame = ""
        frame += "\(sgr("38;2;215;119;87"))⏺\(reset) Reading \(sgr("1"))Sources/App.swift\(reset)\r\n"
        frame += "  ⎿  Read \(sgr("1"))120\(reset) lines\r\n"
        frame += "\r\n"
        frame += "\(sgr("38;2;215;119;87"))✻\(reset) \(sgr("38;2;215;119;87"))Thinking…\(reset) \(sgr("2"))(esc to interrupt)\(reset)\r\n"
        frame += "\(border)╭\(String(repeating: "─", count: width - 2))╮\(reset)\r\n"
        frame += "\(border)│\(reset) > \(sgr("7")) \(reset)\(sgr("2"))Try \"refactor this file\"\(reset)" + String(repeating: " ", count: width - 30) + "\(border)│\(reset)\r\n"
        frame += "\(border)╰\(String(repeating: "─", count: width - 2))╯\(reset)\r\n"
        frame += "  \(sgr("2"))? for shortcuts\(reset)" + String(repeating: " ", count: 40) + "\(sgr("38;2;255;107;128"))⏵⏵ accept edits on\(reset)"
        // Redraw in place the way ink does: move up, erase lines, rewrite.
        let redraw = "\(csi)8A\r" + String(repeating: "\(csi)2K\(csi)1B", count: 8) + "\(csi)8A\r"
        return FixtureScenario(name: "claude-frame",
                               summary: "Ink-style frame with a redraw-in-place pass",
                               cols: 80, rows: 12,
                               output: frame + "\r\n" + redraw + frame)
    }()

    static let backgroundRuns = FixtureScenario(
        name: "background-runs",
        summary: "Diff-style full-line backgrounds (delta, git diff), erase-with-background",
        cols: 70, rows: 8,
        output: [
            "\(sgr("48;2;40;70;40"))+ added line with green background\(csi)K\(sgr("0"))",
            "\(sgr("48;2;80;30;30"))- removed line with red background\(csi)K\(sgr("0"))",
            "\(sgr("48;2;80;30;30"))- removed \(sgr("48;2;140;40;40"))emphasis\(sgr("48;2;80;30;30")) rest\(csi)K\(sgr("0"))",
            "  context line",
            "\(sgr("44"))\(csi)K\(sgr("0"))",
            "\(sgr("43;30")) STATUS \(sgr("0;100")) bar spanning\(csi)K\(sgr("0"))",
        ].joined(separator: "\r\n"))

    static let cursorAndInverse = FixtureScenario(
        name: "cursor",
        summary: "Cursor over a wide char and inverse-video cursor emulation",
        cols: 40, rows: 4,
        output: "ab日本cd\r\nfake cursor:\(sgr("7")) \(sgr("27")) end\r\n\(csi)1;3H"
    )
}
#endif
