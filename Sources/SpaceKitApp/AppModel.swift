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
    var backStack: [DirNode] = []
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
    @ObservationIgnored var capacityMonitor: Task<Void, Never>?
    @ObservationIgnored var observers: [NSObjectProtocol] = []
    private(set) var runningJobID: String?

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

    /// Evaluates a job off the main actor, marking it as running meanwhile (cards show a spinner).
    func evaluate(_ job: Job, with runner: JobRunner) async -> Result<JobEvaluation, Error> {
        runningJobID = job.id
        defer { runningJobID = nil }
        return await Task.detached { Result { try runner.evaluate(job) } }.value
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

    // MARK: State changes
    // Extensions in other files read the published state freely but change it only through these methods, so the
    // properties keep their private setters.

    func beginCleanup() { runningCleanups += 1 }

    func endCleanup() {
        runningCleanups -= 1
        if runningCleanups == 0 && quitWhenCleanupsFinish {
            quitWhenCleanupsFinish = false
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    /// Shrinks the trees and findings in place after a cleanup: trashed items move into the Trash folder (they
    /// still use space until it's emptied), the AI report and category totals update only if they were affected.
    func applyToTreesAndFindings(_ removals: [Removal]) {
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

    func trashMeasured(_ bytes: UInt64?) {
        if trashBytes != bytes { trashBytes = bytes }
    }

    /// The trees changed in place (the Trash folder re-synced): rebuild map layouts and category totals.
    func treesChangedInPlace() {
        treeRevision += 1
        if let tree, tree.roots == ["/"] || tree.covers(PathUtil.home) {
            categories = CategoryBreakdown.compute(tree: tree, findings: analysis?.findings ?? [], capacity: scanCapacity)
        }
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

    func refreshSnapshots() {
        Task {
            let count = await Task.detached(priority: .utility) { LocalSnapshots.list(volume: "/").count }.value
            if count != localSnapshotCount { localSnapshotCount = count }
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
    func untilTreesAreFree() async {
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
