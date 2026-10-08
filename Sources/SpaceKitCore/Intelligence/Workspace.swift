import Foundation
import Synchronization

/// The Explore scan a person is looking at in the app or the TUI, with its analysis, kept current while they clean up.
///
/// A `DirNode` can't be read while it changes, and background work reads the tree for seconds at a time: an analysis
/// that reuses it, the app's map layout. The workspace is the one place that decides when the tree changes:
/// - Background work reads the tree only inside `read`, which counts it as a reader.
/// - Changes (a cleanup's removals, a re-synced folder) wait until no reader is left, then run in a step the front end
///   runs on its own thread (`Deliver`: the app's main actor, the TUI's loop), holding the gate so no reader starts
///   meanwhile. That thread may therefore read the tree directly, without `read`.
/// - An analysis's result is put in place at the moment it stops reading, so a cleanup that finished while it ran is
///   applied to the new findings, never lost under them.
///
/// Every step returns events (`Event`) that tell the front end what changed, so it can fix its own selection.
/// One-shot CLI commands don't need any of this and call `Scanner` and `StorageAnalyzer` directly.
public final class Workspace: Sendable {
    /// A piece of the workspace's work that may change the tree; it returns what it did.
    public typealias Step = @Sendable () -> [Event]
    /// Runs `step` on the thread that owns the front end's view of the tree, then handles the events it returns.
    /// Steps must run one at a time, in the order they are handed over.
    public typealias Deliver = @Sendable (_ step: @escaping Step) -> Void
    /// Evaluates every rule, reusing the tree when it covers what they need (a seam for tests).
    typealias Analyze = @Sendable (SpaceKitContext, ScanTree?, ScanProgress) throws -> Analysis

    private let state = Mutex(State())
    private let deliver: Deliver
    private let analyzeTree: Analyze

    public convenience init(deliver: @escaping Deliver) {
        self.init(deliver: deliver) { context, tree, progress in
            try context.analyzer.analyzeSync(reusing: tree, progress: progress)
        }
    }

    init(deliver: @escaping Deliver, analyze: @escaping Analyze) {
        self.deliver = deliver
        self.analyzeTree = analyze
    }

    /// The tree and the analysis as they are now.
    public var snapshot: Snapshot { state.withLock { $0.snapshot } }

    // MARK: Reading

    /// Runs `body` with the tree, which doesn't change until `body` returns; changes that arrive meanwhile wait for
    /// every reader to finish. Callable from any thread. Waits only while a change is being applied.
    public func read<T>(_ body: (ScanTree?) throws -> T) rethrows -> T {
        let lease = beginRead()
        defer { lease.end() }
        return try body(lease.tree)
    }

    /// Starts a read now that other work ends later (`ReadLease.end`). The front end's thread begins one before it
    /// hands nodes it holds to background work: a change could otherwise land on that thread before the work starts
    /// reading, and free the removed nodes (and the parents of the ones it holds) under it.
    public func beginRead() -> ReadLease {
        let tree = state.withLock { state in
            state.readers += 1
            return state.tree
        }
        return ReadLease(tree: tree) { [self] in endRead() }
    }

    private func endRead() {
        let drainNow = state.withLock { state in
            state.readers -= 1
            return state.readers == 0 && !state.pending.isEmpty
        }
        if drainNow { deliver { [self] in drain() } }
    }

    // MARK: Scans and analyses

    /// Shows a finished scan (or none, while a new one runs): the previous tree's analysis is dropped and one still
    /// running is stopped, so its result never lands on this tree. Changes still waiting for the previous tree are
    /// dropped too: they were worked out on it, and the new scan already shows the disk as it is (a removal of a folder
    /// it doesn't have would take bytes from the folder around it). Call it on the front end's own thread.
    @discardableResult
    public func show(_ tree: ScanTree?) -> Snapshot {
        state.withLock { state in
            state.analysisProgress?.cancel()
            state.analysisProgress = nil
            state.analysisRun += 1
            state.generation += 1
            state.tree = tree
            state.result = nil
            state.refreshing = []
            state.pending = []
            return state.snapshot
        }
    }

