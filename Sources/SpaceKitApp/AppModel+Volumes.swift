import AppKit
import Foundation
import SpaceKitCore

extension AppModel {
    // MARK: Volumes and Trash

    /// Keeps capacity live: every few seconds (one cheap system call per volume), and immediately when SpaceKit
    /// becomes active, which is also when the Trash is re-measured (you may have emptied it in Finder).
    func startMonitoring() {
        observers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshVolumes()
                    self.refreshTrash(resync: true)
                    self.refreshSnapshots()
                }
            })
        startCapacityLoop()
        refreshSnapshots()
    }

    private func startCapacityLoop() {
        capacityMonitor?.cancel()
        capacityMonitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                self?.refreshVolumes()
            }
        }
    }

    var trashPath: String { PathUtil.home + "/.Trash" }

    private var trashScanOptions: ScanOptions {
        var options = context.scanOptions
        options.boundary = .device
        return options
    }

    /// Measures the Trash. With `resync`, the Trash folder in the map is replaced by the fresh scan, so
    /// emptying the Trash anywhere (Finder, Terminal, SpaceKit) shows up without a full rescan.
    func refreshTrash(resync: Bool) {
        let options = trashScanOptions
        let path = trashPath
        let exploreTree = tree
        let analysisTree = analysis?.tree
        let needsSecondScan = resync && analysisTree != nil && analysisTree !== exploreTree && analysisTree!.covers(path)
        Task {
            // Each tree gets its own fresh scan: splicing hands the scanned nodes over to the tree.
            let (fresh, freshForAnalysis) = await Task.detached(priority: .utility) {
                (try? Scanner(options: options).scan(path), needsSecondScan ? try? Scanner(options: options).scan(path) : nil)
            }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                trashMeasured(nil)
                return
            }
            trashMeasured(fresh.root.size)
            guard resync else { return }
            await untilTreesAreFree()
            var changed = false
            // Only touch the trees this measurement was taken for (a new scan may have replaced them).
            if let tree, tree === exploreTree, tree.covers(path), tree.node(at: path)?.size != fresh.root.size {
                tree.splice(fresh, at: path)
                changed = true
            }
            if let freshForAnalysis, let analysis, analysis.tree === analysisTree {
                analysis.tree.splice(freshForAnalysis, at: path)
                changed = true
            }
            guard changed else { return }
            treesChangedInPlace()
            let trashRules = Set(library.rules.filter { $0.paths.contains { PathUtil.expand($0) == path } }.map(\.id))
            if !trashRules.isEmpty { refreshFindings(ruleIDs: trashRules) }
        }
    }

    /// Opens the review sheet for permanently deleting what's in the Trash.
    func emptyTrash() {
        let options = trashScanOptions
        let path = trashPath
        let rule = library.rules.first { $0.paths.contains { PathUtil.expand($0) == path } }
        Task {
            let fresh = await Task.detached(priority: .userInitiated) { try? Scanner(options: options).scan(path) }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                errorMessage = "SpaceKit can't read the Trash. Grant Full Disk Access, or empty it in Finder."
                return
            }
            var items = fresh.root.children.filter { $0.size > 0 }.map {
                CleanupItem(path: $0.path, kind: .directory, name: $0.name, size: $0.size, ruleID: rule?.id)
            }
            if fresh.root.directFileSize > 0 {
                items.append(
                    CleanupItem(
                        path: path, kind: .looseFiles, name: "Files in the Trash", size: fresh.root.directFileSize, ruleID: rule?.id))
            }
            guard !items.isEmpty else {
                errorMessage = "The Trash is already empty."
                return
            }
            review(CleanupPlan(items: items, useTrash: false), title: "Empty Trash")
        }
    }

    var bootVolume: VolumeCapacity? { volumes.first { $0.mountPoint == "/" } ?? VolumeCapacity.of(path: "/") }
}
