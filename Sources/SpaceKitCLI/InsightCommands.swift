import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI
import Yams

struct HistoryCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "How your disk usage changed over time, and what grew.",
        subcommands: [Show.self, Snapshot.self],
        defaultSubcommand: Show.self
    )

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Usage over time and what grew.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Days to show.") var days: Int = 90
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            let history = context.history
            if json {
                try Output.json(history.records(since: Date().addingTimeInterval(-Double(days) * 86_400)))
                return
            }
            let daily = history.dailyUsage(days: days)
            Output.print("YOUR DISK".bold)
            guard daily.count >= 2 else {
                Output.print("Not enough history yet. The agent records usage every few hours (`spacekit agent install`);".dim)
                Output.print("`spacekit history snapshot` records a full breakdown now.".dim)
                return
            }
            let values = daily.map { Double($0.used) }
            Output.print(ByteCount.format(daily.last!.total).dim + " total")
            Output.print(ANSI.sparkline(values).fg(ANSI.accent) + "  " + ByteCount.format(daily.last!.used).bold + " used")
            Output.print(
                daily.first!.date.formatted(.dateTime.month(.abbreviated).day()).dim + " → "
                    + daily.last!.date.formatted(.dateTime.month(.abbreviated).day()).dim)
            Output.print()
            if let month = history.usedDelta(over: 30 * 86_400) {
                Output.print((ByteCount.formatDelta(month) + " this month").bold.fg(month > 0 ? ANSI.review : ANSI.safe))
            }
            let grew = history.whatGrew(over: Double(days) * 86_400)
            if !grew.isEmpty {
                Output.print()
                Output.print("WHAT GREW?".bold)
                for item in grew {
                    Output.print(
                        "  " + ANSI.pad(item.name, to: 26)
                            + ANSI.pad(ByteCount.formatDelta(item.delta), to: 10, alignRight: true).fg(
                                item.delta > 0 ? ANSI.review : ANSI.safe))
                }
            }
        }
    }

    struct Snapshot: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Record a full storage breakdown now.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            let analysis = try ProgressReporter.run("Analysing") { try context.analyzer.analyzeSync(progress: $0) }
            try context.history.recordSnapshot(analysis: analysis)
            Output.print(
                "Snapshot recorded: \(analysis.groups.count) groups, \(ByteCount.format(analysis.findings.reduce(0) { $0 + $1.size })) recognised."
            )
        }
    }
}

struct JournalCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journal", abstract: "Everything SpaceKit removed, and how much it recovered.")
    @OptionGroup var global: GlobalOptions
    @Option(name: .long, help: "Days to show.") var days: Int = 90
    @Flag(name: .long, help: "Machine-readable output.") var json = false

    func run() throws {
        let context = global.loadContext()
        let since = Date().addingTimeInterval(-Double(days) * 86_400)
        let entries = context.journal.entries(since: since)
        if json {
            try Output.json(entries)
            return
        }
        Output.print(
            "Your Mac has recovered " + ByteCount.format(entries.reduce(0) { $0 + $1.bytes }).bold.fg(ANSI.safe)
                + " over the last \(days) days.")
        Output.print()
        for entry in entries.suffix(50) {
            let how = entry.automatic ? "auto" : "manual"
            Output.print(
                entry.date.formatted(date: .abbreviated, time: .shortened).dim + "  " + Output.size(entry.bytes) + "  "
                    + ANSI.pad(entry.method.rawValue, to: 7).dim + ANSI.pad(how, to: 7).dim + PathUtil.abbreviate(entry.path))
        }
        if entries.count > 50 { Output.print("… \(entries.count - 50) earlier entries (use --json for all)".dim) }
    }
}