    /// Evaluates every rule of `context`, reusing the tree when it covers the locations they need, and records a
    /// History snapshot. Starting again stops the analysis in progress. Delivers `.analysed` or `.analysisFailed`.
    @discardableResult
    public func analyze(_ context: SpaceKitContext) -> ScanProgress {
        let progress = ScanProgress()
        let (tree, run) = state.withLock { state in
            state.analysisProgress?.cancel()
            state.analysisProgress = progress
            state.analysisRun += 1
            state.readers += 1
            return (state.tree, state.analysisRun)
        }
        let analyze = analyzeTree
        Thread.detachNewThread { [self] in
            let outcome = Result { () throws -> AnalysisResult? in
                let analysis = try analyze(context, tree, progress)
                // A newer scan or analysis replaced this one, so its findings are never shown nor recorded.
                guard state.withLock({ $0.analysisRun == run }) else { return nil }
                // History reads the tree too, so it's recorded while this analysis still counts as a reader.
                try? context.history.recordSnapshot(analysis: analysis)
                return context.result(of: analysis)
            }
            finishAnalysis(run, outcome)
        }
        return progress
    }

    /// `outcome` is nil for an analysis that was replaced before it finished.
    private func finishAnalysis(_ run: Int, _ outcome: Result<AnalysisResult?, any Error>) {
        state.withLock { state in
            state.readers -= 1
            guard state.analysisRun == run else { return }
            state.analysisProgress = nil
            if case .success(let result?) = outcome { state.result = result }
        }
        deliver { [self] in
            // Removals that waited for this analysis are applied to its result first.
            var events = drain()
            guard state.withLock({ $0.analysisRun == run }) else { return events }
            switch outcome {
            case .success: events.append(.analysed(snapshot))
            case .failure(let error): events.append(.analysisFailed(error))
            }
            return events
        }
    }

    /// Labels folders with a reloaded rule library.
    @discardableResult
    public func reindex(rules: [Rule]) -> Snapshot {
        state.withLock { state in
            state.result?.reindex(rules: rules)
            return state.snapshot
        }
    }

    // MARK: Changes

    /// Brings the tree and the findings up to date after a cleanup, without scanning or analysing everything again:
    /// removed items leave the tree (moved ones reappear in the Trash), partly removed ones are rescanned, findings
    /// lose what went, and rules whose tool command ran are re-evaluated alone. Delivers `.changed` once applied.
    public func apply(_ report: CleanupReport, context: SpaceKitContext) {
        enqueue(.removals(Removal.from(report), reevaluate: report.rulesToReevaluate, context: context))
    }

    /// Replaces the folder at `path` in the trees that hold it with `fresh`, a scan of it taken now (the Trash, emptied
    /// in Finder), then re-evaluates `ruleIDs`, whose findings live there. Delivers `.changed` if a tree changed.
    public func resync(_ fresh: ScanTree, at path: String, context: SpaceKitContext, reevaluating ruleIDs: Set<String> = []) {
        let (explore, analysed) = state.withLock { ($0.tree, $0.result?.analysis.tree) }
        let separate = analysed.flatMap { $0 !== explore && $0.covers(path) ? $0 : nil }
        guard let separate else {
            enqueue(.resync(Resync(path: path, fresh: fresh, explore: explore, reevaluate: ruleIDs, context: context)))
            return
        }
        // Splicing hands the scanned nodes over to the tree, so the analysis tree needs a scan of its own.
        Thread.detachNewThread { [self] in
            let second = try? Scanner(options: fresh.options).scan(path)
            let resync = Resync(
                path: path, fresh: fresh, explore: explore, forAnalysis: second.map { ($0, separate) }, reevaluate: ruleIDs,
                context: context)
            enqueue(.resync(resync))
        }
    }

    private func enqueue(_ write: Write) {
        let drainNow = state.withLock { state in
            state.pending.append(write)
            return state.readers == 0
        }
        if drainNow { deliver { [self] in drain() } }
    }

    /// Applies every waiting change, unless something reads the tree (the last reader drains again when it ends).
    private func drain() -> [Event] {
        let (changes, refreshes) = state.withLock { state -> ([Change], [Refresh]) in
            guard state.readers == 0, !state.pending.isEmpty else { return ([], []) }
            let writes = state.pending
            state.pending = []
            var changes: [Change] = []
            var refreshes: [Refresh] = []
            for write in writes {
                let (change, refresh) = Workspace.perform(write, on: &state)
                if let change { changes.append(change) }
                if let refresh { refreshes.append(refresh) }
            }
            return (changes, refreshes)
        }
        for refresh in refreshes { start(refresh) }
        return changes.map(Event.changed)
    }

