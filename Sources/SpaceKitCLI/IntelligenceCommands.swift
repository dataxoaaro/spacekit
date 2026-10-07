import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

/// Shared rule-selection options.
struct RuleSelection: ParsableArguments {
    @Option(name: .customLong("rule"), help: "Only this rule id (repeatable).")
    var rules: [String] = []
    @Option(name: .long, help: "Only rules in this category prefix (e.g. developer, ai, cache).")
    var category: String?
    @Option(name: .long, help: "Only rules with this safety level: safe, review or protected.")
    var safety: String?

    func select(from library: RuleLibrary) throws -> [Rule] {
        var selected = library.rules
        if !rules.isEmpty {
            selected = try rules.map { id in
                guard let rule = library.rule(id: id) else {
                    throw ValidationError("Unknown rule '\(id)'. See `spacekit rules list`.")
                }
                return rule
            }
        }
        if let category { selected = selected.filter { $0.category == category || $0.category.hasPrefix(category + ".") } }
        if let safety {
            guard let level = SafetyLevel(alias: safety) else { throw ValidationError("Safety must be safe, review or protected") }
            selected = selected.filter { $0.safety.level == level }
        }
        return selected
    }
}

struct DevCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev",
        abstract: "Dev Intelligence: developer storage on this Mac, and what's actually safe to remove."
    )

    @OptionGroup var global: GlobalOptions
    @OptionGroup var selection: RuleSelection
    @Option(name: .long, help: "Items to list per rule (0 = none).")
    var items: Int = 0
    @Flag(name: .long, help: "Machine-readable output.")
    var json = false

    func run() throws {
        let context = global.loadContext()
        let rules = try selection.select(from: context.library)
        let analysis = try ProgressReporter.run("Analysing") { try context.analyzer.analyzeSync(rules: rules, progress: $0) }
        if selection.rules.isEmpty && selection.safety == nil {
            try? context.history.recordSnapshot(analysis: analysis)
        }
        if json {
            try Output.json(analysis.findings.map(FindingJSON.init))
            return
        }
        if analysis.findings.isEmpty {
            Output.print("Nothing found for these rules.")
            return
        }
        if selection.rules.count == 1, let finding = analysis.findings.first {
            printDetail(finding)
            return
        }
        Output.print(
            "DEV INTELLIGENCE".bold
                + "  ·  scanned \(analysis.tree.stats.files.formatted()) files in \(String(format: "%.1f", analysis.tree.stats.duration))s"
                .dim)
        for level in SafetyLevel.allCases {
            let findings = analysis.findings(level)
            guard !findings.isEmpty else { continue }
            Output.print()
            Output.print(level.heading.bold.fg(ANSI.color(for: level)) + " · " + ByteCount.format(analysis.total(level)).bold)
            for finding in findings {
                let used = finding.lastUsed.map { "used " + $0.relativeDescription() } ?? ""
                let count = "\(finding.items.count) item\(finding.items.count == 1 ? "" : "s")"
                Output.print(
                    "  " + ANSI.pad(finding.rule.name, to: 34) + ANSI.pad(finding.rule.group.dim, to: 18) + Output.size(finding.size).bold
                        + "  " + ANSI.pad(count.dim, to: 12) + used.dim)
                if items > 0 {
                    for item in finding.items.prefix(items) {
                        Output.print(
                            "      " + Output.size(item.size) + "  " + PathUtil.abbreviate(item.path).dim
                                + (item.idleDays().map { "  \($0)d idle".dim } ?? ""))
                    }
                }
            }
        }
        Output.print()
        let safe = analysis.total(.safe)
        if safe > 0 {
            Output.print("Regenerable data you can reclaim: " + ByteCount.format(safe).bold.fg(ANSI.safe))
            Output.print(
                "Preview a cleanup:  ".dim + "spacekit clean --safety safe".bold + "    Details:  ".dim
                    + "spacekit dev --rule <id> --items 20".bold)
        }
    }

    private func printDetail(_ finding: Finding) {
        let rule = finding.rule
        Output.print(rule.name.bold + " — " + ByteCount.format(finding.size).bold)
        Output.print()
        if let description = rule.description { Output.print(description) }
        if rule.granularity == .children || rule.isPattern {
            Output.print("\(finding.items.count) item\(finding.items.count == 1 ? "" : "s").".dim)
        }
        Output.print()
        let reclaimable = finding.isCleanable ? ByteCount.format(finding.size) : "—"
        Output.print("  Reclaimable:   ".dim + reclaimable.bold)
        Output.print("  Risk:          ".dim + rule.safety.level.risk + "  " + rule.safety.level.badge)
        if let recreatedBy = rule.recreatedBy { Output.print("  Recreated by:  ".dim + recreatedBy) }
        if let used = finding.lastUsed { Output.print("  Last used:     ".dim + used.relativeDescription()) }
        if let command = rule.action.command { Output.print("  Cleans with:   ".dim + command.joined(separator: " ")) }
        if let manual = rule.action.manual { Output.print("  How to clean:  ".dim + manual) }
        Output.print()
        for item in finding.items.prefix(max(items, 15)) {
            Output.print(
                "  " + Output.size(item.size) + "  " + ANSI.pad((item.idleDays().map { "\($0)d" } ?? "–").dim, to: 6, alignRight: true)
                    + "  " + PathUtil.abbreviate(item.path))
        }
        if finding.items.count > max(items, 15) { Output.print("  … \(finding.items.count - max(items, 15)) more".dim) }
        if finding.isCleanable {
            Output.print()
            Output.print("Clean \(ByteCount.format(finding.size)):  ".dim + "spacekit clean \(rule.id)".bold)
        }
    }
}

