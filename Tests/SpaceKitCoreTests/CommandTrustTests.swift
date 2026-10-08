import Foundation
import Synchronization
import Testing

@testable import SpaceKitCore

/// Stands in for running tools: records every call and answers with what the test scripted, so trust and budget
/// tests never start a real program.
final class RecordingRunner: ProcessRunner {
    let environment: [String: String]
    private let locator: @Sendable (String) -> [String]
    private let respond: @Sendable (_ call: [String]) -> Shell.Result
    private let recorded = Mutex<[[String]]>([])
    private let standIns: String?

    /// Each tool in `installed` is found as a small stand-in file, so the executor has a program file to check.
    convenience init(
        environment: [String: String] = [:], installed: Set<String>,
        respond: @escaping @Sendable (_ call: [String]) -> Shell.Result = { _ in Shell.Result(status: 0, output: "", timedOut: false) }
    ) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("spacekit-runner-\(UUID().uuidString)").path
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        for name in installed { try? Data("stand-in for \(name)\n".utf8).write(to: URL(fileURLWithPath: folder + "/" + name)) }
        let locate: @Sendable (String) -> [String] = { installed.contains($0) ? [folder + "/" + $0] : [] }
        self.init(environment: environment, standIns: folder, locate: locate, respond: respond)
    }

    /// Tools are found the way `Shell.which` finds them, in `searchPath`; still none is started.
    convenience init(
        environment: [String: String] = [:], searchPath: [String],
        respond: @escaping @Sendable (_ call: [String]) -> Shell.Result = { _ in Shell.Result(status: 0, output: "", timedOut: false) }
    ) {
        self.init(environment: environment, standIns: nil, locate: { Shell.installed($0, in: searchPath) }, respond: respond)
    }

    private init(
        environment: [String: String], standIns: String?, locate: @escaping @Sendable (String) -> [String],
        respond: @escaping @Sendable (_ call: [String]) -> Shell.Result
    ) {
        self.environment = environment
        self.standIns = standIns
        self.locator = locate
        self.respond = respond
    }

    deinit {
        if let standIns { try? FileManager.default.removeItem(atPath: standIns) }
    }

    func locate(_ name: String) -> String? { locator(name).first }

    func locateAll(_ name: String) -> [String] { locator(name) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Shell.Result {
        let call = [PathUtil.lastComponent(executable)] + arguments
        recorded.withLock { $0.append(call) }
        return respond(call)
    }

    /// Every call so far, the tool by its bare name.
    var calls: [[String]] { recorded.withLock { $0 } }
}

/// What `docker context inspect` prints for a context whose endpoint is `endpoint`.
func dockerContext(_ endpoint: String) -> @Sendable ([String]) -> Shell.Result {
    { call in
        call.starts(with: ["docker", "context", "inspect"])
            ? Shell.Result(status: 0, output: endpoint + "\n", timedOut: false) : Shell.Result(status: 0, output: "", timedOut: false)
    }
}

@Suite("Command trust")
struct CommandTrustTests {
    func rule(
        _ id: String = "tool", builtin: Bool, level: SafetyLevel = .safe, command: [String]? = nil, itemCommand: [String]? = nil,
        paths: [String] = ["/Users/tester/.tool/cache"]
    ) -> Rule {
        var rule = Rule(
            id: id, name: id, paths: paths, granularity: .children, safety: SafetySpec(level: level),
            action: ActionSpec(command: command, itemCommand: itemCommand))
        rule.isBuiltin = builtin
        return rule
    }

    func executor(_ tree: TempTree, rules: [Rule], runner: RecordingRunner, budget: ByteCount = .gb(100), allowed: Set<String> = [])
        -> CleanupExecutor
    {
        var executor = sandboxExecutor(tree, rules: rules, budget: budget, allowed: allowed)
        executor.runner = runner
        return executor
    }

    func skipReason(_ outcome: CleanupOutcome?) -> String? {
        if case .skipped(let reason) = outcome { return reason }
        return nil
    }

    let automatic = CleanupContext.automatic(AutomationContext(jobID: "j"))

