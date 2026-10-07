import Foundation
import SpaceKitCore
import Synchronization

/// The full-screen terminal interface: `spacekit tui [path]`.
///
/// Threading: the UI thread (the one that calls `run()`) owns `state` and `context`, and is the only thread
/// that reads or changes a finished scan tree. Scans, analyses, job evaluations and cleanups run on
/// background threads that work on their own copies and report back through `inbox`; the UI thread applies
/// their results between frames.
public final class TUIApp {
    enum Tab: Int, CaseIterable {
        case explore, dev, ai, jobs, history
        var title: String {
            switch self {
            case .explore: return "Explore"
            case .dev: return "Dev Intelligence"
            case .ai: return "AI"
            case .jobs: return "Automation"
            case .history: return "History"
            }
        }
    }

    struct Modal {
        var title: String
        var lines: [String]
        /// Always visible below the scrolling lines, whatever the scroll position.
        var footer: [String] = []
        var pager: Pager
        /// Runs when the person presses `y`, once every line has been on screen. `nil` makes it an information box.
        var onConfirm: (() -> Void)?
        var confirmLabel = "y confirm · n cancel"

        init(title: String, lines: [String], footer: [String] = [], onConfirm: (() -> Void)? = nil, confirmLabel: String? = nil) {
            self.title = title
            self.lines = lines
            self.footer = footer
            self.pager = Pager(lineCount: lines.count)
            self.onConfirm = onConfirm
            if let confirmLabel { self.confirmLabel = confirmLabel }
        }
    }

    /// A selected row and the scroll position that keeps it in view.
    struct ListCursor {
        var selection = 0
        var window = ScrollWindow()

        mutating func move(by delta: Int, count: Int) {
            guard count > 0 else { return }
            selection = min(max(selection + delta, 0), count - 1)
        }

        mutating func visibleRows(_ visible: Int, count: Int) -> Range<Int> {
            window.follow(selection: selection, visible: visible, count: count)
        }
    }

    /// Long-running work that other keys must wait for.
    enum Activity {
        case evaluating(String)
        case cleaning

        var text: String {
            switch self {
            case .evaluating(let name): return "Evaluating \(name)…"
            case .cleaning: return "Cleaning… (q quits when it's done)"
            }
        }
    }

    /// Results posted by background threads.
    enum Event: Sendable {
        case scanned(generation: Int, Result<ScanTree, Error>)
        case analysed(generation: Int, Result<AnalysisResult, Error>)
        case refreshed(generation: Int, ruleIDs: Set<String>, Result<AnalysisResult, Error>)
        case evaluated(Job, Result<(JobEvaluation, CleanupPlan), Error>)
        /// The evaluation is set when the cleanup ran a job, so the result is recorded against it.
        case cleaned(CleanupReport, JobEvaluation?)
    }

    struct AnalysisResult: Sendable {
        var analysis: Analysis
        var aiReport: AIReport
        var ruleIndex: RuleIndex
    }

    struct State {
        var tab: Tab = .explore
        var rootPath: String
        /// Bumped by every scan; results from an older scan are dropped.
        var generation = 0
        /// When the current scan started. Plans made from it don't touch loose files changed after this.
        var scanStarted = Date()
        var tree: ScanTree?
        var scanProgress: ScanProgress?
        var current: DirNode?
        var explore = ListCursor()
        var mapMode = false
        var marked: [String: CleanupItem] = [:]

        var analysis: Analysis?
        var analysisProgress: ScanProgress?
        var aiReport: AIReport?
        var dev = ListCursor()
        var markedRules: Set<String> = []
        var ai = ListCursor()
        /// Removals that arrived while an analysis was reading the tree; applied when it finishes.
        var pendingRemovals: [Removal] = []

        var jobSelection = 0
        var automation: AutomationSnapshot?
        var history: HistorySnapshot?
        var activity: Activity?
        var quitWhenIdle = false

        var ruleIndex: RuleIndex
        var modal: Modal?
        var flash: String?
        var flashUntil = Date.distantPast
        var quit = false
        var error: String?
        /// Printed after the terminal is restored.
        var exitMessage: String?
    }

    /// Hands results from background threads to the UI thread.
    final class Inbox: Sendable {
        private let events = Mutex<[Event]>([])
        func post(_ event: Event) { events.withLock { $0.append(event) } }
        func drain() -> [Event] { events.withLock { events in defer { events = [] }; return events } }
    }

    let terminal = Terminal()
    let inbox = Inbox()
    var state: State
    var context: SpaceKitContext

    public init(context: SpaceKitContext, path: String?) {
        let root = PathUtil.expand(path ?? context.config.scan.defaultPath)
        state = State(rootPath: root, ruleIndex: RuleIndex(rules: context.library.rules))
        self.context = context
    }

