import CoreGraphics
import Foundation
import SpaceKitCore

extension TUIApp {
    func render() {
        let (width, height) = terminal.size
        let snapshot = state.read { $0 }
        var lines: [String] = []
        lines.append(headerLine(snapshot, width: width))
        lines.append(tabLine(snapshot, width: width))
        lines.append(String(repeating: "─", count: width).fg(238))

        let bodyHeight = max(1, height - lines.count - 2)
        var body: [String]
        switch snapshot.tab {
        case .explore: body = exploreView(snapshot, width: width, height: bodyHeight)
        case .dev: body = devView(snapshot, width: width, height: bodyHeight)
        case .ai: body = aiView(snapshot, width: width, height: bodyHeight)
        case .jobs: body = jobsView(snapshot, width: width, height: bodyHeight)
        case .history: body = historyView(snapshot, width: width, height: bodyHeight)
        }
        body = Array(body.prefix(bodyHeight))
        while body.count < bodyHeight { body.append("") }
        if let modal = snapshot.modal { body = overlay(modal, on: body, width: width) }
        lines += body
        lines.append(String(repeating: "─", count: width).fg(238))
        lines.append(footerLine(snapshot, width: width))

        let frame = lines.map { fit($0, width) }.joined(separator: "\r\n")
        terminal.write("\u{1B}[H" + frame + "\u{1B}[0m\u{1B}[J")
    }

    /// Pads or cuts a styled line to exactly `width` columns.
    func fit(_ line: String, _ width: Int) -> String {
        let w = ANSI.width(line)
        if w == width { return line + ANSI.reset }
        if w < width { return line + ANSI.reset + String(repeating: " ", count: width - w) }
        // Cut while keeping escape sequences intact.
        var result = ""
        var used = 0
        var inEscape = false
        for character in line {
            if inEscape {
                result.append(character)
                if character == "m" { inEscape = false }
                continue
            }
            if character == "\u{1B}" {
                inEscape = true
                result.append(character)
                continue
            }
            let cw = character.unicodeScalars.reduce(0) { $0 + ANSI.scalarWidth($1) }
            if used + cw > width { break }
            result.append(character)
            used += cw
        }
        return result + ANSI.reset + String(repeating: " ", count: max(0, width - used))
    }

    // MARK: Chrome

    func headerLine(_ s: State, width: Int) -> String {
        let title = " ◆ SpaceKit ".styled(Style(fg: 255, bg: 25, bold: true))
        let tagline = "  Understand your Mac. Automate the cleanup.".dim
        var right = ""
        if let capacity = s.tree?.capacity ?? VolumeCapacity.of(path: s.rootPath) {
            let fraction = capacity.usedFraction
            let color: UInt8 = fraction > 0.9 ? ANSI.protected : fraction > 0.75 ? ANSI.review : ANSI.accent
            right =
                "\(capacity.name)  " + "\(ByteCount.format(capacity.used)) / \(ByteCount.format(capacity.total))".bold
                + "  " + ANSI.bar(fraction: fraction, width: 16, color: color) + " "
        }
        let gap = max(1, width - ANSI.width(title) - ANSI.width(tagline) - ANSI.width(right))
        return title + tagline + String(repeating: " ", count: gap) + right
    }

    func tabLine(_ s: State, width: Int) -> String {
        var line = " "
        for tab in Tab.allCases {
            let label = " \(tab.rawValue + 1) \(tab.title) "
            line += tab == s.tab ? label.styled(Style(fg: 255, bg: 238, bold: true)) : label.dim
            line += " "
        }
        return line
    }

    func footerLine(_ s: State, width: Int) -> String {
        if let busy = s.busy { return " " + spinner() + " " + busy }
        if let flash = s.flash, Date() < s.flashUntil { return " " + flash.fg(ANSI.accent) }
        let hints: String
        switch s.tab {
        case .explore: hints = "↑↓ move  → open  ← up  t treemap  space mark  d clean  o reveal  r rescan  ? help  q quit"
        case .dev: hints = "↑↓ move  enter details  space mark  d clean  j make job  r refresh  ? help  q quit"
        case .ai: hints = "↑↓ move  d remove model  ? help  q quit"
        case .jobs: hints = "↑↓ move  e enable/disable  m mode  x run now  i install/remove agent  q quit"
        case .history: hints = "Tab switch view  q quit"
        }
        var right = ""
        if s.tab == .explore, !s.marked.isEmpty {
            let total = s.marked.values.reduce(0) { $0 + $1.size }
            right = "\(s.marked.count) marked · \(ByteCount.format(total)) ".fg(ANSI.review)
        }
        if s.tab == .dev, !s.markedRules.isEmpty { right = "\(s.markedRules.count) marked ".fg(ANSI.review) }
        let gap = max(1, width - ANSI.width(hints) - ANSI.width(right) - 1)
        return " " + hints.dim + String(repeating: " ", count: gap) + right
    }

