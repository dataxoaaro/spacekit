import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Rule loading")
struct RuleLoadingTests {
    /// A built-in rule file and a user rule directory in a temporary tree.
    struct Folders {
        let tree: TempTree
        var user: String { tree.path("user") }

        static let builtin = BuiltinRules(files: [
            RuleFileText(
                source: "built-in rules/base.yaml",
                yaml: """
                    group: Base
                    category: developer.cache
                    rules:
                      - id: base.keys
                        name: Keys
                        path: ~/.base-keys
                        safety: protected
                      - id: base.models
                        name: Models
                        path: ~/.base/models
                        safety: review
                        exclusions: [active_projects]
                        policy:
                          threshold: 10GB
                          olderThan: 30d
                        action: remove
                      - id: base.cache
                        name: Cache
                        path: ~/.base/cache
                        safety: safe
                        action:
                          command: [brew, cleanup]
                      - id: base.builds
                        name: Builds
                        match:
                          names: [build, out]
                          sibling: [Makefile]
                        safety: safe
                        action: remove
                    """)
        ])

        init() throws {
            tree = try TempTree()
            try tree.directory("user")
        }

        func write(_ relative: String, _ text: String) throws {
            try text.write(toFile: tree.path(relative), atomically: true, encoding: .utf8)
        }

        func load(disabled: Set<String> = []) -> RuleLibrary {
            RuleLibrary.load(builtin: Folders.builtin, directories: [user], disabled: disabled)
        }
    }

    func errors(_ library: RuleLibrary, _ id: String) -> [RuleIssue] {
        library.issues.filter { $0.severity == .error && $0.ruleID == id }
    }

    @Test("Rules from the built-in directory are marked built-in; user rules are not")
    func builtinFlag() throws {
        let folders = try Folders()
        try folders.write("user/mine.yaml", "id: mine.cache\nname: Mine\npath: ~/.mine/cache\nsafety: safe\naction: remove\n")
        let library = folders.load()
        #expect(library.rule(id: "base.cache")?.isBuiltin == true)
        #expect(library.rule(id: "mine.cache")?.isBuiltin == false)
        let decoded = try #require(try RuleLibrary.parse(yaml: "name: x\npath: ~/.x/y\nisBuiltin: true\n").first)
        #expect(!decoded.isBuiltin)
    }

    @Test("A user rule can't replace a built-in protected rule")
    func protectedOverride() throws {
        let folders = try Folders()
        try folders.write("user/evil.yaml", "id: base.keys\nname: Keys\npath: ~/.base-keys\nsafety: safe\naction: remove\n")
        let library = folders.load()
        let rule = try #require(library.rule(id: "base.keys"))
        #expect(rule.safety.level == .protected)
        #expect(rule.isBuiltin)
        #expect(!errors(library, "base.keys").isEmpty)
    }

    @Test("A user rule can't lower a built-in rule's safety level, but may raise it")
    func loweredSafety() throws {
        let folders = try Folders()
        try folders.write(
            "user/a.yaml",
            "id: base.models\nname: Models\npath: ~/.base/models\nexclusions: [active_projects]\nsafety: safe\naction: remove\n")
        try folders.write(
            "user/b.yaml", "id: base.cache\nname: Cache\npath: ~/.base/cache\nsafety: review\naction:\n  command: [brew, cleanup]\n")
        let library = folders.load()
        #expect(library.rule(id: "base.models")?.safety.level == .review)
        #expect(library.rule(id: "base.models")?.isBuiltin == true)
        #expect(!errors(library, "base.models").isEmpty)
        #expect(library.rule(id: "base.cache")?.safety.level == .review)
        #expect(library.rule(id: "base.cache")?.isBuiltin == false)
        #expect(errors(library, "base.cache").isEmpty)
    }

    @Test("A second user override can't lower the level below the built-in either")
    func chainedOverride() throws {
        let folders = try Folders()
        try folders.write("user/a.yaml", "id: base.models\nname: Models\npath: ~/.base/models\nsafety: protected\n")
        try folders.write("user/b.yaml", "id: base.models\nname: Models\npath: ~/.base/models\nsafety: safe\naction: remove\n")
        let library = folders.load()
        #expect(library.rule(id: "base.models")?.safety.level == .protected)
    }

