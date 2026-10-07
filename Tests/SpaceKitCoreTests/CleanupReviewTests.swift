import Foundation
import Testing

@testable import SpaceKitCore

/// Runs `plan` the way a front end does once a person said go: through a review, with every warning it showed
/// accepted unless `acceptingWarnings` is false. Rows the review blocked never reach the executor; they are added to
/// the report as skipped with the guard's reasons, so tests of a gate see its refusal whichever step makes it.
func manualRun(
    _ plan: CleanupPlan, with executor: CleanupExecutor, acceptingWarnings: Bool = true, dryRun: Bool = false,
    onProgress: CleanupExecutor.ProgressHandler? = nil
) -> CleanupReport {
    let review = CleanupReview(plan, executor: executor)
    var report = executor.execute(review.acknowledge(acceptingWarnings: acceptingWarnings), dryRun: dryRun, onProgress: onProgress)
    func refusal(_ verdict: SafetyVerdict) -> CleanupOutcome { .skipped(reason: "Blocked: " + verdict.reasons.joined(separator: "; ")) }
    report.items += review.items.filter(\.verdict.isBlocked).map { ($0.subject, refusal($0.verdict)) }
    report.commands += review.commands.filter(\.verdict.isBlocked).map { ($0.subject, refusal($0.verdict), "") }
    return report
}

@Suite("Cleanup review")
struct CleanupReviewTests {
    @Test("Nothing that needs confirmation runs without the person's acknowledgement")
    func acknowledgementRequired() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/old/x", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let review = CleanupReview(
            CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/old"), size: 1_000)], useTrash: false), executor: executor)
        #expect(review.items.first?.verdict.decision == .confirm)
        #expect(review.needsAcknowledgement)
        #expect(review.warningCount == 1)

        let unacknowledged = executor.execute(review.acknowledge(acceptingWarnings: false), dryRun: false)
        #expect(unacknowledged.skipped.first?.reason.hasPrefix("Needs confirmation: ") == true)
        #expect(onDisk(tree.path("home/Projects/old/x")))