    @Test("Who may run what: built-in rules use the trusted list, user rules allowedCommands and only by hand, launchers never")
    func decisionTable() {
        let trust = CommandTrust(allowedCommands: ["mytool", "sh", "baſh", "oſaſcript", "xcrun"])
        func refused(_ executable: String, builtin: Bool, _ context: CleanupContext) -> Bool {
            let command = PlannedCommand(ruleID: "tool", arguments: [executable, "x"], estimatedBytes: 1)
            return !trust.refusals(command, rule: rule(builtin: builtin, command: [executable, "x"]), context: context).isEmpty
        }
        // Built-in rule: trusted tools in every run, allowedCommands too, anything else never.
        #expect(!refused("brew", builtin: true, .manual) && !refused("brew", builtin: true, automatic))
        #expect(!refused("mytool", builtin: true, automatic))
        #expect(refused("make", builtin: true, .manual))
        // User rule: only allowedCommands, only by hand; the trusted list is no help.
        #expect(!refused("mytool", builtin: false, .manual))
        #expect(refused("mytool", builtin: false, automatic))
        #expect(refused("brew", builtin: false, .manual))
        // A code launcher in allowedCommands still never runs, in any spelling APFS finds it by.
        #expect(refused("sh", builtin: false, .manual) && refused("sh", builtin: true, .manual))
        #expect(refused("baſh", builtin: false, .manual) && refused("oſaſcript", builtin: true, .manual))
        // xcrun is trusted for built-in rules only; allowing it doesn't let a rule of yours start any developer tool.
        #expect(!refused("xcrun", builtin: true, automatic) && refused("xcrun", builtin: false, .manual))
        // swift is a launcher, but on the trusted list for built-in rules.
        #expect(!refused("swift", builtin: true, automatic))
        #expect(refused("/usr/local/bin/mytool", builtin: false, .manual))
    }

    @Test("Tools get a cleaned environment: PATH, HOME, locale and tool homes stay; Docker, tokens and the rest go")
    func cleanedEnvironment() {
        let parent = [
            "PATH": "/usr/bin:relative", "HOME": "/Users/tester", "USER": "tester", "LOGNAME": "tester", "LANG": "en_US.UTF-8",
            "LC_ALL": "C", "TMPDIR": "/var/folders/x", "XDG_CACHE_HOME": "/Users/tester/.xdg", "CARGO_HOME": "/Users/tester/.cargo",
            "RUSTUP_HOME": "/r", "GOPATH": "/g", "GOMODCACHE": "/gm", "GOCACHE": "/gc", "npm_config_cache": "/n",
            "NPM_CONFIG_CACHE": "/N", "PNPM_HOME": "/p", "YARN_CACHE_FOLDER": "/y", "GRADLE_USER_HOME": "/gr",
            "OLLAMA_MODELS": "/o", "HOMEBREW_CACHE": "/hc", "HOMEBREW_PREFIX": "/opt/homebrew",
            "DOCKER_HOST": "tcp://build.example.com:2376", "DOCKER_CONTEXT": "remote", "DOCKER_CONFIG": "/elsewhere",
            "OLLAMA_HOST": "gpu.example.com", "GITHUB_TOKEN": "ghp_x", "AWS_SECRET_ACCESS_KEY": "s", "HF_TOKEN": "h",
            "DYLD_INSERT_LIBRARIES": "/tmp/evil.dylib", "NODE_OPTIONS": "--require /tmp/evil.js", "SSH_AUTH_SOCK": "/tmp/agent",
        ]
        let environment = Shell.toolEnvironment(from: parent, home: "/Users/tester")
        let droppedMarks = ["DOCKER", "OLLAMA_HOST", "TOKEN", "AWS", "DYLD", "NODE", "SSH", "PATH"]
        for kept in parent.keys where !droppedMarks.contains(where: { kept.contains($0) }) {
            #expect(environment[kept] == parent[kept], "\(kept)")
        }
        for dropped in [
            "DOCKER_HOST", "DOCKER_CONTEXT", "DOCKER_CONFIG", "OLLAMA_HOST", "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "HF_TOKEN",
            "DYLD_INSERT_LIBRARIES", "NODE_OPTIONS", "SSH_AUTH_SOCK",
        ] {
            #expect(environment[dropped] == nil, "\(dropped)")
        }
        let path = environment["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(path.first == "/usr/bin" && path.contains("/opt/homebrew/bin") && !path.contains("relative"))
    }

    @Test("The real runner hands a tool the cleaned environment, not SpaceKit's own")
    func realRunnerCleansEnvironment() {
        let result = Shell.run(
            "/usr/bin/env", [], timeout: 10, environment: ["HOME": "/Users/tester", "DOCKER_HOST": "tcp://remote:2376", "API_TOKEN": "x"])
        let lines = Set(result.output.split(separator: "\n").map(String.init))
        #expect(lines.contains("HOME=/Users/tester"))
        #expect(!result.output.contains("DOCKER_HOST") && !result.output.contains("API_TOKEN"))
    }

    @Test("Refused commands never reach the runner")
    func refusalsDontRun() throws {
        let tree = try TempTree()
        let runner = RecordingRunner(installed: ["du", "sh", "brew"])
        let user = rule("user", builtin: false, command: ["du", "-s", "/Users/tester/.tool/cache"])
        let launcher = rule("launcher", builtin: false, command: ["sh", "-c", "true"])
        let untrusted = rule("untrusted", builtin: true, command: ["make", "clean"])
        let plan = CleanupPlan(
            commands: [user, launcher, untrusted].map { rule in
                PlannedCommand(ruleID: rule.id, arguments: rule.action.command ?? [], estimatedBytes: 1)
            })
        let executor = executor(tree, rules: [user, launcher, untrusted], runner: runner, allowed: ["du", "sh"])
        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.commands.count == 3)
        #expect(report.commands.allSatisfy { skipReason($0.outcome) != nil })
        #expect(runner.calls.isEmpty)
        // By hand, the allowed user command runs; the launcher and the untrusted built-in one still don't.
        let manual = manualRun(plan, with: executor)
        #expect(manual.commands.filter { skipReason($0.outcome) == nil }.map(\.command.ruleID) == ["user"])
        #expect(runner.calls == [["du", "-s", "/Users/tester/.tool/cache"]])
    }

