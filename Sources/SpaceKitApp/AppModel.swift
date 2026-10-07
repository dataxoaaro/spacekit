import AppKit
import Foundation
import Observation
import SpaceKitCore

/// Sidebar destinations.
enum AppSection: String, CaseIterable, Identifiable, Hashable {
    case explore, dev, ai, automation, history, rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .explore: return "Explore"
        case .dev: return "Dev Intelligence"
        case .ai: return "AI Development"
        case .automation: return "Automation"
        case .history: return "History"
        case .rules: return "Rules Library"
        }
    }

    var subtitle: String {
        switch self {
        case .explore: return "Where is my disk going?"
        case .dev: return "What is actually safe to remove?"
        case .ai: return "Local models and caches"
        case .automation: return "Automate the cleanup"
        case .history: return "What grew?"
        case .rules: return "What SpaceKit knows"
        }
    }

    var symbol: String {
        switch self {
        case .explore: return "circle.circle"
        case .dev: return "hammer"
        case .ai: return "cpu"
        case .automation: return "clock.arrow.2.circlepath"
        case .history: return "chart.xyaxis.line"
        case .rules: return "books.vertical"
        }
    }
}

/// App-wide state. Everything heavy (scans, analysis, cleanup) runs off the main actor;
/// results are published back here.
@Observable
@MainActor
final class AppModel {
    // MARK: Context
    private(set) var context: SpaceKitContext
    var section: AppSection = .explore
    var showOnboarding = false
    var showSafety = false
    var errorMessage: String?

    // MARK: Explore
    private(set) var tree: ScanTree?
    private(set) var scanProgress: ScanProgress?
    private(set) var progressSnapshot: ScanProgress.Snapshot?
    private(set) var scanPath: String
    /// The directory at the center of the map.
    var focus: DirNode?
    var selection: MapItem?
    var hovered: MapItem?
    private var backStack: [DirNode] = []
    private(set) var categories: [CategorySlice] = []
    private(set) var ruleIndex: RuleIndex {
        didSet { ruleCache.removeAll() }
    }
    var visualization: UISettings.Visualization
    var colorMode: UISettings.ColorMode
    var mapDepth: Int
    private var scanTask: Task<Void, Never>?
    @ObservationIgnored private var scanRequests = RequestGeneration()
    /// The folder the current `tree` is a scan of (`scanPath` moves on as soon as another scan starts).
    @ObservationIgnored private var treeScanPath: String?
    /// Off-main work reading the trees, and tree changes waiting for it to finish (see `readingTrees`).
    @ObservationIgnored private var treeReaders = 0
    @ObservationIgnored private var treeWriters: [CheckedContinuation<Void, Never>] = []

    // MARK: Intelligence
    private(set) var analysis: Analysis?
    private(set) var analysisProgress: ScanProgress?
    private(set) var aiReport: AIReport?
    @ObservationIgnored private var analysisRequests = RequestGeneration()

    // MARK: Cleanup
    /// Items collected from Explore and Dev Intelligence for one combined review.
    var cleanupList: [CleanupItem] = []
    /// The plan currently shown in the cleanup sheet.
    var pendingCleanup: PendingCleanup?
    /// The job currently open in the job editor.
    var jobDraft: JobDraft?
    /// Bumped whenever the tree changes in place, so cached map layouts are rebuilt.
    private(set) var treeRevision = 0 {
        didSet { itemsCache.removeAll() }
    }
    /// Rules currently being re-evaluated after a tool command ran (cards show a spinner).
    private(set) var refreshingRules: Set<String> = []
    /// Cleanups removing things right now. Quitting waits for them (see `AppDelegate`).
    private(set) var runningCleanups = 0
    /// Set when the person chose to quit while a cleanup ran; the app quits once the last one finishes.
    @ObservationIgnored var quitWhenCleanupsFinish = false