struct FindingJSON: Encodable {
    var rule: String
    var name: String
    var group: String
    var category: String
    var safety: String
    var bytes: UInt64
    var lastUsed: Date?
    var items: [FindingItem]

    init(_ finding: Finding) {
        rule = finding.rule.id
        name = finding.rule.name
        group = finding.rule.group
        category = finding.rule.category
        safety = finding.safety.rawValue
        bytes = finding.size
        lastUsed = finding.lastUsed
        items = finding.items
    }
}

struct AICommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ai",
        abstract: "AI Development storage: local models, hubs and caches, and how much is idle."
    )

    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Machine-readable output.")
    var json = false

    func run() throws {
        let context = global.loadContext()
        let rules = context.library.rules.filter { $0.ai != nil }
        let analysis = try ProgressReporter.run("Looking for local AI storage") {
            try context.analyzer.analyzeSync(rules: rules, progress: $0)
        }
        let report = AIInspector.report(
            findings: analysis.findings, tree: analysis.tree, activeWindow: context.config.automation.activeModelWindow)
        if json {
            try Output.json(AIJSON(report))
            return
        }
        guard report.total > 0 else {
            Output.print("No local AI storage found (Ollama, Hugging Face, LM Studio, PyTorch, Whisper, …).")
            return
        }
        let days = Int(report.activeWindow.days)
        Output.print("LOCAL AI".bold + String(repeating: " ", count: 34) + ByteCount.format(report.total).bold)
        Output.print()
        for tool in report.tools {
            Output.print(ANSI.pad(tool.name.bold, to: 42) + Output.size(tool.size).bold)
            for (index, model) in tool.models.enumerated() {
                let branch = index == tool.models.count - 1 ? "└ " : "├ "
                let state: String
                switch model.kind {
                case .orphaned: state = "orphaned".fg(ANSI.review)
                case .cache: state = "cache".dim
                default: state = model.isActive(within: report.activeWindow) ? "active".fg(ANSI.safe) : "idle".fg(ANSI.review)
                }
                let used = model.lastUsed.map { $0.relativeDescription() } ?? ""
                Output.print(
                    branch.dim + ANSI.pad(ANSI.truncate(model.name, to: 38), to: 40) + Output.size(model.size) + "  "
                        + ANSI.pad(state, to: 9) + " " + used.dim)
            }
            Output.print()
        }
        Output.print("AI storage".bold + "                                " + ByteCount.format(report.total).bold)
        Output.print("Potentially reclaimable".fg(ANSI.safe) + "                   " + ByteCount.format(report.reclaimable()))
        Output.print("Models you're actively using".dim + "              " + ByteCount.format(report.active()))
        Output.print("Unused for \(days)+ days".fg(ANSI.review) + "                    " + ByteCount.format(report.unused()))
        Output.print()
        Output.print("Remove an Ollama model with `ollama rm <name>`; other models from the TUI's AI view (spacekit tui).".dim)
    }
}

struct AIJSON: Encodable {
    struct Model: Encodable {
        var name: String
        var kind: String
        var bytes: UInt64
        var lastUsed: Date?
        var active: Bool
        var paths: [String]
        var removeCommand: [String]?
    }
    struct Tool: Encodable {
        var name: String
        var bytes: UInt64
        var models: [Model]
    }
    var total: UInt64
    var reclaimable: UInt64
    var active: UInt64
    var unused: UInt64
    var activeWindowDays: Int
    var tools: [Tool]

    init(_ report: AIReport) {
        total = report.total
        reclaimable = report.reclaimable()
        active = report.active()
        unused = report.unused()
        activeWindowDays = Int(report.activeWindow.days)
        tools = report.tools.map { tool in
            Tool(
                name: tool.name, bytes: tool.size,
                models: tool.models.map {
                    Model(
                        name: $0.name, kind: $0.kind.rawValue, bytes: $0.size, lastUsed: $0.lastUsed,
                        active: $0.isActive(within: report.activeWindow), paths: $0.paths, removeCommand: $0.removeCommand)
                })
        }
    }
}