    @Test("An allowed name whose program is a launcher's (a symlink, a copy or a hard link) is refused and never started")
    func launcherUnderAnotherName() throws {
        let tree = try TempTree()
        let files = FileManager.default
        try tree.directory("renamed")
        try files.createSymbolicLink(atPath: tree.path("renamed/cleanup-tool"), withDestinationPath: "/bin/sh")
        try files.copyItem(atPath: "/bin/zsh", toPath: tree.path("renamed/cache-tool"))
        try "#!/bin/sh\necho tidy\n".write(toFile: tree.path("renamed/fine-tool"), atomically: true, encoding: .utf8)
        #expect(chmod(tree.path("renamed/fine-tool"), 0o755) == 0)
        // /bin is on the system volume, so a hard link needs a launcher of its own: an `sh` found before /bin's.
        try tree.directory("linked")
        try "#!/bin/sh\nexit 0\n".write(toFile: tree.path("linked/sh"), atomically: true, encoding: .utf8)
        #expect(chmod(tree.path("linked/sh"), 0o755) == 0)
        #expect(link(tree.path("linked/sh"), tree.path("linked/tidy-tool")) == 0)

        func run(_ name: String, in folder: String) -> (outcome: CleanupOutcome?, calls: [[String]]) {
            let runner = RecordingRunner(searchPath: [tree.path(folder)] + Shell.searchPath)
            let tool = rule("tool", builtin: false, command: [name, "--all"])
            let plan = CleanupPlan(commands: [PlannedCommand(ruleID: "tool", arguments: [name, "--all"], estimatedBytes: 1)])
            let report = manualRun(plan, with: executor(tree, rules: [tool], runner: runner, allowed: [name]))
            return (report.commands.first?.outcome, runner.calls)
        }
        let renamed = [("cleanup-tool", "renamed", "'sh'"), ("cache-tool", "renamed", "'zsh'"), ("tidy-tool", "linked", "'sh'")]
        for (name, folder, launcher) in renamed {
            let result = run(name, in: folder)
            let reason = skipReason(result.outcome)
            #expect(reason?.contains("same program as \(launcher)") == true, "\(name): \(String(describing: result.outcome))")
            #expect(result.calls.isEmpty, "\(name)")
        }
        let fine = run("fine-tool", in: "renamed")
        #expect(skipReason(fine.outcome) == nil)
        #expect(fine.calls == [["fine-tool", "--all"]])
    }

    @Test("What a command frees is charged to the run's budget; the next command that doesn't fit isn't started")
    func budgetCharging() throws {
        let tree = try TempTree()
        let cache = try tree.file("home/first/blob", bytes: 6_000)
        let freed = tree.allocated("home/first/blob")
        let runner = RecordingRunner(installed: ["brew", "cargo"]) { call in
            if call.first == "brew" { try? FileManager.default.removeItem(atPath: cache) }
            return Shell.Result(status: 0, output: "", timedOut: false)
        }
        let first = rule("first", builtin: true, command: ["brew", "cleanup"])
        let second = rule("second", builtin: true, command: ["cargo", "cache", "--autoclean"])
        let plan = CleanupPlan(commands: [
            PlannedCommand(
                ruleID: "first", arguments: ["brew", "cleanup"], estimatedBytes: 6_000, measurePaths: [tree.path("home/first")]),
            PlannedCommand(ruleID: "second", arguments: ["cargo", "cache", "--autoclean"], estimatedBytes: 6_000),
        ])
        let budget = ByteCount(freed + 1_000)
        let report = executor(tree, rules: [first, second], runner: runner, budget: budget)
            .execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        #expect(report.commands.first?.outcome == .removed(bytes: freed, trashedTo: nil))
        #expect(skipReason(report.commands.last?.outcome)?.contains("budget") == true)
        #expect(runner.calls == [["brew", "cleanup"]])
        #expect(journalEntries(tree).map(\.bytes) == [freed])
    }

