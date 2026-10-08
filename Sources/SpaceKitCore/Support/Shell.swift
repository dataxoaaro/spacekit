import Foundation
import Synchronization

/// Runs external tools directly (never through a shell), with a timeout.
public enum Shell {
    /// Directories searched for tools. launchd agents start with a minimal PATH, so common
    /// package-manager locations are always included.
    public static var searchPath: [String] {
        searchPath(environmentPATH: ProcessInfo.processInfo.environment["PATH"], home: PathUtil.home)
    }

    /// Relative PATH entries are dropped: they would resolve against whatever directory SpaceKit runs in.
    static func searchPath(environmentPATH: String?, home: String) -> [String] {
        let env = environmentPATH?.split(separator: ":").map(String.init) ?? []
        let extra = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
            "\(home)/.local/bin", "\(home)/.cargo/bin", "\(home)/go/bin", "\(home)/.bun/bin",
            "/Applications/Docker.app/Contents/Resources/bin", "\(home)/.orbstack/bin",
        ]
        var seen = Set<String>()
        return (env + extra).filter { $0.hasPrefix("/") && seen.insert($0).inserted }
    }

    /// True for a tool name without any path: `docker`, not `/usr/bin/docker` or `../docker`.
    /// A path would bypass the name-based allowlist, and a `{…}` placeholder would let an item name pick the program.
    public static func isBareName(_ name: String) -> Bool {
        !name.isEmpty && !name.contains("/") && !name.contains("..") && !name.contains("{")
    }

    /// Finds a tool by bare name in `directories` (`searchPath` unless a test names others), the first match in order.
    /// Paths are refused. The containing directory is canonicalized, but the tool keeps its own name: multi-call tools
    /// (rustup proxies, mise shims, bunx) pick their behavior from the name they were started as.
    public static func which(_ name: String, in directories: [String] = searchPath) -> String? {
        guard isBareName(name) else { return nil }
        for directory in directories {
            guard let real = PathUtil.realpath(directory) else { continue }
            let candidate = PathUtil.join(real, name)
            var st = stat()
            guard stat(candidate, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public struct Result: Sendable {
        public var status: Int32
        /// Standard output, and standard error too unless the run kept it apart.
        public var output: String
        public var timedOut: Bool
        /// Standard error of a run that kept it apart (`separateErrors`); empty otherwise.
        public var errors: String = ""
    }

    /// How long a tool gets to exit after SIGTERM before it (and its process group) gets SIGKILL.
    static let terminationGrace: TimeInterval = 1

    /// Who started a tool, which decides the variables it keeps.
    public enum RunKind: Sendable {
        /// A person: their review showed the command, and the tool cleans the cache SpaceKit measured for them.
        case manual
        /// The background agent, with nobody watching. Any process of the person's can set the agent's variables
        /// (`launchctl setenv`), so a tool keeps only who and where the person is: no tool home, `XDG_*` folder or
        /// Homebrew setting that would steer what the tool deletes.
        case automatic
    }

    /// Variables an automatic run's tool keeps: who and where the person is, and their locale (`LC_*` too).
    static let automaticVariables: Set<String> = ["HOME", "USER", "LOGNAME", "LANG", "TMPDIR"]

    /// Variables a manual run's tool keeps from SpaceKit's environment: who and where the person is, their locale, and
    /// the variables that move a tool's own cache, so a tool cleans the cache SpaceKit measured. DEVELOPER_DIR isn't one:
    /// it picks the folder `xcrun` starts developer tools from, so any process of the person's could set it (through
    /// `launchctl setenv`) to a folder of its own and have its program run with SpaceKit's Full Disk Access.
    static let keptVariables: Set<String> = [
        "HOME", "USER", "LOGNAME", "LANG", "TMPDIR",
        "CARGO_HOME", "RUSTUP_HOME", "GOPATH", "GOMODCACHE", "GOCACHE", "npm_config_cache", "NPM_CONFIG_CACHE", "PNPM_HOME",
        "YARN_CACHE_FOLDER", "GRADLE_USER_HOME", "OLLAMA_MODELS",
    ]
    /// `HOMEBREW_*` covers Homebrew's own settings, which decide what `brew cleanup` keeps (HOMEBREW_NO_CLEANUP_FORMULAE,
    /// HOMEBREW_CLEANUP_MAX_AGE_DAYS) as well as its cache and prefix.
    static let keptPrefixes = ["LC_", "XDG_", "HOMEBREW_"]
    /// Parts of a name that mark a credential, which stays behind even under a kept prefix (HOMEBREW_GITHUB_API_TOKEN).
    static let credentialMarks = ["TOKEN", "PASSWORD", "PASSWD", "SECRET", "KEY", "AUTH", "CREDENTIAL"]

    /// The environment a tool runs with: for a manual run `keptVariables` and `keptPrefixes` from `environment`, minus
    /// credentials, for an automatic run `automaticVariables` and `LC_*`; and PATH set to `searchPath`. Everything else
    /// stays behind. A variable can point a tool somewhere else entirely
    /// (DOCKER_HOST at another machine's daemon, OLLAMA_HOST at another server), load code into it (DYLD_*,
    /// NODE_OPTIONS) or hand it credentials (tokens, SSH_AUTH_SOCK), and SpaceKit runs with Full Disk Access, often
    /// from an agent nobody watches. Every tool SpaceKit starts gets it, its own helpers too (launchctl, tmutil,
    /// osascript, open), so no caller can forget it.
    public static func toolEnvironment(from environment: [String: String], home: String, kind: RunKind = .manual) -> [String: String] {
        var kept = environment.filter { name, _ in
            if kind == .automatic { return automaticVariables.contains(name) || name.hasPrefix("LC_") }
            guard keptVariables.contains(name) || keptPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
            let upper = name.uppercased()
            return !credentialMarks.contains { upper.contains($0) }
        }
        kept["PATH"] = searchPath(environmentPATH: environment["PATH"], home: home).joined(separator: ":")
        return kept
    }

    /// Runs a tool and waits until it has exited and closed its output, or until `timeout`. A tool that is still
    /// running then, or left a background child holding its output, is sent SIGTERM and then SIGKILL; its
    /// process group goes with it. Timed-out runs report status -2. The tool gets `toolEnvironment(from:kind:)` of
    /// `environment`, never SpaceKit's own environment as is. `separateErrors` keeps standard error out of `output`
    /// (in `errors`), for a tool whose output is read as an answer, where a warning must not pass for one.
    public static func run(
        _ executable: String, _ arguments: [String], timeout: TimeInterval = 120,
        environment: [String: String] = ProcessInfo.processInfo.environment, separateErrors: Bool = false, kind: RunKind = .manual
    ) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = toolEnvironment(from: environment, home: PathUtil.home, kind: kind)
        process.standardInput = FileHandle.nullDevice
        let capture = Capture(process, separateErrors: separateErrors)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            capture.close()
            return Result(status: -1, output: error.localizedDescription, timedOut: false)
        }
        let timedOut = !finished(process.processIdentifier, exited: exited, ended: capture.ended, timeout: timeout)
        capture.close()
        return Result(
            status: timedOut ? -2 : process.terminationStatus, output: capture.output.text, timedOut: timedOut,
            errors: capture.errors.text)
    }

    /// Waits until the tool has exited and its output has ended, for at most `timeout`. A tool that hasn't by then
    /// gets SIGTERM, then SIGKILL after `terminationGrace`, with its process group. True when it finished in time.
    private static func finished(_ pid: pid_t, exited: DispatchSemaphore, ended: DispatchGroup, timeout: TimeInterval) -> Bool {
        // Process starts each tool in its own process group, so the group holds everything it spawned.
        let ownsGroup = getpgid(pid) == pid
        let deadline = DispatchTime.now() + timeout
        var hasExited = exited.wait(timeout: deadline) == .success
        var hasEnded = hasExited && ended.wait(timeout: deadline) == .success
        if hasExited && hasEnded { return true }
        func send(_ signal: Int32) {
            if ownsGroup { killpg(pid, signal) } else if !hasExited { kill(pid, signal) }
        }
        send(SIGTERM)
        let graceEnd = DispatchTime.now() + terminationGrace
        if !hasExited { hasExited = exited.wait(timeout: graceEnd) == .success }
        if hasExited && !hasEnded { hasEnded = ended.wait(timeout: graceEnd) == .success }
        if !(hasExited && hasEnded) {
            send(SIGKILL)
            if !hasExited { _ = exited.wait(timeout: .now() + terminationGrace) }
        }
        return false
    }

    /// A tool's output pipes and what has been read from them: standard output, and standard error in the same pipe
    /// unless it is kept apart.
    private struct Capture {
        let pipes: [Pipe]
        let output = OutputBuffer()
        let errors = OutputBuffer()
        /// Left once per pipe, when that pipe reaches its end.
        let ended = DispatchGroup()

        init(_ process: Process, separateErrors: Bool) {
            let pipe = Pipe()
            let errorPipe = separateErrors ? Pipe() : nil
            pipes = [pipe] + (errorPipe.map { [$0] } ?? [])
            process.standardOutput = pipe
            process.standardError = errorPipe ?? pipe
            for (reading, buffer) in zip(pipes, [output, errors]) {
                ended.enter()
                reading.fileHandleForReading.readabilityHandler = { [ended] handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty { handle.readabilityHandler = nil }
                    if buffer.append(chunk) { ended.leave() }
                }
            }
        }

        func close() {
            for reading in pipes {
                reading.fileHandleForReading.readabilityHandler = nil
                try? reading.fileHandleForReading.close()
            }
        }
    }

    /// Keeps the last 64 KB of a tool's output.
    private final class OutputBuffer: Sendable {
        private static let limit = 64 * 1024
        private let state = Mutex<(data: Data, ended: Bool)>((Data(), false))

        /// Returns true exactly once, when the output reaches its end.
        func append(_ chunk: Data) -> Bool {
            state.withLock { state in
                if chunk.isEmpty {
                    defer { state.ended = true }
                    return !state.ended
                }
                state.data.append(chunk)
                if state.data.count > 2 * OutputBuffer.limit { state.data = Data(state.data.suffix(OutputBuffer.limit)) }
                return false
            }
        }

        var text: String {
            state.withLock { String(decoding: $0.data.suffix(OutputBuffer.limit), as: UTF8.self) }
        }
    }
}