    @Test("rules validate <file> judges a file the way loading it would, overrides of built-in rules included")
    func checkFiles() throws {
        let folders = try Folders()
        try folders.write("user/wider.yaml", "id: base.cache\nname: Cache\npath: ~/.base/cache\nsafety: review\naction: remove\n")
        try folders.write(
            "user/mine.yaml", "id: mine.cache\nname: Mine\npath: ~/.mine/cache\nsafety: safe\naction:\n  command: [brew, cleanup]\n")
        let wider = RuleLibrary.check(files: [folders.tree.path("user/wider.yaml")], builtin: Folders.builtin)
        #expect(wider.rules.count == 1)
        #expect(wider.issues.isEmpty)
        try folders.write("user/lower.yaml", "id: base.models\nname: Models\npath: ~/.base/models\nsafety: safe\naction: remove\n")
        let lower = RuleLibrary.check(files: [folders.tree.path("user/lower.yaml")], builtin: Folders.builtin)
        #expect(lower.issues.contains { $0.severity == .error && $0.message.contains("lower the safety level") })
        let mine = RuleLibrary.check(files: [folders.tree.path("user/mine.yaml")], builtin: Folders.builtin)
        #expect(!mine.issues.contains { $0.severity == .error })
        #expect(mine.issues.contains { $0.message.contains("allowedCommands") })
        let asBuiltin = RuleLibrary.check(files: [folders.tree.path("user/mine.yaml")], asBuiltin: true, builtin: Folders.builtin)
        #expect(asBuiltin.issues.isEmpty)
        let missing = RuleLibrary.check(files: [folders.tree.path("user/missing.yaml")], builtin: Folders.builtin)
        #expect(missing.issues.contains { $0.severity == .error })
    }

    @Test("rules.disabled never disables a protected rule")
    func disablingProtected() throws {
        let folders = try Folders()
        let library = folders.load(disabled: ["base.keys", "base.models"])
        #expect(library.rule(id: "base.keys") != nil)
        #expect(library.rule(id: "base.models") == nil)
        #expect(library.issues.contains { $0.severity == .warning && $0.ruleID == "base.keys" })
    }

    @Test("Rules with errors are reported but not loaded")
    func invalidRulesNotLoaded() throws {
        let folders = try Folders()
        try folders.write(
            "user/bad.yaml",
            """
            rules:
              - id: bad.home
                name: Home
                path: "~"
                safety: safe
                action: remove
              - id: bad.everything
                name: Everything
                path: ~/*
                safety: safe
                action: remove
              - id: bad.prefix
                name: Prefix
                path: ~/Do*
                safety: safe
                action: remove
              - id: bad.manual
                name: Manual
                path: ~/.keys
                safety: protected
                action:
                  manual: Delete it by hand
              - id: good.cache
                name: Good
                path: ~/.good/cache
                safety: safe
                action: remove
            """)
        let library = folders.load()
        for id in ["bad.home", "bad.everything", "bad.prefix", "bad.manual"] {
            #expect(library.rule(id: id) == nil, "\(id) must not load")
            #expect(!errors(library, id).isEmpty, "\(id) must be reported")
        }
        #expect(library.rule(id: "good.cache") != nil)
    }

    @Test("Command executables must be bare names; user rules need allowedCommands")
    func commandValidation() {
        func issues(_ command: [String], builtin: Bool = false) -> [RuleIssue] {
            var rule = Rule(
                id: "c", name: "C", paths: ["~/.c/cache"], safety: SafetySpec(level: .safe), action: ActionSpec(command: command))
            rule.isBuiltin = builtin
            return RuleLibrary(rules: [rule]).validate()
        }
        for command in [["/bin/rm", "-rf", "/"], ["../bin/brew"], ["..", "x"], ["bin/brew"], ["{name}"], [""]] {
            #expect(issues(command).contains { $0.severity == .error }, "\(command)")
        }
        #expect(issues(["brew", "cleanup"], builtin: true).isEmpty)
        let user = issues(["brew", "cleanup"])
        #expect(user.count == 1)
        #expect(user.first?.severity == .warning && user.first?.message.contains("safety.allowedCommands") == true)
        #expect(user.first?.message.contains("manual") == true)
        let launcher = issues(["sh", "-c", "rm -rf ~/.c/cache"])
        #expect(launcher.count == 1)
        #expect(launcher.first?.severity == .warning && launcher.first?.message.contains("never runs") == true)
        #expect(Shell.isBareName("brew"))
        #expect(!Shell.isBareName("/opt/homebrew/bin/brew"))
    }

    @Test("Unknown AI layouts are flagged")
    func aiLayout() {
        let rule = Rule(id: "ai", name: "AI", paths: ["~/.ai/models"], ai: AISpec(tool: "AI", layout: "olama"))
        #expect(RuleLibrary(rules: [rule]).validate().contains { $0.message.contains("olama") })
    }

    @Test("Undocumented safety aliases and action words are rejected")
    func strictWords() {
        #expect(throws: (any Error).self) { try RuleLibrary.parse(yaml: "name: x\npath: ~/.x/y\nsafety: green\n") }
        #expect(throws: (any Error).self) { try RuleLibrary.parse(yaml: "name: x\npath: ~/.x/y\naction: trash\n") }
        #expect(SafetyLevel(alias: "regenerable") == .safe)
    }
}

@Suite("Built-in rules")
struct BuiltinRulesTests {
    /// Tests/SpaceKitCoreTests/RuleLoadingTests.swift → <repo>/rules
    static let repositoryRules = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("rules").path

    @Test("Every embedded rule parses and validates without errors, and its commands use trusted tools")
    func embeddedRulesAreValid() {
        let library = RuleLibrary.load(builtin: .embedded, directories: [])
        #expect(library.rules.count > 100)
        #expect(library.issues.isEmpty, "\(library.issues.map(\.description).joined(separator: "\n"))")
        #expect(library.validate().isEmpty)
        #expect(library.rules.allSatisfy { $0.isBuiltin })
        let ids = library.rules.map(\.id)
        #expect(Set(ids).count == ids.count, "rule ids must be unique")
    }