        let acknowledged = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(acknowledged.items.first?.outcome.isRemoved == true)
    }

    @Test("Commands that need confirmation run only once acknowledged")
    func commandsNeedAcknowledgement() throws {
        let tree = try TempTree()
        var rule = Rule(
            id: "tool", name: "Tool", paths: [], safety: SafetySpec(level: .review), action: ActionSpec(command: ["swift", "--version"]))
        rule.isBuiltin = true
        let executor = sandboxExecutor(tree, rules: [rule])
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: ["swift", "--version"], estimatedBytes: 1)])
        let review = CleanupReview(plan, executor: executor)
        #expect(review.commands.first?.needsAcknowledgement == true)
        let refused = executor.execute(review.acknowledge(acceptingWarnings: false), dryRun: true)
        #expect(refused.unfinishedCommands.first?.reason.hasPrefix("Needs confirmation: ") == true)
        let accepted = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: true)
        #expect(accepted.unfinishedCommands.isEmpty)
        #expect(accepted.commands.map(\.outcome) == [.wouldRemove(bytes: 1)])
    }

    @Test("A warning the review didn't show for a row is refused, even when another row showed it")
    func unshownWarningRefused() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/repo/x", bytes: 1_000)
        try tree.directory("home/Projects/repo/.git")
        try tree.file("home/Projects/plain/y", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/repo"), size: 1_000, isRepository: true),
                CleanupItem(path: tree.path("home/Projects/plain"), size: 1_000),
            ], useTrash: false)
        let reviewed = CleanupReview(plan, executor: executor).acknowledge(acceptingWarnings: true)
        // After the review, the plain folder becomes a repository: the person accepted that warning for the other row only.
        try tree.directory("home/Projects/plain/.git")
        let report = executor.execute(reviewed, dryRun: false)
        #expect(!onDisk(tree.path("home/Projects/repo")))
        let skipped = try #require(report.skipped.first)
        #expect(skipped.item.path == tree.path("home/Projects/plain"))
        #expect(skipped.reason.hasPrefix("Changed since you reviewed it: "))
        #expect(skipped.reason.contains("git repository"))
        #expect(onDisk(tree.path("home/Projects/plain/y")))
    }

    @Test("Unticked rows don't run, and the counts and totals leave them out")
    func untickedRowsDontRun() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        try tree.file("home/Projects/b/y", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/a"), size: 2_000),
                CleanupItem(path: tree.path("home/Projects/b"), size: 1_000),
            ], useTrash: false)
        let review = CleanupReview(plan, executor: executor)
        let keepB = try #require(review.items.first { $0.subject.path == tree.path("home/Projects/b") })
        let narrowed = review.including(keepB, false)
        #expect(review.isIncluded(keepB))
        #expect(!narrowed.isIncluded(keepB))
        #expect(narrowed.selectedItems.map(\.path) == [tree.path("home/Projects/a")])
        #expect(narrowed.itemBytes == 2_000)
        #expect(narrowed.warningCount == 1)

        let report = executor.execute(narrowed.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(report.items.map(\.item.path) == [tree.path("home/Projects/a")])
        #expect(!onDisk(tree.path("home/Projects/a")))
        #expect(onDisk(tree.path("home/Projects/b/y")))
        #expect(narrowed.including(keepB, true).selectedItems.count == 2)
    }

    @Test("Blocked rows can't be ticked and never reach the executor")
    func blockedRowsNeverRun() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let arguments = ["xcrun", "--version"]
        var user = Rule(id: "tool", name: "Tool", paths: [], safety: SafetySpec(level: .safe), action: ActionSpec(command: arguments))
        user.isBuiltin = false
        let executor = sandboxExecutor(tree, rules: [user])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home"), size: 1_000),
                CleanupItem(path: tree.path("home/Projects/a"), size: 1_000),
            ],
            commands: [PlannedCommand(ruleID: "tool", arguments: arguments, estimatedBytes: 1)], useTrash: false)
        let review = CleanupReview(plan, executor: executor)
        #expect(review.blockedCount == 2)
        let home = try #require(review.items.first { $0.subject.path == tree.path("home") })
        #expect(home.verdict.isBlocked)
        #expect(!review.including(home, true).isIncluded(home))
        #expect(review.selectedItems.map(\.path) == [tree.path("home/Projects/a")])
        #expect(review.selectedCommands.isEmpty)

        let report = executor.execute(review.acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(report.items.map(\.item.path) == [tree.path("home/Projects/a")])
        #expect(report.commands.isEmpty)
        #expect(onDisk(tree.path("home")))
    }

    @Test("The review says where the selected items go")
    func disposalWording() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 1_000)
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let trashed = CleanupItem(path: tree.path("home/.Trash/old"), size: 1_000, scanStarted: Date())
        let project = CleanupItem(path: tree.path("home/Projects/a"), size: 1_000)

        let emptying = CleanupReview(CleanupPlan(items: [trashed], useTrash: true), executor: executor)
        #expect(emptying.disposal == .deleteFromTrash)
        #expect(emptying.disposalSummary?.contains("already in the Trash") == true)

        let review = CleanupReview(CleanupPlan(items: [trashed, project], useTrash: true), executor: executor)
        #expect(review.disposal == .moveToTrash)
        #expect(review.canChooseTrash)
        #expect(review.usingTrash(false).disposal == .delete)
        #expect(review.usingTrash(false).disposalSummary?.contains("deleted permanently") == true)
        #expect(review.commandSummary == nil)

        var always = executor
        always.alwaysTrash = true
        let forced = CleanupReview(CleanupPlan(items: [project], useTrash: false), executor: always)
        #expect(!forced.canChooseTrash)
        #expect(forced.disposal == .moveToTrash)
    }

    @Test("The unticked Trash choice is what runs")
    func trashChoiceRuns() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/x", bytes: 1_000)
        let executor = sandboxExecutor(tree)
        let review = CleanupReview(
            CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a"), size: 1_000)], useTrash: true), executor: executor)
        let report = executor.execute(review.usingTrash(false).acknowledge(acceptingWarnings: true), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.trashedBytes == 0)
    }
}
