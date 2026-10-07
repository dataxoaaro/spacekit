import Foundation

/// Runs external tools directly (never through a shell), with a timeout.
public enum Shell {
    /// Directories searched for tools. launchd agents start with a minimal PATH, so common
    /// package-manager locations are always included.
    public static var searchPath: [String] {
        let env = ProcessInfo.processInfo.environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        let home = PathUtil.home
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.bun/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "\(home)/.orbstack/bin",
        ]
        var seen = Set<String>()
        return (env + extra).filter { seen.insert($0).inserted }
    }

    public static func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        return searchPath.map { $0 + "/" + name }.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public struct Result: Sendable {
        public var status: Int32
        public var output: String
        public var timedOut: Bool
    }

    public static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = searchPath.joined(separator: ":")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice

        let collector = OutputCollector()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            collector.append(handle.availableData)
        }
        do {
            try process.run()
        } catch {
            pipe.fileHandleForReading.readabilityHandler = nil
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                timedOut = true
                break
            }
            usleep(50_000)
        }
        process.waitUntilExit()
        pipe.fileHandleForReading.readabilityHandler = nil
        collector.append(pipe.fileHandleForReading.readDataToEndOfFile())
        return Result(status: timedOut ? -2 : process.terminationStatus, output: collector.text, timedOut: timedOut)
    }

    private final class OutputCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func append(_ chunk: Data) {
            lock.lock()
            data.append(chunk)
            lock.unlock()
        }
        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: data.suffix(64 * 1024), as: UTF8.self)
        }
    }
}
