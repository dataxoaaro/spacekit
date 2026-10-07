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

    /// Items skipped because they gained a warning after the preview, which the person never saw.
    public var changedSinceReview: [(item: CleanupItem, reason: String)] {
        items.compactMap { entry in
            guard case .skipped(let reason) = entry.outcome, reason.hasPrefix(CleanupExecutor.changedSinceReview) else {
                return nil
            }
            return (entry.item, reason)
        }
    }

    /// The run didn't do everything it was asked to: an item failed or changed since the preview, a command was
    /// skipped or failed, or a warning was raised. Other skipped items don't count: the preview showed them as
    /// blocked. Front ends report this as an error (the CLI exits nonzero).
    public var hasProblems: Bool {
        !failures.isEmpty || !changedSinceReview.isEmpty || !unfinishedCommands.isEmpty || !warnings.isEmpty
    }

    /// At least one item was removed or one command ran.
    public var removedAnything: Bool {
        items.contains { $0.outcome.isRemoved } || commands.contains { $0.outcome.isRemoved }
    }
}
