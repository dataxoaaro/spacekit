import Foundation

/// Where a `docker` command acts. Docker rules prune images and build cache, and a Docker CLI can be pointed at a
/// daemon or a BuildKit builder on another machine (a CI builder, a shared server, Docker Build Cloud). Those commands
/// run only when what they reach is served through a unix socket on this Mac, which is how Docker Desktop, OrbStack,
/// Colima and Podman's Docker socket serve a local VM.
///
/// Every question goes to `docker` itself, through the runner, in the cleaned environment the command's run gets: without
/// DOCKER_HOST, DOCKER_CONTEXT or BUILDX_BUILDER (see `Shell.toolEnvironment`). So the active context and the
/// selected builder it reports are the ones the command uses, whatever SpaceKit's own environment says. Answers are
/// read from standard output only; anything that can't be read as an answer refuses the command.
extension CommandTrust {
    /// How long Docker gets to answer one question.
    static let dockerQueryTimeout: TimeInterval = 30
    /// Longest piece of tool output quoted in a reason.
    static let shownOutputLength = 120

    /// `buildx` drivers that build inside a Docker daemon; the daemon's endpoint then says where.
    static let localBuilderDrivers: Set<String> = ["docker", "docker-container"]

    /// Why `arguments`, a `docker` command, would act somewhere other than this Mac, or `nil`.
    func dockerRefusal(_ arguments: [String], docker: DockerCLI) -> String? {
        let active = CommandTrust.dockerEndpoint(of: nil, docker: docker)
        switch active {
        case .failure(let problem):
            return "Couldn't tell which Docker the active context uses (docker context inspect: \(problem))"
        case .success(let endpoint) where !endpoint.hasPrefix("unix://"):
            return "The active Docker context points at \(endpoint.isEmpty ? "no endpoint" : CommandTrust.shown(endpoint)), "
                + "not at a socket on this Mac; SpaceKit only cleans a Docker running on this Mac (docker context use)"
        case .success:
            break
        }
        // `docker builder` (an alias of `docker buildx` since Docker 23) acts on the selected buildx builder, which
        // can be remote even when the context is local.
        guard arguments.count > 1, ["builder", "buildx"].contains(arguments[1]) else { return nil }
        return builderRefusal(docker: docker)
    }

    /// Why the selected buildx builder isn't this Mac's Docker, or `nil` when it is: its driver builds in a Docker
    /// daemon, and every node's endpoint is a unix socket or a context whose endpoint is one.
    private func builderRefusal(docker: DockerCLI) -> String? {
        let listed = docker.ask(["buildx", "ls", "--format", "json"])
        guard listed.status == 0, !listed.timedOut else {
            return "Couldn't tell which buildx builder docker builder uses (docker buildx ls: \(CommandTrust.problem(listed)))"
        }
        guard let builders = BuildxBuilder.list(listed.output) else {
            return "Couldn't read the builders docker buildx ls listed, so SpaceKit can't tell where docker builder acts"
        }
        guard let builder = builders.first(where: \.isCurrent) else {
            return "docker buildx ls shows no selected builder, so SpaceKit can't tell where docker builder acts"
        }
        let name = CommandTrust.shown(builder.name)
        guard CommandTrust.localBuilderDrivers.contains(builder.driver) else {
            return "The selected buildx builder \(name) uses the \(CommandTrust.shown(builder.driver)) driver, which builds outside this "
                + "Mac's Docker; SpaceKit only prunes a builder in a Docker running on this Mac (docker buildx use)"
        }
        guard !builder.endpoints.isEmpty else { return "The selected buildx builder \(name) has no nodes to check" }
        for endpoint in builder.endpoints {
            if let refusal = nodeRefusal(endpoint, builder: name, docker: docker) { return refusal }
        }
        return nil
    }

