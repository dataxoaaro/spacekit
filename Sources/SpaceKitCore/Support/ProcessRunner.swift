import Foundation

/// How the executor finds and runs tools. `SystemProcessRunner` runs them for real; tests stand in a recorder, so
/// what a run would start, and what it charges to its budget, can be checked without starting anything.
protocol ProcessRunner: Sendable {
    /// The environment SpaceKit runs in. A tool never gets it as is (`Shell.toolEnvironment`).
    var environment: [String: String] { get }
    /// Where the tool with this bare name is installed, or `nil` when it isn't.
    func locate(_ name: String) -> String?
    /// Every place the tool with this bare name is installed, the one `locate` finds first.
    func locateAll(_ name: String) -> [String]
    /// Runs a tool without a shell, with stdin from /dev/null and the cleaned environment, until it exits or
    /// `timeout` passes.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Shell.Result
}

/// Runs tools as `Process`es, through `Shell`.
struct SystemProcessRunner: ProcessRunner {
    var environment: [String: String] { ProcessInfo.processInfo.environment }

    func locate(_ name: String) -> String? { Shell.which(name) }

    func locateAll(_ name: String) -> [String] { Shell.installed(name, in: Shell.searchPath) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) -> Shell.Result {
        Shell.run(executable, arguments, timeout: timeout, environment: environment)
    }
}
