#if os(macOS)
import AppKit
import Foundation
import SwiftTerm

/// Where a named interactive session keeps its socket and snapshots.
struct FixtureSessionPaths {
    let name: String
    let directory: URL

    init(name: String, root: String) {
        self.name = name
        self.directory = URL(fileURLWithPath: root, isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    var socket: URL { directory.appendingPathComponent("control.sock") }

    func snapshot(_ snapshotName: String) -> URL {
        directory.appendingPathComponent("\(snapshotName).png")
    }
}

/// Keeps a real process running in a terminal view and services control
/// requests (type keys, snapshot, dump text, resize) over a Unix socket, so a
/// CLI can be driven step by step from separate shell invocations.
final class FixtureSessionServer {
    private let host: FixtureTerminalHost
    private let paths: FixtureSessionPaths
    private var listener: FixtureSocket?
    private var shouldQuit = false
    private let requests = FixtureRequestQueue()

    init(host: FixtureTerminalHost, paths: FixtureSessionPaths) {
        self.host = host
        self.paths = paths
    }

    func run() throws {
        try FileManager.default.createDirectory(at: paths.directory, withIntermediateDirectories: true)
        let listener = try FixtureSocket.listen(at: paths.socket.path)
        self.listener = listener
        // Accept on a background thread and hand requests to the main loop
        // below. Requests are not run as main-queue blocks: handlers pump the
        // run loop, and the PTY output SwiftTerm delivers on the main queue
        // would starve while a main-queue block is executing.
        let pending = requests
        Thread.detachNewThread {
            while let connection = try? listener.accept() {
                let request = connection.readAll()
                pending.push((request, connection))
            }
        }
        print("session '\(paths.name)' ready: \(paths.socket.path)")
        fflush(stdout)
        while !shouldQuit {
            host.pump(0.02)
            while let (request, connection) = requests.pop() {
                connection.writeAll(handle(request) + "\n")
                connection.close()
            }
        }
        listener.close()
        try? FileManager.default.removeItem(at: paths.socket)
    }

    private func handle(_ request: String) -> String {
        let trimmed = request.trimmingCharacters(in: .newlines)
        let verb = trimmed.prefix { $0 != " " }
        let argument = trimmed.dropFirst(verb.count).drop { $0 == " " }
        do {
            switch verb {
            case "send":
                host.send(TerminalFixture.Run.expandEscapes(String(argument)))
                host.pump(0.1)
                return "ok"
            case "key":
                guard let sequence = FixtureKeys.sequence(named: String(argument)) else {
                    return "error: unknown key '\(argument)'; known: \(FixtureKeys.names.joined(separator: ", "))"
                }
                host.send(sequence)
                host.pump(0.1)
                return "ok"
            case "wait":
                host.pump(TimeInterval(argument) ?? 1)
                return "ok"
            case "snap":
                let url = paths.snapshot(argument.isEmpty ? "snap" : String(argument))
                host.pump(0.05)
                try host.snapshot(to: url)
                return url.path
            case "text":
                return host.screenText()
            case "verify":
                let url = paths.snapshot(argument.isEmpty ? "verify" : String(argument))
                let mismatched = try host.verifyIncrementalRedraw(writingTo: url)
                return mismatched == 0 ? "clean: partial redraws match a full render" : "STALE: \(mismatched) pixels differ, see \(url.deletingPathExtension().path)-diff.png"
            case "resize":
                let parts = argument.split(separator: " ").compactMap { Int($0) }
                guard parts.count == 2 else { return "error: resize COLS ROWS" }
                host.resize(cols: parts[0], rows: parts[1])
                host.pump(0.2)
                return "ok"
            case "status":
                return host.processExited ? "exited" : "running"
            case "quit":
                shouldQuit = true
                return "bye"
            default:
                return "error: commands are send TEXT | key NAME | wait SECONDS | snap NAME | text | verify NAME | resize COLS ROWS | status | quit"
            }
        } catch {
            return "error: \(error)"
        }
    }
}

/// Requests accepted on the socket thread, waiting for the main loop.
final class FixtureRequestQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(String, FixtureSocket)] = []

    func push(_ item: (String, FixtureSocket)) {
        lock.lock()
        items.append(item)
        lock.unlock()
    }

    func pop() -> (String, FixtureSocket)? {
        lock.lock()
        defer { lock.unlock() }
        return items.isEmpty ? nil : items.removeFirst()
    }
}

/// Named keys for driving TUIs without spelling escape sequences.
enum FixtureKeys {
    private static let table: [String: String] = [
        "enter": "\r", "tab": "\t", "esc": "\u{1b}", "backspace": "\u{7f}", "space": " ",
        "up": "\u{1b}[A", "down": "\u{1b}[B", "right": "\u{1b}[C", "left": "\u{1b}[D",
        "home": "\u{1b}[H", "end": "\u{1b}[F", "pageup": "\u{1b}[5~", "pagedown": "\u{1b}[6~",
        "shift-tab": "\u{1b}[Z", "ctrl-c": "\u{03}", "ctrl-d": "\u{04}", "ctrl-l": "\u{0c}",
        "ctrl-r": "\u{12}", "ctrl-u": "\u{15}", "ctrl-z": "\u{1a}",
    ]

    static var names: [String] { table.keys.sorted() }

    static func sequence(named name: String) -> String? {
        table[name.lowercased()]
    }
}

/// Minimal blocking Unix-domain stream socket.
final class FixtureSocket {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func listen(at path: String) throws -> FixtureSocket {
        unlink(path)
        let socket = try make()
        var address = try FixtureSocket.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket.descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(socket.descriptor, 8) == 0 else {
            throw FixtureSocketError.system("bind/listen \(path): \(String(cString: strerror(errno)))")
        }
        return socket
    }

    static func connect(to path: String) throws -> FixtureSocket {
        let socket = try make()
        var address = try FixtureSocket.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket.descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            throw FixtureSocketError.system("no session at \(path) (\(String(cString: strerror(errno))))")
        }
        return socket
    }

    func accept() throws -> FixtureSocket {
        let client = Darwin.accept(descriptor, nil, nil)
        guard client >= 0 else {
            throw FixtureSocketError.system("accept: \(String(cString: strerror(errno)))")
        }
        return FixtureSocket(descriptor: client)
    }

    /// Reads until the peer shuts down its write side.
    func readAll() -> String {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return String(decoding: data, as: UTF8.self)
    }

    func writeAll(_ text: String) {
        var bytes = Array(text.utf8)[...]
        while !bytes.isEmpty {
            let written = bytes.withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            if written <= 0 { return }
            bytes = bytes.dropFirst(written)
        }
    }

    func finishWriting() {
        shutdown(descriptor, SHUT_WR)
    }

    func close() {
        Darwin.close(descriptor)
    }

    private static func make() throws -> FixtureSocket {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw FixtureSocketError.system("socket: \(String(cString: strerror(errno)))")
        }
        return FixtureSocket(descriptor: descriptor)
    }

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else {
            throw FixtureSocketError.system("socket path too long: \(path)")
        }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: path.utf8)
            raw[path.utf8.count] = 0
        }
        return address
    }
}

enum FixtureSocketError: Error, CustomStringConvertible {
    case system(String)

    var description: String {
        switch self {
        case .system(let message): return message
        }
    }
}
#endif
