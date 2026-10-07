import Foundation

/// What a job would do right now.
public struct JobEvaluation: Sendable {
    public var job: Job
    /// Everything the job's rules and folders matched.
    public var findings: [Finding]
    /// Findings narrowed to items that pass the job's age conditions.
    public var eligible: [Finding]
    public var tree: ScanTree?

    public var matchedBytes: UInt64 { findings.reduce(0) { $0 &+ $1.size } }
    public var eligibleBytes: UInt64 { eligible.reduce(0) { $0 &+ $1.size } }

    /// True when the job's size threshold (if any) is exceeded and there's something to clean.
    public var isTriggered: Bool {
        if let threshold = job.when.sizeAbove, matchedBytes < threshold.bytes { return false }
        return eligibleBytes > 0
    }

    public var triggerSummary: String {
        if let threshold = job.when.sizeAbove, matchedBytes < threshold.bytes {
            return "\(ByteCount.format(matchedBytes)) is below the \(threshold) threshold"
        }
        if eligibleBytes == 0 { return "Nothing matches the job's conditions" }
        return "\(ByteCount.format(eligibleBytes)) ready to clean"
    }
}

public struct JobRunResult: Sendable {
    public enum Action: Sendable {
        case notTriggered(String)
        case observed
        case suggested(Suggestion)
        case cleaned(CleanupReport)
        case failed(String)
    }

    public var job: Job
    public var date: Date
    public var evaluation: JobEvaluation?
    public var action: Action

    public var summary: String {
        switch action {
        case .notTriggered(let reason): return "Skipped — \(reason)"
        case .observed: return "Observed \(ByteCount.format(evaluation?.matchedBytes ?? 0))"
        case .suggested(let suggestion): return "Suggested cleanup of \(ByteCount.format(suggestion.plan.totalBytes)) (id \(suggestion.id))"
        case .cleaned(let report):
            let skipped = report.skipped.count
            return report.summary
                + (skipped > 0 ? ", \(skipped) item\(skipped == 1 ? "" : "s") skipped" : "")
        case .failed(let message): return "Failed — \(message)"
        }
    }
}

/// Evaluates and runs jobs. Used by the background agent (`spacekit agent run`), the CLI and the app.
public struct JobRunner: Sendable {
    public var context: SpaceKitContext

    public init(context: SpaceKitContext) { self.context = context }

    /// Rules a job refers to that exist, plus a synthetic rule for its own folders.
    public func rules(for job: Job) -> (rules: [Rule], missing: [String]) {
        var rules: [Rule] = []
        var missing: [String] = []
        for id in job.rules {
            if let rule = context.library.rule(id: id) { rules.append(rule) } else { missing.append(id) }
        }
        return (rules, missing)
    }

    /// The synthetic rule for a job's own folders. Its items carry no rule id, so the safety guard treats
    /// them as user-chosen folders with the stricter checks that implies.
    static func customRuleID(_ job: Job) -> String { "job:\(job.id)" }

    public func evaluate(_ job: Job, progress: ScanProgress = ScanProgress(), now: Date = Date()) throws -> JobEvaluation {
        var (rules, _) = rules(for: job)
        if !job.paths.isEmpty {
            rules.append(
                Rule(
                    id: JobRunner.customRuleID(job), name: job.name, group: "Custom", category: "custom",
                    paths: job.paths, granularity: job.granularity, safety: SafetySpec(level: .review),
                    action: ActionSpec(remove: true)))
        }
        guard !rules.isEmpty else { return JobEvaluation(job: job, findings: [], eligible: [], tree: nil) }
        let analysis = try context.analyzer.analyzeSync(rules: rules, progress: progress)
        let eligible = analysis.findings.compactMap { finding -> Finding? in
            let items = finding.eligibleItems(olderThan: job.when.olderThan, keepRecent: job.when.keepRecent, now: now)
            return items.isEmpty ? nil : Finding(rule: finding.rule, items: items)
        }
        return JobEvaluation(job: job, findings: analysis.findings, eligible: eligible, tree: analysis.tree)
    }

    public func plan(for evaluation: JobEvaluation) -> CleanupPlan {
        var plan = CleanupPlan.make(findings: evaluation.eligible, trashPreference: context.trashPreference(for: evaluation.job.action))
        let customID = JobRunner.customRuleID(evaluation.job)
        for index in plan.items.indices where plan.items[index].ruleID == customID {
            plan.items[index].ruleID = nil
        }
        return plan
    }

    public func automationContext(for job: Job) -> AutomationContext {
        AutomationContext(
            jobID: job.id, allowReview: job.includeReview, customPaths: job.paths,
            olderThan: job.when.olderThan, usesTrash: context.trashPreference(for: job.action) ?? false)
    }