struct CleanCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clean",
        abstract: "Preview and run a cleanup by rule id or path. Previews by default; add --yes to clean.",
        discussion: """
            Examples:
              spacekit clean xcode.derived-data --keep-recent 14d
              spacekit clean node.node-modules --older-than 60d
              spacekit clean --safety safe                 everything regenerable
              spacekit clean ~/Downloads/old-vm.utm        a specific path (asks for confirmation)

            Removed items go to the Trash unless your config sets safety.trash: rules and the rule allows deletion,
            or you pass --permanent. Every item is checked by the safety guard; blocked items are listed and skipped.
            """
    )

    @OptionGroup var global: GlobalOptions
    @Argument(help: "Rule ids or paths.")
    var targets: [String] = []
    @Option(name: .long, help: "Only rules with this safety level: safe or review.")
    var safety: String?
    @Option(name: .long, help: "Only items unused for at least this long (e.g. 60d).")
    var olderThan: String?
    @Option(name: .long, help: "Keep items used within this window (e.g. 14d).")
    var keepRecent: String?
    @Flag(name: .long, help: "Delete permanently instead of moving to the Trash.")
    var permanent = false
    @Flag(name: [.short, .long], help: "Clean without asking (otherwise preview, then ask on a terminal).")
    var yes = false
    @Flag(name: .long, help: "Machine-readable plan/result.")
    var json = false

    func run() throws {
        let context = global.loadContext()
        guard !targets.isEmpty || safety != nil else {
            throw ValidationError("Name rule ids or paths to clean, or use --safety safe. See `spacekit dev`.")
        }
        let olderThanAge = try olderThan.map { try parseAge($0) }
        let keepRecentAge = try keepRecent.map { try parseAge($0) }

        var rules: [Rule] = []
        var paths: [String] = []
        for target in targets {
            if let rule = context.library.rule(id: target) {
                rules.append(rule)
            } else if target.hasPrefix("/") || target.hasPrefix("~") || target.hasPrefix(".")
                || FileManager.default.fileExists(atPath: target)
            {
                paths.append(PathUtil.expand(target))
            } else {
                throw ValidationError("'\(target)' is neither a rule id nor an existing path. See `spacekit rules list`.")
            }
        }
        if let safety {
            guard let level = SafetyLevel(alias: safety), level != .protected else {
                throw ValidationError("--safety must be safe or review")
            }
            rules += context.library.rules.filter { $0.safety.level == level && $0.action.isCleanable && !rules.contains($0) }
        }

        var plan = CleanupPlan(useTrash: true)
        if !rules.isEmpty {
            let analysis = try ProgressReporter.run("Analysing") { try context.analyzer.analyzeSync(rules: rules, progress: $0) }
            plan = CleanupPlan.make(
                findings: analysis.findings.filter(\.isCleanable),
                trashPreference: permanent ? false : context.trashPreference(for: .rule)
            ) { finding in
                finding.eligibleItems(olderThan: olderThanAge, keepRecent: keepRecentAge)
            }
            for finding in analysis.findings where !finding.isCleanable {
                Output.warn("\(finding.rule.name) is report-only" + (finding.rule.action.manual.map { ": \($0)" } ?? ""))
            }
        }
        if !paths.isEmpty {
            var options = context.scanOptions
            options.minFileSize = .max
            let index = RuleIndex(rules: context.library.rules)
            for path in paths {
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
                    throw ValidationError("No such file or folder: \(path)")
                }
                // Ask the guard before measuring, so `clean /` doesn't scan the whole disk just to refuse.
                let rule = index.rule(for: path)
                let early = context.safetyGuard.evaluate(path: path, rule: rule, context: .manual(confirmed: false))
                var size: UInt64 = 0
                var repository = false
                var containsRepository = false
                if early.isBlocked {
                    plan.items.append(CleanupItem(path: path, kind: isDirectory.boolValue ? .directory : .file, size: 0, ruleID: rule?.id))
                    continue
                }
                if isDirectory.boolValue, let tree = try? Scanner(options: options).scan(path) {
                    size = tree.root.size
                    let git = tree.markers.bit(for: ".git")
                    repository = tree.root.markers & git != 0
                    containsRepository = tree.root.subtreeMarkers & git != 0
                } else {
                    var st = stat()
                    if lstat(path, &st) == 0 { size = UInt64(max(0, st.st_blocks)) * 512 }
                }
                plan.items.append(
                    CleanupItem(
                        path: path, kind: isDirectory.boolValue ? .directory : .file, size: size,
                        ruleID: rule?.id, isRepository: repository, containsRepository: containsRepository))
            }
        }
        if permanent { plan.useTrash = false } else if context.config.safety.trash == .always { plan.useTrash = true }

        guard !plan.isEmpty || !plan.manualSteps.isEmpty else {
            Output.print("Nothing to clean.")
            return
        }
        let executor = context.executor
        let preview = executor.execute(plan, context: .manual(confirmed: true), dryRun: true)
        if json && !yes {
            try Output.json(PlanJSON(plan: plan, executor: executor))
            return
        }
        printPlan(plan, executor: executor)
        guard preview.wouldFreeBytes > 0 || !plan.commands.isEmpty else { return }

        let fileBytes =
            plan.items.isEmpty
            ? ""
            : ByteCount.format(
                preview.items.reduce(0) { total, entry in
                    if case .wouldRemove(let bytes) = entry.outcome { return total + bytes }
                    return total
                }) + (plan.useTrash ? " to the Trash" : " permanently")
        let question = [
            fileBytes, plan.commands.isEmpty ? "" : "run \(plan.commands.count) tool command\(plan.commands.count == 1 ? "" : "s")",
        ]
        .filter { !$0.isEmpty }.joined(separator: " and ")
        let proceed = yes || Output.confirm("\nClean \(question)?")
        guard proceed else {
            Output.print("\nPreview only. Run again with --yes to clean.".dim)
            return
        }
        let report = executor.execute(plan, context: .manual(confirmed: true), dryRun: false)
        if json {
            try Output.json(["freedBytes": report.freedBytes])
            return
        }
        Output.print()
        Output.print(report.summary.bold.fg(ANSI.safe))
        if report.trashedBytes > 0 {
            Output.print("Items in the Trash still use disk space until it's emptied: ".dim + "spacekit trash --empty".bold)
        }
        for (item, reason) in report.failures { Output.print("  ✗ ".fg(ANSI.protected) + PathUtil.abbreviate(item.path) + ": " + reason) }
        for (command, outcome, output) in report.commands {
            if case .failed(let reason) = outcome {
                Output.print("  ✗ ".fg(ANSI.protected) + command.displayString + ": " + reason)
                if !output.isEmpty { Output.print(output.split(separator: "\n").suffix(5).map { "    " + $0 }.joined(separator: "\n").dim) }
            }
        }
    }

    private func printPlan(_ plan: CleanupPlan, executor: CleanupExecutor) {
        Output.heading("Cleanup preview")
        for item in plan.items.sorted(by: { $0.size > $1.size }) {
            let verdict = executor.verdict(for: item, context: .manual(confirmed: false))
            let symbol: String
            switch verdict.decision {
            case .allow: symbol = "✓".fg(ANSI.safe)
            case .confirm: symbol = "!".fg(ANSI.review)
            case .block: symbol = "✗".fg(ANSI.protected)
            }
            let label = item.kind == .looseFiles ? "files in " + PathUtil.abbreviate(item.path) : PathUtil.abbreviate(item.path)
            Output.print("  \(symbol) " + Output.size(item.size) + "  " + label)
            for reason in verdict.reasons where verdict.decision != .allow {
                Output.print("        " + (verdict.decision == .block ? "Blocked: \(reason)".fg(ANSI.protected) : reason.fg(ANSI.review)))
            }
        }
        for command in plan.commands {
            Output.print(
                "  $ ".fg(ANSI.accent) + command.displayString + "  "
                    + "(frees up to \(ByteCount.format(command.estimatedBytes)); the tool decides what's unused)".dim)
        }
        for step in plan.manualSteps { Output.print("  → ".dim + step) }
    }
}

