import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// An executor whose home, Trash and journal all live inside `tree`, so nothing reaches the real Trash.
func sandboxExecutor(
    _ tree: TempTree, rules: [Rule] = [], budget: ByteCount = .gb(100), allowed: Set<String> = [], configError: String? = nil,
    root: Bool = false
) -> CleanupExecutor {
    let home = tree.path("home")
    let guardian = SafetyGuard(home: home, volumes: emptyVolumes, isRunningAsRoot: root)
    var executor = CleanupExecutor(
        safety: guardian, journal: Journal(file: tree.path("state/journal.jsonl")), rules: rules, extraAllowedCommands: allowed,
        maxBytesPerAutomaticRun: budget.bytes, configError: configError)
    executor.builtinRulesDirectory = tree.path("builtin-rules")
    executor.trash = { path in
        let trash = home + "/.Trash"
        try FileManager.default.createDirectory(atPath: trash, withIntermediateDirectories: true)
        var destination = trash + "/" + PathUtil.lastComponent(path)
        var counter = 2
        while FileManager.default.fileExists(atPath: destination) {
            destination = trash + "/\(PathUtil.lastComponent(path)) \(counter)"
            counter += 1
        }
        try FileManager.default.moveItem(atPath: path, toPath: destination)
        return destination
    }
    return executor
}

func journalEntries(_ tree: TempTree) -> [JournalEntry] {
    Journal(file: tree.path("state/journal.jsonl")).entries()
}

func onDisk(_ path: String) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0
}

/// Lets file times move past a plan's `created` date.
func waitForClockTick() { usleep(20_000) }

func cacheRule(_ tree: TempTree, id: String = "cache", level: SafetyLevel, paths: [String]) -> Rule {
    Rule(
        id: id, name: id, paths: paths.map { tree.path($0) }, granularity: .children,
        safety: SafetySpec(level: level, trash: level != .safe), action: ActionSpec(remove: true))
}

@Suite("Cleanup execution: automatic runs")
struct AutomaticCleanupTests {
    @Test("Non-safe rule items in an automatic delete plan go to the Trash instead of being skipped")
    func reviewItemsAreTrashed() throws {
        let tree = try TempTree()
        try tree.file("home/archives/a/x", bytes: 4000)
        let rule = cacheRule(tree, level: .review, paths: ["home/archives"])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/archives/a"), size: 4000, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule])
            .execute(plan, context: .automatic(AutomationContext(jobID: "j", allowReview: true)), dryRun: false)
        let outcome = try #require(report.items.first?.outcome)
        #expect(outcome.isRemoved)
        #expect(outcome.trashedTo != nil)
        #expect(onDisk(tree.path("home/.Trash/a/x")))
        #expect(journalEntries(tree).first?.method == .trash)
    }

    @Test("Job folders without a rule are trashed, never deleted permanently, by automatic runs")
    func customPathsAreTrashed() throws {
        let tree = try TempTree()
        try tree.file("home/Scratch/old/x", bytes: 4000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Scratch/old"), size: 4000)], useTrash: false)
        let context = CleanupContext.automatic(AutomationContext(jobID: "j", customPaths: [tree.path("home/Scratch")], usesTrash: false))
        let report = sandboxExecutor(tree).execute(plan, context: context, dryRun: false)
        #expect(report.items.first?.outcome.trashedTo != nil)
        #expect(onDisk(tree.path("home/.Trash/old/x")))
    }

    @Test("Safe rule items in an automatic delete plan are deleted")
    func safeItemsAreDeleted() throws {
        let tree = try TempTree()
        try tree.file("home/dd/a/x", bytes: 4000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/dd"])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/dd/a"), size: 4000, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule]).execute(plan, context: .automatic(AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.items.first?.outcome.trashedTo == nil)
        #expect(!onDisk(tree.path("home/dd/a")))
        #expect(!onDisk(tree.path("home/.Trash/a")))
    }

