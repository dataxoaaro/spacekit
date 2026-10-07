import Foundation

extension CleanupReport {
    /// Commands that were refused, couldn't start, or didn't finish, with the reason.
    public var unfinishedCommands: [(command: PlannedCommand, reason: String)] {
        commands.compactMap { entry in
            switch entry.outcome {
            case .skipped(let reason), .failed(let reason): return (entry.command, reason)
            case .removed, .wouldRemove: return nil
            }
        }
    }

    /// The run didn't do everything it was asked to: an item failed, a command was skipped or failed, or a
    /// warning was raised. Items the guard skipped don't count; the preview already showed they would be.
    /// Front ends report this as an error (the CLI exits nonzero).
    public var hasProblems: Bool { !failures.isEmpty || !unfinishedCommands.isEmpty || !warnings.isEmpty }

    /// At least one item was removed or one command ran.
    public var removedAnything: Bool {
        items.contains { $0.outcome.isRemoved } || commands.contains { $0.outcome.isRemoved }
    }
}
