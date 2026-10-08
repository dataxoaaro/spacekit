import Foundation

/// A plan as a person reviews it before anything is removed: the guard's verdict on every item and command, the rows
/// they untick, what the selection adds up to and where it goes. The app's review sheet, the TUI's dialog and the
/// CLI's preview render it and ask; only `acknowledge(acceptingWarnings:)` turns it into the `ReviewedPlan` that
/// `CleanupExecutor` runs by hand.
///
/// Verdicts are computed once, here. Blocked rows can't be selected and never reach the executor, which checks
/// everything else again right before removal.
public struct CleanupReview: Sendable {
    /// An item or a command with the guard's verdict, as the review shows it.
    public struct Row<Subject: Identifiable & Sendable>: Sendable, Identifiable where Subject.ID == String {
        public let subject: Subject
        public let verdict: SafetyVerdict
        fileprivate let key: Key

        public var id: String { subject.id }
        /// May run only once the person has seen `verdict.reasons` and accepted them.
        public var needsAcknowledgement: Bool { verdict.decision == .confirm }
    }

    /// Where the selected items end up.
    public enum Disposal: Sendable, Equatable {
        case moveToTrash
        case delete
        /// Every selected item is already in the Trash: removing it deletes it for good.
        case deleteFromTrash
    }

    /// Items and commands can share an id, so each kind keeps its own.
    fileprivate enum Key: Hashable, Sendable {
        case item(String)
        case command(String)
    }

    /// Largest first, the order every preview lists them in.
    public let items: [Row<CleanupItem>]
    public let commands: [Row<PlannedCommand>]
    /// Steps to take in another app. Shown, never run.
    public let manualSteps: [String]
    /// Whether items go to the Trash instead of being deleted.
    public private(set) var useTrash: Bool
    /// `false` when the config moves everything to the Trash (`safety.trash: always`), whatever `useTrash` says.
    public let canChooseTrash: Bool
    /// Ids of items already in the Trash.
    private let trashed: Set<String>
    /// Decides where items go, for the wording.
    private let remover: Remover
    private var unticked: Set<Key> = []

    public init(_ plan: CleanupPlan, executor: CleanupExecutor) {
        let remover = executor.remover
        // One target per item, as the plan recorded it, for both the verdict and where the item ends up.
        let targets = plan.itemsLargestFirst.map { ($0, remover.target(of: $0, probingRepositories: false)) }
        items = targets.map { item, target in
            Row(subject: item, verdict: executor.verdict(for: target, ruleID: item.ruleID, context: .manual), key: .item(item.id))
        }
        commands = plan.commands.map { Row(subject: $0, verdict: executor.verdict(for: $0, context: .manual), key: .command($0.id)) }
        manualSteps = plan.manualSteps
        useTrash = plan.useTrash
        canChooseTrash = !executor.alwaysTrash
        trashed = Set(targets.filter { remover.isInsideTrash($1) }.map { $0.0.id })
        self.remover = remover
    }

    // MARK: Selection

    /// Selected: not blocked, and not unticked by the person.
    public func isIncluded<Subject>(_ row: Row<Subject>) -> Bool {
        !row.verdict.isBlocked && !unticked.contains(row.key)
    }

    /// This review with `row` ticked or unticked. Ticking a blocked row changes nothing.
    public func including<Subject>(_ row: Row<Subject>, _ included: Bool) -> CleanupReview {
        var review = self
        if included { review.unticked.remove(row.key) } else { review.unticked.insert(row.key) }
        return review
    }

    /// This review with items going to the Trash (`true`) or deleted.
    public func usingTrash(_ useTrash: Bool) -> CleanupReview {
        var review = self
        review.useTrash = useTrash
        return review
    }

    public var selectedItems: [CleanupItem] { items.filter(isIncluded).map(\.subject) }
    public var selectedCommands: [PlannedCommand] { commands.filter(isIncluded).map(\.subject) }
    public var isEmpty: Bool { selectedItems.isEmpty && selectedCommands.isEmpty }

    // MARK: Counts and totals

    /// Selected rows whose warnings the person must accept before they run.
    public var warningCount: Int {
        items.filter { isIncluded($0) && $0.needsAcknowledgement }.count
            + commands.filter { isIncluded($0) && $0.needsAcknowledgement }.count
    }

    public var needsAcknowledgement: Bool { warningCount > 0 }

