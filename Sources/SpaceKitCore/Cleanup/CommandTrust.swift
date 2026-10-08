import Foundation

/// Whether a rule's tool command may run. One place decides it from where the rule came from (built into SpaceKit or
/// a person's own file), how the run started (a reviewed manual run or an automatic one) and the executable policy:
/// the built-in trusted list, `safety.allowedCommands` and the code launchers nobody may allow. Rule validation asks
/// the same module, so `spacekit rules validate` warns about exactly what the executor will refuse.
public struct CommandTrust: Sendable {
    /// Executables that built-in rule commands may run without the person listing them in `safety.allowedCommands`.
    public static let trustedCommands: Set<String> = [
        "brew", "docker", "xcrun", "npm", "pnpm", "yarn", "bun", "ollama", "go", "cargo", "pip", "pip3",
        "uv", "conda", "mamba", "gem", "pod", "flutter", "dart", "gradle", "huggingface-cli", "hf", "mise", "rustup",
        "orb", "podman", "colima", "swift", "deno",
    ]

    /// Executables that run whatever code or program their arguments name. Allowing one would let any rule file,
    /// and anything that can write one, run arbitrary code with SpaceKit's Full Disk Access. Names are lower case,
    /// as `isCodeLauncher` compares them.
    static let codeLaunchers: Set<String> = [
        // Shells.
        "sh", "bash", "zsh", "fish", "dash", "ksh", "mksh", "oksh", "csh", "tcsh", "pwsh", "nu",
        // Interpreters and runtimes that run code given on the command line or in a file it names.
        "python", "perl", "ruby", "irb", "node", "nodejs", "deno", "bun", "bunx", "npx", "php", "lua", "luajit", "tclsh", "wish",
        "expect", "r", "rscript", "java", "jshell", "julia", "awk", "gawk", "nawk", "mawk", "sqlite3", "osascript", "swift",
        // Tools that start another program, or run commands their arguments or configuration give them (git aliases and
        // hooks, make recipes, rsync -e, ssh's ProxyCommand, xcrun's developer tools).
        "env", "arch", "nohup", "nice", "time", "timeout", "gtimeout", "caffeinate", "sudo", "su", "doas", "script", "xargs",
        "find", "open", "xcrun", "make", "gmake", "git", "ssh", "rsync", "launchctl", "sandbox-exec", "watch", "parallel",
        "stdbuf", "unbuffer", "chroot",
    ]

    /// True for shells, interpreters and launchers, including versioned names (`python3.12`, `perl5.30`). Names are
    /// compared with full Unicode case folding, the way APFS looks them up: `/bin/baſh` is `/bin/bash` and `SH` is `sh`.
    public static func isCodeLauncher(_ executable: String) -> Bool {
        let name = executable.trimmingCharacters(in: .whitespaces).folding(options: [.caseInsensitive], locale: nil)
        if name.hasPrefix("python") { return true }
        let unversioned = String(name.reversed().drop { $0.isNumber || $0 == "." }.reversed())
        return codeLaunchers.contains(name) || codeLaunchers.contains(unversioned)
    }

    /// True for a name `safety.allowedCommands` may hold: ASCII letters, digits, `.`, `_`, `+` and `-`. Any other
    /// character could reach a launcher through the file system's case and normalization folding, or pass for a
    /// name it isn't.
    public static func isPlainName(_ executable: String) -> Bool {
        !executable.isEmpty && executable.unicodeScalars.allSatisfy { plainNameCharacters.contains($0) }
    }

    private static let plainNameCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyz" + "ABCDEFGHIJKLMNOPQRSTUVWXYZ" + "0123456789" + "._+-")

    /// Why a `safety.allowedCommands` entry can't be allowed, or `nil`. Config validation and the executor say the same.
    public static func allowedCommandProblem(_ executable: String) -> String? {
        if isCodeLauncher(executable) { return "'\(executable)' runs whatever code its arguments name, so it can't be allowed" }
        guard isPlainName(executable) else {
            return "'\(executable)' isn't a plain tool name; list tools by names made of ASCII letters, digits, '.', '_', '+' and '-'"
        }
        return nil
    }

    /// `safety.allowedCommands`: executables allowed beyond the trusted list, and the only ones a person's own rules
    /// may run. A code launcher listed here never counts.
    public let allowedCommands: Set<String>

