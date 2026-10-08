import Foundation

/// How one item leaves its place: the target it's judged and removed by, whether it goes to the Trash or is deleted,
/// and the move or deletion itself, both checked against the target.
///
/// `CleanupExecutor` drives it per item, between the guard, the budget and the journal. Everything here works from one
/// `RemovalTarget`, built once per item, so the guard, the decision and the removal can't see different locations.
struct Remover: Sendable {
    enum Method: Sendable, Equatable {
        case trash, delete

        var journalMethod: JournalEntry.Method { self == .trash ? .trash : .delete }
    }

    /// What a removal did.
    struct Removed: Sendable, Equatable {
        /// Where the item went in the Trash. `nil` when it was deleted.
        var trashedTo: String?
        /// Folders inside the item left because another volume is mounted on them; everything else was removed.
        var leftOnOtherVolumes: [String] = []
    }

    /// A deletion that began and stopped part way: some of the item may be gone. Errors thrown before anything was
    /// removed (the folder or the item no longer what the target pinned) are not this.
    struct Interrupted: LocalizedError {
        let cause: Error
        /// Folders left because another volume is mounted on them, besides what couldn't be removed.
        var leftOnOtherVolumes: [String] {
            (cause as? SafeRemoval.Incomplete)?.leftOnOtherVolumes ?? []
        }

        var errorDescription: String? { cause.localizedDescription }
    }

    let home: String
    /// `safety.trash: always`.
    let alwaysTrash: Bool
    /// Resolves the folder an item is removed from.
    let resolve: @Sendable (String) -> String?
    /// Moves a path to the Trash and returns where it went.
    let trash: @Sendable (String) throws -> String?
    /// Reads the device of an open folder, to stay on the item's volume while deleting.
    let device: SafeRemoval.DeviceReader

    var trashDirectory: String { Trash.path(home: home) }

    // MARK: Target

    /// The item's target, from the disk as it is now. Loose files are targeted as their folder's `*`: the folder is
    /// what's pinned, and each file's own target derives from it (`RemovalTarget.entry`).
    func target(of item: CleanupItem, probingRepositories: Bool) -> RemovalTarget {
        let path = item.kind == .looseFiles ? CleanupItem.looseFilesPath(in: item.path) : item.path
        let repositories: RemovalTarget.Repositories =
            probingRepositories
            ? .probed(recordedRepository: item.isRepository, recordedContains: item.containsRepository)
            : .recorded(isRepository: item.isRepository, containsRepository: item.containsRepository)
        return RemovalTarget.resolving(path, home: home, size: item.size, repositories: repositories, resolve: resolve)
    }

    // MARK: Trash or delete

    /// Inside the home Trash. For loose files (`folder/*`) that includes the files directly in the Trash.
    func isInsideTrash(_ target: RemovalTarget) -> Bool {
        let trashKeys = Set([trashDirectory, PathUtil.realpath(trashDirectory) ?? trashDirectory].map(PathUtil.comparisonKey))
        let candidates = [target.path, target.resolvedPath].map(PathUtil.comparisonKey)
        return candidates.contains { candidate in trashKeys.contains { PathUtil.isStrictAncestor($0, of: candidate) } }
    }

    /// How the target leaves its place. `nil`: it may not leave at all.
    func method(for target: RemovalTarget, useTrash: Bool, rule: Rule?, context: CleanupContext) -> Method? {
        method(inTrash: isInsideTrash(target), useTrash: useTrash, rule: rule, context: context)
    }

    /// The one place Trash or delete is decided; the review's wording asks it too. `nil`: it may not leave at all.
    ///
    /// Things already in the Trash can only be deleted, and automatic runs delete only regenerable (safe) items:
    /// anything else they remove goes to the Trash. `safety.trash: always` trashes what a plan says to delete.
    func method(inTrash: Bool, useTrash: Bool, rule: Rule?, context: CleanupContext) -> Method? {
        let isSafe = rule?.safety.level == .safe
        if inTrash { return context.isAutomatic && !isSafe ? nil : .delete }
        return useTrash || alwaysTrash || (context.isAutomatic && !isSafe) ? .trash : .delete
    }

    /// The context the guard judges a removal by `method` in: its personal-folder rule depends on whether an automatic
    /// run actually trashes the item.
    static func context(_ context: CleanupContext, removingBy method: Method) -> CleanupContext {
        guard case .automatic(var automation) = context else { return context }
        automation.usesTrash = method == .trash
        return .automatic(automation)
    }

    // MARK: Removing

    /// Opens the target's folder: the pinned one, reached with no symlinks, or not at all.
    func openDirectory(of target: RemovalTarget) throws -> Int32 {
        guard let directory = target.directory else {
            throw SafeRemoval.Refused(errorDescription: "\(target.path) is gone; nothing was removed")
        }
        return try SafeRemoval.openDirectory(directory, pinned: target.directoryIdentity)
    }

    /// Removes the target by `method`, refusing anything at its location that isn't what it pinned.
    func remove(_ target: RemovalTarget, by method: Method) throws -> Removed {
        let fd = try openDirectory(of: target)
        defer { close(fd) }
        return try remove(target, in: fd, by: method)
    }

    /// Removes the target from its folder, open as `fd` (`openDirectory(of:)`).
    ///
    /// Deleting stays on handles throughout; one that stops part way throws `Interrupted`. Moving to the Trash goes
    /// through `FileManager.trashItem`, so Put Back works, and that takes a path; so the entry is checked against the
    /// target right before the move, and what arrived in the Trash is checked after it. A swap in the moment between
    /// the two moves the wrong item to the Trash, where it can be put back, and is reported.
    func remove(_ target: RemovalTarget, in fd: Int32, by method: Method) throws -> Removed {
        try SafeRemoval.verifyEntry(target, in: fd)
        switch method {
        case .delete:
            do {
                let left = try SafeRemoval.delete(target.name, in: fd, directory: target.directory ?? "", device: device)
                return Removed(trashedTo: nil, leftOnOtherVolumes: left)
            } catch {
                throw Interrupted(cause: error)
            }
        case .trash:
            // FileManager reports where the item went; without that there is nothing to check it against.
            guard let destination = try trash(target.resolvedPath) else { return Removed(trashedTo: trashDirectory) }
            var st = stat()
            guard lstat(destination, &st) == 0, RemovalTarget.Identity(st) == target.identity else {
                throw SafeRemoval.Refused(
                    errorDescription: "\(target.resolvedPath) changed while it was moved to the Trash: what went to "
                        + "\(PathUtil.abbreviate(destination, home: home)) isn't what was checked. Look there and put it back if needed.")
            }
            return Removed(trashedTo: destination)
        }
    }
}

extension CleanupExecutor {
    /// The removal module, set up with this executor's home, Trash setting and seams.
    var remover: Remover {
        Remover(home: safety.home, alwaysTrash: alwaysTrash, resolve: resolve, trash: trash, device: device)
    }
}