    public var blockedCount: Int {
        items.filter(\.verdict.isBlocked).count + commands.filter(\.verdict.isBlocked).count
    }

    /// Bytes of the selected items, as the scan measured them.
    public var itemBytes: UInt64 { selectedItems.reduce(0) { $0 &+ $1.size } }

    /// What the selected tool commands are expected to free; each tool decides what's unused.
    public var commandBytes: UInt64 { selectedCommands.reduce(0) { $0 &+ $1.estimatedBytes } }

    // MARK: Wording

    public var disposal: Disposal {
        let selected = selectedItems
        if !selected.isEmpty && selected.allSatisfy({ trashed.contains($0.id) }) { return .deleteFromTrash }
        return remover.method(inTrash: false, useTrash: useTrash, rule: nil, context: .manual) == .trash ? .moveToTrash : .delete
    }

    /// "1.2 GB will be moved to the Trash." `nil` with no item selected.
    public var disposalSummary: String? {
        guard !selectedItems.isEmpty else { return nil }
        let size = ByteCount.format(itemBytes)
        switch disposal {
        case .moveToTrash: return "\(size) will be moved to the Trash."
        case .delete: return "\(size) will be deleted permanently, not moved to the Trash."
        case .deleteFromTrash: return "\(size) is already in the Trash and will be deleted permanently."
        }
    }

    /// "2 tool commands will run; …" `nil` with no command selected.
    public var commandSummary: String? {
        let count = selectedCommands.count
        guard count > 0 else { return nil }
        return "\(count) tool command\(count == 1 ? "" : "s") will run; each removes only what its tool knows is unused."
    }

    // MARK: Acknowledgement

    /// The plan to run now that the person said go: the selected rows, without blocked or unticked ones.
    ///
    /// `acceptingWarnings`: the person was shown every reason of every selected row that needs acknowledgement and
    /// accepted them all, once for the whole plan. The reviewed plan records exactly those reasons for each row, and
    /// the executor refuses any warning outside them. Without it, such rows stay in the plan and the executor skips
    /// them as needing confirmation, so the report lists them.
    public func acknowledge(acceptingWarnings: Bool) -> ReviewedPlan {
        func shown<Subject>(_ rows: [Row<Subject>]) -> [String: Set<String>] {
            guard acceptingWarnings else { return [:] }
            let warned = rows.filter { isIncluded($0) && $0.needsAcknowledgement }
            return Dictionary(
                warned.map { ($0.id, Set($0.verdict.reasons.map(CleanupExecutor.reasonKey))) }, uniquingKeysWith: { $0.union($1) })
        }
        // With `safety.trash: always` the executor moves everything to the Trash, and the plan says so too.
        let plan = CleanupPlan(
            items: selectedItems, commands: selectedCommands, manualSteps: manualSteps, useTrash: useTrash || !canChooseTrash)
        return ReviewedPlan(plan: plan, accepted: AcceptedWarnings(items: shown(items), commands: shown(commands)))
    }
}

/// A plan a person reviewed and said go to. `CleanupReview.acknowledge(acceptingWarnings:)` alone makes one, and it is
/// the only plan `CleanupExecutor` runs by hand, so no front end can reach "manual and confirmed" without a review.
public struct ReviewedPlan: Sendable {
    /// The selected items and commands.
    public let plan: CleanupPlan
    let accepted: AcceptedWarnings

    fileprivate init(plan: CleanupPlan, accepted: AcceptedWarnings) {
        self.plan = plan
        self.accepted = accepted
    }
}

extension ReviewedPlan {
    /// Only the rows that are also in `plan`, with the warnings accepted for them.
    func limited(to plan: CleanupPlan) -> ReviewedPlan {
        let items = Set(plan.items.map(\.id))
        let commands = Set(plan.commands.map(\.id))
        var limited = self.plan
        limited.items = limited.items.filter { items.contains($0.id) }
        limited.commands = limited.commands.filter { commands.contains($0.id) }
        return ReviewedPlan(plan: limited, accepted: accepted)
    }
}

/// The warnings a person accepted in a review, by item and command id, as reason keys (`CleanupExecutor.reasonKey`).
/// Automatic runs have none.
struct AcceptedWarnings: Sendable {
    var items: [String: Set<String>] = [:]
    var commands: [String: Set<String>] = [:]

    static let none = AcceptedWarnings()
}