    // Render-time caches. Not observed, so filling them during a view update doesn't trigger another one.
    @ObservationIgnored private var itemsCache: [UInt: [DiskItem]] = [:]
    @ObservationIgnored private var ruleCache: [String: Rule?] = [:]
    @ObservationIgnored private var rulesIncludingDisabledCache: [Rule]?

    // MARK: Automation & history
    private(set) var jobStates: [String: JobState] = [:]
    private(set) var suggestions: [Suggestion] = []
    private(set) var agentStatus: LaunchAgent.Status?
    private(set) var recovered90Days: UInt64 = 0
    private(set) var journal: [JournalEntry] = []
    private(set) var history: [HistoryRecord] = []
    private(set) var volumes: [VolumeCapacity] = []
    /// Live capacity of the volume being explored, refreshed every few seconds while the app is active.
    private(set) var scanCapacity: VolumeCapacity?
    /// Size of the Trash, once measured (nil if it can't be read without Full Disk Access).
    private(set) var trashBytes: UInt64?
    /// Local Time Machine snapshots on the startup disk; they hold deleted files' space as "purgeable".
    private(set) var localSnapshotCount = 0
    @ObservationIgnored private var capacityMonitor: Task<Void, Never>?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    var runningJobID: String?

    struct PendingCleanup: Identifiable {
        let id = UUID()
        var title: String
        var plan: CleanupPlan
        /// Called with the report after a successful run.
        var completion: (@MainActor (CleanupReport) -> Void)?
    }

    init() {
        let context = SpaceKitContext.load()
        self.context = context
        scanPath = PathUtil.expand(context.config.scan.defaultPath)
        ruleIndex = RuleIndex(rules: context.library.rules)
        visualization = context.config.ui.visualization
        colorMode = context.config.ui.colorBy
        mapDepth = context.config.ui.mapDepth
        showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingComplete")
        refreshVolumes()
        refreshAutomation()
        startMonitoring()
        AppDelegate.model = self
    }

    var config: SpaceKitConfig { context.config }
    var library: RuleLibrary { context.library }

    // MARK: Config

    /// Applies one change to the config file as it is on disk now, so changes made elsewhere (jobs added with the CLI,
    /// hand edits) are kept, and saves it. A config file that doesn't parse is left untouched and the problem shown.
    /// Only what changed is reloaded: the rule library only when rule settings differ.
    func updateConfig(_ change: (inout SpaceKitConfig) -> Void) {
        let before = context.config
        let saved: SpaceKitConfig
        do {
            saved = try context.configStore.update(change)
        } catch let error as ConfigError {
            errorMessage =
                "SpaceKit didn't save this change because the config file has a problem: \(error.localizedDescription). "
                + "Fix it (spacekit config validate), then Reload."
            return
        } catch {
            errorMessage = "Couldn't save the config: \(error.localizedDescription)"
            return
        }
        if saved.rules != before.rules || context.configError != nil {
            reloadContext()
        } else if saved != before {
            context.config = saved
            if saved.jobs != before.jobs { refreshJournal() }
        }
    }

    /// Re-reads config and rules from disk (after edits in the YAML file).
    func reloadContext() {
        rulesIncludingDisabledCache = nil
        context = SpaceKitContext.load(paths: context.paths)
        ruleIndex = RuleIndex(rules: context.library.rules, findings: analysis?.findings ?? [])
        if let error = context.configError { errorMessage = "Config problem: \(error)" }
        refreshAutomation()
    }

    // MARK: Scanning

    var isScanning: Bool { scanProgress != nil }