    public init(allowedCommands: Set<String>) {
        self.allowedCommands = allowedCommands
    }

    /// Why `command`, planned from `rule`, may not run in `context`; empty when it may.
    public func refusals(_ command: PlannedCommand, rule: Rule, context: CleanupContext) -> [String] {
        var reasons: [String] = []
        if let refusal = executableRefusal(command.arguments.first ?? "", isBuiltin: rule.isBuiltin, context: context) {
            reasons.append(refusal)
        }
        if let name = substitutedName(command, rule: rule), name.isEmpty || name.hasPrefix("-") {
            reasons.append("'\(name)' would reach the tool as an option, not a name, so it isn't passed to it")
        }
        return reasons
    }

    /// The value a command put in place of `{name}`: a model's name, or an item's last path component when the
    /// rule's `itemCommand` uses `{name}`. `{path}` is absolute, so it can't be taken for an option.
    private func substitutedName(_ command: PlannedCommand, rule: Rule) -> String? {
        if let model = command.modelName { return model }
        guard let itemPath = command.itemPath, rule.action.itemCommand?.contains(where: { $0.contains("{name}") }) == true else {
            return nil
        }
        return PathUtil.lastComponent(itemPath)
    }

    /// Built-in rules may use `trustedCommands`; every other rule only `allowedCommands`, and only in manual runs.
    /// A code launcher never counts as allowed, whoever lists it.
    func executableRefusal(_ executable: String, isBuiltin: Bool, context: CleanupContext) -> String? {
        guard Shell.isBareName(executable) else {
            return "Commands must name a tool by its bare name, not a path: '\(executable)'"
        }
        // The agent runs as the person with Full Disk Access, and any process of theirs can write a rule file. So
        // a command from outside the built-in library runs only when the person reviews and starts it by hand.
        if !isBuiltin && context.isAutomatic {
            return "'\(executable)' comes from a rule outside SpaceKit's built-in library; automatic runs never run those, run it by hand"
        }
        if isBuiltin && CommandTrust.trustedCommands.contains(executable) { return nil }
        if let problem = CommandTrust.allowedCommandProblem(executable) { return problem }
        if allowedCommands.contains(executable) { return nil }
        if isBuiltin { return "'\(executable)' isn't a trusted command; add it to safety.allowedCommands to allow it" }
        return CommandTrust.untrustedRuleCommand(executable)
    }

    /// Why the program a command found may not start, checked right before it would: the name may run, but the file
    /// may not be what the name says. `name` is the command's bare name, `executable` where it was found.
    func launchRefusal(_ name: String, at executable: String, isBuiltin: Bool, runner: any ProcessRunner) -> String? {
        if !(isBuiltin && CommandTrust.trustedCommands.contains(name)),
            let refusal = launcherIdentityRefusal(name, at: executable, runner: runner)
        {
            return refusal
        }
        return endpointRefusal(name, runner: runner)
    }

    /// Why the program found for the allowed name `name` is a code launcher after all, or `nil`. A name check can't
    /// see a symlink, a hard link or a copy of `sh` that a rule calls `cleanup-tool`, so the file is compared with
    /// every copy of each launcher on the search path the command was found on: same real path, same (device, inode),
    /// or same bytes.
    func launcherIdentityRefusal(_ name: String, at executable: String, runner: any ProcessRunner) -> String? {
        guard let program = ProgramFile(executable) else {
            return "Couldn't read '\(name)' at \(executable) to check which program it is"
        }
        for launcher in CommandTrust.locatableLaunchers {
            for path in runner.locateAll(launcher) {
                guard let other = ProgramFile(path), program.isSameProgram(as: other) else { continue }
                return "'\(name)' is the same program as '\(launcher)' (\(path)), which runs whatever code its arguments name, "
                    + "so it can't be allowed"
            }
        }
        return nil
    }

    /// Launcher names to look up for `launcherIdentityRefusal`, in a fixed order so the reason names the same one each time.
    private static let locatableLaunchers = (codeLaunchers.union(["python3"])).sorted()

    /// Why a command from a rule outside the built-in library doesn't run: the validation warning and the
    /// executor's refusal say the same thing.
    static func untrustedRuleCommand(_ executable: String) -> String {
        "'\(executable)' comes from a rule outside SpaceKit's built-in library; built-in trust covers SpaceKit's own rules only. "
            + "It runs only in manual runs, and only if you add it to safety.allowedCommands"
    }

