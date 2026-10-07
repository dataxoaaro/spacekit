import Foundation
import SpaceKitCore

extension TUIApp {
    var isCleaning: Bool {
        if case .cleaning = state.activity { return true }
        return false
    }

    func handle(_ key: Key) {
        if key == .character("q") || key == .control("c"), state.modal == nil || isCleaning {
            requestQuit()
            return
        }
        if state.modal != nil {
            handleModal(key)
            return
        }
        guard !isTooSmall(terminal.size) else { return }
        switch key {
        case .tab:
            switchTab(by: 1)
            return
        case .backTab:
            switchTab(by: -1)
            return
        case .character(let c) where ("1"..."5").contains(c):
            selectTab(Tab(rawValue: Int(String(c))! - 1)!)
            return
        case .character("?"):
            showHelp()
            return
        default:
            break
        }
        switch state.tab {
        case .explore: handleExplore(key)
        case .dev: handleDev(key)
        case .ai: handleAI(key)
        case .jobs: handleJobs(key)
        case .history: break
        }
    }

    func switchTab(by delta: Int) {
        let count = Tab.allCases.count
        selectTab(Tab(rawValue: (state.tab.rawValue + delta + count) % count)!)
    }

    func selectTab(_ tab: Tab) {
        state.tab = tab
        switch tab {
        case .dev, .ai: startAnalysis()
        case .jobs: refreshAutomation()
        case .history: refreshHistory()
        case .explore: break
        }
    }

    /// Keys that start a scan or a cleanup wait while a cleanup runs, so two never run at once.
    func refuseWhileBusy() -> Bool {
        guard let activity = state.activity else { return false }
        flash("Busy: \(activity.text)")
        return true
    }

    func handleModal(_ key: Key) {
        guard var modal = state.modal else { return }
        let visible = modalListHeight(modal, size: terminal.size)
        switch key {
        case .up, .character("k"): modal.pager.scroll(by: -1, visible: visible)
        case .down, .character("j"): modal.pager.scroll(by: 1, visible: visible)
        case .pageUp: modal.pager.scroll(by: -max(1, visible - 1), visible: visible)
        case .pageDown, .space: modal.pager.scroll(by: max(1, visible - 1), visible: visible)
        case .home: modal.pager.scroll(by: -modal.lines.count, visible: visible)
        case .end: modal.pager.scroll(by: modal.lines.count, visible: visible)
        case .character("y"), .character("Y"):
            guard let onConfirm = modal.onConfirm else {
                state.modal = nil
                return
            }
            guard modal.pager.hasShownEnd else {
                flash("Scroll to the end of the list first (↓ or PgDn), then press y")
                return
            }
            state.modal = nil
            onConfirm()
            return
        case .character("n"), .character("N"), .escape, .character("q"), .control("c"):
            state.modal = nil
            return
        default:
            if modal.onConfirm == nil { state.modal = nil }
            return
        }
        state.modal = modal
    }

    func showHelp() {
        state.modal = Modal(
            title: "Keys",
            lines: [
                "Tab / 1–5      switch view",
                "↑ ↓ PgUp PgDn  move (also scrolls dialogs)",
                "→ / Enter      open folder · details",
                "← / Backspace  go up",
                "t              toggle treemap (Explore)",
                "space          mark for cleanup",
                "d              clean marked items (asks first)",
                "o              reveal in Finder",
                "r              rescan (Explore) · refresh (Dev)",
                "n              create a job from a rule (Dev)",
                "e / m          enable / change mode of a job",
                "x              run a job now (asks first)",
                "i              install / remove the background agent",
                "q              quit (waits for a running cleanup)",
                "",
                "Everything is checked by the safety guard. Removed items go to the Trash",
                "unless your config says otherwise. See docs/SAFETY.md.",
            ])
    }

    // MARK: Explore

    func handleExplore(_ key: Key) {
        let items = state.current?.items ?? []
        let pageSize = max(1, terminal.size.rows - 8)
        switch key {
        case .up, .character("k"): state.explore.move(by: -1, count: items.count)
        case .down, .character("j"): state.explore.move(by: 1, count: items.count)
        case .pageUp: state.explore.move(by: -pageSize, count: items.count)
        case .pageDown: state.explore.move(by: pageSize, count: items.count)
        case .home: state.explore.move(by: -items.count, count: items.count)
        case .end: state.explore.move(by: items.count, count: items.count)
        case .right, .enter, .character("l"):
            guard let item = selectedItem(items), let directory = item.directory,
                !directory.children.isEmpty || !directory.files.isEmpty
            else { return }
            state.current = directory
            state.explore = ListCursor()
        case .left, .backspace, .character("h"):
            guard let current = state.current, let parent = current.parent,
                !parent.name.isEmpty || parent.parent != nil || !parent.children.isEmpty
            else { return }
            state.current = parent
            state.explore = ListCursor(selection: parent.items.firstIndex { $0.directory === current } ?? 0)
        case .character("t"):
            state.mapMode.toggle()
        case .character("r"):
            guard !refuseWhileBusy() else { return }
            startScan()
        case .space:
            guard let item = selectedItem(items), let path = item.path else { return }
            if state.marked[path] != nil {
                state.marked[path] = nil
            } else {
                state.marked[path] = cleanupItem(for: item)
            }
            state.explore.move(by: 1, count: items.count)
        case .character("o"):
            if let path = selectedItem(items)?.path { _ = Shell.run("/usr/bin/open", ["-R", path], timeout: 5) }
        case .character("d"):
            guard !refuseWhileBusy() else { return }
            var plan = CleanupPlan(items: Array(state.marked.values), created: state.scanStarted)
            if plan.items.isEmpty {
                guard let item = selectedItem(items).flatMap(cleanupItem(for:)) else { return }
                plan.items = [item]
            }
            plan.useTrash = context.trashPreference(for: .trash) ?? true
            confirmCleanup(plan, title: "Clean selected items")
        default:
            break
        }
    }

