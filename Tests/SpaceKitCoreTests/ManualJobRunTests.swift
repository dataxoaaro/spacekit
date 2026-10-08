import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Manual job runs")
struct ManualJobRunTests {
    /// A fixture with one 🟢 rule over `home/build`, whose child folders are the items.
    func buildFixture(_ folders: [String]) throws -> RunnerFixture {
        var fixture = try RunnerFixture()
        for folder in folders { try fixture.tree.file("home/build/\(folder)/out.o", bytes: 8192) }
        fixture.rules = [fixture.rule("build", "home/build", level: .safe)]
        return fixture
    }

    func buildJob(mode: Job.Mode = .suggest, sizeAbove: ByteCount? = nil) -> Job {
        Job(id: "build", name: "Build", rules: ["build"], mode: mode, when: Job.Conditions(sizeAbove: sizeAbove), action: .delete)
    }

    /// Runs the job the way the agent does, so its suggestion is saved, and returns it.
    func suggest(_ fixture: RunnerFixture, job: Job) throws -> Suggestion {
        guard case .suggested(let suggestion) = fixture.runner.run(job, now: Date(timeIntervalSince1970: 1_000)).action else {
            throw TestFailure("expected a suggestion")
        }
        return suggestion
    }

    func reviewed(_ run: ManualJobRun, _ fixture: RunnerFixture, untick: Set<String> = []) throws -> ReviewedPlan {
        var review = CleanupReview(try #require(run.plan), executor: fixture.runner.executor)
        for row in review.items where untick.contains(PathUtil.lastComponent(row.subject.path)) {
            review = review.including(row, false)
        }
        return review.acknowledge(acceptingWarnings: false)
    }

    func lastRun(_ fixture: RunnerFixture) -> Date? { fixture.context.jobStates.load()["build"]?.lastRun }

    @Test("Preparing and completing a job run removes its plan, records the run and journals each removal once")
    func jobRun() throws {
        let fixture = try buildFixture(["a"])
        let run = try ManualJobRun.prepare(buildJob(), runner: fixture.runner)
        #expect(run.skipReason == nil)
        #expect(lastRun(fixture) == nil)

        let date = Date(timeIntervalSince1970: 5_000)
        let outcome = run.complete(try reviewed(run, fixture), now: date)

        #expect(outcome.report.freedBytes > 0)
        #expect(outcome.saveErrors.isEmpty)
        #expect(outcome.suggestion == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.tree.path("home/build/a")))
        #expect(lastRun(fixture) == date)
        #expect(fixture.context.jobStates.load()["build"]?.lastOutcome == outcome.report.summary)
        let journal = Journal(file: fixture.tree.path("state/journal.jsonl")).entries()
        #expect(journal.map(\.path) == [fixture.tree.path("home/build/a")])
        #expect(journal.first?.automatic == false)
    }

    @Test("A job below its threshold would skip, says why, and runs only when forced")
    func belowThreshold() throws {
        let fixture = try buildFixture(["a"])
        let run = try ManualJobRun.prepare(buildJob(sizeAbove: .gb(1)), runner: fixture.runner)

        #expect(run.skipReason?.hasSuffix("is below the 1.0 GB threshold") == true)
        #expect(run.canForce)
        #expect(run.plan == nil)

        let forced = run.forced()
        #expect(forced.skipReason == nil)
        let plan = try reviewed(forced, fixture)

        // Only the forced run runs it: the skipped one removes nothing and records nothing.
        let skipped = run.complete(plan)
        #expect(!skipped.report.removedAnything)
        #expect(FileManager.default.fileExists(atPath: fixture.tree.path("home/build/a")))
        #expect(lastRun(fixture) == nil)

        let outcome = forced.complete(plan)
        #expect(outcome.report.removedAnything)
        #expect(lastRun(fixture) != nil)
    }

    @Test("A job with nothing to clean can't be forced")
    func nothingToForce() throws {
        let fixture = try buildFixture([])
        try fixture.tree.directory("home/build")
        let run = try ManualJobRun.prepare(buildJob(), runner: fixture.runner)
        #expect(run.skipReason == "Nothing matches the job's conditions")
        #expect(!run.canForce)
        #expect(run.forced().plan == nil)
    }

    @Test("Approving a suggestion that removes everything dismisses it and records the job's run")
    func approvalDismisses() throws {
        var fixture = try buildFixture(["a", "b"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)

        let date = Date(timeIntervalSince1970: 9_000)
        let outcome = run.complete(try reviewed(run, fixture), now: date)

        #expect(outcome.suggestion == .dismissed)
        #expect(fixture.context.suggestions.all().isEmpty)
        #expect(lastRun(fixture) == date)
    }

    @Test("A partly successful approval keeps the suggestion, narrowed to what's left, with the problems attached")
    func approvalKeepsRemainder() throws {
        var fixture = try buildFixture(["a", "b", "c"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        // `b` can't lose its contents, so removing it fails; `c` is unticked.
        #expect(chmod(fixture.tree.path("home/build/b"), 0o555) == 0)
        defer { chmod(fixture.tree.path("home/build/b"), 0o755) }

        let outcome = run.complete(try reviewed(run, fixture, untick: ["c"]))

        guard case .kept(let kept) = outcome.suggestion else {
            Issue.record("expected the suggestion to be kept")
            return
        }
        #expect(kept.id == suggestion.id)
        #expect(kept.plan.items.map { PathUtil.lastComponent($0.path) }.sorted() == ["b", "c"])
        #expect(kept.problems.count == 1)
        #expect(kept.problems.first?.contains("build/b") == true)
        let stored = try #require(fixture.context.suggestions.get(suggestion.id))
        #expect(stored.plan.items.count == 2)
        #expect(stored.problems == kept.problems)
        #expect(lastRun(fixture) != nil)
    }

    @Test("An approval that removed nothing because nothing eligible is left dismisses the suggestion")
    func nothingLeft() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let plan = try reviewed(run, fixture)
        try FileManager.default.removeItem(atPath: fixture.tree.path("home/build/a"))

        let outcome = run.complete(plan)

        #expect(!outcome.report.removedAnything)
        #expect(outcome.suggestion == .dismissed)
        #expect(fixture.context.suggestions.all().isEmpty)
    }

    @Test("Approving drops items that no longer meet the job's conditions, and isn't held back by its threshold")
    func approvalNarrows() throws {
        var fixture = try buildFixture(["a", "b"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        try FileManager.default.removeItem(atPath: fixture.tree.path("home/build/b"))
        fixture.config.jobs = [buildJob(sizeAbove: .gb(1))]

        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)

        #expect(!run.evaluation.isTriggered)
        #expect(run.skipReason == nil)
        #expect(run.plan?.items.map { PathUtil.lastComponent($0.path) } == ["a"])
        #expect(run.dropped.map { PathUtil.lastComponent($0.path) } == ["b"])
    }

    @Test("Approving takes each item's facts from the fresh evaluation, never more than the saved suggestion offered")
    func approvalTrustsFreshFacts() throws {
        var fixture = try buildFixture(["a"])
        try fixture.tree.file("home/build/stray.log", bytes: 4096)
        let job = buildJob()
        fixture.config.jobs = [job]
        var suggestion = try suggest(fixture, job: job)
        let loose = try #require(suggestion.plan.items.firstIndex { $0.kind == .looseFiles })
        let folder = try #require(suggestion.plan.items.firstIndex { $0.kind == .directory })
        // A suggestions file edited after it was saved: facts that would widen what the run may remove.
        suggestion.plan.items[loose].looseFileNames = ["stray.log", "elsewhere.log"]
        suggestion.plan.items[loose].scanStarted = Date.distantFuture
        suggestion.plan.items[folder].ruleID = "other"
        suggestion.plan.items[folder].size = 1
        let saved = Date(timeIntervalSince1970: 500)
        suggestion.plan.items[folder].scanStarted = saved

        let run = try ManualJobRun.prepare(suggestion, runner: fixture.runner)
        let items = try #require(run.plan?.items)
        let fresh = fixture.runner.plan(for: run.evaluation)
        let looseItem = try #require(items.first { $0.kind == .looseFiles })
        #expect(looseItem.looseFileNames == ["stray.log"])
        #expect(looseItem.scanStarted == run.evaluation.scanStarted, "never later than the scan that saw the files")
        let folderItem = try #require(items.first { $0.kind == .directory })
        #expect(folderItem.ruleID == "build")
        #expect(folderItem.size == fresh.items.first { $0.id == folderItem.id }?.size)
        #expect(folderItem.scanStarted == saved, "an earlier saved scan start is the stricter one")
    }

    @Test("A suggestion whose job is gone can't be approved")
    func missingJob() throws {
        var fixture = try buildFixture(["a"])
        let job = buildJob()
        fixture.config.jobs = [job]
        let suggestion = try suggest(fixture, job: job)
        fixture.config.jobs = []
        #expect(throws: ManualJobRun.JobMissing.self) { try ManualJobRun.prepare(suggestion, runner: fixture.runner) }
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