    func spinner() -> String {
        let frames = Array("⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏")
        return String(frames[Int(Date().timeIntervalSince1970 * 10) % frames.count]).fg(ANSI.accent)
    }

    func progressView(_ progress: ScanProgress, title: String, width: Int, height: Int) -> [String] {
        let p = progress.snapshot
        var lines = Array(repeating: "", count: max(0, height / 3))
        lines.append("  " + spinner() + " " + title.bold)
        lines.append("")
        lines.append(
            "    " + "\(ByteCount.format(p.bytes))".bold.fg(ANSI.accent)
                + "   \(p.files.formatted()) files · \(p.directories.formatted()) folders")
        lines.append("    " + ANSI.truncateMiddle(PathUtil.abbreviate(p.currentPath), to: width - 8).dim)
        if p.errors > 0 {
            lines.append("")
            lines.append(
                "    " + "\(p.errors) locations unreadable — grant Full Disk Access to your terminal for a complete picture".fg(ANSI.review)
            )
        }
        if let root = progress.liveRoot, root.isListed {
            lines.append("")
            let children = root.children.filter(\.isListed).sorted { $0.liveSize > $1.liveSize }.prefix(max(0, height - lines.count - 2))
            let largest = children.first?.liveSize ?? 1
            for child in children where child.liveSize > 0 {
                lines.append(
                    "    " + ANSI.pad(ByteCount.format(child.liveSize), to: 9, alignRight: true) + "  "
                        + ANSI.bar(fraction: Double(child.liveSize) / Double(max(largest, 1)), width: 20, color: ANSI.accent) + "  "
                        + child.name)
            }
        }
        return lines
    }

    // MARK: Explore

    func exploreView(_ s: State, width: Int, height: Int) -> [String] {
        if let progress = s.scanProgress {
            return progressView(progress, title: "Scanning \(PathUtil.abbreviate(s.rootPath))…", width: width, height: height)
        }
        if let error = s.error { return ["", "  " + error.fg(ANSI.protected)] }
        guard let current = s.current, let tree = s.tree else { return [] }

        var lines: [String] = []
        let crumbs = current.path.isEmpty ? "Scan" : PathUtil.abbreviate(current.path)
        let info = "\(ByteCount.format(current.size))".bold + "  \(current.fileCount.formatted()) files".dim
        var label = ""
        if let rule = s.ruleIndex.rule(for: current.path) { label = "  " + rule.name.fg(ANSI.color(for: rule.safety.level)) }
        lines.append(" " + ANSI.truncateMiddle(crumbs, to: width / 2).bold + label + "   " + info)
        if tree.stats.errors > 0 && current === tree.root {
            lines.append(
                " "
                    + "\(tree.stats.errors) folders couldn't be read (privacy-protected). Grant Full Disk Access to see everything.".fg(
                        ANSI.review))
        }
        lines.append("")
        let available = height - lines.count
        if s.mapMode {
            return lines + treemapView(current, selection: s.selection, width: width, height: available)
        }
        return lines + listView(current, s: s, width: width, height: available)
    }

