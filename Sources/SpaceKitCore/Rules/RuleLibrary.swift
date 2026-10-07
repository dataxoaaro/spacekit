import Foundation
import Yams

/// A problem found while loading or validating rules.
public struct RuleIssue: Sendable, CustomStringConvertible {
    public enum Severity: String, Sendable { case error, warning }
    public var severity: Severity
    public var source: String
    public var ruleID: String?
    public var message: String

    public init(severity: Severity, source: String, ruleID: String? = nil, message: String) {
        self.severity = severity
        self.source = source
        self.ruleID = ruleID
        self.message = message
    }

    public var description: String {
        let location = ruleID.map { "\(PathUtil.abbreviate(source)) [\($0)]" } ?? PathUtil.abbreviate(source)
        return "\(severity.rawValue): \(location): \(message)"
    }
}

/// The set of known storage rules: SpaceKit's built-in library plus the user's own rule files.
public struct RuleLibrary: Sendable {
    public private(set) var rules: [Rule]
    public private(set) var issues: [RuleIssue]

    public init(rules: [Rule], issues: [RuleIssue] = []) {
        self.rules = rules
        self.issues = issues
    }

    public static let empty = RuleLibrary(rules: [])

    /// Executables that rule commands may run without the user explicitly allowing them in the config.
    public static let trustedCommands: Set<String> = [
        "brew", "docker", "xcrun", "npm", "pnpm", "yarn", "bun", "ollama", "go", "cargo", "pip", "pip3",
        "uv", "conda", "mamba", "gem", "pod", "flutter", "dart", "gradle", "huggingface-cli", "hf", "mise", "rustup",
        "orb", "podman", "colima", "swift", "deno",
    ]

    /// Loads built-in rules and every `*.yaml` / `*.yml` in `directories`. Later rules with the same id
    /// override earlier ones, so a user can customise a built-in rule by copying it.
    public static func load(
        includeBuiltin: Bool = true,
        directories: [String] = [],
        disabled: Set<String> = []
    ) -> RuleLibrary {
        var byID: [String: Rule] = [:]
        var order: [String] = []
        var issues: [RuleIssue] = []

        var sources: [String] = []
        if includeBuiltin, let builtin = builtinDirectory { sources.append(builtin) }
        sources += directories.map { PathUtil.expand($0) }

        for directory in sources {
            for file in yamlFiles(in: directory) {
                do {
                    let text = try String(contentsOfFile: file, encoding: .utf8)
                    for rule in try parse(yaml: text, source: file) {
                        if byID[rule.id] == nil { order.append(rule.id) }
                        byID[rule.id] = rule
                    }
                } catch {
                    issues.append(RuleIssue(severity: .error, source: file, message: describe(error)))
                }
            }
        }
        let rules = order.compactMap { byID[$0] }.filter { !disabled.contains($0.id) }
        var library = RuleLibrary(rules: rules, issues: issues)
        library.issues += library.validate()
        return library
    }

