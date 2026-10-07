import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

/// `--yes` and `--accept-warnings`, the go-ahead of every command that removes things.
struct AcknowledgementOptions: ParsableArguments {
    @Flag(
        name: [.short, .long],
        help: "Go ahead without asking. Only what the guard allows outright runs unless you add --accept-warnings.")
    var yes = false
    @Flag(name: .long, help: "With --yes, also remove the items whose warnings the preview printed.")
    var acceptWarnings = false

    func validate() throws {
        if acceptWarnings && !yes { throw ValidationError("--accept-warnings goes with --yes.") }
    }
}

/// How every command that removes things shows its plan and its result.
enum CleanupOutput {
    /// The review as the preview prints it: every row with every one of the guard's reasons, so the warnings a
    /// person accepts are exactly the ones on screen.
    static func planLines(_ review: CleanupReview) -> [String] {
        planLines(
            items: review.items.map { ($0.subject, $0.verdict) }, commands: review.commands.map { ($0.subject, $0.verdict) },
            manualSteps: review.manualSteps)
    }

    /// The plan with the verdicts `context` gets, such as an automatic run's (`jobs show`).
    static func planLines(_ plan: CleanupPlan, executor: CleanupExecutor, context: CleanupContext, limit: Int) -> [String] {
        planLines(
            items: plan.itemsLargestFirst.map { ($0, executor.verdict(for: $0, context: context)) },
            commands: plan.commands.map { ($0, executor.verdict(for: $0, context: context)) }, manualSteps: plan.manualSteps,
            limit: limit)
    }

    /// One line per item and command with its verdict, followed by the guard's reasons for anything that isn't
    /// simply allowed, and the manual steps.
    private static func planLines(
        items: [(CleanupItem, SafetyVerdict)], commands: [(PlannedCommand, SafetyVerdict)], manualSteps: [String], limit: Int = .max
    ) -> [String] {
        var lines: [String] = []
        for (item, verdict) in items.prefix(limit) {
            let label = item.kind == .looseFiles ? "files in " + Output.path(item.path) : Output.path(item.path)
            lines += verdictLines(verdict, Output.size(item.size) + "  " + label)
        }
        if items.count > limit { lines.append("  … \(items.count - limit) more".dim) }
        for (command, verdict) in commands {
            let text =
                "$ ".fg(ANSI.accent) + Output.safe(command.displayString) + "  "
                + "(frees up to \(ByteCount.format(command.estimatedBytes)); the tool decides what's unused)".dim
            lines += verdictLines(verdict, text)
        }
        lines += manualSteps.map { "  → ".dim + Output.safe($0) }
        return lines
    }

    /// Each reason carries its own decision: a blocked item can also have a reason that alone would only need
    /// confirmation, and that one isn't labelled "Blocked".
    private static func verdictLines(_ verdict: SafetyVerdict, _ text: String) -> [String] {
        var lines = ["  \(verdict.decision.mark) " + text]
        guard verdict.decision != .allow else { return lines }
        for entry in verdict.entries {
            let reason = Output.safe(entry.reason)
            let label: String = entry.decision == .block ? "Blocked: " + reason : reason
            lines.append("        " + label.fg(entry.decision.color))
        }
        return lines
    }

    /// The summary, then everything that didn't go as planned.
    static func reportLines(_ report: CleanupReport) -> [String] {
        var lines = [report.summary.bold.fg(report.hasProblems ? ANSI.review : ANSI.safe)]
        if report.trashedBytes > 0 {
            lines.append("Items in the Trash still use disk space until it's emptied: ".dim + "spacekit trash --empty".bold)
        }
        for (item, reason) in report.failures {
            lines.append("  ✗ ".fg(ANSI.protected) + Output.path(item.path) + ": " + Output.safe(reason))
        }
        for (item, reason) in report.skipped {
            lines.append("  skipped ".dim + Output.path(item.path) + ": " + Output.safe(reason).dim)
        }
        for entry in report.commands {
            switch entry.outcome {
            case .failed(let reason):
                lines.append("  ✗ ".fg(ANSI.protected) + Output.safe(entry.command.displayString) + ": " + Output.safe(reason))
                lines += entry.output.split(separator: "\n").suffix(5).map { "    " + Output.safe(String($0)).dim }
            case .skipped(let reason):
                lines.append("  skipped ".dim + Output.safe(entry.command.displayString) + ": " + Output.safe(reason).dim)
            case .removed, .wouldRemove:
                break
            }
        }
        lines += report.warnings.map { "  ! ".fg(ANSI.review) + Output.safe($0) }
        return lines
    }

