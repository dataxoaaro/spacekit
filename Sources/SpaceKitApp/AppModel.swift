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
    var categories: [CategorySlice] = []
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
    var analysis: Analysis?
    private(set) var analysisProgress: ScanProgress?
    var aiReport: AIReport?
    @ObservationIgnored private var analysisRequests = RequestGeneration()

    // MARK: Cleanup
    /// Items collected from Explore and Dev Intelligence for one combined review.
    var cleanupList: [CleanupItem] = []
    /// The plan currently shown in the cleanup sheet.
    var pendingCleanup: PendingCleanup?
    /// The job currently open in the job editor.
    var jobDraft: JobDraft?
    /// Bumped whenever the tree changes in place, so cached map layouts are rebuilt.
    var treeRevision = 0 {
        didSet { itemsCache.removeAll() }
    }
    /// Rules currently being re-evaluated after a tool command ran (cards show a spinner).
    var refreshingRules: Set<String> = []
    /// Cleanups removing things right now. Quitting waits for them (see `AppDelegate`).
    var runningCleanups = 0
    /// Set when the person chose to quit while a cleanup ran; the app quits once the last one finishes.
    @ObservationIgnored var quitWhenCleanupsFinish = false

    // Render-time caches. Not observed, so filling them during a view update doesn't trigger another one.
    @ObservationIgnored private var itemsCache: [UInt: [DiskItem]] = [:]
    @ObservationIgnored private var ruleCache: [String: Rule?] = [:]
    @ObservationIgnored private var rulesIncludingDisabledCache: [Rule]?

    // MARK: Automation & history
    var jobStates: [String: JobState] = [:]
    var suggestions: [Suggestion] = []
    var agentStatus: LaunchAgent.Status?
    var recovered90Days: UInt64 = 0
    var journal: [JournalEntry] = []
    var history: [HistoryRecord] = []
    var volumes: [VolumeCapacity] = []
    /// Live capacity of the volume being explored, refreshed every few seconds while the app is active.
    var scanCapacity: VolumeCapacity?
    /// Size of the Trash, once measured (nil if it can't be read without Full Disk Access).
    var trashBytes: UInt64?
    /// Local Time Machine snapshots on the startup disk; they hold deleted files' space as "purgeable".
    var localSnapshotCount = 0
    @ObservationIgnored var capacityMonitor: Task<Void, Never>?
    @ObservationIgnored var observers: [NSObjectProtocol] = []
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
