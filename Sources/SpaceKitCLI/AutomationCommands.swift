import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

struct JobsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jobs",
        abstract: "Scheduled cleanups: observe, suggest or clean automatically.",
        subcommands: [List.self, Show.self, Add.self, Remove.self, Enable.self, Disable.self, Run.self, Next.self],
        defaultSubcommand: List.self
    )

    static func save(_ context: SpaceKitContext, _ config: SpaceKitConfig) throws {
        try context.configStore.save(config)
    }

    static func find(_ id: String, in context: SpaceKitContext) throws -> Job {
        guard let job = context.config.jobs.first(where: { $0.id == id }) else {
            throw ValidationError("No job '\(id)'. See `spacekit jobs list`.")
        }
        return job
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List jobs.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            if json {
                try Output.json(context.config.jobs)
                return
            }
            let states = context.jobStates.load()
            let next = Dictionary(JobRunner(context: context).nextRuns().map { ($0.job.id, $0.date) }, uniquingKeysWith: { a, _ in a })
            guard !context.config.jobs.isEmpty else {
                Output.print("No jobs. Add one with `spacekit jobs add --rule xcode.derived-data`, or start from `spacekit config init`.")
                return
            }
            for job in context.config.jobs {
                let toggle = job.enabled ? "ON ●".fg(ANSI.safe) : "OFF ○".dim
                Output.print(
                    ANSI.pad(toggle, to: 6) + " " + ANSI.pad(job.name.bold, to: 32) + ANSI.pad(job.mode.title, to: 11)
                        + ANSI.pad(job.schedule.description, to: 22)
                        + (job.enabled ? (next[job.id].map { "next " + $0.relativeDescription() } ?? "") : "").dim)
                Output.print(
                    "       " + "\(job.id)  ·  ".dim + job.conditionSummary.dim
                        + (states[job.id]?.lastOutcome.map { "  ·  last: \($0)" } ?? "").dim)
            }
            let agent = LaunchAgent(paths: context.paths).status()
            if !agent.loaded {
                Output.print()
                Output.print(
                    "The background agent isn't running, so jobs only run when you call them. Install it: ".fg(ANSI.review)
                        + "spacekit agent install".bold)
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Evaluate a job now and show what it would do.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String

        func run() throws {
            let context = global.loadContext()
            let job = try JobsCommand.find(id, in: context)
            let runner = JobRunner(context: context)
            let missing = runner.rules(for: job).missing
            if !missing.isEmpty { Output.warn("Unknown rules: \(missing.joined(separator: ", "))") }
            let evaluation = try ProgressReporter.run("Evaluating") { try runner.evaluate(job, progress: $0) }
            Output.print(job.name.bold + "  ·  " + job.mode.title + "  ·  " + job.schedule.description)
            Output.print(job.conditionSummary.dim)
            Output.print()
            Output.print("Matched:   " + ByteCount.format(evaluation.matchedBytes).bold)
            Output.print("Eligible:  " + ByteCount.format(evaluation.eligibleBytes).bold + "  (after age conditions)".dim)
            Output.print(
                "Status:    " + (evaluation.isTriggered ? "would run — ".fg(ANSI.safe) : "would skip — ".dim) + evaluation.triggerSummary)
            let plan = runner.plan(for: evaluation)
            let executor = context.executor
            let automation = CleanupContext.automatic(runner.automationContext(for: job))
            Output.print()
            for item in plan.items.sorted(by: { $0.size > $1.size }).prefix(25) {
                let verdict = executor.verdict(for: item, context: automation)
                let symbol = verdict.decision == .allow ? "✓".fg(ANSI.safe) : "✗".fg(ANSI.protected)
                Output.print(
                    "  \(symbol) " + Output.size(item.size) + "  " + PathUtil.abbreviate(item.path)
                        + (verdict.decision == .allow ? "" : "  " + (verdict.reasons.first ?? "").fg(ANSI.review)))
            }
            if plan.items.count > 25 { Output.print("  … \(plan.items.count - 25) more".dim) }
            for command in plan.commands { Output.print("  $ ".fg(ANSI.accent) + command.displayString) }
            Output.print()
            Output.print("✓ = an automatic run may remove it; ✗ = automatic runs leave it alone (you can still clean it yourself).".dim)
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a job to the config.",
            discussion: """
                Examples:
                  spacekit jobs add --rule xcode.derived-data --mode automatic --schedule "sunday 03:00" --size-above 30GB --keep-recent 14d
                  spacekit jobs add --rule node.node-modules --older-than 60d
                  spacekit jobs add --name "Old downloads" --path ~/Downloads --older-than 90d --mode suggest
                """
        )
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Rule id (repeatable).") var rule: [String] = []
        @Option(name: .long, help: "Your own folder to clean (repeatable).") var path: [String] = []
        @Option(name: .long, help: "Job name (default: from the first rule).") var name: String?
        @Option(name: .long, help: "Job id (default: from the name).") var id: String?
        @Option(name: .long, help: "observe, suggest or automatic.") var mode: String?
        @Option(name: .long, help: "hourly, daily, weekly, monthly, or e.g. \"sunday 03:00\".") var schedule: String?
        @Option(name: .long, help: "Only act when the total exceeds this (e.g. 30GB).") var sizeAbove: String?
        @Option(name: .long, help: "Only items unused at least this long (e.g. 60d).") var olderThan: String?
        @Option(name: .long, help: "Keep items used within this window (e.g. 14d).") var keepRecent: String?
        @Option(name: .long, help: "trash, delete or rule.") var action: String = "trash"
        @Flag(name: .long, help: "Allow 🟡 review items in automatic runs.") var includeReview = false

        func run() throws {
            let context = global.loadContext()
            guard !rule.isEmpty || !path.isEmpty else { throw ValidationError("Give at least one --rule or --path") }
            var rules: [Rule] = []
            for id in rule {
                guard let found = context.library.rule(id: id) else { throw ValidationError("Unknown rule '\(id)'") }
                guard found.safety.level != .protected else { throw ValidationError("\(found.name) is protected and can't be cleaned") }
                rules.append(found)
            }
            var job = rules.first.map(Job.suggested(for:)) ?? Job(id: "custom", name: name ?? "Custom cleanup")
            job.rules = rules.map(\.id)
            job.paths = path.map { PathUtil.abbreviate(PathUtil.expand($0)) }
            if let name { job.name = name } else if rules.count > 1 { job.name = rules.map(\.name).joined(separator: " + ") }
            job.id = id ?? Rule.slug(job.name)
            if let mode {
                guard let value = Job.Mode(rawValue: mode) else { throw ValidationError("--mode must be observe, suggest or automatic") }
                job.mode = value
            } else if !path.isEmpty {
                job.mode = .suggest
            }
            if let schedule {
                guard let value = Schedule.parse(schedule) else { throw ValidationError("Couldn't understand schedule '\(schedule)'") }
                job.schedule = value
            }
            if let sizeAbove { job.when.sizeAbove = try parseSize(sizeAbove) }
            if let olderThan { job.when.olderThan = try parseAge(olderThan) }
            if let keepRecent { job.when.keepRecent = try parseAge(keepRecent) }
            guard let actionValue = Job.Action(rawValue: action) else { throw ValidationError("--action must be trash, delete or rule") }
            job.action = actionValue
            job.includeReview = includeReview

            // Check custom folders against the guard up front.
            let guardian = context.safetyGuard
            for folder in job.paths {
                let verdict = guardian.evaluate(
                    path: PathUtil.join(PathUtil.expand(folder), "item"),
                    context: .automatic(JobRunner(context: context).automationContext(for: job)))
                if verdict.isBlocked {
                    Output.warn("Automatic runs won't clean inside \(folder): \(verdict.reasons.joined(separator: "; "))")
                }
            }
            var config = context.config
            var base = job.id
            var counter = 2
            while config.jobs.contains(where: { $0.id == job.id }) {
                job.id = "\(base)-\(counter)"
                counter += 1
            }
            base = job.id
            config.jobs.append(job)
            try JobsCommand.save(context, config)
            Output.print("Added job " + job.id.bold + ": \(job.mode.title), \(job.schedule). " + job.conditionSummary.dim)
            if job.mode == .automatic && !LaunchAgent(paths: context.paths).status().loaded {
                Output.print("Install the background agent so it runs on schedule: ".fg(ANSI.review) + "spacekit agent install".bold)
            }
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a job from the config.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String

        func run() throws {
            let context = global.loadContext()
            _ = try JobsCommand.find(id, in: context)
            var config = context.config
            config.jobs.removeAll { $0.id == id }
            try JobsCommand.save(context, config)
            Output.print("Removed \(id).")
        }
    }

    struct Enable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a job on.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() throws { try JobsCommand.setEnabled(id, true, global) }
    }

    struct Disable: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Turn a job off.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        func run() throws { try JobsCommand.setEnabled(id, false, global) }
    }

    static func setEnabled(_ id: String, _ enabled: Bool, _ global: GlobalOptions) throws {
        let context = global.loadContext()
        _ = try find(id, in: context)
        var config = context.config
        for index in config.jobs.indices where config.jobs[index].id == id { config.jobs[index].enabled = enabled }
        try save(context, config)
        Output.print("\(id): \(enabled ? "on" : "off")")
    }

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Run a job now. Previews by default; --yes cleans; --scheduled behaves exactly like the agent would."
        )
        @OptionGroup var global: GlobalOptions
        @Argument var id: String
        @Flag(name: [.short, .long], help: "Clean now (as if you approved it).") var yes = false
        @Flag(name: .long, help: "Follow the job's mode (observe/suggest/automatic) like a scheduled run.") var scheduled = false

        func run() throws {
            let context = global.loadContext()
            let job = try JobsCommand.find(id, in: context)
            let runner = JobRunner(context: context)
            if scheduled {
                let result = ProgressReporter.run("Running \(job.name)") { _ in runner.run(job) }
                Output.print(result.summary)
                return
            }
            if !yes {
                try JobsCommand.Show.parse([id] + (global.config.map { ["--config", $0] } ?? [])).run()
                Output.print()
                Output.print("Preview only. Run with --yes to clean now, or --scheduled to run it the way the agent would.".dim)
                return
            }
            let result = ProgressReporter.run("Running \(job.name)") { _ in runner.run(job, manual: true) }
            Output.print(result.summary)
            if case .cleaned(let report) = result.action {
                for (item, reason) in report.skipped { Output.print("  skipped ".dim + PathUtil.abbreviate(item.path) + ": " + reason.dim) }
            }
        }
    }

    struct Next: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "When jobs run next, and how much they're expected to free.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            let runner = JobRunner(context: context)
            let runs = runner.nextRuns()
            guard let first = runs.first else {
                Output.print("No enabled jobs.")
                return
            }
            Output.print("Next automatic cleanup".bold)
            Output.print(first.date.formatted(.dateTime.weekday(.wide).hour().minute()) + "  ·  " + first.job.name)
            let estimate = runner.estimatedRecovery()
            if estimate.high > 0 {
                Output.print("Estimated recovery: \(ByteCount.format(estimate.low))–\(ByteCount.format(estimate.high))".dim)
            }
            Output.print()
            for run in runs {
                Output.print("  " + ANSI.pad(run.date.formatted(date: .abbreviated, time: .shortened), to: 22) + run.job.name)
            }
        }
    }
}