    /// Prints the review of `plan`, gets the go-ahead and runs it. Returns the report, or `nil` when nothing ran.
    ///
    /// Warnings are accepted only here, after the preview printed them: by `--accept-warnings` next to `--yes`, or by
    /// answering the question when `interactive`. `--yes` alone runs only what the guard allows outright. With `json`,
    /// stdout carries only JSON: the plan alone without `--yes`, else the plan and the result; the preview then goes
    /// to stderr.
    static func session(
        _ plan: CleanupPlan, executor: CleanupExecutor, acknowledgement: AcknowledgementOptions, json: Bool, interactive: Bool,
        heading: String = "Cleanup preview", verb: String = "Clean", hint: String
    ) throws -> CleanupReport? {
        let review = CleanupReview(plan, executor: executor)
        let planJSON = json ? PlanJSON(review) : nil
        if let planJSON, !acknowledgement.yes {
            try Output.json(RunJSON(plan: planJSON))
            return nil
        }
        Output.emit([heading.bold] + planLines(review), toStandardError: json)
        guard !review.isEmpty else {
            Output.emit(["Nothing in this plan can be removed.".dim], toStandardError: json)
            if let planJSON { try Output.json(RunJSON(plan: planJSON)) }
            return nil
        }
        let acceptingWarnings: Bool
        if acknowledgement.yes {
            acceptingWarnings = acknowledgement.acceptWarnings
        } else if interactive && Output.confirm("\n" + question(review, verb: verb)) {
            acceptingWarnings = true
        } else {
            let warnings = review.needsAcknowledgement ? " Items with warnings also need --accept-warnings." : ""
            print("\n" + (hint + warnings).dim)
            return nil
        }
        if review.needsAcknowledgement && !acceptingWarnings {
            let count = review.warningCount
            let note = "\(count) item\(count == 1 ? "" : "s") with warnings left alone; add --accept-warnings to remove them too."
            Output.emit([note.fg(ANSI.review)], toStandardError: json)
            guard count < review.selectedItems.count + review.selectedCommands.count else {
                if let planJSON { try Output.json(RunJSON(plan: planJSON)) }
                return nil
            }
        }
        let report = executor.execute(review.acknowledge(acceptingWarnings: acceptingWarnings), dryRun: false)
        if let planJSON {
            try Output.json(RunJSON(plan: planJSON, result: ReportJSON(report)))
        } else {
            Output.emit([""] + reportLines(report))
        }
        return report
    }

    /// Ends the command with a nonzero status when the run didn't do everything it was asked to.
    static func exitIfProblems(_ report: CleanupReport) throws {
        if report.hasProblems { throw ExitCode(1) }
    }

    /// "Clean 1.2 GB to the Trash and run 1 tool command?", saying when the answer accepts the printed warnings.
    static func question(_ review: CleanupReview, verb: String) -> String {
        let commands = review.selectedCommands.count
        let parts = [
            review.selectedItems.isEmpty
                ? "" : ByteCount.format(review.itemBytes) + (review.disposal == .moveToTrash ? " to the Trash" : " permanently"),
            commands > 0 ? "run \(commands) tool command\(commands == 1 ? "" : "s")" : "",
        ]
        let warnings = review.needsAcknowledgement ? ", accepting the warnings above" : ""
        return "\(verb) " + parts.filter { !$0.isEmpty }.joined(separator: " and ") + warnings + "?"
    }
}

// MARK: JSON