struct PlanJSON: Encodable {
    struct Item: Encodable {
        var path: String
        var kind: String
        var bytes: UInt64
        var rule: String?
        var decision: String
        var reasons: [String]
    }
    var useTrash: Bool
    var totalBytes: UInt64
    var items: [Item]
    var commands: [[String]]
    var manualSteps: [String]

    init(plan: CleanupPlan, executor: CleanupExecutor) {
        useTrash = plan.useTrash
        totalBytes = plan.totalBytes
        items = plan.items.map { item in
            let verdict = executor.verdict(for: item, context: .manual(confirmed: false))
            let decision = verdict.decision == .allow ? "allow" : verdict.decision == .confirm ? "confirm" : "block"
            return Item(
                path: item.path, kind: item.kind.rawValue, bytes: item.size, rule: item.ruleID, decision: decision, reasons: verdict.reasons
            )
        }
        commands = plan.commands.map(\.arguments)
        manualSteps = plan.manualSteps
    }
}

func parseAge(_ text: String) throws -> Age {
    guard let age = Age.parse(text) else { throw ValidationError("Invalid age '\(text)'. Use values like 14d, 2w, 3mo.") }
    return age
}

func parseSize(_ text: String) throws -> ByteCount {
    guard let size = ByteCount.parse(text) else { throw ValidationError("Invalid size '\(text)'. Use values like 500MB, 30GB.") }
    return size
}
