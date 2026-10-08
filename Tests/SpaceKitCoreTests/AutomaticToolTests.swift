import Foundation
import Testing

@testable import SpaceKitCore

/// What an automatic run starts: only programs, interpreters and search folders nothing of the person's can change, in
/// an environment that leaves their own tool settings behind. Nothing here starts a program the test wrote.
extension CommandTrustTests {
    /// A test's folders are its own, which settles the walk at once. Judged as someone else (`user`), each folder shows
    /// what else makes it changeable; the folders are made unwritable for their owner too, so no access check passes them
    /// for the test's own account.
    @Test("A folder writable through its group, by everyone (sticky or not) or by an access control list counts as changeable")
    func changeableFolderModes() throws {
        let tree = try TempTree()
        let someoneElse = getuid() &+ 1
        func isChangeable(_ relative: String, mode: mode_t, acl: String? = nil) throws -> Bool {
            try tree.directory(relative)
            let path = tree.path(relative)
            #expect(chown(path, getuid(), getgid()) == 0)
            #expect(chmod(path, mode) == 0)
            if let acl { #expect(Shell.run("/bin/chmod", ["+a", acl, path], timeout: 10).status == 0) }
            var st = stat()
            #expect(lstat(path, &st) == 0)
            return CommandTrust.isChangeable(path, st, user: someoneElse)
        }
        #expect(try !isChangeable("closed", mode: 0o555))
        #expect(try isChangeable("group", mode: 0o575), "your own group can write it")
        #expect(try isChangeable("everyone", mode: 0o557))
        #expect(try isChangeable("sticky", mode: 0o1557), "the sticky bit stops renames, not new programs")
        #expect(try isChangeable("acl", mode: 0o555, acl: "user:\(NSUserName()) allow add_file,add_subdirectory"))
        #expect(try !isChangeable("denied", mode: 0o555, acl: "user:\(NSUserName()) deny add_file"))
        // The system's sticky, world-writable folder.
        #expect(CommandTrust.changeablePart(of: "/private/tmp/no-such-tool-for-spacekit") == "/private/tmp")
    }

    @Test("A symlinked folder on the way to a program is checked, and so is the folder it leads to")
    func changeableThroughSymlinkedFolder() throws {
        let tree = try TempTree()
        try program(tree, "real/bin/tool")
        try FileManager.default.createSymbolicLink(atPath: tree.path("absolute"), withDestinationPath: tree.path("real"))
        try FileManager.default.createSymbolicLink(atPath: tree.path("relative"), withDestinationPath: "real")
        for link in ["absolute", "relative"] {
            let tool = tree.path("\(link)/bin/tool")
            #expect(CommandTrust.changeablePart(of: tool) { part, _ in part == tree.path(link) } == tree.path(link))
            #expect(CommandTrust.changeablePart(of: tool) { part, _ in part == tree.path("real") } == tree.path("real"), "\(link)")
            #expect(CommandTrust.changeablePart(of: tool) { part, _ in part == tree.path("real/bin/tool") } == tree.path("real/bin/tool"))
            #expect(CommandTrust.changeablePart(of: tool) { _, _ in false } == nil)
        }
    }

    /// A tool that starts a helper by name, or a script `/usr/bin/env` starts, searches the PATH it is given. In an
    /// automatic run that PATH holds only folders nothing of yours can change, so no program of yours is found first.
    @Test("An automatic run's PATH holds only search folders you can't change; a manual run's holds them all")
    func automaticSearchPath() throws {
        let tree = try TempTree()
        try tree.directory("bin")
        try tree.directory("home/.local/bin")
        let home = tree.path("home")
        let parent = ["PATH": "\(tree.path("bin")):/usr/bin:/bin", "HOME": home]
        func folders(_ environment: [String: String]) -> [String] {
            (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        }
        // The file system as it is: the test's folders are yours, /usr/bin and /bin the system's.
        let automatic = folders(Shell.toolEnvironment(from: parent, home: home, kind: .automatic))
        #expect(automatic.contains("/usr/bin") && automatic.contains("/bin"))
        #expect(!automatic.contains { $0.hasPrefix(tree.root) }, "\(automatic)")
        // With a stand-in judge, the folders it calls changeable go, whoever owns them.
        let judged = folders(Shell.toolEnvironment(from: parent, home: home, kind: .automatic) { $0 == "/usr/bin" ? $0 : nil })
        #expect(!judged.contains("/usr/bin") && judged.contains(tree.path("bin")) && judged.contains(home + "/.local/bin"))
        // You start a manual run yourself: it searches everywhere it did.
        let manual = folders(Shell.toolEnvironment(from: parent, home: home))
        #expect(manual.contains(tree.path("bin")) && manual.contains(home + "/.local/bin") && manual.contains("/usr/bin"))
    }

    /// Built-in rules' trusted tools skip the launcher-name check (`npm` is a script `node` runs), but not this one: a
    /// script runs its interpreter, which must be no more yours to change than the script.
    @Test("A trusted tool that is a script runs automatically only when its interpreter is one you can't change")
    func automaticScriptInterpreters() throws {
        let tree = try TempTree()
        try program(tree, "fixed/npm", "#!/usr/bin/env node\n")
        try program(tree, "fixed/go", "#!\(tree.path("mine/interpreter")) -q\n")
        try program(tree, "fixed/uv", "#!/usr/bin/env -S fixed-interpreter --quiet\n")
        try program(tree, "fixed/fixed-interpreter")
        try program(tree, "mine/node")
        try program(tree, "mine/interpreter")
        let mine = tree.path("mine")
        // Stands in for the system: `fixed` is a folder you can't change, `mine` one you can.
        let changeable: @Sendable (String) -> String? = { $0.hasPrefix(mine) ? mine : nil }
        let commands = [["npm", "cache", "clean", "--force"], ["go", "clean", "-cache"], ["uv", "cache", "clean"]]
        let rules = commands.map { rule($0[0], builtin: true, command: $0) }
        let plan = CleanupPlan(commands: commands.map { PlannedCommand(ruleID: $0[0], arguments: $0, estimatedBytes: 1) })
        let runner = RecordingRunner(searchPath: [tree.path("fixed"), mine, "/usr/bin", "/bin"])
        let executor = executor(tree, rules: rules, runner: runner, changeable: changeable)

        let report = executor.execute(AutomaticPlan(plan, automation: AutomationContext(jobID: "j")), dryRun: false)
        let reasons = report.commands.map { skipReason($0.outcome) ?? "ran" }
        // env looks for node on the automatic run's PATH, which leaves your folder out.
        #expect(reasons[0].contains("for 'node', which isn't installed where env looks"), "\(reasons[0])")
        #expect(reasons[1].contains("\(mine) can be replaced by any program of yours, so 'interpreter' runs only when you start it"))
        #expect(reasons[2] == "ran")
        #expect(runner.calls == [["uv", "cache", "clean"]])

        // By hand you start them yourself, interpreters and all.
        let manual = manualRun(plan, with: executor)
        #expect(manual.commands.allSatisfy { skipReason($0.outcome) == nil })
        #expect(runner.calls.suffix(3) == commands[...])
    }
}
