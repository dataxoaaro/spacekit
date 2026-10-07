import Foundation
import SpaceKitCore
import SpaceKitTUI

enum Output {
    static func print(_ text: String = "") {
        Swift.print(text)
    }

    static func warn(_ text: String) {
        FileHandle.standardError.write(Data(("warning: ".fg(ANSI.review) + text + "\n").utf8))
    }

    static func json<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        Swift.print(String(decoding: try encoder.encode(value), as: UTF8.self))
    }

    static func heading(_ text: String) {
        Swift.print(text.bold)
    }

    /// Asks a yes/no question on an interactive terminal; returns `false` otherwise.
    static func confirm(_ question: String) -> Bool {
        guard isatty(STDIN_FILENO) != 0 else { return false }
        Swift.print(question + " [y/N] ", terminator: "")
        fflush(stdout)
        guard let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return answer == "y" || answer == "yes"
    }

    static func size(_ bytes: UInt64, width: Int = 9) -> String {
        ANSI.pad(ByteCount.format(bytes), to: width, alignRight: true)
    }
}

/// Live progress on stderr while a scan runs (only on a terminal).
final class ProgressReporter: @unchecked Sendable {
    private let progress: ScanProgress
    private let label: String
    private var thread: Thread?
    private let lock = NSLock()
    private var running = false
    private let enabled = isatty(STDERR_FILENO) != 0

    init(_ progress: ScanProgress, label: String) {
        self.progress = progress
        self.label = label
    }

    func start() {
        guard enabled else { return }
        lock.lock()
        running = true
        lock.unlock()
        let thread = Thread { [self] in
            let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
            var tick = 0
            while isRunning {
                let p = progress.snapshot
                let line =
                    "\r\u{1B}[2K\(frames[tick % frames.count]) \(label) \(ByteCount.format(p.bytes)) · \(p.files.formatted()) files · \(p.directories.formatted()) folders"
                FileHandle.standardError.write(Data(line.utf8))
                tick += 1
                Thread.sleep(forTimeInterval: 0.1)
            }
            FileHandle.standardError.write(Data("\r\u{1B}[2K".utf8))
        }
        self.thread = thread
        thread.start()
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    func stop() {
        guard enabled else { return }
        lock.lock()
        running = false
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.12)
    }

    /// Runs `body` with a live progress line.
    static func run<T>(_ label: String, progress: ScanProgress = ScanProgress(), _ body: (ScanProgress) throws -> T) rethrows -> T {
        let reporter = ProgressReporter(progress, label: label)
        reporter.start()
        defer { reporter.stop() }
        return try body(progress)
    }
}

extension SafetyLevel {
    var heading: String {
        switch self {
        case .safe: return "🟢 REGENERABLE"
        case .review: return "🟡 REVIEW"
        case .protected: return "🔴 DON'T TOUCH"
        }
    }
}
