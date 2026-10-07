import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI
import Yams

struct RulesCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rules",
        abstract: "Browse, validate and write storage rules.",
        subcommands: [List.self, Show.self, Validate.self, New.self, Dirs.self],
        defaultSubcommand: List.self
    )

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List known rules.")
        @OptionGroup var global: GlobalOptions
        @OptionGroup var selection: RuleSelection
        @Flag(name: .long, help: "Machine-readable output.") var json = false

        func run() throws {
            let context = global.loadContext()
            let rules = try selection.select(from: context.library)
            if json {
                try Output.json(rules)
                return
            }
            var group = ""
            for rule in rules.sorted(by: { ($0.group, $0.name) < ($1.group, $1.name) }) {
                if rule.group != group {
                    group = rule.group
                    Output.print()
                    Output.print(group.bold)
                }
                let location =
                    rule.paths.first.map { PathUtil.abbreviate($0) } ?? rule.match.map { "**/" + $0.names.joined(separator: ", ") } ?? ""
                Output.print(
                    "  " + "●".fg(ANSI.color(for: rule.safety.level)) + " " + ANSI.pad(rule.id, to: 36)
                        + ANSI.pad(ANSI.truncate(rule.name, to: 30), to: 32) + location.dim)
            }
            Output.print()
            Output.print(
                "\(rules.count) rules · ".dim
                    + "built-in: \(RuleLibrary.builtinDirectory.map { PathUtil.abbreviate($0) } ?? "not found")".dim)
            for issue in context.library.issues where issue.severity == .error { Output.warn(issue.description) }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a rule as YAML.")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Rule id.") var id: String

        func run() throws {
            let context = global.loadContext()
            guard let rule = context.library.rule(id: id) else { throw ValidationError("Unknown rule '\(id)'") }
            if let source = rule.source { Output.print("# \(PathUtil.abbreviate(source))".dim) }
            Output.print(try YAMLEncoder().encode(rule))
        }
    }

    struct Validate: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Validate rule files (default: every loaded rule).")
        @OptionGroup var global: GlobalOptions
        @Argument(help: "Rule files to check.") var files: [String] = []

        func run() throws {
            var issues: [RuleIssue] = []
            var count = 0
            if files.isEmpty {
                let library = global.loadContext().library
                issues = library.issues
                count = library.rules.count
            } else {
                var rules: [Rule] = []
                for file in files.map({ PathUtil.expand($0) }) {
                    do {
                        rules += try RuleLibrary.parse(yaml: try String(contentsOfFile: file, encoding: .utf8), source: file)
                    } catch {
                        issues.append(RuleIssue(severity: .error, source: file, message: "\(error)"))
                    }
                }
                count = rules.count
                issues += RuleLibrary(rules: rules).validate()
            }
            for issue in issues {
                Output.print(issue.severity == .error ? issue.description.fg(ANSI.protected) : issue.description.fg(ANSI.review))
            }
            let errors = issues.filter { $0.severity == .error }.count
            Output.print(
                "\(count) rules checked, \(errors) error\(errors == 1 ? "" : "s"), \(issues.count - errors) warning\(issues.count - errors == 1 ? "" : "s")."
            )
            if errors > 0 { throw ExitCode.failure }
        }
    }

    struct New: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Scaffold a new rule in your rules folder.")
        @OptionGroup var global: GlobalOptions
        @Option(name: .long, help: "Display name.") var name: String
        @Option(name: .long, help: "Location (repeatable).") var path: [String] = []
        @Option(name: .long, help: "Folder name to match anywhere (instead of --path).") var match: String?
        @Option(name: .long, help: "File that must sit next to a match (e.g. package.json).") var sibling: String?
        @Option(name: .long, help: "safe, review or protected.") var safety: String = "review"
        @Option(name: .long, help: "Group name.") var group: String = "Custom"
        @Flag(name: .long, help: "Print instead of writing a file.") var print = false

        func run() throws {
            guard !path.isEmpty || match != nil else { throw ValidationError("Give --path or --match") }
            guard let level = SafetyLevel(alias: safety) else { throw ValidationError("--safety must be safe, review or protected") }
            let id = "custom." + Rule.slug(name)
            var rule = Rule(
                id: id, name: name, group: group, category: "custom",
                description: "Describe what this is and what happens if it's removed.",
                paths: path, safety: SafetySpec(level: level), action: level == .protected ? ActionSpec() : ActionSpec(remove: true))
            if let match { rule.match = PatternSpec(names: [match], sibling: sibling.map { [$0] } ?? []) }
            let yaml = "# Schema: docs/RULES.md\n" + (try YAMLEncoder().encode(rule))
            let issues = RuleLibrary(rules: [rule]).validate()
            for issue in issues { Output.warn(issue.message) }
            if print {
                Output.print(yaml)
                return
            }
            let context = global.loadContext()
            let file = context.paths.userRulesDirectory + "/\(Rule.slug(name)).yaml"
            guard !FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("\(PathUtil.abbreviate(file)) already exists")
            }
            try FileManager.default.createDirectory(atPath: context.paths.userRulesDirectory, withIntermediateDirectories: true)
            try yaml.write(toFile: file, atomically: true, encoding: .utf8)
            Output.print("Wrote \(PathUtil.abbreviate(file)). Try it: " + "spacekit dev --rule \(id)".bold)
        }
    }

    struct Dirs: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "dirs", abstract: "Print where rules are loaded from.")
        @OptionGroup var global: GlobalOptions

        func run() throws {
            let context = global.loadContext()
            Output.print("built-in: \(RuleLibrary.builtinDirectory ?? "not found")")
            var directories = context.config.rules.directories.map { PathUtil.expand($0) }
            if !directories.contains(context.paths.userRulesDirectory) { directories.append(context.paths.userRulesDirectory) }
            for directory in directories {
                Output.print("user:     \(directory)" + (FileManager.default.fileExists(atPath: directory) ? "" : " (not created yet)".dim))
            }
        }
    }
}
