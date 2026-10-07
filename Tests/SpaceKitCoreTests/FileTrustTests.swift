import Foundation
import Testing

@testable import SpaceKitCore

/// Config and rule files decide what SpaceKit removes and runs, so files other users can change aren't read.
@Suite("Config and rule files other users can change")
struct FileTrustTests {
    @Test("A config file other users can write is a config error")
    func writableConfig() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        try "version: 1\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(chmod(file, 0o666) == 0)
        #expect(throws: ConfigError.self) { try ConfigStore(file: file).load() }
        let context = SpaceKitContext.load(paths: SpaceKitPaths(configFile: file, stateDirectory: tree.path("state")))
        #expect(context.configError != nil)
    }

    @Test("A config file in a folder other users can write to (without the sticky bit) is a config error")
    func configInWritableFolder() throws {
        let tree = try TempTree()
        try tree.directory("shared")
        let file = tree.path("shared/config.yaml")
        try "version: 1\n".write(toFile: file, atomically: true, encoding: .utf8)
        #expect(chmod(tree.path("shared"), 0o777) == 0)
        defer { chmod(tree.path("shared"), 0o755) }
        #expect(throws: ConfigError.self) { try ConfigStore(file: file).load() }

        #expect(chmod(tree.path("shared"), 0o1777) == 0)
        #expect(throws: Never.self) { try ConfigStore(file: file).load() }
    }

    @Test("A rule file other users can write isn't loaded")
    func writableRuleFile() throws {
        let tree = try TempTree()
        try tree.directory("rules")
        let file = tree.path("rules/mine.yaml")
        try "id: mine.cache\nname: Mine\npath: ~/.mine/cache\nsafety: safe\naction: remove\n".write(
            toFile: file, atomically: true, encoding: .utf8)
        #expect(chmod(file, 0o664) == 0)
        let library = RuleLibrary.load(builtinDirectory: nil, directories: [tree.path("rules")])
        #expect(library.rule(id: "mine.cache") == nil)
        #expect(library.issues.contains { $0.severity == .error && $0.source == file })

        #expect(chmod(file, 0o644) == 0)
        #expect(RuleLibrary.load(builtinDirectory: nil, directories: [tree.path("rules")]).rule(id: "mine.cache") != nil)
    }
}