    func scan(_ path: String? = nil) {
        if let path { scanPath = PathUtil.expand(path) }
        scanTask?.cancel()
        let generation = scanRequests.next()
        let progress = ScanProgress()
        scanProgress = progress
        progressSnapshot = progress.snapshot
        selection = nil
        hovered = nil
        backStack = []
        let options = context.scanOptions
        let root = scanPath
        scanTask = Task {
            // Lives only as long as the scan task (cancelled in the defer below).
            let poller = Task { @MainActor in
                while !Task.isCancelled {
                    self.progressSnapshot = progress.snapshot
                    try? await Task.sleep(for: .milliseconds(120))
                }
            }
            defer { poller.cancel() }
            do {
                let tree = try await Scanner(options: options).scan(root, progress: progress)
                guard self.scanRequests.isCurrent(generation) else { return }
                if tree.stats.cancelled {
                    self.stopScan()
                } else {
                    self.finishScan(tree, path: root)
                }
            } catch {
                guard self.scanRequests.isCurrent(generation) else { return }
                self.errorMessage = error.localizedDescription
                self.stopScan()
            }
        }
    }

    func cancelScan() {
        scanProgress?.cancel()
    }

    /// A stopped scan's tree is missing whatever wasn't reached yet, so it isn't shown, analysed or recorded in
    /// history. The previous scan stays on screen.
    private func stopScan() {
        scanProgress = nil
        progressSnapshot = nil
        if let treeScanPath { scanPath = treeScanPath }
    }

    private func finishScan(_ tree: ScanTree, path: String) {
        self.tree = tree
        treeScanPath = path
        treeRevision += 1
        focus = tree.root
        scanProgress = nil
        progressSnapshot = nil
        analysis = nil
        aiReport = nil
        categories = CategoryBreakdown.compute(tree: tree)
        refreshVolumes()
        refreshTrash(resync: false)
        analyze()
    }

    /// The scan root's subfolders while scanning, for progressive drawing.
    var liveChildren: [DirNode] { scanProgress?.liveChildren ?? [] }

    // MARK: Navigation

    func open(_ node: DirNode) {
        guard node !== focus, !node.children.isEmpty || !node.files.isEmpty else { return }
        if let focus { backStack.append(focus) }
        focus = node
        selection = nil
    }

    func goUp() {
        guard let focus, let parent = focus.parent, !(parent.name.isEmpty && parent.parent == nil && tree?.isMultiRoot == false) else {
            return
        }
        backStack.append(focus)
        selection = .item(.directory(focus))
        self.focus = parent
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        focus = previous
        selection = nil
    }

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoUp: Bool { focus?.parent != nil }

    /// Folders from the scan root to the focus, for the breadcrumb.
    var breadcrumb: [DirNode] {
        guard let focus else { return [] }
        return focus.ancestors.filter { !$0.name.isEmpty } + [focus]
    }

    // MARK: Intelligence

    var isAnalysing: Bool { analysisProgress != nil }

    /// Evaluates all rules, reusing the Explore scan when it covers the locations rules need. Starting again (after a
    /// rescan, or Refresh) stops the analysis in progress and drops its result, so the current tree is always the one
    /// analysed.
    func analyze() {
        analysisProgress?.cancel()
        let generation = analysisRequests.next()
        let progress = ScanProgress()
        analysisProgress = progress
        let analyzer = context.analyzer
        let tree = self.tree
        let window = context.config.automation.activeModelWindow
        let history = context.history
        Task {
            let analysis: Analysis
            do {
                analysis = try await self.readingTrees { try await analyzer.analyze(reusing: tree, progress: progress) }
            } catch {
                guard self.analysisRequests.isCurrent(generation) else { return }
                self.analysisProgress = nil
                self.errorMessage = error.localizedDescription
                return
            }
            guard self.analysisRequests.isCurrent(generation) else { return }
            self.analysisProgress = nil
            self.analysis = analysis
            self.aiReport = AIInspector.report(findings: analysis.findings, tree: analysis.tree, activeWindow: window)
            self.ruleIndex = RuleIndex(rules: self.context.library.rules, findings: analysis.findings)
            if let tree = self.tree, tree.covers(PathUtil.home) {
                self.categories = CategoryBreakdown.compute(tree: tree, findings: analysis.findings)
            }
            if !analysis.tree.stats.cancelled {
                try? history.recordSnapshot(analysis: analysis)
                self.refreshHistory()
            }
        }
    }