    @Test("The embedded rules are exactly the repository's rules/ folder")
    func embeddedMatchesRepository() throws {
        let onDisk = RuleLibrary.read(directory: BuiltinRulesTests.repositoryRules)
        #expect(onDisk.issues.isEmpty)
        let prefix = BuiltinRulesTests.repositoryRules + "/"
        let repository = onDisk.files.map { ("built-in rules/" + $0.source.dropFirst(prefix.count), $0.yaml) }
        #expect(repository.map(\.0) == BuiltinRules.embedded.files.map(\.source))
        #expect(repository.map(\.1) == BuiltinRules.embedded.files.map(\.yaml))
    }

    @Test("Credentials stay protected with no rules folder anywhere on disk")
    func credentialsWithoutFolders() throws {
        let library = RuleLibrary.load(builtin: .embedded, directories: [])
        let protected = Set(library.rules.filter { $0.safety.level == .protected }.flatMap(\.paths))
        for path in [
            "~/.netrc", "~/.git-credentials", "~/.npmrc", "~/.docker/config.json", "~/.azure", "~/.aws", "~/.kube",
            "~/.config/gh", "~/.pypirc", "~/.cargo/credentials.toml",
        ] {
            #expect(protected.contains(path), "\(path)")
        }
        let guardian = testGuard(rules: library.rules)
        for path in ["/Users/tester/.netrc", "/Users/tester/.npmrc", "/Users/tester/.docker/config.json", "/Users/tester/.azure/creds"] {
            #expect(guardian.check(path, context: .manual).isBlocked, "\(path)")
        }
        #expect(guardian.check("/Users/tester/.docker", context: .manual).isBlocked, "a folder holding credentials")
    }

    @Test("Release builds ignore SPACEKIT_RULES_DIR; debug builds use it in place of the embedded rules")
    func rulesDirectoryOverrideIsDebugOnly() throws {
        let tree = try TempTree()
        try tree.directory("rules")
        try "id: dev.cache\nname: Dev\npath: ~/.dev/cache\nsafety: safe\naction: remove\n".write(
            toFile: tree.path("rules/dev.yaml"), atomically: true, encoding: .utf8)
        let environment = ["SPACEKIT_RULES_DIR": tree.path("rules")]
        let release = BuiltinRules.standard(environment: environment, debugBuild: false)
        #expect(release.files.map(\.source) == BuiltinRules.embedded.files.map(\.source))
        let debug = BuiltinRules.standard(environment: environment, debugBuild: true)
        #expect(debug.files.map(\.source) == [tree.path("rules/dev.yaml")])
        #expect(debug.origin.contains("SPACEKIT_RULES_DIR"))
        #expect(RuleLibrary.load(builtin: debug, directories: []).rule(id: "dev.cache")?.isBuiltin == true)
        let unset = BuiltinRules.standard(environment: ["SPACEKIT_RULES_DIR": ""], debugBuild: true)
        #expect(unset.files.map(\.source) == BuiltinRules.embedded.files.map(\.source))
    }
}

@Suite("Rule scaffold and rule folders")
struct RuleScaffoldTests {
    @Test("The scaffold is a valid custom rule that parses back from its YAML")
    func scaffold() throws {
        let rule = RuleScaffold.rule(name: "My tool's cache", paths: ["~/Library/Caches/com.example.tool"])
        #expect(rule.id == "custom." + Rule.slug("My tool's cache"))
        #expect(rule.category == "personal.custom" && rule.safety.level == .review && rule.action.remove)
        #expect(!RuleLibrary.issues(for: rule).contains { $0.severity == .error })
        let yaml = try RuleScaffold.yaml(rule, note: "save, then Reload")
        #expect(yaml.hasPrefix("# Schema: docs/RULES.md · save, then Reload\n"))
        #expect(try RuleLibrary.parse(yaml: yaml, source: "x.yaml").map(\.id) == [rule.id])

        let pattern = RuleScaffold.rule(name: "Build", match: "build", sibling: "Makefile", safety: .protected)
        #expect(pattern.match?.names == ["build"] && pattern.match?.sibling == ["Makefile"])
        #expect(pattern.action.isEmpty)
    }

    @Test("User rules load from the configured folders plus the standard one, once")
    func ruleDirectories() {
        let paths = SpaceKitPaths(configFile: "/tmp/sk/config.yaml", stateDirectory: "/tmp/sk/state")
        var config = SpaceKitConfig()
        config.rules.directories = ["/tmp/sk/extra"]
        let context = SpaceKitContext(paths: paths, config: config, library: RuleLibrary(rules: []))
        #expect(context.ruleDirectories == ["/tmp/sk/extra", paths.userRulesDirectory])
        config.rules.directories = [paths.userRulesDirectory]
        #expect(
            SpaceKitContext(paths: paths, config: config, library: RuleLibrary(rules: [])).ruleDirectories == [paths.userRulesDirectory])
    }
}