    @Test("Items already in the Trash: automatic runs delete them only for safe rules")
    func trashContentsInAutomaticRuns() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4000)
        try tree.file("home/.Trash/older/y", bytes: 4000)
        let review = cacheRule(tree, id: "review", level: .review, paths: ["home/.Trash"])
        let safe = cacheRule(tree, id: "safe", level: .safe, paths: ["home/.Trash"])
        let context = CleanupContext.automatic(AutomationContext(jobID: "j", allowReview: true))

        let reviewPlan = CleanupPlan(items: [CleanupItem(path: tree.path("home/.Trash/old"), size: 4000, ruleID: "review")])
        let skipped = sandboxExecutor(tree, rules: [review]).execute(reviewPlan, context: context, dryRun: false)
        #expect(skipped.skipped.count == 1)
        #expect(onDisk(tree.path("home/.Trash/old/x")))

        let safePlan = CleanupPlan(items: [CleanupItem(path: tree.path("home/.Trash/older"), size: 4000, ruleID: "safe")])
        let deleted = sandboxExecutor(tree, rules: [safe]).execute(safePlan, context: context, dryRun: false)
        #expect(deleted.items.first?.outcome.isRemoved == true)
        #expect(!onDisk(tree.path("home/.Trash/older")))
        #expect(journalEntries(tree).map(\.method) == [.delete])
    }

    @Test("The budget is charged with the size measured at removal time, not the plan's")
    func budgetUsesMeasuredSize() throws {
        let tree = try TempTree()
        try tree.file("home/dd/a/x", bytes: 64_000)
        let rule = cacheRule(tree, level: .safe, paths: ["home/dd"])
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/dd/a"), size: 1, ruleID: "cache")], useTrash: false)
        let report = sandboxExecutor(tree, rules: [rule], budget: ByteCount(10_000))
            .execute(plan, context: .automatic(AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.skipped.count == 1)
        #expect(onDisk(tree.path("home/dd/a/x")))
    }

    @Test("A repository that appeared after the scan blocks automatic removal")
    func repositoryRecheckedAtRemoval() throws {
        let tree = try TempTree()
        try tree.file("home/dd/a/x", bytes: 4000)
        try tree.directory("home/dd/a/.git")
        try tree.file("home/dd/b/deep/er/y", bytes: 4000)
        try tree.directory("home/dd/b/deep/er/.git")
        let rule = cacheRule(tree, level: .review, paths: ["home/dd"])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/dd/a"), size: 4000, ruleID: "cache"),
                CleanupItem(path: tree.path("home/dd/b"), size: 4000, ruleID: "cache"),
            ], useTrash: true)
        let report = sandboxExecutor(tree, rules: [rule])
            .execute(plan, context: .automatic(AutomationContext(jobID: "j", allowReview: true)), dryRun: false)
        #expect(report.skipped.count == 2)
        #expect(onDisk(tree.path("home/dd/a/x")))
        #expect(onDisk(tree.path("home/dd/b/deep/er/y")))
    }
}

