import ArgumentParser
import Foundation
import SpaceKitCore
import SpaceKitTUI

struct TrashCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "trash",
        abstract: "How much the Trash holds (it still uses disk space), and empty it.",
        discussion: """
            SpaceKit moves things to the Trash by default, so they can be put back. The space is only released
            when the Trash is emptied. `spacekit trash --empty` previews; add --yes to delete permanently.
            """
    )

    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Empty the Trash (preview unless --yes).") var empty = false
    @Flag(name: [.short, .long], help: "Delete without asking.") var yes = false

    func run() throws {
        let context = global.loadContext()
        let path = PathUtil.home + "/.Trash"
        var options = context.scanOptions
        options.boundary = .device
        let tree = try Scanner(options: options).scan(path)
        guard !tree.root.flags.contains(.unreadable) else {
            Output.warn("Can't read the Trash. Give your terminal Full Disk Access (see `spacekit doctor`), or empty it in Finder.")
            throw ExitCode.failure
        }
        Output.print("Trash: ".bold + ByteCount.format(tree.root.size).bold + "  \(tree.root.fileCount.formatted()) files".dim)
        guard empty else {
            if tree.root.size > 0 { Output.print("Empty it with: ".dim + "spacekit trash --empty".bold) }
            return
        }
        guard tree.root.size > 0 else { return }
        let rule = context.library.rules.first { $0.paths.contains { PathUtil.expand($0) == path } }
        var plan = CleanupPlan(useTrash: false)
        plan.items = tree.root.children.filter { $0.size > 0 }.map {
            CleanupItem(path: $0.path, kind: .directory, name: $0.name, size: $0.size, ruleID: rule?.id)
        }
        if tree.root.directFileSize > 0 {
            plan.items.append(
                CleanupItem(path: path, kind: .looseFiles, name: "Files in the Trash", size: tree.root.directFileSize, ruleID: rule?.id))
        }
        let proceed = yes || Output.confirm("Permanently delete \(ByteCount.format(tree.root.size)) in the Trash?")
        guard proceed else {
            Output.print("Nothing deleted. Run with --yes to empty the Trash.".dim)
            return
        }
        let report = context.executor.execute(plan, context: .manual(confirmed: true), dryRun: false)
        Output.print(report.summary.bold.fg(ANSI.safe))
        for (item, reason) in report.skipped + report.failures {
            Output.print("  skipped ".dim + PathUtil.abbreviate(item.path) + ": " + reason.dim)
        }
        if let capacity = VolumeCapacity.of(path: "/"), capacity.purgeable > 1_000_000_000, !LocalSnapshots.list(volume: "/").isEmpty {
            Output.print(
                "Local Time Machine snapshots still reference these files; the space shows as purgeable until macOS releases it.".dim)
        }
    }
}
