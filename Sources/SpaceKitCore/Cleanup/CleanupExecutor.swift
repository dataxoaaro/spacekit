import Foundation

public enum CleanupOutcome: Sendable, Equatable {
    case removed(bytes: UInt64, trashedTo: String?)
    /// Dry run: what would have happened.
    case wouldRemove(bytes: UInt64)
    case skipped(reason: String)
    case failed(reason: String)

    /// Bytes taken off their original location (deleted, or moved to the Trash).
    public var freedBytes: UInt64 {
        if case .removed(let bytes, _) = self { return bytes }
        return 0
    }

    public var isRemoved: Bool {
        if case .removed = self { return true }
        return false
    }

    /// Where a trashed item went. `nil` if it was deleted permanently (or not removed).
    public var trashedTo: String? {
        if case .removed(_, let trashedTo) = self { return trashedTo }
        return nil
    }
}

public struct CleanupReport: Sendable {
    public var items: [(item: CleanupItem, outcome: CleanupOutcome)] = []
    public var commands: [(command: PlannedCommand, outcome: CleanupOutcome, output: String)] = []
    public var dryRun: Bool

    /// Everything taken off its original location, including what went to the Trash.
    public var freedBytes: UInt64 {
        items.reduce(0) { $0 &+ $1.outcome.freedBytes } &+ commands.reduce(0) { $0 &+ $1.outcome.freedBytes }
    }

    /// Moved to the Trash: still using disk space until the Trash is emptied.
    public var trashedBytes: UInt64 {
        items.reduce(0) { $0 &+ ($1.outcome.trashedTo != nil ? $1.outcome.freedBytes : 0) }
    }

    /// Actually released: deleted permanently or removed by tool commands. (On a Mac with local Time Machine
    /// snapshots this shows up as purgeable space first; see `VolumeCapacity`.)
    public var deletedBytes: UInt64 { freedBytes - trashedBytes }

    /// "Freed 1.0 GB", "Moved 4.0 GB to the Trash", or both. Never calls trashed bytes "freed".
    public var summary: String {
        var parts: [String] = []
        if deletedBytes > 0 || trashedBytes == 0 { parts.append("Freed \(ByteCount.format(deletedBytes))") }
        if trashedBytes > 0 { parts.append("\(parts.isEmpty ? "Moved" : "moved") \(ByteCount.format(trashedBytes)) to the Trash") }
        return parts.joined(separator: " and ")
    }

    public var wouldFreeBytes: UInt64 {
        let all = items.map(\.outcome) + commands.map(\.outcome)
        return all.reduce(0) { total, outcome in
            if case .wouldRemove(let bytes) = outcome { return total &+ bytes }
            return total
        }
    }

    public var skipped: [(item: CleanupItem, reason: String)] {
        items.compactMap { entry in
            if case .skipped(let reason) = entry.outcome { return (entry.item, reason) }
            return nil
        }
    }

    public var failures: [(item: CleanupItem, reason: String)] {
        items.compactMap { entry in
            if case .failed(let reason) = entry.outcome { return (entry.item, reason) }
            return nil
        }
    }
}

/// Carries out cleanup plans. Every item is re-checked by the `SafetyGuard` immediately before it is
/// touched, every removal is journaled, and automatic runs stop at the configured byte budget.
public struct CleanupExecutor: Sendable {
    public var safety: SafetyGuard
    public var journal: Journal?
    public var rules: [String: Rule]
    /// Executables allowed beyond `RuleLibrary.trustedCommands`.
    public var extraAllowedCommands: Set<String>
    /// Upper bound for one automatic run.
    public var maxBytesPerAutomaticRun: UInt64
    public var commandTimeout: TimeInterval