struct VerdictJSON: Encodable {
    var decision: String
    var reasons: [String]

    init(_ verdict: SafetyVerdict) {
        decision = "\(verdict.decision)"
        reasons = verdict.reasons
    }
}

struct PlanJSON: Encodable {
    struct Item: Encodable {
        var path: String
        var kind: String
        var bytes: UInt64
        var rule: String?
        var verdict: VerdictJSON
    }
    struct Command: Encodable {
        var rule: String
        var arguments: [String]
        var estimatedBytes: UInt64
        var verdict: VerdictJSON
    }
    var useTrash: Bool
    var totalBytes: UInt64
    var items: [Item]
    var commands: [Command]
    var manualSteps: [String]

    /// The plan a person reviews, with the verdicts the review shows.
    init(_ review: CleanupReview) {
        self.init(
            items: review.items.map { ($0.subject, $0.verdict) }, commands: review.commands.map { ($0.subject, $0.verdict) },
            manualSteps: review.manualSteps, useTrash: review.useTrash)
    }

    /// The plan with the verdicts `context` gets, such as an automatic run's (`jobs show`).
    init(plan: CleanupPlan, executor: CleanupExecutor, context: CleanupContext) {
        self.init(
            items: plan.items.map { ($0, executor.verdict(for: $0, context: context)) },
            commands: plan.commands.map { ($0, executor.verdict(for: $0, context: context)) }, manualSteps: plan.manualSteps,
            useTrash: plan.useTrash)
    }

    private init(
        items: [(CleanupItem, SafetyVerdict)], commands: [(PlannedCommand, SafetyVerdict)], manualSteps: [String], useTrash: Bool
    ) {
        self.useTrash = useTrash
        totalBytes = items.reduce(0) { $0 &+ $1.0.size } &+ commands.reduce(0) { $0 &+ $1.0.estimatedBytes }
        self.items = items.map { item, verdict in
            Item(path: item.path, kind: item.kind.rawValue, bytes: item.size, rule: item.ruleID, verdict: VerdictJSON(verdict))
        }
        self.commands = commands.map { command, verdict in
            Command(
                rule: command.ruleID, arguments: command.arguments, estimatedBytes: command.estimatedBytes, verdict: VerdictJSON(verdict))
        }
        self.manualSteps = manualSteps
    }
}

struct OutcomeJSON: Encodable {
    var status: String
    var bytes: UInt64?
    var trashedTo: String?
    var reason: String?

    init(_ outcome: CleanupOutcome) {
        switch outcome {
        case .removed(let bytes, let trashedTo): (status, self.bytes, self.trashedTo) = ("removed", bytes, trashedTo)
        case .wouldRemove(let bytes): (status, self.bytes) = ("wouldRemove", bytes)
        case .skipped(let reason): (status, self.reason) = ("skipped", reason)
        case .failed(let reason): (status, self.reason) = ("failed", reason)
        }
    }
}

struct ReportJSON: Encodable {
    struct Item: Encodable {
        var path: String
        var kind: String
        var outcome: OutcomeJSON
    }
    struct Command: Encodable {
        var arguments: [String]
        var outcome: OutcomeJSON
        var output: String
    }
    var ok: Bool
    var summary: String
    var freedBytes: UInt64
    var trashedBytes: UInt64
    var deletedBytes: UInt64
    var items: [Item]
    var commands: [Command]
    var warnings: [String]

    init(_ report: CleanupReport) {
        ok = !report.hasProblems
        summary = report.summary
        freedBytes = report.freedBytes
        trashedBytes = report.trashedBytes
        deletedBytes = report.deletedBytes
        items = report.items.map { Item(path: $0.item.path, kind: $0.item.kind.rawValue, outcome: OutcomeJSON($0.outcome)) }
        commands = report.commands.map { Command(arguments: $0.command.arguments, outcome: OutcomeJSON($0.outcome), output: $0.output) }
        warnings = report.warnings
    }
}

/// A plan and what running it did.
struct RunJSON: Encodable {
    var plan: PlanJSON
    var result: ReportJSON?
}