struct ConfigCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "config",
        abstract: "Create, show, validate and edit the YAML config.",
        subcommands: [Path.self, Init.self, Show.self, Validate.self, Edit.self],
        defaultSubcommand: Show.self
    )

    struct Path: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print config and state locations.")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let paths = global.loadContext().paths
            Output.print("config: \(paths.configFile)")
            Output.print("rules:  \(paths.userRulesDirectory)")
            Output.print("state:  \(paths.stateDirectory)")
        }
    }

    struct Init: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Write a commented starter config.")
        @OptionGroup var global: GlobalOptions
        @Flag(name: .long, help: "Overwrite an existing config.") var force = false
        func run() throws {
            let context = global.loadContext()
            if try context.configStore.initialize(force: force) {
                Output.print("Wrote \(PathUtil.abbreviate(context.paths.configFile)). Edit it, then check with `spacekit config validate`.")
            } else {
                Output.print("\(PathUtil.abbreviate(context.paths.configFile)) already exists (use --force to replace it).")
            }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Print the effective config (defaults filled in).")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let context = global.loadContext()
            Output.print(
                "# \(PathUtil.abbreviate(context.paths.configFile))\(context.configStore.exists ? "" : " (not created yet — showing defaults)")"
                    .dim)
            Output.print(try YAMLEncoder().encode(context.config))
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Check a config file for mistakes.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "File to check (default: your config).") var file: String?
        func run() throws {
            let path = file.map { PathUtil.expand($0) } ?? global.loadContext().paths.configFile
            guard FileManager.default.fileExists(atPath: path) else {
                throw ValidationError("No config at \(path). Create one with `spacekit config init`.")
            }
            let config = try ConfigStore(file: path).load()
            let library = global.loadContext().library
            var problems = 0
            for job in config.jobs {
                for id in job.rules where library.rule(id: id) == nil {
                    Output.print("job \(job.id): unknown rule '\(id)'".fg(ANSI.protected))
                    problems += 1
                }
            }
            if problems > 0 { throw ExitCode.failure }
            Output.print(
                "✓ ".fg(ANSI.safe) + "\(PathUtil.abbreviate(path)) is valid: \(config.jobs.count) job\(config.jobs.count == 1 ? "" : "s").")
        }
    }

    struct Edit: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Open the config in $EDITOR (creating it first if needed).")
        @OptionGroup var global: GlobalOptions
        func run() throws {
            let context = global.loadContext()
            try context.configStore.initialize()
            let editor = ProcessInfo.processInfo.environment["VISUAL"] ?? ProcessInfo.processInfo.environment["EDITOR"] ?? "nano"
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [editor, context.paths.configFile]
            try process.run()
            process.waitUntilExit()
            do {
                _ = try ConfigStore(file: context.paths.configFile).load()
                Output.print("✓ ".fg(ANSI.safe) + "Config is valid.")
            } catch {
                Output.print("✗ ".fg(ANSI.protected) + error.localizedDescription)
                throw ExitCode.failure
            }
        }
    }
}

struct DoctorCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Check permissions, config, rules and the background agent.")
    @OptionGroup var global: GlobalOptions

    func run() throws {
        let context = global.loadContext()
        func check(_ ok: Bool, _ label: String, _ detail: String = "") {
            Output.print((ok ? "✓ ".fg(ANSI.safe) : "! ".fg(ANSI.review)) + label + (detail.isEmpty ? "" : "  " + detail.dim))
        }
        let fda = FullDiskAccess.isGranted
        check(
            fda, "Full Disk Access",
            fda ? "" : "System Settings → Privacy & Security → Full Disk Access → add your terminal app (and the agent)")
        check(
            context.configError == nil, "Config",
            context.configError
                ?? (context.configStore.exists
                    ? PathUtil.abbreviate(context.paths.configFile) : "not created (defaults) — `spacekit config init`"))
        let errors = context.library.issues.filter { $0.severity == .error }
        check(
            errors.isEmpty, "Rules",
            "\(context.library.rules.count) loaded from \(RuleLibrary.builtinDirectory.map { PathUtil.abbreviate($0) } ?? "nowhere")"
                + (errors.isEmpty ? "" : ", \(errors.count) errors (spacekit rules validate)"))
        let agent = LaunchAgent(paths: context.paths).status()
        check(agent.loaded, "Background agent", agent.loaded ? "running" : "not running — `spacekit agent install`")
        check(geteuid() != 0, "Not running as root", geteuid() == 0 ? "SpaceKit refuses to remove files as root" : "")
        check(
            true, "Trash",
            context.config.safety.trash == .always ? "everything goes to the Trash" : "regenerable caches may be deleted directly")
        if let capacity = VolumeCapacity.of(path: "/") {
            check(
                capacity.usedFraction < 0.9, "Startup disk",
                "\(ByteCount.format(capacity.available)) available of \(ByteCount.format(capacity.total))"
                    + (capacity.purgeable > 0
                        ? " (\(ByteCount.format(capacity.freeNow)) free now, \(ByteCount.format(capacity.purgeable)) purgeable)" : ""))
        }
    }
}
