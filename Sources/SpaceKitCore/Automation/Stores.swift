import Foundation

/// What the agent remembers about each job between runs.
public struct JobState: Codable, Sendable {
    /// When the agent first saw the job; the first run is scheduled after this.
    public var firstSeen: Date
    public var lastRun: Date?
    public var lastOutcome: String?
    /// Bytes the last run matched.
    public var lastMatchedBytes: UInt64?
    /// Bytes the last run would clean (after conditions).
    public var lastEligibleBytes: UInt64?
    public var lastFreedBytes: UInt64?

    public init(firstSeen: Date = Date()) { self.firstSeen = firstSeen }
}

public struct JobStateStore: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    public func load() -> [String: JobState] {
        guard let data = FileManager.default.contents(atPath: file) else { return [:] }
        return (try? JSONDecoder.spaceKit.decode([String: JobState].self, from: data)) ?? [:]
    }

    public func save(_ states: [String: JobState]) throws {
        let encoder = JSONEncoder.spaceKit
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try LockedFile.write(try encoder.encode(states), to: file)
    }

    public func update(_ jobID: String, _ change: (inout JobState) -> Void) throws {
        var states = load()
        var state = states[jobID] ?? JobState()
        change(&state)
        states[jobID] = state
        try save(states)
    }
}

/// A cleanup a `suggest` job prepared and is waiting for approval.
public struct Suggestion: Codable, Sendable, Identifiable {
    public var id: String
    public var jobID: String
    public var jobName: String
    public var created: Date
    public var plan: CleanupPlan

    public init(jobID: String, jobName: String, plan: CleanupPlan, created: Date = Date()) {
        self.id = String(UUID().uuidString.prefix(8)).lowercased()
        self.jobID = jobID
        self.jobName = jobName
        self.created = created
        self.plan = plan
    }
}

public struct SuggestionStore: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    public func all() -> [Suggestion] {
        guard let data = FileManager.default.contents(atPath: file) else { return [] }
        return ((try? JSONDecoder.spaceKit.decode([Suggestion].self, from: data)) ?? []).sorted { $0.created > $1.created }
    }

    public func get(_ id: String) -> Suggestion? { all().first { $0.id == id || $0.id.hasPrefix(id) } }

    /// Adds a suggestion, replacing any older one from the same job.
    public func add(_ suggestion: Suggestion) throws {
        var list = all().filter { $0.jobID != suggestion.jobID }
        list.append(suggestion)
        try save(list)
    }

    public func remove(_ id: String) throws {
        try save(all().filter { $0.id != id })
    }

    private func save(_ list: [Suggestion]) throws {
        try LockedFile.write(try JSONEncoder.spaceKit.encode(list), to: file)
    }
}

/// Posts user notifications.
public protocol Notifier: Sendable {
    func notify(title: String, body: String)
}

/// Notifications via `osascript`, which works from the CLI and the launchd agent without an app bundle.
public struct AppleScriptNotifier: Notifier {
    public init() {}

    public func notify(title: String, body: String) {
        func escape(_ text: String) -> String {
            text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        }
        let script = "display notification \"\(escape(body))\" with title \"\(escape(title))\" sound name \"default\""
        _ = Shell.run("/usr/bin/osascript", ["-e", script], timeout: 10)
    }
}