    func selectedItem(_ items: [DiskItem]) -> DiskItem? {
        items.indices.contains(state.explore.selection) ? items[state.explore.selection] : nil
    }

    func cleanupItem(for item: DiskItem) -> CleanupItem? {
        CleanupItem(item, markers: state.tree?.markers, ruleID: item.path.flatMap { state.ruleIndex.rule(for: $0)?.id })
    }

    // MARK: Dev Intelligence

    func devRows() -> [(group: String, finding: Finding?)] {
        guard let analysis = state.analysis else { return [] }
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
        if key == .character("r") {
            guard !refuseWhileBusy() else { return }
            guard state.analysisProgress == nil else {
                flash("Already analysing")
                return
            }
            state.analysis = nil
            state.aiReport = nil
            startAnalysis()
            return
        }
        let rows = devRows()
        let selectable = rows.indices.filter { rows[$0].finding != nil }
        guard !selectable.isEmpty else { return }
        let position = selectable.firstIndex(of: state.dev.selection) ?? 0
        func select(_ p: Int) { state.dev.selection = selectable[min(max(p, 0), selectable.count - 1)] }
        guard let finding = rows[selectable[position]].finding else { return }
        switch key {
        case .up, .character("k"): select(position - 1)
        case .down, .character("j"): select(position + 1)
        case .pageUp: select(position - 10)
        case .pageDown: select(position + 10)
        case .space:
            guard finding.isCleanable else { return }
            if state.markedRules.contains(finding.id) {
                state.markedRules.remove(finding.id)
            } else {
                state.markedRules.insert(finding.id)
            }
            select(position + 1)
        case .enter, .right:
            showFinding(finding)
        case .character("d"), .character("c"):
            guard !refuseWhileBusy() else { return }
            let marked = state.markedRules
            let findings = rows.compactMap(\.finding).filter { marked.isEmpty ? $0.id == finding.id : marked.contains($0.id) }
            let plan = CleanupPlan.make(
                findings: findings.filter(\.isCleanable), trashPreference: context.trashPreference(for: .rule),
                created: state.scanStarted)
            let name = findings.count == 1 ? TerminalText.sanitize(findings[0].rule.name) : "\(findings.count) rules"
            confirmCleanup(plan, title: "Clean \(name)")
        case .character("n"):
            createJob(for: finding.rule)
        default:
            break
        }
    }

    func showFinding(_ finding: Finding) {
        let rule = finding.rule
        let clean = TerminalText.sanitize
        var lines: [String] = []
        if let description = rule.description { lines.append(clean(description)) }
        lines.append("")
        lines.append("Reclaimable: ".dim + ByteCount.format(finding.size).bold)
        lines.append("Risk: ".dim + rule.safety.level.badge)
        if let recreatedBy = rule.recreatedBy { lines.append("Recreated by: ".dim + clean(recreatedBy)) }
        if let used = finding.lastUsed { lines.append("Last used: ".dim + used.relativeDescription()) }
        lines.append("Items: ".dim + "\(finding.items.count)")
        lines.append("")
        for item in finding.items {
            let age = item.idleDays().map { "\($0)d" } ?? "–"
            lines.append(
                ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true) + "  " + ANSI.pad(age, to: 5, alignRight: true) + "  "
                    + clean(PathUtil.abbreviate(item.path)))
        }
        if let command = rule.action.command {
            lines.append("")
            lines.append("Cleans with: ".dim + clean(command.joined(separator: " ")))
        }
        if let manual = rule.action.manual {
            lines.append("")
            lines.append("How to clean: ".dim + clean(manual))
        }
        state.modal = Modal(title: clean(rule.name), lines: lines)
    }

    // MARK: AI

    func aiRows() -> [(tool: String, model: AIModel?)] {
        guard let report = state.aiReport else { return [] }
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
        let position = selectable.firstIndex(of: state.ai.selection) ?? 0
        func select(_ p: Int) { state.ai.selection = selectable[min(max(p, 0), selectable.count - 1)] }
        switch key {
        case .up, .character("k"): select(position - 1)
        case .down, .character("j"): select(position + 1)
        case .pageUp: select(position - 10)
        case .pageDown: select(position + 10)
        case .character("d"), .character("x"):
            guard !refuseWhileBusy(), let model = rows[selectable[position]].model else { return }
            guard let plan = CleanupPlan.removing(model, created: state.scanStarted) else {
                flash("\(TerminalText.sanitize(model.name)) can't be removed on its own; remove the models that use it")
                return
            }
            confirmCleanup(plan, title: "Remove \(TerminalText.sanitize(model.name))")
        default:
            break
        }
    }
}