@Suite("Cleanup execution: Trash and journal")
struct TrashAndJournalTests {
    @Test("Items already in the Trash are deleted and journaled as deletions")
    func trashContentsAreDeleted() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/.Trash/old"), size: 4000)], useTrash: true)
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.items.first?.outcome.trashedTo == nil)
        #expect(!onDisk(tree.path("home/.Trash/old")))
        #expect(journalEntries(tree).map(\.method) == [.delete])
    }

    @Test("The Trash is recognised whatever the case of the path")
    func trashCaseFolded() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/old/x", bytes: 4000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/.TRASH/old"), size: 4000)], useTrash: true)
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.items.first?.outcome.trashedTo == nil)
        #expect(journalEntries(tree).map(\.method) == [.delete])
    }

    @Test("Each removal is journaled as it happens")
    func journalPerRemoval() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/build/x", bytes: 1000)
        try tree.file("home/Projects/b/build/y", bytes: 1000)
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/Projects/a/build"), size: 1000),
                CleanupItem(path: tree.path("home/Projects/b/build"), size: 1000),
            ], useTrash: false)
        let journal = Journal(file: tree.path("state/journal.jsonl"))
        let seen = Mutex<[Int]>([])
        _ = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false) { completed, _, _ in
            let count = journal.entries().count
            seen.withLock { $0.append(count) }
            _ = completed
        }
        #expect(seen.withLock { $0 } == [0, 1, 2])
    }

    @Test("A failed journal write is reported, not swallowed")
    func journalFailureSurfaces() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/build/x", bytes: 1000)
        try tree.directory("state/journal.jsonl")
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a/build"), size: 1000)], useTrash: false)
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(report.warnings.contains { $0.contains("journal") })
    }

    @Test("Trashed loose files each record where they went")
    func looseFilesRecordTrashLocation() throws {
        let tree = try TempTree()
        try tree.file("home/cache/a.tmp", bytes: 1000)
        try tree.file("home/cache/b.tmp", bytes: 1000)
        waitForClockTick()
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/cache"), kind: .looseFiles, size: 2000)], useTrash: true)
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.trashedBytes > 0)
        #expect(report.deletedBytes == 0)
        let entries = journalEntries(tree)
        #expect(entries.count == 2)
        for entry in entries {
            #expect(entry.method == .trash)
            #expect(entry.trashedTo.map(onDisk) == true)
        }
    }

    @Test("A partly failed loose-file removal journals what went and charges the budget")
    func partialLooseFiles() throws {
        let tree = try TempTree()
        let stuck = try tree.file("home/cache/a.tmp", bytes: 8000)
        try tree.file("home/cache/b.tmp", bytes: 8000)
        try tree.file("home/cache2/c.tmp", bytes: 8000)
        #expect(chflags(stuck, UInt32(UF_IMMUTABLE)) == 0)
        defer { chflags(stuck, 0) }
        waitForClockTick()
        let rule = cacheRule(tree, level: .safe, paths: ["home/cache", "home/cache2"])
        let plan = CleanupPlan(
            items: [
                CleanupItem(path: tree.path("home/cache"), kind: .looseFiles, size: 16_000, ruleID: "cache"),
                CleanupItem(path: tree.path("home/cache2/c.tmp"), kind: .file, size: 8000, ruleID: "cache"),
            ], useTrash: false)
        let budget = ByteCount(tree.allocated("home/cache/b.tmp") + 1)
        let report = sandboxExecutor(tree, rules: [rule], budget: budget)
            .execute(plan, context: .automatic(AutomationContext(jobID: "j")), dryRun: false)
        #expect(!onDisk(tree.path("home/cache/b.tmp")))
        #expect(onDisk(stuck))
        #expect(journalEntries(tree).map(\.path) == [tree.path("home/cache/b.tmp")])
        #expect(!report.warnings.isEmpty)
        #expect(onDisk(tree.path("home/cache2/c.tmp")), "the budget was spent on b.tmp")
    }
}

@Suite("Cleanup execution: the plan's snapshot in time")
struct PlanCreatedTests {
    @Test("Loose files that appeared after the plan was made are left alone")
    func newLooseFilesSkipped() throws {
        let tree = try TempTree()
        try tree.file("home/cache/old.tmp", bytes: 1000)
        waitForClockTick()
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/cache"), kind: .looseFiles, size: 1000)], useTrash: false)
        waitForClockTick()
        try tree.file("home/cache/new.tmp", bytes: 1000)
        _ = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(!onDisk(tree.path("home/cache/old.tmp")))
        #expect(onDisk(tree.path("home/cache/new.tmp")))
    }