    func listView(_ current: DirNode, s: State, width: Int, height: Int) -> [String] {
        let items = current.items
        guard !items.isEmpty else { return ["   (empty)".dim] }
        var scroll = s.scroll
        if s.selection < scroll { scroll = s.selection }
        if s.selection >= scroll + height { scroll = s.selection - height + 1 }
        state.write { $0.scroll = scroll }

        let largest = Double(max(items.first?.size ?? 1, 1))
        let total = Double(max(current.size, 1))
        let barWidth = max(8, min(30, width / 5))
        let nameWidth = max(12, width - barWidth - 46)
        var lines: [String] = []
        for index in scroll..<min(items.count, scroll + height) {
            let item = items[index]
            let selected = index == s.selection
            let path = item.path ?? ""
            let marked = s.marked[path] != nil
            let marker = marked ? "◉".fg(ANSI.review) : " "
            let glyph = item.isDirectory ? "▸" : " "
            var name = item.name + (item.isDirectory ? "/" : "")
            if case .otherFiles = item { name = item.name }
            let size = ANSI.pad(ByteCount.format(item.size), to: 9, alignRight: true)
            let percent = ANSI.pad(String(format: "%.0f%%", Double(item.size) / total * 100), to: 4, alignRight: true)
            let color = ANSI.branches[index % ANSI.branches.count]
            let bar = ANSI.bar(fraction: Double(item.size) / largest, width: barWidth, color: color)
            var annotation = ""
            if let directory = item.directory {
                if directory.flags.contains(.unreadable) {
                    annotation = "no access".fg(ANSI.review)
                } else if directory.flags.contains(.firmlinkDuplicate) {
                    annotation = "same as /\(directory.name)".dim
                } else if directory.flags.contains(.otherVolume) {
                    annotation = "other volume".dim
                }
            }
            if annotation.isEmpty, !path.isEmpty, let rule = s.ruleIndex.rule(for: path) {
                annotation = rule.safety.level.badge + " " + rule.name.dim
            }
            let row =
                " \(marker) \(glyph) " + ANSI.pad(ANSI.truncate(name, to: nameWidth), to: nameWidth) + " \(size)  \(bar) \(percent)  "
                + annotation
            lines.append(selected ? row.styled(Style(bg: 237)) + Style(bg: 237).sequence : row)
        }
        return lines
    }

