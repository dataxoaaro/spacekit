import Foundation

/// One thing a cleanup will remove.
public struct CleanupItem: Codable, Sendable, Identifiable, Hashable {
    public var path: String
    public var kind: FindingItem.Kind
    public var name: String
    public var size: UInt64
    public var ruleID: String?
    public var isRepository: Bool
    public var containsRepository: Bool
    public var lastUsed: Date?

    public var id: String { kind == .looseFiles ? path + "/*" : path }

    public init(
        path: String, kind: FindingItem.Kind = .directory, name: String? = nil, size: UInt64, ruleID: String? = nil,
        isRepository: Bool = false, containsRepository: Bool = false, lastUsed: Date? = nil
    ) {
        self.path = path
        self.kind = kind
        self.name = name ?? PathUtil.lastComponent(path)
        self.size = size
        self.ruleID = ruleID
        self.isRepository = isRepository
        self.containsRepository = containsRepository
        self.lastUsed = lastUsed
    }

    public init(_ item: FindingItem, ruleID: String?) {
        self.init(
            path: item.path, kind: item.kind, name: item.displayName, size: item.size, ruleID: ruleID,
            isRepository: item.isRepository, containsRepository: item.containsRepository, lastUsed: item.lastUsed)
    }
}

/// A tool command that frees space its own way (e.g. `docker builder prune`).
public struct PlannedCommand: Codable, Sendable, Hashable, Identifiable {
    public var ruleID: String
    public var arguments: [String]
    /// Best guess of what it frees, from the rule's last scan.
    public var estimatedBytes: UInt64
    /// Paths the command is expected to shrink; rescanned afterwards to measure the result.
    public var measurePaths: [String]
    public var id: String { ruleID + ":" + arguments.joined(separator: " ") }

    public init(ruleID: String, arguments: [String], estimatedBytes: UInt64, measurePaths: [String] = []) {
        self.ruleID = ruleID
        self.arguments = arguments
        self.estimatedBytes = estimatedBytes
        self.measurePaths = measurePaths
    }

    public var displayString: String {
        arguments.map { $0.contains(" ") ? "'\($0)'" : $0 }.joined(separator: " ")
    }
}

/// What a cleanup will do, computed before anything is touched. Plans are shown to the person (or saved as a
/// suggestion) and then executed by `CleanupExecutor`, which re-checks every item.
public struct CleanupPlan: Codable, Sendable {
    public var items: [CleanupItem]
    public var commands: [PlannedCommand]
    /// Instructions for things that must be cleaned in another app.
    public var manualSteps: [String]
    /// Move items to the Trash instead of deleting them.
    public var useTrash: Bool

    public init(items: [CleanupItem] = [], commands: [PlannedCommand] = [], manualSteps: [String] = [], useTrash: Bool = true) {
        self.items = items
        self.commands = commands
        self.manualSteps = manualSteps
        self.useTrash = useTrash
    }

    public var totalBytes: UInt64 {
        items.reduce(0) { $0 &+ $1.size } &+ commands.reduce(0) { $0 &+ $1.estimatedBytes }
    }

    public var isEmpty: Bool { items.isEmpty && commands.isEmpty }

    /// Builds a plan from findings. `select` chooses which items of each finding to include (all by default).
    /// `trashPreference`: `true` forces the Trash; `nil` follows each rule's `safety.trash`.
    public static func make(
        findings: [Finding],
        trashPreference: Bool? = true,
        select: (Finding) -> [FindingItem] = { $0.items }
    ) -> CleanupPlan {
        var plan = CleanupPlan(useTrash: true)
        var allRulesWantDelete = !findings.isEmpty
        for finding in findings where finding.rule.safety.level != .protected {
            let rule = finding.rule
            let chosen = select(finding)
            guard !chosen.isEmpty else { continue }
            if let command = rule.action.command {
                plan.commands.append(
                    PlannedCommand(
                        ruleID: rule.id, arguments: command,
                        estimatedBytes: chosen.reduce(0) { $0 &+ $1.size },
                        measurePaths: rule.paths.flatMap { PathUtil.glob($0) }))
            } else if let template = rule.action.itemCommand {
                // Per-item commands name real entries (a toolchain, a spec repo); loose files aren't one.
                for item in chosen where item.kind != .looseFiles {
                    let arguments = template.map {
                        $0.replacingOccurrences(of: "{name}", with: item.name).replacingOccurrences(of: "{path}", with: item.path)
                    }
                    plan.commands.append(
                        PlannedCommand(
                            ruleID: rule.id, arguments: arguments, estimatedBytes: item.size,
                            measurePaths: [item.path]))
                }
            } else if rule.action.remove {
                plan.items += chosen.map { CleanupItem($0, ruleID: rule.id) }
                if rule.safety.trash || rule.safety.level != .safe { allRulesWantDelete = false }
            } else if let manual = rule.action.manual {
                plan.manualSteps.append("\(rule.name): \(manual)")
            }
        }
        plan.useTrash = trashPreference ?? !allRulesWantDelete
        return plan
    }
}
