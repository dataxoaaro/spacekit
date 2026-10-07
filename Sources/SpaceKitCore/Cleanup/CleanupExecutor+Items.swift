import Foundation

extension CleanupExecutor {
    enum Removal {
        case trash, delete

        var journalMethod: JournalEntry.Method { self == .trash ? .trash : .delete }
    }

    static let stalePlan = "This plan predates per-file checks; refresh it"

    func removeItem(_ item: CleanupItem, plan: CleanupPlan, context: CleanupContext, run: inout Run) -> CleanupOutcome {
        var st = stat()
        guard lstat(item.path, &st) == 0 else { return .skipped(reason: "Already gone") }
        let isFolder = (st.st_mode & S_IFMT) == S_IFDIR
        let rule = item.ruleID.flatMap { rules[$0] }
        let inTrash = isInsideTrash(item.path, orTrashItself: item.kind == .looseFiles)
        guard let removal = removal(useTrash: plan.useTrash, rule: rule, inTrash: inTrash, context: context) else {
            return .skipped(reason: "Automatic runs delete things already in the Trash only when a regenerable (safe) rule covers them")
        }
        let context = CleanupExecutor.context(context, trashing: removal == .trash)

        // Loose files and Trash entries can appear after the preview; only what existed then may go.
        var created: Date?
        if item.kind == .looseFiles || inTrash {
            guard let planCreated = plan.created else { return .skipped(reason: CleanupExecutor.stalePlan) }
            created = planCreated
            if inTrash && item.kind != .looseFiles && CleanupExecutor.changed(st, after: planCreated) {
                return .skipped(reason: "Moved to the Trash after this plan was made")
            }
        }

        // The folder whose entries change: the parent for an item, the folder itself for loose files.
        let directory = item.kind == .looseFiles ? item.path : PathUtil.parent(item.path)
        guard let checkedDirectory = PathUtil.realpath(directory) else { return .skipped(reason: "Already gone") }

        let isRepository = item.isRepository || (isFolder && RepositoryProbe.isRepository(item.path))
        let containsRepository = item.containsRepository || (isFolder && RepositoryProbe.containsRepository(item.path))
        let confirmed = CleanupExecutor.isConfirmed(context)
        func check(size: UInt64) -> SafetyVerdict {
            verdict(for: item, size: size, isRepository: isRepository, containsRepository: containsRepository, context: context)
        }
        let planned = check(size: item.size)
        guard planned.permits(confirmed: confirmed) else { return CleanupExecutor.refusal(planned) }

        if item.kind == .looseFiles, let created {
            if run.dryRun { return .wouldRemove(bytes: item.size) }
            guard PathUtil.realpath(directory) == checkedDirectory else { return CleanupExecutor.changedWhileChecking(directory) }
            return removeLooseFiles(item, in: checkedDirectory, removal: removal, created: created, context: context, run: &run)
        }

        // Charge the budget and report what's there now, not what the scan saw.
        let size = run.dryRun ? item.size : measuredSize(item.path, isFolder: isFolder, fallback: item.size)
        if size != item.size {
            let measured = check(size: size)
            guard measured.permits(confirmed: confirmed) else { return CleanupExecutor.refusal(measured) }
        }
        if context.isAutomatic && size > run.budget { return overBudget() }
        if run.dryRun { return .wouldRemove(bytes: size) }
        guard PathUtil.realpath(directory) == checkedDirectory else { return CleanupExecutor.changedWhileChecking(directory) }

        do {
            let name = PathUtil.lastComponent(item.path)
            var trashedTo: String?
            switch removal {
            case .delete:
                try SafeRemoval.delete(name, inDirectory: checkedDirectory)
            case .trash:
                try SafeRemoval.verifyUnchanged(checkedDirectory)
                trashedTo = try trash(PathUtil.join(checkedDirectory, name)) ?? trashDirectory
            }
            run.charge(size)
            record(
                entry(
                    path: item.path, bytes: size, method: removal.journalMethod, ruleID: item.ruleID, context: context,
                    trashedTo: trashedTo),
                in: &run)
            return .removed(bytes: size, trashedTo: trashedTo)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }

    /// Removes the plain files directly inside the checked folder, leaving subfolders alone. Each file is checked
    /// by the guard, charged to the budget and journaled on its own, so a partial failure keeps an exact record.
    private func removeLooseFiles(
        _ item: CleanupItem, in directory: String, removal: Removal, created: Date, context: CleanupContext, run: inout Run
    ) -> CleanupOutcome {
        let fd: Int32
        let names: [String]
        do {
            fd = try SafeRemoval.openDirectory(directory)
            names = try FileManager.default.contentsOfDirectory(atPath: directory).sorted()
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        defer { close(fd) }

        let rule = item.ruleID.flatMap { rules[$0] }
        let confirmed = CleanupExecutor.isConfirmed(context)
        var freed: UInt64 = 0
        var trashLocations: [String] = []
        var removedCount = 0
        var overBudgetCount = 0
        var failures: [String] = []
        for name in names {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            guard !CleanupExecutor.changed(st, after: created) else { continue }
            let path = PathUtil.join(item.path, name)
            guard safety.evaluate(path: path, rule: rule, context: context).permits(confirmed: confirmed) else { continue }
            let size = FileSize.allocated(st)
            if context.isAutomatic && size > run.budget {
                overBudgetCount += 1
                continue
            }
            do {
                var trashedTo: String?
                switch removal {
                case .delete:
                    if unlinkat(fd, name, 0) != 0 { throw SafeRemoval.posixError(path) }
                case .trash:
                    try SafeRemoval.verifyUnchanged(directory)
                    trashedTo = try trash(PathUtil.join(directory, name)) ?? trashDirectory
                }
                freed &+= size
                removedCount += 1
                trashedTo.map { trashLocations.append($0) }
                run.charge(size)
                record(
                    entry(
                        path: path, bytes: size, method: removal.journalMethod, ruleID: item.ruleID, context: context,
                        trashedTo: trashedTo),
                    in: &run)
            } catch {
                failures.append("Couldn't remove \(PathUtil.abbreviate(path, home: safety.home)): \(error.localizedDescription)")
            }
        }

        let budgetNote = overBudgetCount > 0 ? "\(overBudgetCount) loose files over this run's budget were left" : nil
        guard removedCount > 0 else {
            if let first = failures.first {
                return .failed(reason: first + (failures.count > 1 ? " (and \(failures.count - 1) more)" : ""))
            }
            return .skipped(reason: budgetNote ?? "None of the files from the reviewed plan are left")
        }
        run.report.warnings += failures
        if let budgetNote { run.report.warnings.append("\(PathUtil.abbreviate(item.path, home: safety.home)): \(budgetNote)") }
        return .removed(bytes: freed, trashedTo: removal == .trash ? trashLocations.first.map(PathUtil.parent) : nil)
    }

    /// How an item leaves its place. `nil`: it may not leave at all.
    ///
    /// Things already in the Trash can only be deleted, and automatic runs delete only regenerable (safe) items:
    /// anything else they remove goes to the Trash.
    func removal(useTrash: Bool, rule: Rule?, inTrash: Bool, context: CleanupContext) -> Removal? {
        let isSafe = rule?.safety.level == .safe
        if inTrash { return context.isAutomatic && !isSafe ? nil : .delete }
        return useTrash || (context.isAutomatic && !isSafe) ? .trash : .delete
    }

    /// Tells the guard whether this item will actually be trashed, which its personal-folder rule depends on.
    static func context(_ context: CleanupContext, trashing: Bool) -> CleanupContext {
        guard case .automatic(var automation) = context else { return context }
        automation.usesTrash = trashing
        return .automatic(automation)
    }

    var trashDirectory: String { PathUtil.join(safety.home, ".Trash") }

    /// True inside the guard's home Trash, whatever the spelling or symlinks in the parent path.
    func isInsideTrash(_ path: String, orTrashItself: Bool) -> Bool {
        let trashKeys = Set([trashDirectory, PathUtil.realpath(trashDirectory) ?? trashDirectory].map(SafeRemoval.comparisonKey))
        let candidates = [path, PathUtil.resolveParent(path)].map(SafeRemoval.comparisonKey)
        return candidates.contains { candidate in
            trashKeys.contains { trash in
                orTrashItself ? PathUtil.isAncestorOrEqual(trash, of: candidate) : PathUtil.isStrictAncestor(trash, of: candidate)
            }
        }
    }

    /// Modified or had its status changed (created, renamed into place) after `date`.
    static func changed(_ st: stat, after date: Date) -> Bool {
        func time(_ ts: timespec) -> Date { Date(timeIntervalSince1970: Double(ts.tv_sec) + Double(ts.tv_nsec) / 1e9) }
        return time(st.st_mtimespec) > date || time(st.st_ctimespec) > date
    }

    static func changedWhileChecking(_ directory: String) -> CleanupOutcome {
        .failed(reason: "\(directory) changed while it was being checked; nothing was removed")
    }

    /// Allocated size now. Folders are rescanned; a symlink counts as itself.
    func measuredSize(_ path: String, isFolder: Bool, fallback: UInt64) -> UInt64 {
        guard isFolder else { return FileSize.allocated(atPath: path) ?? fallback }
        return measure([path]) ?? fallback
    }

    /// Allocated size of folders, the way the scanner counts it. `nil` if none could be scanned.
    func measure(_ paths: [String]) -> UInt64? {
        let existing = paths.filter { FileManager.default.fileExists(atPath: $0) }
        guard !existing.isEmpty else { return 0 }
        var options = ScanOptions()
        options.minFileSize = .max
        return try? Scanner(options: options).scan(roots: existing).root.size
    }
}
