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
    /// Where each item was judged, by id: the reviewed plan binds the person's go-ahead to it.
    private let locations: [String: RemovalTarget.Location]
    /// Decides where items go, for the wording.
    private let remover: Remover
    /// The executor the verdicts came from; only it runs the reviewed plan.
    private let settingsID: UUID
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
        canChooseTrash = remover.method(inTrash: false, useTrash: false, rule: nil, context: .manual) == .delete
        trashed = Set(targets.filter { remover.isInsideTrash($1) }.map { $0.0.id })
        locations = Dictionary(targets.map { ($0.id, $1.location) }, uniquingKeysWith: { first, _ in first })
        self.remover = remover
        settingsID = executor.settingsID
    }

    // MARK: Selection

    /// Selected: not blocked, and not unticked by the person.
    public func isIncluded<Subject>(_ row: Row<Subject>) -> Bool {
        !row.verdict.isBlocked && !unticked.contains(row.key)
    }

    /// This review with `row` ticked or unticked. Ticking a blocked row changes nothing.
    public func setting<Subject>(_ row: Row<Subject>, included: Bool) -> CleanupReview {
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
        return movesToTrash ? .moveToTrash : .delete
    }

    /// Items not already in the Trash go there, as the removal module decides for a manual run with `useTrash`.
    private var movesToTrash: Bool {
        remover.method(inTrash: false, useTrash: useTrash, rule: nil, context: .manual) == .trash
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
    /// accepted them all, once for the whole plan. Without it, such rows stay in the plan and the executor skips them
    /// as needing confirmation, so the report lists them.
    ///
    /// The reviewed plan records, for every selected row, the reasons the review showed and, for an item, the location
    /// it was judged at. The executor holds the run to that record: a reason the review didn't show for the row, or an
    /// item no longer at that location, skips the row as changed since the review.
    public func acknowledge(acceptingWarnings: Bool) -> ReviewedPlan {
        func record<Subject>(_ rows: [Row<Subject>], location: (Row<Subject>) -> RemovalTarget.Location?) -> [String: ReviewRecord.Row] {
            let selected = rows.filter(isIncluded).map { row in
                let accepted = acceptingWarnings || !row.needsAcknowledgement
                return (row.id, ReviewRecord.Row(shown: Set(row.verdict.reasons), accepted: accepted, location: location(row)))
            }
            // Two rows with one id (the same path listed twice) hold the run to what both of them showed.
            return Dictionary(selected, uniquingKeysWith: { $0.both($1) })
        }
        // The plan says what the removal module will do: with `safety.trash: always`, the Trash whatever `useTrash` says.
        let plan = CleanupPlan(items: selectedItems, commands: selectedCommands, manualSteps: manualSteps, useTrash: movesToTrash)
        let review = ReviewRecord(
            settingsID: settingsID, items: record(items) { locations[$0.id] }, commands: record(commands) { _ in nil })
        return ReviewedPlan(plan: plan, review: review)
    }
}

/// A plan a person reviewed and said go to. `CleanupReview.acknowledge(acceptingWarnings:)` alone makes one, and it is
/// the only plan `CleanupExecutor` runs by hand, so no front end can reach "manual and confirmed" without a review.
public struct ReviewedPlan: Sendable {
    /// The selected items and commands.
    public let plan: CleanupPlan
    let review: ReviewRecord

    fileprivate init(plan: CleanupPlan, review: ReviewRecord) {
        self.plan = plan
        self.review = review
    }
}

extension ReviewedPlan {
    /// Only the rows that are also in `plan`, with what the review recorded for them.
    func limited(to plan: CleanupPlan) -> ReviewedPlan {
        let items = Set(plan.items.map(\.id))
        let commands = Set(plan.commands.map(\.id))
        var limited = self.plan
        limited.items = limited.items.filter { items.contains($0.id) }
        limited.commands = limited.commands.filter { commands.contains($0.id) }
        return ReviewedPlan(plan: limited, review: review)
    }
}

/// What a person's review showed for each row, by item and command id, and which executor showed it. The executor
/// holds a manual run to it; automatic runs have none.
struct ReviewRecord: Sendable {
    /// One row as the review showed it.
    struct Row: Sendable {
        /// Every reason the review showed; none for a row it allowed outright.
        let shown: Set<String>
        /// The person accepted `shown` (or there was nothing to accept).
        let accepted: Bool
        /// Where the review judged an item. `nil` for a command.
        let location: RemovalTarget.Location?

        /// What two rows for the same thing both showed and the person accepted for both.
        func both(_ other: Row) -> Row {
            Row(shown: shown.intersection(other.shown), accepted: accepted && other.accepted, location: location)
        }

        /// A row with no record: everything about it is unseen.
        static let unseen = Row(shown: [], accepted: false, location: nil)

        /// Whether `reason`, raised at removal time, is one the review showed: the same text, or the same text with
        /// every number in it no larger. An item shown as holding 12% of the disk is the same warning at 11%, not
        /// at 45%: the person accepted removing that much, not more.
        func showed(_ reason: String) -> Bool {
            if shown.contains(reason) { return true }
            let raised = ReviewRecord.numbers(in: reason)
            return shown.contains { candidate in
                let seen = ReviewRecord.numbers(in: candidate)
                return seen.text == raised.text && seen.values.count == raised.values.count
                    && zip(raised.values, seen.values).allSatisfy { $0 <= $1 }
            }
        }
    }

    /// `CleanupExecutor.settingsID` of the executor whose verdicts the review showed.
    let settingsID: UUID
    let items: [String: Row]
    let commands: [String: Row]

    /// `reason` without its digits, and the numbers it holds in order.
    static func numbers(in reason: String) -> (text: String, values: [UInt64]) {
        var text = ""
        var values: [UInt64] = []
        var digits = ""
        for character in reason {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            if let value = UInt64(digits) { values.append(value) }
            digits = ""
            text.append(character)
        }
        if let value = UInt64(digits) { values.append(value) }
        return (text, values)
    }
}
