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

    var trashPath: String { Trash.path() }

    private var trashScanOptions: ScanOptions { Trash.scanOptions(context.scanOptions) }

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
            let trashRules = Set(Trash.rules(in: library.rules).map(\.id))
            if !trashRules.isEmpty { refreshFindings(ruleIDs: trashRules) }
        }
    }

    /// Opens the review sheet for permanently deleting what's in the Trash.
    func emptyTrash() {
        let options = trashScanOptions
        let path = trashPath
        let rules = library.rules
        let started = Date()
        Task {
            let fresh = await Task.detached(priority: .userInitiated) { try? Scanner(options: options).scan(path) }.value
            guard let fresh, !fresh.root.flags.contains(.unreadable) else {
                errorMessage = "SpaceKit can't read the Trash. Grant Full Disk Access, or empty it in Finder."
                return
            }
            let plan = Trash.emptyingPlan(fresh, rules: rules, created: started)
            guard !plan.isEmpty else {
                errorMessage = "The Trash is already empty."
                return
            }
            review(plan, title: "Empty Trash")
        }
    }

    var bootVolume: VolumeCapacity? { volumes.first { $0.mountPoint == "/" } ?? VolumeCapacity.of(path: "/") }
}