    /// What validating a rule says about one of its commands: errors keep the rule from loading, warnings say what
    /// the executor will refuse.
    static func ruleIssues(_ command: [String], isBuiltin: Bool) -> [(severity: RuleIssue.Severity, message: String)] {
        guard let executable = command.first, Shell.isBareName(executable) else {
            let got = command.first ?? ""
            return [(.error, "command must start with a bare program name such as brew, without / or .. or {name}; got '\(got)'")]
        }
        var issues: [(RuleIssue.Severity, String)] = []
        if isBuiltin {
            if !trustedCommands.contains(executable) {
                let message = "command '\(executable)' is not in the trusted list; it only runs if listed in safety.allowedCommands"
                issues.append((.warning, message))
            }
        } else if let problem = allowedCommandProblem(executable) {
            issues.append((.warning, "command '\(executable)' never runs: safety.allowedCommands can't list it (\(problem))"))
        } else {
            issues.append((.warning, untrustedRuleCommand(executable)))
        }
        if command.contains(where: { $0.contains(";") || $0.contains("&&") || $0.contains("|") || $0.contains("`") || $0.contains("$(") }) {
            issues.append((.error, "commands run without a shell; remove shell syntax (; && | ` $( )"))
        }
        return issues
    }

    // MARK: Where the tool acts

    /// The `docker context inspect` call that tells which daemon `docker` would talk to.
    static let dockerEndpointQuery = ["context", "inspect", "--format", "{{.Endpoints.docker.Host}}"]

    /// Why a tool would act on something other than this Mac, or `nil`. Docker rules prune images and build cache,
    /// and a Docker CLI can be pointed at a daemon on another machine (a CI builder, a shared server). Those
    /// commands run only when the daemon is reached through a unix socket, which is how Docker Desktop, OrbStack,
    /// Colima and Podman's Docker socket serve a local VM. Tools run without DOCKER_HOST and DOCKER_CONTEXT (see
    /// `Shell.toolEnvironment`), so the context `docker context inspect` reports in that environment is the one the
    /// command uses.
    func endpointRefusal(_ executable: String, runner: any ProcessRunner) -> String? {
        guard executable == "docker" else { return nil }
        if let host = runner.environment["DOCKER_HOST"], !host.isEmpty, !host.hasPrefix("unix://") {
            return "DOCKER_HOST points Docker at \(CommandTrust.shown(host)), not at a socket on this Mac; "
                + "SpaceKit only cleans a Docker running on this Mac"
        }
        guard let docker = runner.locate(executable) else { return nil }
        let result = runner.run(docker, CommandTrust.dockerEndpointQuery, timeout: 30)
        let endpoint = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, !result.timedOut else {
            return "Couldn't tell which Docker the active context uses (docker context inspect: \(CommandTrust.shown(endpoint)))"
        }
        guard endpoint.hasPrefix("unix://") else {
            return "The active Docker context points at \(endpoint.isEmpty ? "no endpoint" : CommandTrust.shown(endpoint)), "
                + "not at a socket on this Mac; SpaceKit only cleans a Docker running on this Mac (docker context use)"
        }
        return nil
    }

    /// Tool output quoted in a reason: one line, kept short.
    private static func shown(_ text: String) -> String {
        let line = text.split(separator: "\n").first.map(String.init) ?? ""
        return line.count > 120 ? String(line.prefix(120)) + "…" : line
    }
}

/// The file a program name leads to, as far as telling two programs apart goes.
private struct ProgramFile {
    let realPath: String
    let device: dev_t
    let inode: ino_t
    let size: off_t

    /// `nil` when nothing readable is there.
    init?(_ path: String) {
        var st = stat()
        guard stat(path, &st) == 0, let real = PathUtil.realpath(path) else { return nil }
        realPath = real
        device = st.st_dev
        inode = st.st_ino
        size = st.st_size
    }

    func isSameProgram(as other: ProgramFile) -> Bool {
        if realPath == other.realPath || (device == other.device && inode == other.inode) { return true }
        return size == other.size && FileManager.default.contentsEqual(atPath: realPath, andPath: other.realPath)
    }
}
