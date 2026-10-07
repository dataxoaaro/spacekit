import Foundation

/// Where SpaceKit keeps its files. The CLI, TUI, app and background agent all share these.
///
/// - Config (yours, dotfile-friendly): `~/.config/spacekit/config.yaml`, rules in `~/.config/spacekit/rules/`
/// - State (SpaceKit's): `~/Library/Application Support/SpaceKit/` — history, journal, job state, suggestions
///
/// Override with `SPACEKIT_CONFIG` (config file) and `SPACEKIT_STATE_DIR` (state directory).
public struct SpaceKitPaths: Sendable {
    public var configFile: String
    public var stateDirectory: String

    public init(configFile: String, stateDirectory: String) {
        self.configFile = PathUtil.expand(configFile)
        self.stateDirectory = PathUtil.expand(stateDirectory)
    }

    public static var standard: SpaceKitPaths {
        let env = ProcessInfo.processInfo.environment
        let configHome = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/.config"
        let config = env["SPACEKIT_CONFIG"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(configHome)/spacekit/config.yaml"
        let state = env["SPACEKIT_STATE_DIR"].flatMap { $0.isEmpty ? nil : $0 } ?? "~/Library/Application Support/SpaceKit"
        return SpaceKitPaths(configFile: config, stateDirectory: state)
    }

    public var configDirectory: String { PathUtil.parent(configFile) }
    public var userRulesDirectory: String { configDirectory + "/rules" }
    public var journalFile: String { stateDirectory + "/journal.jsonl" }
    public var historyFile: String { stateDirectory + "/history.jsonl" }
    public var jobStateFile: String { stateDirectory + "/jobs-state.json" }
    public var suggestionsFile: String { stateDirectory + "/suggestions.json" }
    public var logDirectory: String { stateDirectory + "/logs" }

    public func ensureDirectories() throws {
        for directory in [configDirectory, stateDirectory, logDirectory] {
            try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        }
    }
}

/// Appends lines to a file with an advisory lock, so the app and the background agent can share it.
enum LockedFile {
    static func append(_ text: String, to path: String) throws {
        try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
        defer { close(fd) }
        flock(fd, LOCK_EX)
        defer { flock(fd, LOCK_UN) }
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            if written <= 0 { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: path]) }
            offset += written
        }
    }

    /// Writes atomically (temp file + rename).
    static func write(_ data: Data, to path: String) throws {
        try FileManager.default.createDirectory(atPath: PathUtil.parent(path), withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    static func readLines(_ path: String) -> [Substring] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return text.split(separator: "\n", omittingEmptySubsequences: true)
    }
}

extension JSONEncoder {
    static var spaceKit: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension JSONDecoder {
    static var spaceKit: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