    /// Squarified treemap drawn with colored cells. Terminal cells are about twice as tall as wide,
    /// so the layout runs in a space with doubled height to keep cells visually square.
    func treemapView(_ node: DirNode, selection: Int, width: Int, height: Int) -> [String] {
        guard height > 2, width > 10 else { return [] }
        let cells = Treemap.layout(
            node, in: CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height * 2)),
            maxDepth: 2, minCellArea: 6, padding: 0)
        var grid = Array(
            repeating: Array(repeating: (character: Character(" "), fg: UInt8(255), bg: UInt8(235)), count: width), count: height)
        let items = node.items
        let selectedID = items.indices.contains(selection) ? MapItem.item(items[selection]).id : nil
        let shades: [[UInt8]] = [
            [25, 31], [30, 37], [28, 34], [136, 178], [130, 166], [125, 162], [54, 92], [60, 67], [100, 142], [95, 132], [23, 29],
            [94, 137],
        ]

        for cell in cells {
            let x0 = Int(cell.rect.minX.rounded())
            let x1 = Int(cell.rect.maxX.rounded())
            let y0 = Int((cell.rect.minY / 2).rounded())
            let y1 = Int((cell.rect.maxY / 2).rounded())
            guard x1 > x0, y1 > y0 else { continue }
            let palette = shades[max(0, cell.branch) % shades.count]
            var bg = cell.depth == 0 ? palette[0] : palette[(abs(cell.id.hashValue) % 2)]
            if case .remainder = cell.item { bg = 239 }
            let isSelected = cell.depth == 0 && cell.id == selectedID
            if isSelected { bg = 250 }
            for y in max(0, y0)..<min(height, y1) {
                for x in max(0, x0)..<min(width, x1) {
                    grid[y][x] = (" ", isSelected ? 232 : 255, bg)
                }
            }
            // Label at the top-left of cells that have room.
            if cell.depth == 0 || (x1 - x0 >= 10 && y1 - y0 >= 2) {
                let label = Array(" \(cell.item.name) \(ByteCount.format(cell.item.size))")
                let row = max(0, min(height - 1, y0))
                for (offset, character) in label.prefix(max(0, x1 - x0 - 1)).enumerated() where x0 + offset < width {
                    grid[row][x0 + offset].character = character
                }
            }
            // Thin separators between top-level cells.
            if cell.depth == 0 {
                for y in max(0, y0)..<min(height, y1) where x0 > 0 && x0 < width {
                    if grid[y][x0].character == " " {
                        grid[y][x0].character = "▏"
                        grid[y][x0].fg = 235
                    }
                }
            }
        }
        return grid.map { row in
            var line = ""
            var last: (UInt8, UInt8)?
            for cell in row {
                if last == nil || last! != (cell.fg, cell.bg) {
                    line += ANSI.enabled ? Style(fg: cell.fg, bg: cell.bg).sequence : ""
                    last = (cell.fg, cell.bg)
                }
                line.append(cell.character)
            }
            return line + ANSI.reset
        }
    }

    // MARK: Dev Intelligence

    func devView(_ s: State, width: Int, height: Int) -> [String] {
        if s.tree == nil {
            if let progress = s.scanProgress { return progressView(progress, title: "Scanning…", width: width, height: height) }
            return ["", "  Waiting for the scan…".dim]
        }
        if let progress = s.analysisProgress {
            return progressView(progress, title: "Looking for developer storage…", width: width, height: height)
        }
        guard let analysis = s.analysis else { return ["", "  Press r to analyse.".dim] }
        let rows = devRows()
        guard !rows.isEmpty else { return ["", "  Nothing recognised. Rules live in rules/ and ~/.config/spacekit/rules.".dim] }

        var lines: [String] = []
        let safe = analysis.total(.safe)
        let review = analysis.total(.review)
        lines.append(
            "  " + "Regenerable \(ByteCount.format(safe))".fg(ANSI.safe).bold + "   " + "Review \(ByteCount.format(review))".fg(ANSI.review)
                + "   " + "Don't touch \(ByteCount.format(analysis.total(.protected)))".fg(ANSI.protected))
        lines.append("")
        let available = height - lines.count - 5
        var scroll = s.devScroll
        if s.devSelection < scroll { scroll = s.devSelection }
        if s.devSelection >= scroll + available { scroll = s.devSelection - available + 1 }
        state.write { $0.devScroll = scroll }

        let nameWidth = max(16, min(36, width - 70))
        for index in scroll..<min(rows.count, scroll + max(1, available)) {
            let row = rows[index]
            guard let finding = row.finding else {
                lines.append(" " + row.group.bold)
                continue
            }
            let selected = index == s.devSelection
            let mark = s.markedRules.contains(finding.id) ? "◉".fg(ANSI.review) : " "
            let dot = "●".fg(ANSI.color(for: finding.safety))
            let name = ANSI.pad(ANSI.truncate(finding.rule.name, to: nameWidth), to: nameWidth)
            let group = ANSI.pad(ANSI.truncate(finding.rule.group, to: 14), to: 14).dim
            let size = ANSI.pad(ByteCount.format(finding.size), to: 9, alignRight: true).bold
            let count = ANSI.pad("\(finding.items.count) item\(finding.items.count == 1 ? "" : "s")", to: 10, alignRight: true).dim
            let used = finding.lastUsed.map { "used " + $0.relativeDescription() } ?? ""
            let line = "  \(mark) \(dot) \(name) \(group) \(size) \(count)  " + used.dim
            lines.append(selected ? line.styled(Style(bg: 237)) + Style(bg: 237).sequence : line)
        }
        if let finding = rows.indices.contains(s.devSelection) ? rows[s.devSelection].finding : nil {
            lines.append("")
            lines.append(" " + finding.rule.name.bold + " — " + ByteCount.format(finding.size).bold + "  " + finding.safety.badge)
            if let description = finding.rule.description { lines.append(" " + ANSI.truncate(description, to: width - 2).dim) }
            var facts: [String] = ["Risk: \(finding.safety.risk)"]
            if let recreated = finding.rule.recreatedBy { facts.append("Recreated by: \(recreated)") }
            if let used = finding.lastUsed { facts.append("Last used: \(used.relativeDescription())") }
            lines.append(" " + facts.joined(separator: "  ·  ").dim)
        }
        return lines
    }

    // MARK: AI

    func aiView(_ s: State, width: Int, height: Int) -> [String] {
        if let progress = s.analysisProgress {
            return progressView(progress, title: "Looking for local AI storage…", width: width, height: height)
        }
        guard let report = s.aiReport else { return ["", "  Waiting for the scan…".dim] }
        guard report.total > 0 else { return ["", "  No local AI models found (Ollama, Hugging Face, LM Studio, …).".dim] }
        var lines: [String] = []
        lines.append("  " + "LOCAL AI".bold + "   " + ByteCount.format(report.total).bold.fg(ANSI.accent))
        lines.append(
            "  " + "Potentially reclaimable \(ByteCount.format(report.reclaimable()))".fg(ANSI.safe)
                + "   " + "Active (\(Int(report.activeWindow.days))d) \(ByteCount.format(report.active()))".dim
                + "   " + "Unused \(Int(report.activeWindow.days))+ days \(ByteCount.format(report.unused()))".fg(ANSI.review))
        lines.append("")
        let rows = aiRows()
        let available = height - lines.count
        var scroll = s.aiScroll
        if s.aiSelection < scroll { scroll = s.aiSelection }
        if s.aiSelection >= scroll + available { scroll = s.aiSelection - available + 1 }
        state.write { $0.aiScroll = scroll }
        let tools = Dictionary(report.tools.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        for index in scroll..<min(rows.count, scroll + max(1, available)) {
            let row = rows[index]
            guard let model = row.model else {
                lines.append(" " + ANSI.pad(row.tool.bold, to: 40) + ByteCount.format(tools[row.tool]?.size ?? 0).bold)
                continue
            }
            let active = model.isActive(within: report.activeWindow)
            let status =
                model.kind == .orphaned
                ? "orphaned".fg(ANSI.review)
                : model.kind == .cache
                    ? "cache".dim
                    : active ? "active".fg(ANSI.safe) : "idle".fg(ANSI.review)
            let used = model.lastUsed.map { $0.relativeDescription() } ?? "–"
            let line =
                "   ├ " + ANSI.pad(ANSI.truncate(model.name, to: 40), to: 40)
                + ANSI.pad(ByteCount.format(model.size), to: 9, alignRight: true)
                + "  " + ANSI.pad(status, to: 9) + "  " + used.dim
            lines.append(index == s.aiSelection ? line.styled(Style(bg: 237)) + Style(bg: 237).sequence : line)
        }
        return lines
    }

    // MARK: Automation

    func jobsView(_ s: State, width: Int, height: Int) -> [String] {
        let context = self.context
        let journal = context.journal
        let recovered = journal.recovered(since: Date().addingTimeInterval(-90 * 86_400))
        let runner = JobRunner(context: context)
        let states = context.jobStates.load()
        let next = Dictionary(runner.nextRuns().map { ($0.job.id, $0.date) }, uniquingKeysWith: { a, _ in a })
        let agent = LaunchAgent(paths: context.paths).status()

        var lines: [String] = []
        lines.append(
            "  " + "AUTOMATIC CLEANUP".bold + "    Your Mac has recovered " + ByteCount.format(recovered).bold.fg(ANSI.safe)
                + " over the last 3 months.")
        let agentText =
            agent.loaded
            ? "● Background agent running".fg(ANSI.safe)
            : agent.installed
                ? "● Agent installed, not loaded".fg(ANSI.review)
                : "○ Background agent not installed — press i".fg(ANSI.review)
        lines.append("  " + agentText)
        if let error = context.configError { lines.append("  " + "Config error: \(error)".fg(ANSI.protected)) }
        lines.append("")
        guard !context.config.jobs.isEmpty else {
            return lines + ["  No jobs yet. Create one from Dev Intelligence (j), or run: spacekit jobs add".dim]
        }
        for (index, job) in context.config.jobs.enumerated() {
            let selected = index == s.jobSelection
            let toggle = job.enabled ? "ON ●".fg(ANSI.safe) : "OFF ○".dim
            let mode = ANSI.pad(job.mode.title, to: 10).fg(job.mode == .automatic ? ANSI.accent : 250)
            let nextText = job.enabled ? (next[job.id].map { "next " + $0.relativeDescription() } ?? "") : ""
            var title =
                " " + ANSI.pad(job.name.bold, to: 34) + mode + ANSI.pad(job.schedule.description, to: 27) + ANSI.pad(nextText.dim, to: 18)
                + toggle
            if selected { title = title.styled(Style(bg: 237)) + Style(bg: 237).sequence }
            lines.append(title)
            var detail = "   " + job.conditionSummary.dim
            if let last = states[job.id]?.lastOutcome { detail += "   last: ".dim + last }
            lines.append(detail)
            lines.append("")
        }
        let estimate = runner.estimatedRecovery(states: states)
        if let first = runner.nextRuns().first {
            lines.append(
                "  Next automatic cleanup: " + first.date.formatted(date: .abbreviated, time: .shortened).bold
                    + (estimate.high > 0
                        ? "   Estimated recovery: \(ByteCount.format(estimate.low))–\(ByteCount.format(estimate.high))".dim : ""))
        }
        return lines
    }

    // MARK: History

    func historyView(_ s: State, width: Int, height: Int) -> [String] {
        let history = context.history
        let days = history.dailyUsage(days: 120)
        var lines: [String] = []
        lines.append("  " + "YOUR DISK".bold)
        guard days.count >= 2 else {
            return lines + [
                "", "  History builds up as SpaceKit runs. The background agent records usage every few hours.".dim,
                "  Install it from the Automation view (i) or with: spacekit agent install".dim,
            ]
        }
        let values = days.map { Double($0.used) }
        let chartWidth = min(width - 14, values.count * 2)
        let resampled = (0..<chartWidth).map { values[min(values.count - 1, $0 * values.count / max(chartWidth, 1))] }
        let rows = min(10, height - 12)
        let low = (values.min() ?? 0) * 0.98
        let high = values.max() ?? 1
        for row in (0..<rows).reversed() {
            let threshold = low + (high - low) * Double(row) / Double(max(rows - 1, 1))
            let label =
                row == rows - 1 || row == 0
                ? ANSI.pad(ByteCount.format(UInt64(threshold)), to: 9, alignRight: true) : String(repeating: " ", count: 9)
            let bar = resampled.map { $0 >= threshold ? "█" : " " }.joined()
            lines.append("  " + label.dim + " │".dim + bar.fg(ANSI.accent))
        }
        lines.append("  " + String(repeating: " ", count: 9) + " └".dim + String(repeating: "─", count: chartWidth).dim)
        if let first = days.first?.date, let last = days.last?.date {
            let left = first.formatted(.dateTime.month(.abbreviated).day())
            let right = last.formatted(.dateTime.month(.abbreviated).day())
            lines.append(
                "  " + String(repeating: " ", count: 11) + left.dim
                    + String(repeating: " ", count: max(1, chartWidth - left.count - right.count)) + right.dim)
        }
        lines.append("")
        if let month = history.usedDelta(over: 30 * 86_400) {
            let text = ByteCount.formatDelta(month) + " this month"
            lines.append("  " + (month > 0 ? text.fg(ANSI.review) : text.fg(ANSI.safe)).bold)
        }
        let grew = history.whatGrew(over: 90 * 86_400)
        if !grew.isEmpty {
            lines.append("")
            lines.append("  " + "WHAT GREW?".bold)
            for item in grew.prefix(max(0, height - lines.count - 1)) {
                lines.append(
                    "  " + ANSI.pad(item.name, to: 28)
                        + ANSI.pad(ByteCount.formatDelta(item.delta), to: 10, alignRight: true).fg(item.delta > 0 ? ANSI.review : ANSI.safe)
                )
            }
        }
        return lines
    }

    // MARK: Modal

    func overlay(_ modal: Modal, on body: [String], width: Int) -> [String] {
        let boxWidth = min(width - 4, max(50, (modal.lines.map(ANSI.width).max() ?? 40) + 6))
        let inner = boxWidth - 4
        var box: [String] = []
        box.append("╭─ " + modal.title.bold + " " + String(repeating: "─", count: max(0, boxWidth - ANSI.width(modal.title) - 5)) + "╮")
        let maxLines = max(3, body.count - 4)
        for line in modal.lines.prefix(maxLines) {
            box.append("│ " + fit(ANSI.width(line) > inner ? ANSI.truncate(line, to: inner) : line, inner) + " │")
        }
        if modal.lines.count > maxLines { box.append("│ " + fit("… \(modal.lines.count - maxLines) more".dim, inner) + " │") }
        let hint = modal.onConfirm == nil ? "any key to close" : modal.confirmLabel
        box.append("│ " + fit("", inner) + " │")
        box.append("│ " + fit(hint.fg(ANSI.accent), inner) + " │")
        box.append("╰" + String(repeating: "─", count: boxWidth - 2) + "╯")
        var result = body
        let top = max(0, (body.count - box.count) / 2)
        let left = max(0, (width - boxWidth) / 2)
        for (offset, line) in box.enumerated() where top + offset < result.count {
            result[top + offset] = String(repeating: " ", count: left) + line.styled(Style(bg: 235)) + Style(bg: 235).sequence
        }
        return result
    }
}