    /// Where the built-in rule library lives, searched in this order:
    /// `$SPACEKIT_RULES_DIR`, the app bundle's `Resources/rules`, `<prefix>/share/spacekit/rules` next to
    /// the executable (Homebrew, `make install`), the bundle's resources when the CLI runs from
    /// `SpaceKit.app/Contents/Helpers`, and finally the `rules/` folder of a source checkout.
    public static var builtinDirectory: String? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let env = ProcessInfo.processInfo.environment["SPACEKIT_RULES_DIR"], !env.isEmpty { candidates.append(env) }
        if let resources = Bundle.main.resourceURL?.path { candidates.append(resources + "/rules") }
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath().deletingLastPathComponent().path
        candidates.append(executable + "/../share/spacekit/rules")
        candidates.append(executable + "/../Resources/rules")  // SpaceKit.app/Contents/Helpers/spacekit
        candidates.append(executable + "/rules")
        // Source checkout: Sources/SpaceKitCore/Rules/RuleLibrary.swift → <repo>/rules
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().path
        candidates.append(repo + "/rules")
        return candidates.map(PathUtil.standardize).first { path in
            var isDirectory: ObjCBool = false
            return fm.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    static func yamlFiles(in directory: String) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }
        var files: [String] = []
        while let relative = enumerator.nextObject() as? String {
            if relative.hasSuffix(".yaml") || relative.hasSuffix(".yml") { files.append(directory + "/" + relative) }
        }
        return files.sorted()
    }

    /// Parses a rule file. A file is either a single rule (has `name` at the top level) or a list under `rules:`
    /// with optional file-wide `group` and `category` defaults.
    public static func parse(yaml: String, source: String = "<inline>") throws -> [Rule] {
        guard let node = try Yams.compose(yaml: yaml), let mapping = node.mapping else { return [] }
        let decoder = YAMLDecoder()
        var rules: [Rule]
        var defaultGroup = ""
        var defaultCategory = ""
        if mapping["rules"] != nil {
            let file = try decoder.decode(RuleFile.self, from: yaml)
            rules = file.rules
            defaultGroup = file.group ?? ""
            defaultCategory = file.category ?? ""
        } else {
            rules = [try decoder.decode(Rule.self, from: yaml)]
        }
        for index in rules.indices {
            if rules[index].group.isEmpty { rules[index].group = defaultGroup.isEmpty ? rules[index].name : defaultGroup }
            if rules[index].category.isEmpty { rules[index].category = defaultCategory.isEmpty ? "other" : defaultCategory }
            rules[index].source = source
        }
        return rules
    }

    private struct RuleFile: Decodable {
        var group: String?
        var category: String?
        var rules: [Rule]
    }

    public static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .dataCorrupted(let context), .typeMismatch(_, let context), .valueNotFound(_, let context):
                let path = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
                return path.isEmpty ? context.debugDescription : "\(path): \(context.debugDescription)"
            case .keyNotFound(let key, let context):
                let path = (context.codingPath + [key]).map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }.joined(separator: ".")
                return "missing required key '\(path)'"
            @unknown default:
                return "\(error)"
            }
        }
        return "\(error)"
    }

    // MARK: Lookup

    public func rule(id: String) -> Rule? { rules.first { $0.id == id } }

    public var groups: [String] {
        var seen = Set<String>()
        return rules.compactMap { seen.insert($0.group).inserted ? $0.group : nil }
    }

    public func rules(inCategory prefix: String) -> [Rule] {
        rules.filter { $0.category == prefix || $0.category.hasPrefix(prefix + ".") }
    }

    /// Every marker name rules depend on, for `ScanOptions.markers`.
    public var markerNames: [String] {
        var names: [String] = []
        var seen = Set<String>()
        for rule in rules {
            for name in (rule.match?.sibling ?? []) + (rule.match?.contains ?? []) where seen.insert(name).inserted {
                names.append(name)
            }
        }
        return names
    }

    public var markerRegistry: MarkerRegistry { MarkerRegistry(names: markerNames) }

    // MARK: Validation

    /// Checks rules for mistakes that would make them useless or dangerous.
    public func validate() -> [RuleIssue] {
        var issues: [RuleIssue] = []
        var seen: [String: String] = [:]
        let home = PathUtil.home
        for rule in rules {
            let source = rule.source ?? "<inline>"
            func issue(_ severity: RuleIssue.Severity, _ message: String) {
                issues.append(RuleIssue(severity: severity, source: source, ruleID: rule.id, message: message))
            }
            if let other = seen[rule.id], other != source {
                issue(.warning, "id also defined in \(PathUtil.abbreviate(other)); the later definition wins")
            }
            seen[rule.id] = source
            if rule.paths.isEmpty && rule.match == nil {
                issue(.error, "needs either `path` or `match`")
            }
            if let match = rule.match, match.names.isEmpty {
                issue(.error, "`match.names` is empty")
            }
            for path in rule.paths {
                let expanded = PathUtil.expand(path, home: home)
                if !path.hasPrefix("/") && !path.hasPrefix("~") {
                    issue(.error, "path '\(path)' must be absolute or start with ~")
                }
                if PathUtil.components(expanded).count < 2 || expanded == home {
                    issue(.error, "path '\(path)' is too broad; rules may not target a volume root, a top-level folder or the home folder")
                }
            }
            if rule.safety.level == .protected && rule.action.isCleanable {
                issue(.error, "protected rules identify data to keep; they can't have a cleanup action")
            }
            for command in [rule.action.command, rule.action.itemCommand].compactMap({ $0 }) {
                guard let executable = command.first else {
                    issue(.error, "empty command")
                    continue
                }
                let name = PathUtil.lastComponent(executable)
                if !RuleLibrary.trustedCommands.contains(name) {
                    issue(
                        .warning,
                        "command '\(name)' is not in the trusted list; it will only run if allowed in config (safety.allowedCommands)")
                }
                if command.contains(where: {
                    $0.contains(";") || $0.contains("&&") || $0.contains("|") || $0.contains("`") || $0.contains("$(")
                }) {
                    issue(.error, "commands run without a shell; remove shell syntax (; && | ` $( )")
                }
            }
            if rule.granularity == .children && rule.match != nil {
                issue(.warning, "`granularity: children` is unusual for pattern rules")
            }
        }
        return issues
    }
}
