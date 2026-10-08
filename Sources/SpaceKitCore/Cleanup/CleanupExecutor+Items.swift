import Foundation

extension CleanupExecutor {
    static let stalePlan = "This item was saved without what its scan saw; refresh the plan"
    static let notWhereReviewed = "what is at this path now isn't what you reviewed (its folder leads elsewhere, or it was replaced)"

    /// `reviewed`: what the person's review showed for this item; `nil` in an automatic run.
    func removeItem(
        _ item: CleanupItem, plan: CleanupPlan, context: CleanupContext, reviewed: ReviewRecord.Row?, run: inout Run
    ) -> CleanupOutcome {
        let remover = self.remover
        // Built once: the guard, the Trash-or-delete decision and the removal all see this location and these facts.
        let target = remover.target(of: item, probingRepositories: true)
        guard item.kind == .looseFiles ? target.directory != nil : target.exists else { return .skipped(reason: "Already gone") }
        // The person's go-ahead covers what the review judged where it judged it: a parent that leads elsewhere now,
        // or another item in its place, could take an accepted warning to something they never saw.
        if let reviewed, reviewed.location != target.location {
            return .skipped(reason: CleanupExecutor.changedSinceReview + CleanupExecutor.notWhereReviewed)
        }
        let rule = item.ruleID.flatMap { rules[$0] }
        let inTrash = remover.isInsideTrash(target)
        guard let method = remover.method(inTrash: inTrash, useTrash: plan.useTrash, rule: rule, context: context) else {
            return .skipped(reason: "Automatic runs delete things already in the Trash only when a regenerable (safe) rule covers them")
        }
        let context = Remover.context(context, removingBy: method)

        // Loose files and Trash entries can appear after the preview; only what existed when the item's own scan
        // started may go.
        var scanStarted: Date?
        if item.kind == .looseFiles || inTrash {
            guard let started = item.scanStarted, item.kind != .looseFiles || item.looseFileNames != nil else {
                return .skipped(reason: CleanupExecutor.stalePlan)
            }
            scanStarted = started
            if inTrash && item.kind != .looseFiles && target.changed(after: started) {
                return .skipped(reason: "Moved to the Trash after it was scanned")
            }
        }

        func check(_ target: RemovalTarget) -> CleanupOutcome? {
            CleanupExecutor.refusal(verdict(for: target, ruleID: item.ruleID, context: context), reviewed: reviewed)
        }
        if let refused = check(target) { return refused }

        if item.kind == .looseFiles, let scanStarted {
            if run.dryRun { return .wouldRemove(bytes: item.size) }
            return removeLooseFiles(
                item, target: target, method: method, scanStarted: scanStarted, context: context, reviewed: reviewed, run: &run)
        }

        // Charge the budget and report what's there now, not what the scan saw.
        let measured: Measured =
            run.dryRun
            ? Measured(size: item.size, freed: item.size) : measure(target.resolvedPath, isFolder: target.isFolder, fallback: item.size)
        let size = measured.size
        let sized = target.measured(size)
        if size != item.size, let refused = check(sized) { return refused }
        if context.isAutomatic && size > run.budget { return overBudget() }
        if run.dryRun { return .wouldRemove(bytes: size) }

        let removed: Remover.Removed
        do {
            removed = try remover.remove(sized, by: method)
        } catch let interrupted as Remover.Interrupted {
            // Moving to the Trash is all or nothing; a deletion may have removed part of the item before it stopped.
            return partlyDeleted(item, target: sized, before: measured, error: interrupted, context: context, run: &run)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        // A volume mounted inside the item stays, with the folders above it; the bytes still there weren't freed.
        let left =
            removed.leftOnOtherVolumes.isEmpty ? Measured(size: 0, freed: 0) : measure(target.resolvedPath, isFolder: true, fallback: 0)
        let freed = measured.freed - min(measured.freed, left.freed)
        reportLeft(removed.leftOnOtherVolumes, of: item, run: &run)
        run.charge(size - min(size, left.size))
        record(
            entry(
                path: item.path, bytes: freed, method: method.journalMethod, ruleID: item.ruleID, context: context,
                trashedTo: removed.trashedTo),
            in: &run)
        return .removed(bytes: freed, trashedTo: removed.trashedTo)
    }

    /// A deletion that stopped part way: what's no longer there is charged, journaled and reported, so the budget
    /// and the totals match the disk. The item still counts as failed, with what was deleted in the reason.
    private func partlyDeleted(
        _ item: CleanupItem, target: RemovalTarget, before: Measured, error: Remover.Interrupted, context: CleanupContext,
        run: inout Run
    ) -> CleanupOutcome {
        let reason = error.localizedDescription
        reportLeft(error.leftOnOtherVolumes, of: item, run: &run)
        var st = stat()
        let path = target.resolvedPath
        let left = lstat(path, &st) == 0 ? measure(path, isFolder: target.isFolder, fallback: before.size) : Measured(size: 0, freed: 0)
        let gone = before.size - min(before.size, left.size)
        let freed = before.freed - min(before.freed, left.freed)
        guard gone > 0 else { return .failed(reason: reason) }
        run.charge(gone)
        run.report.partiallyFreed[item.path] = freed
        record(entry(path: item.path, bytes: freed, method: .delete, ruleID: item.ruleID, context: context), in: &run)
        return .failed(reason: "\(reason). \(ByteCount.format(freed)) of it was deleted")
    }

    /// Folders inside `item` left because another volume is mounted on them, as warnings of the run.
    private func reportLeft(_ paths: [String], of item: CleanupItem, run: inout Run) {
        guard !paths.isEmpty else { return }
        run.report.leftOnOtherVolumes[item.path] = paths
        run.report.warnings += paths.map { left in
            "Left \(PathUtil.abbreviate(left, home: safety.home)): another volume is mounted there. "
                + "The rest of \(PathUtil.abbreviate(item.path, home: safety.home)) was removed."
        }
    }

    /// Removes the plain files directly inside the target's pinned folder, leaving subfolders alone. Each file is
    /// checked by the guard, charged to the budget and journaled on its own, so a partial failure keeps an exact record.
    private func removeLooseFiles(
        _ item: CleanupItem, target: RemovalTarget, method: Remover.Method, scanStarted: Date, context: CleanupContext,
        reviewed: ReviewRecord.Row?, run: inout Run
    ) -> CleanupOutcome {
        let remover = self.remover
        let names = item.looseFileNames ?? []
        let fd: Int32
        do {
            fd = try remover.openDirectory(of: target)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
        defer { close(fd) }

        var totalFreed: UInt64 = 0
        var trashLocations: [String] = []
        var removedCount = 0
        var overBudgetCount = 0
        var failures: [String] = []
        for name in names {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            let file = target.entry(name, stat: st, namedIn: item.path)
            guard !file.changed(after: scanStarted) else { continue }
            guard CleanupExecutor.refusal(verdict(for: file, ruleID: item.ruleID, context: context), reviewed: reviewed) == nil else {
                continue
            }
            // A file with another hard link keeps its bytes on disk: charged to the budget, but not freed.
            let freed = CleanupExecutor.isLastLink(st) ? file.size : 0
            if context.isAutomatic && file.size > run.budget {
                overBudgetCount += 1
                continue
            }
            do {
                let trashedTo = try remover.remove(file, in: fd, by: method).trashedTo
                totalFreed &+= freed
                removedCount += 1
                trashedTo.map { trashLocations.append($0) }
                run.charge(file.size)
                record(
                    entry(
                        path: file.path, bytes: freed, method: method.journalMethod, ruleID: item.ruleID, context: context,
                        trashedTo: trashedTo),
                    in: &run)
            } catch {
                failures.append("Couldn't remove \(PathUtil.abbreviate(file.path, home: safety.home)): \(error.localizedDescription)")
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
        if !trashLocations.isEmpty { run.report.trashedLooseFiles[item.path] = trashLocations }
        if let budgetNote { run.report.warnings.append("\(PathUtil.abbreviate(item.path, home: safety.home)): \(budgetNote)") }
        return .removed(bytes: totalFreed, trashedTo: method == .trash ? trashLocations.first.map(PathUtil.parent) : nil)
    }

    /// What an item holds at removal time. `size` is all of it, charged to the budget; `freed` leaves out files
    /// with another hard link outside the item, whose bytes stay on disk.
    struct Measured {
        var size: UInt64
        var freed: UInt64
    }

    /// Measures an item now. Folders are rescanned; a symlink counts as itself.
    func measure(_ path: String, isFolder: Bool, fallback: UInt64) -> Measured {
        guard isFolder else {
            var st = stat()
            guard lstat(path, &st) == 0 else { return Measured(size: fallback, freed: fallback) }
            let size = FileSize.allocated(st)
            return Measured(size: size, freed: CleanupExecutor.isLastLink(st) ? size : 0)
        }
        var options = ScanOptions()
        options.minFileSize = .max
        guard let tree = try? Scanner(options: options).scan(roots: [path]) else { return Measured(size: fallback, freed: fallback) }
        let size = tree.root.size
        return Measured(size: size, freed: size - min(size, tree.bytesLinkedOutside()))
    }

    /// True unless `st` is a regular file with another hard link, which keeps its bytes on disk.
    static func isLastLink(_ st: stat) -> Bool {
        (st.st_mode & S_IFMT) != S_IFREG || st.st_nlink <= 1
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
