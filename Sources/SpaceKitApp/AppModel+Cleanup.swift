import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Cleanup

    func cleanupItem(for item: DiskItem) -> CleanupItem? {
        CleanupItem(item, markers: tree?.markers, ruleID: rule(for: item.path)?.id)
    }

    func addToCleanupList(_ items: [CleanupItem]) {
        for item in items where !cleanupList.contains(where: { $0.id == item.id }) {
            cleanupList.append(item)
        }
    }

    func isInCleanupList(_ path: String?) -> Bool {
        guard let path else { return false }
        return cleanupList.contains { $0.path == path }
    }

    var cleanupListBytes: UInt64 { cleanupList.reduce(0) { $0 + $1.size } }

    /// Opens the review sheet for a plan, unless another cleanup is already open (it may be running).
    func review(_ plan: CleanupPlan, title: String, completion: (@MainActor (CleanupReport) -> Void)? = nil) {
        guard pendingCleanup == nil else {
            errorMessage = "Another cleanup is open. Finish or cancel it first."
            return
        }
        var plan = plan
        if context.config.safety.trash == .always { plan.useTrash = true }
        pendingCleanup = PendingCleanup(title: title, plan: plan, completion: completion)
    }

    func reviewFinding(_ finding: Finding, items: [FindingItem]? = nil) {
        let plan = CleanupPlan.make(findings: [finding], trashPreference: context.trashPreference(for: .rule)) { items ?? $0.items }
        review(plan, title: "Clean \(finding.rule.name)")
    }

    /// The guard's verdict on everything in a plan, as the review sheet shows it before anything runs.
    struct PlanVerdicts: Sendable {
        var items: [(item: CleanupItem, verdict: SafetyVerdict)]
        var commands: [(command: PlannedCommand, verdict: SafetyVerdict)]
    }

    func verdicts(for plan: CleanupPlan) async -> PlanVerdicts {
        let executor = context.executor
        return await Task.detached(priority: .userInitiated) {
            PlanVerdicts(
                items: plan.items.map { ($0, executor.verdict(for: $0, context: .manual(confirmed: false))) },
                commands: plan.commands.map { ($0, executor.verdict(for: $0, context: .manual(confirmed: false))) })
        }.value
    }

    var isCleaning: Bool { runningCleanups > 0 }

    /// Runs a reviewed plan, then `completion` (bookkeeping such as job state) before the app may quit.
    /// Pass `confirmed: true` only when the person acknowledged every warning the review showed; otherwise items and
    /// commands that need confirmation are skipped.
    func execute(
        _ plan: CleanupPlan, confirmed: Bool, completion: (@MainActor (CleanupReport) -> Void)? = nil,
        onProgress: @escaping @Sendable (Int, Int, String) -> Void
    ) async -> CleanupReport {
        beginCleanup()
        defer { endCleanup() }
        let executor = context.executor
        let report = await Task.detached(priority: .userInitiated) {
            executor.execute(plan, context: .manual(confirmed: confirmed), dryRun: false, onProgress: onProgress)
        }.value
        completion?(report)
        Task {
            await untilTreesAreFree()
            applyRemovals(report)
        }
        return report
    }

    /// Brings every view up to date after a cleanup without re-scanning or re-analysing everything:
    /// the trees shrink in place, findings lose only the cleaned items, the AI report and category
    /// totals update only if they were affected, and rules whose tool command ran are re-evaluated alone.
    private func applyRemovals(_ report: CleanupReport) {
        let removals = Removal.from(report)
        applyToTreesAndFindings(removals)

        // Tool commands free space their own way; re-evaluate just those rules.
        let commandRules = Set(
            report.commands.compactMap { entry -> String? in
                if case .removed = entry.outcome { return entry.command.ruleID }
                return nil
            })
        if !commandRules.isEmpty { refreshFindings(ruleIDs: commandRules) }

        // Navigation and selection.
        let removedPaths = Set(removals.filter { $0.kind != .looseFiles }.map(\.path))
        if let focus, removedPaths.contains(where: { PathUtil.isAncestorOrEqual($0, of: focus.path) }) {
            var survivor = focus.parent
            while let node = survivor, removedPaths.contains(where: { PathUtil.isAncestorOrEqual($0, of: node.path) }) {
                survivor = node.parent
            }
            self.focus = survivor ?? tree?.root
            backStack = []
        }
        if !removedPaths.isEmpty || removals.contains(where: { $0.kind == .looseFiles }) {
            cleanupList.removeAll { item in
                removedPaths.contains { PathUtil.isAncestorOrEqual($0, of: item.path) }
                    || (item.kind == .looseFiles && removals.contains { $0.kind == .looseFiles && $0.path == item.path })
            }
        }
        if let path = selection?.path, removedPaths.contains(where: { PathUtil.isAncestorOrEqual($0, of: path) }) { selection = nil }
        if let path = hovered?.path, removedPaths.contains(where: { PathUtil.isAncestorOrEqual($0, of: path) }) { hovered = nil }

        refreshJournal()
        refreshVolumes()
        // Re-measure the Trash exactly (and resync it in the map) once the move has settled.
        refreshTrash(resync: report.trashedBytes > 0 || removals.contains { PathUtil.isStrictAncestor(trashPath, of: $0.path) })
        refreshSnapshots()
    }
}