    /// Runs one job according to its mode. `manual` runs (from the app or `spacekit jobs run --yes`) clean
    /// immediately regardless of mode, because a person asked for it.
    public func run(_ job: Job, manual: Bool = false, dryRun: Bool = false, now: Date = Date()) -> JobRunResult {
        let evaluation: JobEvaluation
        do {
            evaluation = try evaluate(job, now: now)
        } catch {
            let result = JobRunResult(job: job, date: now, evaluation: nil, action: .failed(error.localizedDescription))
            record(result)
            return result
        }

        let result: JobRunResult
        if !evaluation.isTriggered {
            result = JobRunResult(job: job, date: now, evaluation: evaluation, action: .notTriggered(evaluation.triggerSummary))
        } else if manual {
            let report = context.executor.execute(plan(for: evaluation), context: .manual(confirmed: true), dryRun: dryRun)
            result = JobRunResult(job: job, date: now, evaluation: evaluation, action: .cleaned(report))
        } else {
            switch job.mode {
            case .observe:
                context.notifier?.notify(
                    title: "\(job.name) is \(ByteCount.format(evaluation.matchedBytes))",
                    body: job.when.sizeAbove.map { "Above your \($0) threshold. Open SpaceKit to review." } ?? "Open SpaceKit to review.")
                result = JobRunResult(job: job, date: now, evaluation: evaluation, action: .observed)
            case .suggest:
                let suggestion = Suggestion(jobID: job.id, jobName: job.name, plan: plan(for: evaluation), created: now)
                if !dryRun { try? context.suggestions.add(suggestion) }
                context.notifier?.notify(
                    title: "Cleanup ready: \(ByteCount.format(suggestion.plan.totalBytes))",
                    body: "\(job.name) — review in SpaceKit, or run: spacekit suggestions approve \(suggestion.id)")
                result = JobRunResult(job: job, date: now, evaluation: evaluation, action: .suggested(suggestion))
            case .automatic:
                let report = context.executor.execute(
                    plan(for: evaluation), context: .automatic(automationContext(for: job)), dryRun: dryRun)
                if report.freedBytes > 0 || !report.skipped.isEmpty {
                    let skipped = report.skipped.count
                    context.notifier?.notify(
                        title: "SpaceKit: \(report.summary)",
                        body: "\(job.name)" + (skipped > 0 ? " · \(skipped) item\(skipped == 1 ? "" : "s") left for review" : ""))
                }
                result = JobRunResult(job: job, date: now, evaluation: evaluation, action: .cleaned(report))
            }
        }
        if !dryRun { record(result) }
        return result
    }

    private func record(_ result: JobRunResult) {
        try? context.jobStates.update(result.job.id) { state in
            state.lastRun = result.date
            state.lastOutcome = result.summary
            state.lastMatchedBytes = result.evaluation?.matchedBytes
            state.lastEligibleBytes = result.evaluation?.eligibleBytes
            if case .cleaned(let report) = result.action { state.lastFreedBytes = report.freedBytes }
        }
    }

    // MARK: Scheduling

    /// When each enabled job runs next.
    public func nextRuns(now: Date = Date()) -> [(job: Job, date: Date)] {
        let states = context.jobStates.load()
        return context.config.jobs.filter(\.enabled).map { job in
            let state = states[job.id]
            let anchor = state?.lastRun ?? state?.firstSeen ?? now
            return (job, job.schedule.nextRun(after: anchor))
        }
        .sorted { $0.date < $1.date }
    }

    /// Jobs whose next run time has passed (catching up after sleep).
    public func dueJobs(now: Date = Date()) -> [Job] {
        var states = context.jobStates.load()
        var changed = false
        var due: [Job] = []
        for job in context.config.jobs where job.enabled {
            if states[job.id] == nil {
                states[job.id] = JobState(firstSeen: now)
                changed = true
                continue
            }
            let state = states[job.id]!
            if job.schedule.nextRun(after: state.lastRun ?? state.firstSeen) <= now { due.append(job) }
        }
        if changed { try? context.jobStates.save(states) }
        return due
    }

    /// The agent's entry point: run due jobs, record a usage sample, and take a snapshot if one is due.
    public func runDue(now: Date = Date(), log: (String) -> Void = { _ in }) -> [JobRunResult] {
        if let capacity = VolumeCapacity.of(path: "/") {
            try? context.history.recordVolumeSample(capacity, now: now)
        }
        var results: [JobRunResult] = []
        for job in dueJobs(now: now) {
            log("Running \(job.id) (\(job.mode.rawValue))")
            let result = run(job, now: now)
            log("  \(result.summary)")
            results.append(result)
        }
        if let schedule = context.config.automation.snapshot {
            let last = context.history.lastSnapshotDate()
            if last == nil || schedule.nextRun(after: last!) <= now {
                log("Taking storage snapshot")
                if let analysis = try? context.analyzer.analyzeSync() {
                    try? context.history.recordSnapshot(analysis: analysis, now: now)
                }
            }
        }
        return results
    }

    /// Range of space the next scheduled automatic runs are expected to free, from the last evaluation of each job.
    public func estimatedRecovery(states: [String: JobState]? = nil) -> (low: UInt64, high: UInt64) {
        let states = states ?? context.jobStates.load()
        var low: UInt64 = 0
        var high: UInt64 = 0
        for job in context.config.jobs where job.enabled && job.mode != .observe {
            guard let state = states[job.id] else { continue }
            let eligible = state.lastEligibleBytes ?? 0
            let matched = state.lastMatchedBytes ?? 0
            let triggered = job.when.sizeAbove.map { matched >= $0.bytes } ?? true
            if triggered { low &+= eligible }
            high &+= max(eligible, matched)
        }
        return (low, high)
    }
}