    public func run() {
        terminal.enter()
        startScan()
        var lastRender = Date.distantPast
        while !state.quit {
            let events = inbox.drain()
            for event in events { handle(event) }
            let keys = terminal.readKeys(timeout: 0.08)
            for key in keys where !state.quit { handle(key) }
            if !events.isEmpty || !keys.isEmpty || Date().timeIntervalSince(lastRender) > 0.12 {
                render()
                lastRender = Date()
            }
        }
        terminal.restore()
        if let message = state.exitMessage { print(message) }
    }

    // MARK: Background work

    func startScan() {
        state.scanProgress?.cancel()
        state.analysisProgress?.cancel()
        let progress = ScanProgress()
        state.generation += 1
        state.scanStarted = Date()
        state.scanProgress = progress
        state.tree = nil
        state.current = nil
        state.explore = ListCursor()
        state.analysis = nil
        state.analysisProgress = nil
        state.aiReport = nil
        state.pendingRemovals = []
        state.dev = ListCursor()
        state.ai = ListCursor()
        state.error = nil
        let (path, options, generation, inbox) = (state.rootPath, context.scanOptions, state.generation, inbox)
        Thread.detachNewThread {
            let result = Result { try Scanner(options: options).scan(path, progress: progress) }
            inbox.post(.scanned(generation: generation, result))
        }
    }

    func startAnalysis() {
        guard state.analysis == nil, state.analysisProgress == nil, let tree = state.tree else { return }
        let progress = ScanProgress()
        state.analysisProgress = progress
        let (context, generation, inbox) = (context, state.generation, inbox)
        Thread.detachNewThread {
            let result = Result { () throws -> AnalysisResult in
                let analysis = try context.analyzer.analyzeSync(reusing: tree, progress: progress)
                try? context.history.recordSnapshot(analysis: analysis)
                return TUIApp.result(of: analysis, context: context)
            }
            inbox.post(.analysed(generation: generation, result))
        }
    }

    /// Re-evaluates only `ruleIDs`, after their tool commands freed space their own way.
    func refreshFindings(ruleIDs: Set<String>) {
        let rules = ruleIDs.compactMap { self.context.library.rule(id: $0) }
        guard !rules.isEmpty, state.analysis != nil else { return }
        let (context, generation, inbox) = (context, state.generation, inbox)
        Thread.detachNewThread {
            let result = Result { TUIApp.result(of: try context.analyzer.analyzeSync(rules: rules), context: context) }
            inbox.post(.refreshed(generation: generation, ruleIDs: ruleIDs, result))
        }
    }

    static func result(of analysis: Analysis, context: SpaceKitContext) -> AnalysisResult {
        AnalysisResult(
            analysis: analysis,
            aiReport: AIInspector.report(
                findings: analysis.findings, tree: analysis.tree, activeWindow: context.config.automation.activeModelWindow),
            ruleIndex: RuleIndex(rules: context.library.rules, findings: analysis.findings))
    }

    func handle(_ event: Event) {
        switch event {
        case .scanned(let generation, let result):
            guard generation == state.generation else { return }
            state.scanProgress = nil
            switch result {
            case .success(let tree):
                state.tree = tree
                state.current = tree.root
                if state.tab == .dev || state.tab == .ai { startAnalysis() }
            case .failure(let error):
                state.error = TerminalText.sanitize(error.localizedDescription)
            }
        case .analysed(let generation, let result):
            guard generation == state.generation else { return }
            state.analysisProgress = nil
            switch result {
            case .success(let fresh):
                state.analysis = fresh.analysis
                state.aiReport = fresh.aiReport
                state.ruleIndex = fresh.ruleIndex
            case .failure(let error):
                state.error = TerminalText.sanitize(error.localizedDescription)
            }
            let pending = state.pendingRemovals
            state.pendingRemovals = []
            applyRemovals(pending)
        case .refreshed(let generation, let ruleIDs, let result):
            guard generation == state.generation, case .success(let fresh) = result else { return }
            mergeRefreshed(fresh, ruleIDs: ruleIDs)
        case .evaluated(let job, let result):
            jobEvaluated(job, result)
        case .cleaned(let report, let job):
            cleanupFinished(report, job: job)
        }
    }

    func flash(_ message: String) {
        state.flash = message
        state.flashUntil = Date().addingTimeInterval(4)
    }

    /// Quits now, or once the running cleanup is done: stopping mid-run would leave it half finished.
    func requestQuit() {
        guard case .cleaning = state.activity else {
            state.quit = true
            return
        }
        state.quitWhenIdle = true
        flash("Waiting for the cleanup to finish, then quitting")
    }
}
