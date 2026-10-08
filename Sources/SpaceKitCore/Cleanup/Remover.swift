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
    /// removed (the folder or the item no longer what the target pinned, the item on another volume, a device that
    /// can't be read, a file that couldn't be unlinked) are not this, so nothing is measured or journaled for them.
    struct Interrupted: LocalizedError {
        let cause: Error
        /// Folders left because another volume is mounted on them, besides what couldn't be removed.
        var leftOnOtherVolumes: [String] {
            (cause as? SafeRemoval.Incomplete)?.leftOnOtherVolumes ?? []
        }

        var errorDescription: String? { cause.localizedDescription }
    }

    /// Something went to the Trash, but it isn't known to be the target: it isn't, or macOS didn't say where it went.
    struct TrashUnverified: LocalizedError {
        var errorDescription: String?
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
    /// Whether the volume of an open folder keeps a file's inode when the file moves.
    let keepsInodes: @Sendable (Int32) -> Bool

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
                let left = try SafeRemoval.delete(target, in: fd, device: device)
                return Removed(trashedTo: nil, leftOnOtherVolumes: left)
            } catch let error as SafeRemoval.Incomplete {
                throw Interrupted(cause: error)
            } catch let error as SafeRemoval.Stopped {
                throw Interrupted(cause: error)
            }
        case .trash:
            let destination = try trash(target.resolvedPath)
            try verifyTrashed(target, at: destination, keepsInodes: keepsInodes(fd))
            return Removed(trashedTo: destination)
        }
    }

    /// Checks that what arrived in the Trash at `destination` is the target: the same device and inode. Without a
    /// destination there is nothing to check, so the move counts as unverified, never as done.
    ///
    /// A volume that doesn't keep inodes (`keepsInodes` false: FAT, exFAT) gives an empty file a new one when it moves.
    /// There an empty file is accepted by what it is: a plain empty file on the same device, where an empty file was
    /// checked. Whatever a swap could have sent instead holds nothing.
    private func verifyTrashed(_ target: RemovalTarget, at destination: String?, keepsInodes: Bool) throws {
        let path = target.resolvedPath
        guard let destination else {
            throw TrashUnverified(
                errorDescription: "\(path) was moved to the Trash, but macOS didn't say where it went, so SpaceKit couldn't check it "
                    + "was the item you reviewed. Look in the Trash.")
        }
        var st = stat()
        let arrived = lstat(destination, &st) == 0 ? st : nil
        if let arrived, RemovalTarget.Identity(arrived) == target.identity { return }
        if !keepsInodes, let arrived, Remover.isEmptyFile(arrived), !target.isFolder, target.size == 0,
            arrived.st_dev == target.identity?.device
        {
            return
        }
        throw TrashUnverified(
            errorDescription: "\(path) changed while it was moved to the Trash: what went to "
                + "\(PathUtil.abbreviate(destination, home: home)) isn't what was checked. Look there and put it back if needed.")
    }

    private static func isEmptyFile(_ st: stat) -> Bool {
        st.st_mode & S_IFMT == S_IFREG && st.st_size == 0
    }
}

extension CleanupExecutor {
    /// The removal module, set up with this executor's home, Trash setting and seams.
    var remover: Remover {
        Remover(home: safety.home, alwaysTrash: alwaysTrash, resolve: resolve, trash: trash, device: device, keepsInodes: keepsInodes)
    }
}
