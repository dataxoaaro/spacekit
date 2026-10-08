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
}