    @Test("A plan without a creation date can't remove loose files")
    func undatedPlanRefusesLooseFiles() throws {
        let tree = try TempTree()
        try tree.file("home/cache/old.tmp", bytes: 1000)
        let plan = CleanupPlan(
            items: [CleanupItem(path: tree.path("home/cache"), kind: .looseFiles, size: 1000)], useTrash: false, created: nil)
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.skipped.first?.reason.contains("refresh") == true)
        #expect(onDisk(tree.path("home/cache/old.tmp")))
    }

    @Test("Old suggestions decode without a creation date")
    func decodesOldPlans() throws {
        let json = #"{"items":[],"commands":[],"manualSteps":[],"useTrash":true}"#
        let plan = try JSONDecoder.spaceKit.decode(CleanupPlan.self, from: Data(json.utf8))
        #expect(plan.created == nil)
    }

    @Test("Emptying the Trash leaves what was trashed after the plan was made")
    func lateTrashSkipped() throws {
        let tree = try TempTree()
        try tree.file("home/.Trash/early/x", bytes: 1000)
        waitForClockTick()
        var plan = CleanupPlan(useTrash: false)
        waitForClockTick()
        try tree.file("home/.Trash/late/y", bytes: 1000)
        plan.items = [
            CleanupItem(path: tree.path("home/.Trash/early"), size: 1000),
            CleanupItem(path: tree.path("home/.Trash/late"), size: 1000),
        ]
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(!onDisk(tree.path("home/.Trash/early")))
        #expect(onDisk(tree.path("home/.Trash/late/y")))
        #expect(report.skipped.count == 1)
    }
}

@Suite("Cleanup execution: config and removal mechanics")
struct ExecutionMechanicsTests {
    @Test("An invalid config refuses every removal")
    func invalidConfigRefuses() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/a/build/x", bytes: 1000)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/a/build"), size: 1000)], useTrash: false)
        let report = sandboxExecutor(tree, configError: "config.yaml: bad").execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.skipped.first?.reason.contains("Config file is invalid") == true)
        #expect(onDisk(tree.path("home/Projects/a/build/x")))
    }

    @Test("A context loaded from an unreadable config refuses removals")
    func contextFailsClosed() throws {
        let tree = try TempTree()
        try tree.directory("config")
        try "safety:\n  maxBytesPerRun: lots\n".write(toFile: tree.path("config/config.yaml"), atomically: true, encoding: .utf8)
        try tree.file("work/build/x", bytes: 1000)
        let paths = SpaceKitPaths(configFile: tree.path("config/config.yaml"), stateDirectory: tree.path("state"))
        let context = SpaceKitContext.load(paths: paths)
        #expect(context.configError != nil)
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("work/build"), size: 1000)], useTrash: false)
        let report = context.executor.execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.skipped.first?.reason.contains("Config file is invalid") == true)
        #expect(onDisk(tree.path("work/build/x")))
    }

    @Test("A symlink is removed as a link; its target stays")
    func symlinkRemovedAsLink() throws {
        let tree = try TempTree()
        try tree.file("home/Projects/target/keep", bytes: 1000)
        try tree.directory("home/Projects/links")
        try FileManager.default.createSymbolicLink(
            atPath: tree.path("home/Projects/links/l"), withDestinationPath: tree.path("home/Projects/target"))
        let plan = CleanupPlan(items: [CleanupItem(path: tree.path("home/Projects/links/l"), size: 0)], useTrash: false)
        let report = sandboxExecutor(tree).execute(plan, context: .manual(confirmed: true), dryRun: false)
        #expect(report.items.first?.outcome.isRemoved == true)
        #expect(!onDisk(tree.path("home/Projects/links/l")))
        #expect(onDisk(tree.path("home/Projects/target/keep")))
    }

    @Test("Removal refuses a parent folder reached through a symlink")
    func handleRefusesSymlinkedParent() throws {
        let tree = try TempTree()
        try tree.directory("real")
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real"))
        #expect(throws: (any Error).self) { _ = try SafeRemoval.openDirectory(tree.path("link")) }
        let fd = try SafeRemoval.openDirectory(tree.path("real"))
        close(fd)
    }

    @Test("Removal refuses when the opened folder isn't the one that was checked")
    func handleRefusesMismatch() throws {
        let tree = try TempTree()
        try tree.directory("a")
        try tree.directory("b")
        #expect(throws: (any Error).self) { _ = try SafeRemoval.openDirectory(tree.path("a"), expecting: tree.path("b")) }
    }
}
