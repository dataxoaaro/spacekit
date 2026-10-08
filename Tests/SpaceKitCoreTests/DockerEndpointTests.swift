import Foundation
import Testing

@testable import SpaceKitCore

/// A Docker set up as the test says, answering the queries SpaceKit makes before a `docker` command. Nothing runs:
/// the recording runner hands these answers back.
struct ScriptedDocker: Sendable {
    /// What `docker context inspect` prints for the active context.
    var context = Shell.Result(status: 0, output: "unix:///var/run/docker.sock\n", timedOut: false)
    /// What `docker buildx ls --format json` prints.
    var builders = Shell.Result(status: 0, output: "", timedOut: false)
    /// Endpoints of contexts by name, for `docker context inspect <name>`; others aren't found.
    var named: [String: String] = [:]

    static let activeContext = ["docker", "context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]
    static let builderList = ["docker", "buildx", "ls", "--format", "json"]
    static func namedContext(_ name: String) -> [String] { activeContext + [name] }

    func respond(_ call: [String]) -> Shell.Result {
        if call == ScriptedDocker.activeContext { return context }
        if call == ScriptedDocker.builderList { return builders }
        if call.count == ScriptedDocker.activeContext.count + 1, call.starts(with: ScriptedDocker.activeContext), let name = call.last {
            guard let endpoint = named[name] else {
                return Shell.Result(status: 1, output: "", timedOut: false, errors: "context \"\(name)\" does not exist\n")
            }
            return Shell.Result(status: 0, output: endpoint + "\n", timedOut: false)
        }
        return Shell.Result(status: 0, output: "", timedOut: false)
    }

    /// `docker buildx ls --format json` output: one JSON object per builder and line.
    static func builders(_ entries: [(name: String, driver: String, endpoints: [String], current: Bool)]) -> Shell.Result {
        let lines = entries.map { entry in
            let nodes = entry.endpoints.map { #"{"Name":"\#(entry.name)0","Endpoint":"\#($0)","Status":"running"}"# }
            let fields = #""Name":"\#(entry.name)","Driver":"\#(entry.driver)","Current":\#(entry.current)"#
            return "{" + fields + #","Nodes":["# + nodes.joined(separator: ",") + "]}"
        }
        return Shell.Result(status: 0, output: lines.joined(separator: "\n") + "\n", timedOut: false)
    }
}

@Suite("Docker endpoint")
struct DockerEndpointTests {
    let tree: TempTree
    let builderPrune = ["docker", "builder", "prune", "--force"]
    let imagePrune = ["docker", "image", "prune", "--all", "--force"]

    init() throws { tree = try TempTree() }

    /// Runs `command` from a built-in rule in an automatic run against `docker`; returns the outcome and every call.
    func run(_ command: [String], _ docker: ScriptedDocker) -> (outcome: CleanupOutcome?, calls: [[String]]) {
        var rule = Rule(
            id: "docker.cache", name: "Docker", paths: [], granularity: .children, safety: SafetySpec(level: .safe),
            action: ActionSpec(command: command))
        rule.isBuiltin = true
        let runner = RecordingRunner(installed: ["docker"]) { docker.respond($0) }
        var executor = sandboxExecutor(tree, rules: [rule])
        executor.runner = runner
        let plan = CleanupPlan(commands: [PlannedCommand(ruleID: rule.id, arguments: command, estimatedBytes: 1)])
        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        return (report.commands.first?.outcome, runner.calls)
    }

    func skipReason(_ outcome: CleanupOutcome?) -> String? {
        if case .skipped(let reason) = outcome { return reason }
        return nil
    }

    func context(_ endpoint: String, errors: String = "") -> Shell.Result {
        Shell.Result(status: 0, output: endpoint + "\n", timedOut: false, errors: errors)
    }

    @Test("Docker commands run only when the active context is a socket on this Mac; its warnings don't matter")
    func activeContext() {
        for endpoint in ["tcp://build.example.com:2376", "ssh://me@build.example.com", "npipe:////./pipe/docker_engine", ""] {
            let result = run(imagePrune, ScriptedDocker(context: context(endpoint)))
            #expect(skipReason(result.outcome)?.contains("Docker") == true, "\(endpoint)")
            #expect(result.calls == [ScriptedDocker.activeContext], "\(endpoint)")
        }
        // Docker Desktop, OrbStack and Colima all listen on a unix socket. A warning on standard error is not the endpoint.
        for endpoint in [
            "unix:///var/run/docker.sock", "unix:///Users/tester/.orbstack/run/docker.sock",
            "unix:///Users/tester/.colima/default/docker.sock",
        ] {
            let docker = ScriptedDocker(context: context(endpoint, errors: "WARNING: Plugin \"/x/docker-scan\" is not valid\n"))
            let result = run(imagePrune, docker)
            #expect(result.outcome?.isRemoved == true, "\(endpoint)")
            #expect(result.calls == [ScriptedDocker.activeContext, imagePrune], "\(endpoint)")
        }
    }

    @Test("When Docker can't say which context is active, nothing runs")
    func contextUnknown() {
        let failures = [
            Shell.Result(status: 1, output: "", timedOut: false, errors: "context not found: remote\n"),
            Shell.Result(status: -2, output: "unix:///var/run/docker.sock\n", timedOut: true),
            Shell.Result(status: 0, output: "unix:///var/run/docker.sock\ntcp://build.example.com:2376\n", timedOut: false),
        ]
        for failure in failures {
            let result = run(imagePrune, ScriptedDocker(context: failure))
            #expect(skipReason(result.outcome) != nil, "\(failure.output)")
            #expect(result.calls == [ScriptedDocker.activeContext])
        }
        let named = run(imagePrune, ScriptedDocker(context: failures[0]))
        #expect(skipReason(named.outcome)?.contains("context not found") == true)
    }

    @Test("docker builder commands run only when the selected buildx builder is this Mac's Docker")
    func localBuilder() {
        let local: [ScriptedDocker] = [
            // Docker Desktop: the docker driver on the active context, named by context.
            ScriptedDocker(
                builders: ScriptedDocker.builders([
                    ("default", "docker", ["default"], false), ("desktop-linux", "docker", ["desktop-linux"], true),
                ]),
                named: ["desktop-linux": "unix:///Users/tester/.docker/run/docker.sock"]),
            // A BuildKit container in the local Docker, by socket.
            ScriptedDocker(
                builders: ScriptedDocker.builders([("kit", "docker-container", ["unix:///var/run/docker.sock"], true)])),
        ]
        for docker in local {
            let result = run(builderPrune, docker)
            #expect(result.outcome?.isRemoved == true, "\(docker.builders.output)")
            #expect(result.calls.first == ScriptedDocker.activeContext && result.calls.last == builderPrune)
            #expect(result.calls.contains(ScriptedDocker.builderList))
        }
        // Commands that act on the daemon itself never ask about builders.
        #expect(run(imagePrune, local[0]).calls == [ScriptedDocker.activeContext, imagePrune])
    }

    @Test("A remote, cloud or unknown buildx builder, or one Docker can't describe, refuses docker builder commands")
    func remoteBuilder() {
        let refused: [(ScriptedDocker, String)] = [
            (ScriptedDocker(builders: ScriptedDocker.builders([("ci", "remote", ["tcp://buildkitd.example.com:1234"], true)])), "remote"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("cloud-me", "cloud", ["cloud://me/builder"], true)])), "cloud"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("k8s", "kubernetes", ["kubernetes:///kit"], true)])), "kubernetes"),
            (
                ScriptedDocker(builders: ScriptedDocker.builders([("kit", "docker-container", ["tcp://build.example.com:2376"], true)])),
                "tcp://build.example.com:2376"
            ),
            (
                ScriptedDocker(
                    builders: ScriptedDocker.builders([("ci", "docker", ["ci-box"], true)]), named: ["ci-box": "ssh://me@ci.example.com"]),
                "ssh://me@ci.example.com"
            ),
            (ScriptedDocker(builders: ScriptedDocker.builders([("gone", "docker", ["gone"], true)])), "does not exist"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("odd", "docker", ["-H"], true)])), "-H"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("empty", "docker-container", [], true)])), "no nodes"),
            (ScriptedDocker(builders: ScriptedDocker.builders([("idle", "docker", ["default"], false)])), "selected"),
            (ScriptedDocker(builders: Shell.Result(status: 0, output: "{\"Name\": \"kit\", \"Driver\":\n", timedOut: false)), "buildx ls"),
            (ScriptedDocker(builders: Shell.Result(status: 0, output: "NAME/NODE DRIVER/ENDPOINT\n", timedOut: false)), "buildx ls"),
            (
                ScriptedDocker(builders: Shell.Result(status: 1, output: "", timedOut: false, errors: "unknown command: docker buildx\n")),
                "unknown command"
            ),
        ]
        for (docker, mentioning) in refused {
            let result = run(builderPrune, docker)
            let reason = skipReason(result.outcome)
            #expect(reason?.contains(mentioning) == true, "\(mentioning): \(reason ?? "ran")")
            #expect(!result.calls.contains(builderPrune), "\(mentioning)")
        }
        // Noise on standard error doesn't spoil a builder list that is fine.
        var noisy = ScriptedDocker(builders: ScriptedDocker.builders([("kit", "docker-container", ["unix:///var/run/docker.sock"], true)]))
        noisy.builders.errors = "WARNING: buildx: git was not found in the system\n"
        #expect(run(builderPrune, noisy).outcome?.isRemoved == true)
    }
}