    public init(
        safety: SafetyGuard, journal: Journal?, rules: [Rule], extraAllowedCommands: Set<String> = [],
        maxBytesPerAutomaticRun: UInt64 = ByteCount.gb(100).bytes, commandTimeout: TimeInterval = 600
    ) {
        self.safety = safety
        self.journal = journal
        self.rules = Dictionary(rules.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        self.extraAllowedCommands = extraAllowedCommands
        self.maxBytesPerAutomaticRun = maxBytesPerAutomaticRun
        self.commandTimeout = commandTimeout
    }

    /// Checks one item without touching it.
    public func verdict(for item: CleanupItem, context: CleanupContext) -> SafetyVerdict {
        // Loose files are judged as "something inside the folder", not as the folder itself.
        let path = item.kind == .looseFiles ? PathUtil.join(item.path, "*") : item.path
        return safety.evaluate(
            path: path, size: item.size, rule: item.ruleID.flatMap { rules[$0] }, context: context,
            isRepository: item.isRepository, containsRepository: item.containsRepository)
    }

    public func execute(
        _ plan: CleanupPlan,
        context: CleanupContext,
        dryRun: Bool,
        onProgress: (@Sendable (_ completed: Int, _ total: Int, _ current: String) -> Void)? = nil
    ) -> CleanupReport {
        var report = CleanupReport(dryRun: dryRun)
        var journalEntries: [JournalEntry] = []
        let confirmed: Bool
        let jobID: String?
        switch context {
        case .manual(let c):
            confirmed = c
            jobID = nil
        case .automatic(let automation):
            confirmed = false
            jobID = automation.jobID
        }
        var budget = context.isAutomatic ? maxBytesPerAutomaticRun : UInt64.max
        let total = plan.items.count + plan.commands.count
        var completed = 0

        for item in plan.items {
            onProgress?(completed, total, item.path)
            completed += 1
            let outcome = removeItem(item, plan: plan, context: context, confirmed: confirmed, dryRun: dryRun, budget: &budget)
            if case .removed(let bytes, let trashedTo) = outcome {
                journalEntries.append(
                    JournalEntry(
                        path: item.kind == .looseFiles ? item.path + "/*" : item.path, bytes: bytes,
                        method: plan.useTrash ? .trash : .delete, ruleID: item.ruleID, jobID: jobID,
                        automatic: context.isAutomatic, trashedTo: trashedTo))
            }
            report.items.append((item, outcome))
        }

        for command in plan.commands {
            onProgress?(completed, total, command.displayString)
            completed += 1
            let (outcome, output) = run(command, context: context, dryRun: dryRun, budget: &budget)
            if case .removed(let bytes, _) = outcome {
                journalEntries.append(
                    JournalEntry(
                        path: command.displayString, bytes: bytes, method: .command, ruleID: command.ruleID, jobID: jobID,
                        automatic: context.isAutomatic))
            }
            report.commands.append((command, outcome, output))
        }
        onProgress?(total, total, "")

        if !dryRun { try? journal?.append(journalEntries) }
        return report
    }

    // MARK: Files

    private func removeItem(
        _ item: CleanupItem, plan: CleanupPlan, context: CleanupContext, confirmed: Bool,
        dryRun: Bool, budget: inout UInt64
    ) -> CleanupOutcome {
        var st = stat()
        guard lstat(item.path, &st) == 0 else { return .skipped(reason: "Already gone") }

        let verdict = verdict(for: item, context: context)
        guard verdict.permits(confirmed: confirmed) else {
            let prefix = verdict.decision == .confirm ? "Needs confirmation: " : "Blocked: "
            return .skipped(reason: prefix + verdict.reasons.joined(separator: "; "))
        }
        if context.isAutomatic {
            if !plan.useTrash, let rule = item.ruleID.flatMap({ rules[$0] }), rule.safety.level != .safe {
                return .skipped(reason: "Automatic permanent deletion is only allowed for regenerable (safe) items")
            }
            guard item.size <= budget else {
                return .skipped(reason: "Over this run's budget of \(ByteCount.format(maxBytesPerAutomaticRun)) (safety.maxBytesPerRun)")
            }
        }
        if dryRun { return .wouldRemove(bytes: item.size) }

        do {
            switch item.kind {
            case .directory, .file:
                // Things already in the Trash can only be removed by deleting them.
                let inTrash = PathUtil.isStrictAncestor(PathUtil.home + "/.Trash", of: item.path)
                let trashedTo = try remove(item.path, toTrash: plan.useTrash && !inTrash)
                budget -= min(budget, item.size)
                return .removed(bytes: item.size, trashedTo: trashedTo)
            case .looseFiles:
                let inTrash = PathUtil.isAncestorOrEqual(PathUtil.home + "/.Trash", of: item.path)
                let freed = try removeLooseFiles(in: item, toTrash: plan.useTrash && !inTrash, context: context, confirmed: confirmed)
                budget -= min(budget, freed)
                return .removed(bytes: freed, trashedTo: nil)
            }
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Removes one file system item. Returns where it went if it was trashed.
    private func remove(_ path: String, toTrash: Bool) throws -> String? {
        let url = URL(fileURLWithPath: path)
        if toTrash {
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting?.path
        }
        // removefile(3) is much faster than FileManager for large trees and never follows symlinks.
        let state = removefile_state_alloc()
        defer { removefile_state_free(state) }
        if removefile(path, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) != 0 {
            throw CocoaError(
                .fileWriteNoPermission, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: String(cString: strerror(errno))])
        }
        return nil
    }

    /// Removes the plain files directly inside `directory`, leaving subdirectories alone.
    private func removeLooseFiles(in item: CleanupItem, toTrash: Bool, context: CleanupContext, confirmed: Bool) throws -> UInt64 {
        var freed: UInt64 = 0
        let rule = item.ruleID.flatMap { rules[$0] }
        for name in try FileManager.default.contentsOfDirectory(atPath: item.path) {
            let path = PathUtil.join(item.path, name)
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            guard safety.evaluate(path: path, rule: rule, context: context).permits(confirmed: confirmed) else { continue }
            let size = UInt64(max(0, st.st_blocks)) * 512
            _ = try remove(path, toTrash: toTrash)
            freed &+= size
        }
        return freed
    }

    // MARK: Commands

    private func run(_ command: PlannedCommand, context: CleanupContext, dryRun: Bool, budget: inout UInt64) -> (CleanupOutcome, String) {
        guard let executableName = command.arguments.first else { return (.failed(reason: "Empty command"), "") }
        let name = PathUtil.lastComponent(executableName)
        guard RuleLibrary.trustedCommands.contains(name) || extraAllowedCommands.contains(name) else {
            return (.skipped(reason: "'\(name)' isn't a trusted command; add it to safety.allowedCommands to allow it"), "")
        }
        if let rule = rules[command.ruleID] {
            if rule.safety.level == .protected { return (.skipped(reason: "\(rule.name) is protected"), "") }
            if case .automatic(let automation) = context, rule.safety.level == .review, !automation.allowReview {
                return (.skipped(reason: "\(rule.name) needs review; the job doesn't include review items"), "")
            }
        }
        guard let executable = Shell.which(executableName) else {
            return (.skipped(reason: "'\(name)' is not installed"), "")
        }
        if dryRun { return (.wouldRemove(bytes: command.estimatedBytes), "") }

        let before = measure(command.measurePaths)
        let result = Shell.run(executable, Array(command.arguments.dropFirst()), timeout: commandTimeout)
        guard result.status == 0 else {
            return (.failed(reason: "Exited with status \(result.status)"), result.output)
        }
        let after = measure(command.measurePaths)
        let freed = before > after ? before - after : 0
        budget -= min(budget, freed)
        return (.removed(bytes: freed, trashedTo: nil), result.output)
    }

    private func measure(_ paths: [String]) -> UInt64 {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return 0 }
        var options = ScanOptions()
        options.minFileSize = .max
        return (try? Scanner(options: options).scan(roots: existing).root.size) ?? 0
    }
}
