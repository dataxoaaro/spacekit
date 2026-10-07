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

    struct Status: Encodable {
        var path: String
        var bytes: UInt64
        var files: UInt64
    }

    @OptionGroup var global: GlobalOptions
    @Flag(name: .long, help: "Empty the Trash (preview unless --yes).") var empty = false
    @Flag(name: [.short, .long], help: "Delete without asking.") var yes = false
    @Flag(name: .long, help: "Machine-readable output.") var json = false

    func run() throws {
        // Entries moved to the Trash after this weren't in the preview, so the executor leaves them.
        let started = Date()
        let context = global.loadContext()
        let path = PathUtil.home + "/.Trash"
        var options = context.scanOptions
        options.boundary = .device
        let tree = try Scanner(options: options).scan(path)
        guard !tree.root.flags.contains(.unreadable) else {
            Output.warn("Can't read the Trash. Give your terminal Full Disk Access (see `spacekit doctor`), or empty it in Finder.")
            throw ExitCode.failure
        }
        let status = Status(path: path, bytes: tree.root.size, files: tree.root.fileCount)
        if !json { print("Trash: ".bold + ByteCount.format(status.bytes).bold + "  \(status.files.formatted()) files".dim) }
        guard empty, status.bytes > 0 else {
            if json { try Output.json(status) } else if status.bytes > 0 { print("Empty it with: ".dim + "spacekit trash --empty".bold) }
            return
        }
        let rule = context.library.rules.first { $0.paths.contains { PathUtil.expand($0) == path } }
        var plan = CleanupPlan(useTrash: false, created: started)
        plan.items = tree.root.children.filter { $0.size > 0 }.map {
            CleanupItem(path: $0.path, kind: .directory, name: $0.name, size: $0.size, ruleID: rule?.id)
        }
        if tree.root.directFileSize > 0 {
            plan.items.append(
                CleanupItem(path: path, kind: .looseFiles, name: "Files in the Trash", size: tree.root.directFileSize, ruleID: rule?.id))
        }
        guard
            let report = try CleanupOutput.session(
                plan, executor: context.executor, yes: yes, json: json, interactive: true, heading: "Empty the Trash",
                verb: "Delete", hint: "Nothing deleted. Run with --yes to empty the Trash.")
        else { return }
        if !json, let capacity = VolumeCapacity.of(path: "/"), capacity.purgeable > 1_000_000_000,
            !LocalSnapshots.list(volume: "/").isEmpty
        {
            print("Local Time Machine snapshots still reference these files; the space shows as purgeable until macOS releases it.".dim)
        }
        try CleanupOutput.exitIfProblems(report)
    }
}