    /// One change, made while the gate is held and no reader is left.
    private static func perform(_ write: Write, on state: inout State) -> (Change?, Refresh?) {
        switch write {
        case .removals(let removals, let reevaluate, let context):
            let tree = state.tree
            let retired = tree.map { tree in removals.filter { $0.kind != .looseFiles }.flatMap { retiring($0.path, in: tree) } } ?? []
            let treeChanged = tree.map { Removal.apply(removals, to: $0) } ?? false
            state.result?.apply(removals, exploreTree: tree)
            let refresh = state.markRefreshing(reevaluate, context: context)
            let change = Change(
                snapshot: state.snapshot, removals: removals, rescanned: removals.filter(\.partial).map(\.path), treeChanged: treeChanged,
                retired: retired)
            return (change, refresh)
        case .resync(let resync):
            var retired: [DirNode] = []
            var treeChanged = false
            if let tree = state.tree, tree === resync.explore, tree.covers(resync.path),
                tree.node(at: resync.path)?.size != resync.fresh.root.size
            {
                retired = retiring(resync.path, in: tree)
                tree.splice(resync.fresh, at: resync.path)
                treeChanged = true
            }
            var analysisChanged = false
            if let (fresh, analysed) = resync.forAnalysis, state.result?.analysis.tree === analysed {
                analysed.splice(fresh, at: resync.path)
                analysisChanged = true
            }
            guard treeChanged || analysisChanged else { return (nil, nil) }
            let refresh = state.markRefreshing(resync.reevaluate, context: resync.context)
            let change = Change(
                snapshot: state.snapshot, removals: [], rescanned: [resync.path], treeChanged: treeChanged, retired: retired)
            return (change, refresh)
        }
    }

    /// The nodes a change at `path` takes out of the tree: the folder and its contents (a rescan replaces those).
    private static func retiring(_ path: String, in tree: ScanTree) -> [DirNode] {
        guard let node = tree.node(at: path) else { return [] }
        return [node] + node.children
    }

    // MARK: Targeted refreshes

    /// Re-evaluates a few rules with a scan of only their locations (it never reads the tree), then merges the result.
    private func start(_ refresh: Refresh) {
        Thread.detachNewThread { [self] in
            let fresh = try? refresh.context.analyzer.analyzeSync(rules: refresh.rules)
            state.withLock { state in
                state.refreshing.subtract(refresh.ruleIDs)
                guard state.generation == refresh.generation, let fresh else { return }
                state.result?.merge(refresh.context.result(of: fresh), for: refresh.ruleIDs)
            }
            deliver { [self] in [.refreshed(snapshot)] }
        }
    }

    // MARK: State

    private struct State {
        var tree: ScanTree?
        var result: AnalysisResult?
        /// Bumped by `show`: refreshes started for an older tree are dropped.
        var generation = 0
        /// Bumped by every analysis (and `show`): only the latest one's result is used.
        var analysisRun = 0
        var analysisProgress: ScanProgress?
        var readers = 0
        var pending: [Write] = []
        var refreshing: Set<String> = []

        var snapshot: Snapshot { Snapshot(tree: tree, result: result, refreshingRules: refreshing) }

        /// Marks the rules of `ruleIDs` that exist as being re-evaluated, if there are findings to merge them into.
        mutating func markRefreshing(_ ruleIDs: Set<String>, context: SpaceKitContext) -> Refresh? {
            let rules = ruleIDs.compactMap { context.library.rule(id: $0) }
            guard !rules.isEmpty, result != nil else { return nil }
            let ids = Set(rules.map(\.id))
            refreshing.formUnion(ids)
            return Refresh(rules: rules, ruleIDs: ids, generation: generation, context: context)
        }
    }

    /// A change waiting for the readers to finish.
    private enum Write: Sendable {
        case removals([Removal], reevaluate: Set<String>, context: SpaceKitContext)
        case resync(Resync)
    }

    private struct Resync: Sendable {
        var path: String
        var fresh: ScanTree
        /// The Explore tree `fresh` was taken for; a newer scan already shows the folder as it is.
        var explore: ScanTree?
        /// A second scan of the folder for a separate analysis tree, and that tree.
        var forAnalysis: (ScanTree, ScanTree)?
        var reevaluate: Set<String>
        var context: SpaceKitContext
    }

    private struct Refresh: Sendable {
        var rules: [Rule]
        var ruleIDs: Set<String>
        var generation: Int
        var context: SpaceKitContext
    }
}