    /// Why one node of a builder isn't on this Mac. A node names a socket (`unix://…`) or a Docker context, which is
    /// looked up the same way as the active one.
    private func nodeRefusal(_ endpoint: String, builder: String, docker: DockerCLI) -> String? {
        let shownEndpoint = CommandTrust.shown(endpoint)
        if endpoint.hasPrefix("unix://") { return nil }
        guard !endpoint.isEmpty, !endpoint.contains("://"), !endpoint.hasPrefix("-") else {
            return "The selected buildx builder \(builder) runs at \(shownEndpoint), not at a socket on this Mac; "
                + "SpaceKit only prunes a builder in a Docker running on this Mac"
        }
        switch CommandTrust.dockerEndpoint(of: endpoint, docker: docker) {
        case .failure(let problem):
            return "Couldn't tell where the context \(shownEndpoint) of buildx builder \(builder) points (\(problem))"
        case .success(let host) where !host.hasPrefix("unix://"):
            return "The selected buildx builder \(builder) uses the context \(shownEndpoint) at \(CommandTrust.shown(host)), "
                + "not a socket on this Mac; SpaceKit only prunes a builder in a Docker running on this Mac"
        case .success:
            return nil
        }
    }

    /// The Docker endpoint of the context named `context`, or of the active one: the single line `docker context
    /// inspect` prints on standard output.
    private static func dockerEndpoint(of context: String?, docker: DockerCLI) -> Result<String, Unanswered> {
        let arguments = ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"] + (context.map { [$0] } ?? [])
        let result = docker.ask(arguments)
        guard result.status == 0, !result.timedOut else { return .failure(Unanswered(problem(result))) }
        let lines = result.output.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        let answer = lines.filter { !$0.isEmpty }
        guard answer.count <= 1 else { return .failure(Unanswered("more than one endpoint: \(shown(result.output))")) }
        return .success(answer.first ?? "")
    }

    /// Why a query gave no answer, for a reason: its standard error, else its output, else its status.
    private static func problem(_ result: Shell.Result) -> String {
        if result.timedOut { return "no answer within \(Int(dockerQueryTimeout)) seconds" }
        let said = shown(result.errors.isEmpty ? result.output : result.errors)
        return said.isEmpty ? "exited with status \(result.status)" : said
    }

    /// Tool output quoted in a reason: one line, kept short.
    static func shown(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.count > shownOutputLength ? String(line.prefix(shownOutputLength)) + "…" : line
    }

    private struct Unanswered: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The `docker` a command found, asked questions the way the command will run: through the runner, in the environment
/// its run gets, with standard error kept apart from the answer.
struct DockerCLI {
    let path: String
    let runner: any ProcessRunner
    let kind: Shell.RunKind

    func ask(_ arguments: [String]) -> Shell.Result {
        runner.run(path, arguments, timeout: CommandTrust.dockerQueryTimeout, separateErrors: true, kind: kind)
    }
}

/// One builder as `docker buildx ls --format json` describes it.
private struct BuildxBuilder: Decodable {
    let name: String
    let driver: String
    let isCurrent: Bool
    let endpoints: [String]

    private struct Node: Decodable {
        let endpoint: String?
        enum CodingKeys: String, CodingKey { case endpoint = "Endpoint" }
    }

    enum CodingKeys: String, CodingKey {
        case name = "Name"
        case driver = "Driver"
        case current = "Current"
        case nodes = "Nodes"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        driver = try c.decode(String.self, forKey: .driver)
        isCurrent = try c.decodeIfPresent(Bool.self, forKey: .current) ?? false
        // A node without an endpoint can't be checked; an empty one is refused like any other that isn't a socket.
        endpoints = try (c.decodeIfPresent([Node].self, forKey: .nodes) ?? []).map { $0.endpoint ?? "" }
    }

    /// The builders in `output`: one JSON object per line, or a JSON array. `nil` when any of it isn't one.
    static func list(_ output: String) -> [BuildxBuilder]? {
        let decoder = JSONDecoder()
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") { return try? decoder.decode([BuildxBuilder].self, from: Data(text.utf8)) }
        var builders: [BuildxBuilder] = []
        for line in text.split(whereSeparator: \.isNewline) where !line.allSatisfy(\.isWhitespace) {
            guard let builder = try? decoder.decode(BuildxBuilder.self, from: Data(line.utf8)) else { return nil }
            builders.append(builder)
        }
        return builders.isEmpty ? nil : builders
    }
}
