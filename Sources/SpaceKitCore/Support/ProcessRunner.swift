import Foundation

/// How the executor finds and runs tools. `SystemProcessRunner` runs them for real; tests stand in a recorder, so
/// what a run would start, and what it charges to its budget, can be checked without starting anything.
protocol ProcessRunner: Sendable {
    /// Where the tool with this bare name is installed, the first match on the search path, or `nil` when it isn't.
    func locate(_ name: String) -> String?
    /// Runs a tool without a shell, with stdin from /dev/null and the cleaned environment for `kind` of run, until it
    /// exits or `timeout` passes. `separateErrors` keeps standard error out of `output` (in `errors`), for a tool whose
    /// output is read as an answer, where a warning must not pass for one.
    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, separateErrors: Bool, kind: Shell.RunKind)
        -> Shell.Result
}

/// Runs tools as `Process`es, through `Shell`, in the cleaned environment built from SpaceKit's own.
struct SystemProcessRunner: ProcessRunner {
    func locate(_ name: String) -> String? { Shell.which(name) }

    func run(_ executable: String, _ arguments: [String], timeout: TimeInterval, separateErrors: Bool, kind: Shell.RunKind)
        -> Shell.Result
    {
        Shell.run(executable, arguments, timeout: timeout, separateErrors: separateErrors, kind: kind)
    }
}
