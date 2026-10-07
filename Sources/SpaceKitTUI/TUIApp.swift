import CoreGraphics
import Foundation
import SpaceKitCore

/// Thread-safe box for state shared between the UI loop and background work.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func read<T>(_ body: (Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(value)
    }
    func write<T>(_ body: (inout Value) -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}

/// The full-screen terminal interface: `spacekit tui [path]`.
public final class TUIApp: @unchecked Sendable {
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
        /// Runs when the person presses `y`. `nil` makes it an information box.
        var onConfirm: (@Sendable () -> Void)?
        var confirmLabel = "y confirm · n cancel"
    }

    struct State {
        var tab: Tab = .explore
        var rootPath: String
        var tree: ScanTree?
        var scanProgress: ScanProgress?
        var current: DirNode?
        var selection = 0
        var scroll = 0
        var mapMode = false
        var marked: [String: CleanupItem] = [:]

        var analysis: Analysis?
        var analysisProgress: ScanProgress?
        var aiReport: AIReport?
        var devSelection = 0
        var devScroll = 0
        var markedRules: Set<String> = []
        var aiSelection = 0
        var aiScroll = 0

        var jobSelection = 0
        var busy: String?

        var ruleIndex: RuleIndex
        var modal: Modal?
        var flash: String?
        var flashUntil = Date.distantPast
        var quit = false
        var error: String?
    }

    let terminal = Terminal()
    let state: Locked<State>
    let contextBox: Locked<SpaceKitContext>
    var context: SpaceKitContext { contextBox.read { $0 } }

    public init(context: SpaceKitContext, path: String?) {
        let root = PathUtil.expand(path ?? context.config.scan.defaultPath)
        state = Locked(State(rootPath: root, ruleIndex: RuleIndex(rules: context.library.rules)))
        contextBox = Locked(context)
    }

    public func run() {
        terminal.enter()
        defer { terminal.restore() }
        startScan()
        var lastRender = Date.distantPast
        while !state.read(\.quit) {
            if let key = terminal.readKey(timeout: 0.08) {
                handle(key)
                render()
                lastRender = Date()
            } else if Date().timeIntervalSince(lastRender) > 0.12 {
                render()
                lastRender = Date()
            }
        }
    }

    // MARK: Background work

    func startScan() {
        let progress = ScanProgress()
        let (path, options) = (state.read(\.rootPath), context.scanOptions)
        state.write {
            $0.scanProgress = progress
            $0.tree = nil
            $0.current = nil
            $0.selection = 0
            $0.scroll = 0
            $0.error = nil
        }
        Thread.detachNewThread { [self] in
            do {
                let tree = try Scanner(options: options).scan(path, progress: progress)
                state.write {
                    $0.tree = tree
                    $0.current = tree.root
                    $0.scanProgress = nil
                }
            } catch {
                state.write {
                    $0.scanProgress = nil
                    $0.error = error.localizedDescription
                }
            }
        }
    }

    func startAnalysis() {
        guard state.read({ $0.analysis == nil && $0.analysisProgress == nil }) else { return }
        let progress = ScanProgress()
        state.write { $0.analysisProgress = progress }
        let context = self.context
        let tree = state.read(\.tree)
        Thread.detachNewThread { [self] in
            let result: Result<Analysis, Error> = Result { try context.analyzer.analyzeSync(reusing: tree, progress: progress) }
            state.write { state in
                state.analysisProgress = nil
                switch result {
                case .success(let analysis):
                    state.analysis = analysis
                    state.aiReport = AIInspector.report(
                        findings: analysis.findings, tree: analysis.tree,
                        activeWindow: context.config.automation.activeModelWindow)
                    state.ruleIndex = RuleIndex(rules: context.library.rules, findings: analysis.findings)
                    try? context.history.recordSnapshot(analysis: analysis)
                case .failure(let error):
                    state.error = error.localizedDescription
                }
            }
        }
    }

    func flash(_ message: String) {
        state.write {
            $0.flash = message
            $0.flashUntil = Date().addingTimeInterval(4)
        }
    }

    // MARK: Input

    func handle(_ key: Key) {
        if state.read({ $0.modal != nil }) {
            handleModal(key)
            return
        }
        switch key {
        case .character("q"), .control("c"):
            state.write { $0.quit = true }
            return
        case .tab:
            switchTab(by: 1)
            return
        case .backTab:
            switchTab(by: -1)
            return
        case .character(let c) where ("1"..."5").contains(c):
            let index = Int(String(c))! - 1
            selectTab(Tab(rawValue: index)!)
            return
        case .character("?"):
            showHelp()
            return
        default:
            break
        }
        switch state.read(\.tab) {
        case .explore: handleExplore(key)
        case .dev: handleDev(key)
        case .ai: handleAI(key)
        case .jobs: handleJobs(key)
        case .history: break
        }
    }

    func switchTab(by delta: Int) {
        let count = Tab.allCases.count
        let next = (state.read(\.tab).rawValue + delta + count) % count
        selectTab(Tab(rawValue: next)!)
    }

    func selectTab(_ tab: Tab) {
        state.write { $0.tab = tab }
        if tab == .dev || tab == .ai, state.read({ $0.tree != nil }) { startAnalysis() }
    }

    func handleModal(_ key: Key) {
        guard let modal = state.read(\.modal) else { return }
        switch key {
        case .character("y"), .character("Y"):
            state.write { $0.modal = nil }
            modal.onConfirm?()
        case .enter where modal.onConfirm == nil:
            state.write { $0.modal = nil }
        case .character("n"), .character("N"), .escape, .character("q"):
            state.write { $0.modal = nil }
        default:
            if modal.onConfirm == nil { state.write { $0.modal = nil } }
        }
    }

    func showHelp() {
        state.write {
            $0.modal = Modal(
                title: "Keys",
                lines: [
                    "Tab / 1–5      switch view",
                    "↑ ↓ PgUp PgDn  move",
                    "→ / Enter      open folder · details",
                    "← / Backspace  go up",
                    "t              toggle treemap (Explore)",
                    "space          mark for cleanup",
                    "d              clean marked items (asks first)",
                    "o              reveal in Finder",
                    "r              rescan",
                    "j              create a job from a rule (Dev)",
                    "e / m          enable / change mode of a job",
                    "x              run a job now (asks first)",
                    "q              quit",
                    "",
                    "Everything is checked by the safety guard. Removed items go to the Trash",
                    "unless your config says otherwise. See docs/SAFETY.md.",
                ], onConfirm: nil)
        }
    }

    // MARK: Explore input

    func handleExplore(_ key: Key) {
        let items = state.read { $0.current?.items ?? [] }
        let pageSize = max(1, terminal.size.rows - 8)
        switch key {
        case .up, .character("k"): moveSelection(-1, count: items.count)
        case .down, .character("j"): moveSelection(1, count: items.count)
        case .pageUp: moveSelection(-pageSize, count: items.count)
        case .pageDown: moveSelection(pageSize, count: items.count)
        case .home: state.write { $0.selection = 0 }
        case .end: state.write { $0.selection = max(0, items.count - 1) }
        case .right, .enter, .character("l"):
            let index = state.read(\.selection)
            guard items.indices.contains(index), let directory = items[index].directory,
                !directory.children.isEmpty || !directory.files.isEmpty
            else { return }
            state.write {
                $0.current = directory
                $0.selection = 0
                $0.scroll = 0
            }
        case .left, .backspace, .character("h"):
            state.write { state in
                guard let current = state.current, let parent = current.parent,
                    !parent.name.isEmpty || parent.parent != nil || !parent.children.isEmpty
                else { return }
                state.selection = parent.items.firstIndex { $0.directory === current } ?? 0
                state.current = parent
                state.scroll = max(0, state.selection - 5)
            }
        case .character("t"):
            state.write { $0.mapMode.toggle() }
        case .character("r"):
            startScan()
        case .space:
            let index = state.read(\.selection)
            guard items.indices.contains(index), let path = items[index].path else { return }
            state.write { state in
                if state.marked[path] != nil {
                    state.marked[path] = nil
                } else {
                    let item = items[index]
                    let rule = state.ruleIndex.rule(for: path)
                    let git = state.tree?.markers.bit(for: ".git") ?? 0
                    state.marked[path] = CleanupItem(
                        path: path, kind: item.isDirectory ? .directory : .file, name: item.name, size: item.size, ruleID: rule?.id,
                        isRepository: (item.directory?.markers ?? 0) & git != 0,
                        containsRepository: (item.directory?.subtreeMarkers ?? 0) & git != 0, lastUsed: item.modified)
                }
            }
            moveSelection(1, count: items.count)
        case .character("o"):
            let index = state.read(\.selection)
            if items.indices.contains(index), let path = items[index].path {
                _ = Shell.run("/usr/bin/open", ["-R", path], timeout: 5)
            }
        case .character("d"):
            var plan = state.read { CleanupPlan(items: Array($0.marked.values)) }
            if plan.items.isEmpty {
                let index = state.read(\.selection)
                guard items.indices.contains(index), let path = items[index].path else { return }
                let item = items[index]
                let rule = state.read { $0.ruleIndex.rule(for: path) }
                let git = state.read { $0.tree?.markers.bit(for: ".git") ?? 0 }
                plan.items = [
                    CleanupItem(
                        path: path, kind: item.isDirectory ? .directory : .file, name: item.name, size: item.size,
                        ruleID: rule?.id, isRepository: (item.directory?.markers ?? 0) & git != 0,
                        containsRepository: (item.directory?.subtreeMarkers ?? 0) & git != 0)
                ]
            }
            plan.useTrash = context.trashPreference(for: .trash) ?? true
            confirmCleanup(plan, title: "Clean selected items")
        default:
            break
        }
    }

    func moveSelection(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        state.write { $0.selection = min(max($0.selection + delta, 0), count - 1) }
    }

    // MARK: Cleanup flow

    /// Shows what the guard thinks of each item and asks before doing anything.
    func confirmCleanup(_ plan: CleanupPlan, title: String) {
        let executor = context.executor
        var lines: [String] = []
        var allowed = CleanupPlan(commands: plan.commands, manualSteps: plan.manualSteps, useTrash: plan.useTrash)
        for item in plan.items.sorted(by: { $0.size > $1.size }) {
            let verdict = executor.verdict(for: item, context: .manual(confirmed: false))
            let size = ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true)
            let name = PathUtil.abbreviate(item.path)
            switch verdict.decision {
            case .allow:
                lines.append("✓".fg(ANSI.safe) + " \(size)  \(name)")
                allowed.items.append(item)
            case .confirm:
                lines.append("!".fg(ANSI.review) + " \(size)  \(name)")
                lines.append("    " + (verdict.reasons.first ?? "").fg(ANSI.review))
                allowed.items.append(item)
            case .block:
                lines.append("✗".fg(ANSI.protected) + " \(size)  \(name)")
                lines.append("    " + ("Blocked: " + (verdict.reasons.first ?? "")).fg(ANSI.protected))
            }
        }
        for command in plan.commands {
            lines.append(
                "$ ".fg(ANSI.accent) + command.displayString + "  " + "frees up to \(ByteCount.format(command.estimatedBytes))".dim)
        }
        for step in plan.manualSteps { lines.append("→ ".dim + step) }
        guard !allowed.isEmpty else {
            state.write { $0.modal = Modal(title: title, lines: lines + ["", "Nothing here can be removed."], onConfirm: nil) }
            return
        }
        lines.append("")
        if !allowed.items.isEmpty {
            let destination = allowed.useTrash ? "moved to the Trash" : "deleted permanently".fg(ANSI.protected)
            lines.append("\(ByteCount.format(allowed.items.reduce(0) { $0 + $1.size })) will be \(destination).".bold)
        }
        if !allowed.commands.isEmpty {
            lines.append(
                "\(allowed.commands.count) tool command\(allowed.commands.count == 1 ? "" : "s") will run; each removes only what its tool knows is unused."
                    .bold)
        }
        let approved = allowed
        state.write {
            $0.modal = Modal(
                title: title, lines: lines, onConfirm: { [self] in self.execute(approved) }, confirmLabel: "y clean · n cancel")
        }
    }

    func execute(_ plan: CleanupPlan) {
        state.write { $0.busy = "Cleaning…" }
        let executor = context.executor
        Thread.detachNewThread { [self] in
            let report = executor.execute(plan, context: .manual(confirmed: true), dryRun: false)
            state.write { state in
                if let tree = state.tree {
                    for removal in Removal.from(report) { removal.apply(to: tree) }
                }
                for (item, outcome) in report.items where outcome.isRemoved { state.marked[item.path] = nil }
                state.busy = nil
                state.analysis = nil
                state.aiReport = nil
                var lines = [report.summary.bold.fg(ANSI.safe)]
                if report.trashedBytes > 0 {
                    lines.append("Items in the Trash still use disk space until it's emptied (spacekit trash --empty).".dim)
                }
                for (item, reason) in report.skipped + report.failures {
                    lines.append("• \(PathUtil.abbreviate(item.path)): \(reason)".dim)
                }
                for (command, outcome, _) in report.commands {
                    lines.append("$ \(command.displayString): \(outcome)")
                }
                state.modal = Modal(title: "Done", lines: lines, onConfirm: nil)
                if let count = state.current?.items.count { state.selection = min(state.selection, max(0, count - 1)) }
            }
        }
    }

    // MARK: Dev input

    func devRows() -> [(group: String, finding: Finding?)] {
        guard let analysis = state.read(\.analysis) else { return [] }
        var rows: [(String, Finding?)] = []
        for level in SafetyLevel.allCases {
            let findings = analysis.findings(level)
            guard !findings.isEmpty else { continue }
            rows.append(("\(level.emoji) \(level.title) · \(ByteCount.format(analysis.total(level)))", nil))
            for finding in findings { rows.append((finding.rule.group, finding)) }
        }
        return rows
    }

    func handleDev(_ key: Key) {
        let rows = devRows()
        let selectable = rows.indices.filter { rows[$0].finding != nil }
        guard !selectable.isEmpty else {
            if key == .character("r") {
                state.write { $0.analysis = nil }
                startAnalysis()
            }
            return
        }
        let current = state.read(\.devSelection)
        let position = selectable.firstIndex(of: current) ?? 0
        func select(_ p: Int) { state.write { $0.devSelection = selectable[min(max(p, 0), selectable.count - 1)] } }
        switch key {
        case .up, .character("k"): select(position - 1)
        case .down, .character("j"): select(position + 1)
        case .pageUp: select(position - 10)
        case .pageDown: select(position + 10)
        case .character("r"):
            state.write {
                $0.analysis = nil
                $0.aiReport = nil
            }
            startAnalysis()
        case .space:
            guard let finding = rows[selectable[position]].finding, finding.isCleanable else { return }
            state.write { state in
                if state.markedRules.contains(finding.id) {
                    state.markedRules.remove(finding.id)
                } else {
                    state.markedRules.insert(finding.id)
                }
            }
            select(position + 1)
        case .enter, .right:
            guard let finding = rows[selectable[position]].finding else { return }
            showFinding(finding)
        case .character("d"), .character("c"):
            let marked = state.read(\.markedRules)
            let findings = rows.compactMap(\.finding).filter {
                marked.isEmpty ? $0.id == rows[selectable[position]].finding?.id : marked.contains($0.id)
            }
            let plan = CleanupPlan.make(findings: findings.filter(\.isCleanable), trashPreference: context.trashPreference(for: .rule))
            confirmCleanup(plan, title: "Clean \(findings.count == 1 ? findings[0].rule.name : "\(findings.count) rules")")
        case .character("j"):
            guard let finding = rows[selectable[position]].finding else { return }
            createJob(for: finding.rule)
        default:
            break
        }
    }

    func showFinding(_ finding: Finding) {
        let rule = finding.rule
        var lines: [String] = []
        if let description = rule.description { lines.append(description) }
        lines.append("")
        lines.append("Reclaimable: ".dim + ByteCount.format(finding.size).bold)
        lines.append("Risk: ".dim + rule.safety.level.badge)
        if let recreatedBy = rule.recreatedBy { lines.append("Recreated by: ".dim + recreatedBy) }
        if let used = finding.lastUsed { lines.append("Last used: ".dim + used.relativeDescription()) }
        lines.append("Items: ".dim + "\(finding.items.count)")
        lines.append("")
        for item in finding.items.prefix(12) {
            let age = item.idleDays().map { "\($0)d" } ?? "–"
            lines.append(
                ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true) + "  " + ANSI.pad(age, to: 5, alignRight: true) + "  "
                    + PathUtil.abbreviate(item.path))
        }
        if finding.items.count > 12 { lines.append("… \(finding.items.count - 12) more".dim) }
        if let command = rule.action.command {
            lines.append("")
            lines.append("Cleans with: ".dim + command.joined(separator: " "))
        }
        if let manual = rule.action.manual {
            lines.append("")
            lines.append("How to clean: ".dim + manual)
        }
        state.write { $0.modal = Modal(title: rule.name, lines: lines, onConfirm: nil) }
    }

    func createJob(for rule: Rule) {
        var context = self.context
        guard !context.config.jobs.contains(where: { $0.rules == [rule.id] }) else {
            flash("A job for \(rule.name) already exists")
            return
        }
        guard rule.safety.level != .protected, rule.action.isCleanable else {
            flash("\(rule.name) can't be cleaned automatically")
            return
        }
        var job = Job.suggested(for: rule)
        if context.config.jobs.contains(where: { $0.id == job.id }) { job.id += "-\(context.config.jobs.count + 1)" }
        context.config.jobs.append(job)
        do {
            try context.configStore.save(context.config)
            contextBox.write { $0 = context }
            flash("Created job “\(job.name)” (\(job.mode.rawValue), \(job.schedule)) — see Automation")
        } catch {
            flash("Couldn't save config: \(error.localizedDescription)")
        }
    }

    // MARK: AI input

    func aiRows() -> [(tool: String, model: AIModel?)] {
        guard let report = state.read(\.aiReport) else { return [] }
        var rows: [(String, AIModel?)] = []
        for tool in report.tools {
            rows.append((tool.name, nil))
            for model in tool.models { rows.append((tool.name, model)) }
        }
        return rows
    }

    func handleAI(_ key: Key) {
        let rows = aiRows()
        let selectable = rows.indices.filter { rows[$0].model != nil }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: state.read(\.aiSelection)) ?? 0
        func select(_ p: Int) { state.write { $0.aiSelection = selectable[min(max(p, 0), selectable.count - 1)] } }
        switch key {
        case .up, .character("k"): select(position - 1)
        case .down, .character("j"): select(position + 1)
        case .pageUp: select(position - 10)
        case .pageDown: select(position + 10)
        case .character("d"), .character("x"):
            guard let model = rows[selectable[position]].model else { return }
            var plan = CleanupPlan(useTrash: context.trashPreference(for: .trash) ?? true)
            if let command = model.removeCommand {
                plan.commands.append(PlannedCommand(ruleID: model.ruleID, arguments: command, estimatedBytes: model.size))
            } else if model.kind == .orphaned || model.paths.count == 1 {
                plan.items = model.paths.map {
                    CleanupItem(path: $0, kind: .directory, size: model.paths.count == 1 ? model.size : 0, ruleID: model.ruleID)
                }
            }
            confirmCleanup(plan, title: "Remove \(model.name)")
        default:
            break
        }
    }

    // MARK: Jobs input

    func handleJobs(_ key: Key) {
        var context = self.context
        let jobs = context.config.jobs
        guard !jobs.isEmpty else { return }
        let index = min(state.read(\.jobSelection), jobs.count - 1)
        func save(_ message: String) {
            do {
                try context.configStore.save(context.config)
                contextBox.write { $0 = context }
                flash(message)
            } catch {
                flash("Couldn't save config: \(error.localizedDescription)")
            }
        }
        switch key {
        case .up, .character("k"): state.write { $0.jobSelection = max(0, index - 1) }
        case .down, .character("j"): state.write { $0.jobSelection = min(jobs.count - 1, index + 1) }
        case .character("e"), .space:
            context.config.jobs[index].enabled.toggle()
            save("\(jobs[index].name): \(context.config.jobs[index].enabled ? "enabled" : "disabled")")
        case .character("m"):
            let modes = Job.Mode.allCases
            let next = modes[(modes.firstIndex(of: jobs[index].mode)! + 1) % modes.count]
            context.config.jobs[index].mode = next
            save("\(jobs[index].name): \(next.title) — \(next.explanation)")
        case .character("x"), .enter:
            let job = jobs[index]
            state.write { $0.busy = "Evaluating \(job.name)…" }
            let runner = JobRunner(context: context)
            Thread.detachNewThread { [self] in
                do {
                    let evaluation = try runner.evaluate(job)
                    let plan = runner.plan(for: evaluation)
                    state.write { $0.busy = nil }
                    if plan.isEmpty {
                        state.write { $0.modal = Modal(title: job.name, lines: [evaluation.triggerSummary], onConfirm: nil) }
                    } else {
                        confirmCleanup(plan, title: "Run “\(job.name)” now")
                    }
                } catch {
                    state.write {
                        $0.busy = nil
                        $0.modal = Modal(title: job.name, lines: [error.localizedDescription], onConfirm: nil)
                    }
                }
            }
        case .character("i"):
            let agent = LaunchAgent(paths: context.paths)
            if agent.status().installed {
                try? agent.uninstall()
                flash("Background agent removed")
            } else if let executable = Bundle.main.executablePath {
                do {
                    try agent.install(executable: executable, interval: context.config.automation.checkEvery.seconds)
                    flash("Background agent installed — jobs run on schedule")
                } catch {
                    flash("Couldn't install agent: \(error.localizedDescription)")
                }
            }
        default:
            break
        }
    }
}