    // MARK: Tree access

    /// Runs `work` off the main actor while it reads the scan trees (rule evaluation, map layout). Trees change only
    /// on the main actor and only while no such work runs (see `untilTreesAreFree`), because a `DirNode` can't be
    /// read while it changes.
    func readingTrees<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        treeReaders += 1
        defer { endTreeRead() }
        return try await Task.detached(priority: .userInitiated, operation: work).value
    }

    private func endTreeRead() {
        treeReaders -= 1
        guard treeReaders == 0 else { return }
        let waiting = treeWriters
        treeWriters = []
        for writer in waiting { writer.resume() }
    }

    /// Suspends until no off-main work reads the trees. Change them right after, without suspending in between.
    private func untilTreesAreFree() async {
        while treeReaders > 0 {
            await withCheckedContinuation { treeWriters.append($0) }
        }
    }

    /// Every rule that loads, disabled ones included, so Settings can turn them back on. Cached until the next reload.
    func rulesIncludingDisabled() -> [Rule] {
        if let cached = rulesIncludingDisabledCache { return cached }
        let rules = RuleLibrary.load(directories: config.rules.directories).rules
        rulesIncludingDisabledCache = rules
        return rules
    }

    func rule(for path: String?) -> Rule? {
        guard let path else { return nil }
        if let cached = ruleCache[path] { return cached }
        let rule = ruleIndex.rule(for: path)
        ruleCache[path] = rule
        return rule
    }

    /// A directory's items, largest first; cached until the tree changes.
    func items(of node: DirNode) -> [DiskItem] {
        if let cached = itemsCache[node.address] { return cached }
        let items = node.items
        itemsCache[node.address] = items
        return items
    }

    // MARK: Cleanup

    func cleanupItem(for item: DiskItem) -> CleanupItem? {
        guard let path = item.path else { return nil }
        let git = tree?.markers.bit(for: ".git") ?? 0
        return CleanupItem(
            path: path, kind: item.isDirectory ? .directory : .file, name: item.name, size: item.size,
            ruleID: rule(for: path)?.id,
            isRepository: (item.directory?.markers ?? 0) & git != 0,
            containsRepository: (item.directory?.subtreeMarkers ?? 0) & git != 0,
            lastUsed: item.modified)
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
        runningCleanups += 1
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

    private func endCleanup() {
        runningCleanups -= 1
        if runningCleanups == 0 && quitWhenCleanupsFinish {
            quitWhenCleanupsFinish = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Brings every view up to date after a cleanup without re-scanning or re-analysing everything:
    /// the trees shrink in place, findings lose only the cleaned items, the AI report and category
    /// totals update only if they were affected, and rules whose tool command ran are re-evaluated alone.
    private func applyRemovals(_ report: CleanupReport) {
        let removals = Removal.from(report)

        // Explore tree. Trashed items move into the Trash folder: they still use space until it's emptied.
        var exploreChanged = false
        if let tree {
            for removal in removals where removal.apply(to: tree) { exploreChanged = true }
        }

        // Findings (and the analysis tree, if it's a separate scan).
        var touched = Set<String>()
        if var updated = analysis {
            if updated.tree !== tree {
                for removal in removals { removal.apply(to: updated.tree) }
            }
            touched = updated.apply(removals)
            if !touched.isEmpty { analysis = updated }
        }
        if !touched.isEmpty { rebuildAIReportIfNeeded(touchedRules: touched) }

        // Categories: subtract instead of recomputing.
        if exploreChanged {
            categories = CategoryBreakdown.subtracting(removals, from: categories, findings: analysis?.findings ?? [])
            treeRevision += 1
        }

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

    /// Re-evaluates a few rules with a targeted scan of only their locations, then merges the results.
    func refreshFindings(ruleIDs: Set<String>) {
        let rules = ruleIDs.compactMap { library.rule(id: $0) }
        guard !rules.isEmpty, analysis != nil else { return }
        refreshingRules.formUnion(ruleIDs)
        let analyzer = context.analyzer
        Task {
            let fresh = try? await analyzer.analyze(rules: rules)
            refreshingRules.subtract(ruleIDs)
            guard let fresh, var updated = analysis else { return }
            updated.replaceFindings(for: ruleIDs, with: fresh.findings)
            analysis = updated
            // The targeted scan only covers these rules, so merge its AI models into the existing report.
            if ruleIDs.contains(where: { library.rule(id: $0)?.ai != nil }), let current = aiReport {
                let partial = AIInspector.report(findings: fresh.findings, tree: fresh.tree, activeWindow: current.activeWindow)
                aiReport = current.replacingModels(from: ruleIDs, with: partial)
            }
        }
    }

    /// Rebuilds the AI report from the (already updated) analysis tree, if an AI rule was affected.
    private func rebuildAIReportIfNeeded(touchedRules: Set<String>) {
        guard let analysis, touchedRules.contains(where: { library.rule(id: $0)?.ai != nil }) else { return }
        aiReport = AIInspector.report(
            findings: analysis.findings, tree: analysis.tree,
            activeWindow: context.config.automation.activeModelWindow)
    }

    // MARK: Automation

    /// Everything on the Automation screen, including the agent status (which asks launchd).
    func refreshAutomation() {
        refreshJournal()
        refreshHistory()
        refreshAgentStatus()
    }

    /// Cheap file reads only: job state, suggestions and the journal.
    func refreshJournal() {
        let context = self.context
        jobStates = context.jobStates.load()
        suggestions = context.suggestions.all()
        journal = context.journal.entries(since: Date().addingTimeInterval(-90 * 86_400))
        recovered90Days = journal.reduce(0) { $0 + $1.bytes }
    }

    func refreshAgentStatus() {
        let paths = context.paths
        Task.detached {
            let status = LaunchAgent(paths: paths).status()
            await MainActor.run { self.agentStatus = status }
        }
    }

    func refreshHistory() {
        history = context.history.records(since: Date().addingTimeInterval(-365 * 86_400))
    }

    /// Re-reads volume capacities. Values only change (and views only update) when the disk changed.
    func refreshVolumes() {
        let fresh = VolumeTable.current().userVisibleVolumes.compactMap { VolumeCapacity.of(path: $0.mountPoint) }
        if fresh != volumes { volumes = fresh }
        let live = VolumeCapacity.of(path: scanPath)
        if live != scanCapacity {
            scanCapacity = live
            if let live, let tree, tree.roots == ["/"] {
                categories = CategoryBreakdown.updatingHidden(categories, capacity: live, scannedBytes: tree.root.size)
            }
        }
    }

    /// Keeps capacity live: every few seconds (one cheap system call per volume), and immediately when SpaceKit
    /// becomes active, which is also when the Trash is re-measured (you may have emptied it in Finder).
    private func startMonitoring() {
        observers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshVolumes()
                    self.refreshTrash(resync: true)
                    self.refreshSnapshots()
                }
            })
        startCapacityLoop()
        refreshSnapshots()
    }

    private func startCapacityLoop() {
        capacityMonitor?.cancel()
        capacityMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshVolumes()
            }
        }
    }

    var trashPath: String { PathUtil.home + "/.Trash" }

    private var trashScanOptions: ScanOptions {
        var options = context.scanOptions
        options.boundary = .device
        return options
    }

    /// Measures the Trash. With `resync`, the Trash folder in the map is replaced by the fresh scan, so
    /// emptying the Trash anywhere (Finder, Terminal, SpaceKit) shows up without a full rescan.
    func refreshTrash(resync: Bool) {
        let options = trashScanOptions
        let path = trashPath
        let exploreTree = tree
        let analysisTree = analysis?.tree
        let needsSecondScan = resync && analysisTree != nil && analysisTree !== exploreTree && analysisTree!.covers(path)
        Task {
            // Each tree gets its own fresh scan: splicing hands the scanned nodes over to the tree.
            let (fresh, freshForAnalysis) = await Task.detached(priority: .utility) {
                (try? Scanner(options: options).scan(path), needsSecondScan ? try? Scanner(options: options).scan(path) : nil)
            }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                trashBytes = nil
                return
            }
            if trashBytes != fresh.root.size { trashBytes = fresh.root.size }
            guard resync else { return }
            await untilTreesAreFree()
            var changed = false
            // Only touch the trees this measurement was taken for (a new scan may have replaced them).
            if let tree, tree === exploreTree, tree.covers(path), tree.node(at: path)?.size != fresh.root.size {
                tree.splice(fresh, at: path)
                changed = true
            }
            if let freshForAnalysis, let analysis, analysis.tree === analysisTree {
                analysis.tree.splice(freshForAnalysis, at: path)
                changed = true
            }
            guard changed else { return }
            treeRevision += 1
            if let tree, tree.roots == ["/"] || tree.covers(PathUtil.home) {
                categories = CategoryBreakdown.compute(tree: tree, findings: analysis?.findings ?? [], capacity: scanCapacity)
            }
            let trashRules = Set(library.rules.filter { $0.paths.contains { PathUtil.expand($0) == path } }.map(\.id))
            if !trashRules.isEmpty { refreshFindings(ruleIDs: trashRules) }
        }
    }

    func refreshSnapshots() {
        Task {
            let count = await Task.detached(priority: .utility) { LocalSnapshots.list(volume: "/").count }.value
            if count != localSnapshotCount { localSnapshotCount = count }
        }
    }

    /// Opens the review sheet for permanently deleting what's in the Trash.
    func emptyTrash() {
        let options = trashScanOptions
        let path = trashPath
        let rule = library.rules.first { $0.paths.contains { PathUtil.expand($0) == path } }
        Task {
            let fresh = await Task.detached(priority: .userInitiated) { try? Scanner(options: options).scan(path) }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                errorMessage = "SpaceKit can't read the Trash. Grant Full Disk Access, or empty it in Finder."
                return
            }
            var items = fresh.root.children.filter { $0.size > 0 }.map {
                CleanupItem(path: $0.path, kind: .directory, name: $0.name, size: $0.size, ruleID: rule?.id)
            }
            if fresh.root.directFileSize > 0 {
                items.append(
                    CleanupItem(
                        path: path, kind: .looseFiles, name: "Files in the Trash", size: fresh.root.directFileSize, ruleID: rule?.id))
            }
            guard !items.isEmpty else {
                errorMessage = "The Trash is already empty."
                return
            }
            review(CleanupPlan(items: items, useTrash: false), title: "Empty Trash")
        }
    }

    var bootVolume: VolumeCapacity? { volumes.first { $0.mountPoint == "/" } ?? VolumeCapacity.of(path: "/") }

    var jobRunner: JobRunner { JobRunner(context: context) }

    /// Evaluates a job in the background and opens the review sheet with its plan.
    func previewJob(_ job: Job) {
        runningJobID = job.id
        let runner = jobRunner
        Task {
            let result = await Task.detached { Result { try runner.evaluate(job) } }.value
            self.runningJobID = nil
            switch result {
            case .success(let evaluation):
                let plan = runner.plan(for: evaluation)
                if plan.isEmpty {
                    self.errorMessage = "\(job.name): \(evaluation.triggerSummary)."
                } else {
                    self.review(plan, title: "Run “\(job.name)” now") { report in
                        do {
                            try runner.record(.manual(evaluation, report: report))
                        } catch {
                            self.errorMessage = "Couldn't save the job's state: \(error.localizedDescription)"
                        }
                        self.refreshJournal()
                    }
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Re-evaluates the suggestion's job first, so only items that still meet its conditions are offered (a project
    /// used since it was prepared drops out). The suggestion stays if the cleanup removed nothing and had problems.
    func approve(_ suggestion: Suggestion) {
        guard let job = config.jobs.first(where: { $0.id == suggestion.jobID }) else {
            errorMessage = "The job “\(suggestion.jobName)” that prepared this cleanup no longer exists. Dismiss the suggestion."
            return
        }
        runningJobID = job.id
        let runner = jobRunner
        Task {
            let result = await Task.detached { Result { try runner.evaluate(job) } }.value
            self.runningJobID = nil
            switch result {
            case .success(let evaluation):
                let plan = suggestion.plan.keeping(onlyEligible: evaluation.eligible).plan
                guard !plan.isEmpty else {
                    self.errorMessage = "Nothing in “\(suggestion.jobName)” needs cleaning any more: it was used or removed since."
                    return
                }
                self.review(plan, title: "Approve “\(suggestion.jobName)”") { report in
                    if report.removedAnything || !report.hasProblems {
                        self.dismiss(suggestion)
                    } else {
                        self.refreshJournal()
                    }
                }
            case .failure(let error):
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func dismiss(_ suggestion: Suggestion) {
        do {
            try context.suggestions.remove(suggestion.id)
        } catch {
            errorMessage = "Couldn't remove the suggestion: \(error.localizedDescription)"
        }
        refreshJournal()
    }

    func installAgent() {
        guard let executable = AppModel.cliExecutable else {
            errorMessage =
                "Couldn't find the spacekit command-line tool. Build it with `make install`, or use the app bundle from `make app`."
            return
        }
        do {
            try LaunchAgent(paths: context.paths).install(executable: executable, interval: context.config.automation.checkEvery.seconds)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAutomation()
    }

    func uninstallAgent() {
        do {
            try LaunchAgent(paths: context.paths).uninstall()
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshAutomation()
    }

    /// The `spacekit` CLI the agent runs: bundled in `SpaceKit.app/Contents/Helpers`, or installed on PATH.
    static var cliExecutable: String? {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/spacekit").path
        if FileManager.default.isExecutableFile(atPath: bundled) { return bundled }
        return Shell.which("spacekit")
    }

    /// Saves a job: in place of the job `id` when editing, otherwise as a new job whose id doesn't clash with another.
    func saveJob(_ job: Job, replacing id: String? = nil) {
        updateConfig { $0.upsertJob(job, replacing: id) }
    }

    func deleteJob(_ job: Job) {
        updateConfig { $0.jobs.removeAll { $0.id == job.id } }
    }

    // MARK: Finder

    func reveal(_ path: String?) {
        guard let path else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func chooseFolder() {
        if let path = AppModel.askForFolder(prompt: "Scan") { scan(path) }
    }

    /// Asks for one folder (hidden ones shown) and returns its path, or `nil` if the person cancelled.
    static func askForFolder(prompt: String? = nil) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        if let prompt { panel.prompt = prompt }
        return panel.runModal() == .OK ? panel.url?.path : nil
    }
}

/// A job being created or edited in the job editor.
struct JobDraft: Identifiable {
    let id = UUID()
    var job: Job
    /// The id of the job being edited, or nil for a new job.
    var originalID: String?
}

extension JobDraft {
    /// A new job for folders chosen in Explore.
    init(paths: [String]) {
        let name = paths.count == 1 ? "Clean \(PathUtil.lastComponent(paths[0]))" : "Clean \(paths.count) folders"
        self.init(
            job: Job(
                id: Rule.slug(name), name: name, paths: paths.map { PathUtil.abbreviate($0) }, mode: .suggest,
                schedule: .weekly, when: Job.Conditions(olderThan: .days(30))))
    }

    /// A new job from a rule's suggested policy.
    init(rule: Rule) {
        self.init(job: Job.suggested(for: rule))
    }
}