    @Test("Docker commands run only against a Docker on this Mac's own socket")
    func dockerEndpoint() throws {
        let tree = try TempTree()
        let prune = ["docker", "builder", "prune", "--force"]
        let docker = rule("docker.build-cache", builtin: true, command: prune)
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: docker.id, arguments: prune, estimatedBytes: 1)])
        func run(_ runner: RecordingRunner) -> CleanupOutcome? {
            executor(tree, rules: [docker], runner: runner).execute(
                AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false
            )
            .commands.first?.outcome
        }
        let inspect = ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]

        for endpoint in ["tcp://build.example.com:2376", "ssh://me@build.example.com", "npipe:////./pipe/docker_engine", ""] {
            let remote = RecordingRunner(installed: ["docker"], respond: dockerContext(endpoint))
            #expect(skipReason(run(remote))?.contains("Docker") == true, "\(endpoint)")
            #expect(remote.calls == [inspect], "\(endpoint)")
        }
        let viaHost = RecordingRunner(environment: ["DOCKER_HOST": "tcp://build.example.com:2376"], installed: ["docker"])
        #expect(skipReason(run(viaHost))?.contains("DOCKER_HOST") == true)
        #expect(viaHost.calls.isEmpty)
        let failing = RecordingRunner(installed: ["docker"]) { _ in Shell.Result(status: 1, output: "context not found", timedOut: false) }
        #expect(skipReason(run(failing)) != nil)
        #expect(failing.calls == [inspect])

        // Docker Desktop, OrbStack and Colima all listen on a unix socket.
        for endpoint in [
            "unix:///var/run/docker.sock", "unix:///Users/tester/.orbstack/run/docker.sock",
            "unix:///Users/tester/.colima/default/docker.sock",
        ] {
            let local = RecordingRunner(
                environment: ["DOCKER_HOST": "unix:///var/run/docker.sock"], installed: ["docker"], respond: dockerContext(endpoint))
            #expect(run(local)?.isRemoved == true, "\(endpoint)")
            #expect(local.calls == [inspect, prune], "\(endpoint)")
        }
    }

    @Test("An item or model name that would read as an option is refused")
    func dashNames() throws {
        let tree = try TempTree()
        try tree.directory("home/kegs/-rf")
        try tree.directory("home/kegs/wget")
        let kegs = rule("kegs", builtin: true, itemCommand: ["brew", "uninstall", "{name}"], paths: [tree.path("home/kegs")])
        let finding = Finding(
            rule: kegs,
            items: ["-rf", "wget"].map { FindingItem(path: tree.path("home/kegs/\($0)"), kind: .directory, name: $0, size: 10) })
        let plan = CleanupPlan.make(findings: [finding], scanStarted: Date())
        #expect(plan.commands.map(\.arguments) == [["brew", "uninstall", "-rf"], ["brew", "uninstall", "wget"]])
        let runner = RecordingRunner(installed: ["brew"])
        let report = manualRun(plan, with: executor(tree, rules: [kegs], runner: runner))
        let dashed = report.commands.first { $0.command.arguments.last == "-rf" }
        #expect(skipReason(dashed?.outcome)?.contains("'-rf'") == true)
        #expect(runner.calls == [["brew", "uninstall", "wget"]])

        // {path} is absolute, so a dash at the start of the folder name is harmless there.
        let byPath = rule("kegs", builtin: true, itemCommand: ["brew", "uninstall", "{path}"], paths: [tree.path("home/kegs")])
        let pathPlan = CleanupPlan.make(findings: [Finding(rule: byPath, items: finding.items)], scanStarted: Date())
        let pathRunner = RecordingRunner(installed: ["brew"])
        let pathReport = manualRun(pathPlan, with: executor(tree, rules: [byPath], runner: pathRunner))
        #expect(pathReport.commands.allSatisfy { skipReason($0.outcome) == nil })
    }
}