struct SuggestionsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "suggestions",
        abstract: "Cleanups prepared by `suggest` jobs, waiting for your approval.",
        subcommands: [List.self, Approve.self, Dismiss.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List pending suggestions.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            let suggestions = context.suggestions.all()
            guard !suggestions.isEmpty else {
                Output.print("No pending suggestions.")
                return
            }
            for suggestion in suggestions {
                Output.print(
                    suggestion.id.bold + "  " + suggestion.jobName + "  " + ByteCount.format(suggestion.plan.totalBytes).bold
                        + "  " + "prepared \(suggestion.created.relativeDescription())".dim)
                for item in suggestion.plan.items.sorted(by: { $0.size > $1.size }).prefix(5) {
                    Output.print("    " + Output.size(item.size) + "  " + PathUtil.abbreviate(item.path).dim)
                }
                if suggestion.plan.items.count > 5 { Output.print("    … \(suggestion.plan.items.count - 5) more".dim) }
            }
            Output.print()
            Output.print("Approve with `spacekit suggestions approve <id>`, or dismiss with `spacekit suggestions dismiss <id>`.".dim)
        }
    }

    struct Approve: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run a suggested cleanup.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String

        func run() throws {
            let context = global.loadContext()
            guard let suggestion = context.suggestions.get(id) else { throw ValidationError("No suggestion '\(id)'") }
            let report = context.executor.execute(suggestion.plan, context: .manual(confirmed: true), dryRun: false)
            try context.suggestions.remove(suggestion.id)
            try? context.jobStates.update(suggestion.jobID) { $0.lastFreedBytes = report.freedBytes }
            Output.print(report.summary.bold.fg(ANSI.safe))
            for (item, reason) in report.skipped + report.failures {
                Output.print("  skipped ".dim + PathUtil.abbreviate(item.path) + ": " + reason.dim)
            }
        }
    }

    struct Dismiss: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard a suggestion.")
        @OptionGroup var global: GlobalOptions
        @Argument var id: String

        func run() throws {
            let context = global.loadContext()
            guard let suggestion = context.suggestions.get(id) else { throw ValidationError("No suggestion '\(id)'") }
            try context.suggestions.remove(suggestion.id)
            Output.print("Dismissed.")
        }
    }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "The background agent that runs jobs on schedule (a per-user launchd job).",
        subcommands: [Run.self, Install.self, Uninstall.self, Status.self],
        defaultSubcommand: Status.self
    )

    struct Run: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Run due jobs once (what launchd calls).")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            try context.paths.ensureDirectories()
            let stamp = ISO8601DateFormatter().string(from: Date())
            print("[\(stamp)] agent run")
            let results = JobRunner(context: context).runDue { print("[\(stamp)] \($0)") }
            if results.isEmpty { print("[\(stamp)] no jobs due") }
        }
    }

    struct Install: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Install and start the background agent.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Check interval (default: automation.checkEvery, 1h).") var every: String?

        func run() throws {
            let context = global.loadContext()
            let interval = try every.map { try parseAge($0).seconds } ?? context.config.automation.checkEvery.seconds
            guard let executable = Bundle.main.executablePath.map({ URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }) else {
                throw ValidationError("Can't locate the spacekit executable")
            }
            if executable.contains("/.build/") {
                Output.warn("Installing an agent that points at a development build (\(executable)). Run `make install` for a stable path.")
            }
            let agent = LaunchAgent(paths: context.paths)
            try agent.install(executable: executable, interval: interval)
            Output.print("Background agent installed: checks for due jobs every \(Age(seconds: interval)).")
            Output.print("Logs: \(PathUtil.abbreviate(context.paths.logDirectory + "/agent.log"))".dim)
            Output.print(
                "To scan protected folders it needs Full Disk Access: System Settings → Privacy & Security → Full Disk Access → add \(executable)."
                    .dim)
        }
    }

    struct Uninstall: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop and remove the background agent.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            try LaunchAgent(paths: global.loadContext().paths).uninstall()
            Output.print("Background agent removed. Jobs stay in your config.")
        }
    }

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show whether the agent is installed and running.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            let status = LaunchAgent(paths: context.paths).status()
            Output.print("Installed: " + (status.installed ? "yes".fg(ANSI.safe) : "no".fg(ANSI.review)))
            Output.print("Loaded:    " + (status.loaded ? "yes".fg(ANSI.safe) : "no".fg(ANSI.review)))
            if let executable = status.executable { Output.print("Program:   \(executable)") }
            if let interval = status.interval { Output.print("Interval:  \(Age(seconds: TimeInterval(interval)))") }
            let runs = JobRunner(context: context).nextRuns()
            if let first = runs.first { Output.print("Next job:  \(first.job.name), \(first.date.relativeDescription())") }
        }
    }
}
