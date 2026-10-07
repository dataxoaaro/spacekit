import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Overlap resolution")
struct OverlapTests {
    @Test("An inner children rule keeps its loose files; the outer rule doesn't count them again")
    func innerLooseFiles() throws {
        let tree = try TempTree()
        try tree.file("Caches/JetBrains/loose.log", bytes: 40_000)
        try tree.file("Caches/JetBrains/IDEA/index.bin", bytes: 300_000)
        try tree.file("Caches/pip/wheel.bin", bytes: 200_000)
        try tree.file("Caches/top.db", bytes: 10_000)
        let outer = Rule(id: "user-caches", name: "Caches", paths: [tree.path("Caches")], granularity: .children)
        let inner = Rule(id: "jetbrains", name: "JetBrains", paths: [tree.path("Caches/JetBrains")], granularity: .children)
        let result = try scan(tree.root)

        let findings = RuleEngine(rules: [outer, inner]).evaluate(result)
        let total = findings.reduce(UInt64(0)) { $0 + $1.size }
        #expect(total == result.node(at: tree.path("Caches"))!.size)
        let outerItems = findings.first { $0.rule.id == "user-caches" }?.items.map(\.id) ?? []
        #expect(!outerItems.contains(tree.path("Caches/JetBrains") + "/*"))
        #expect(outerItems.contains(tree.path("Caches") + "/*"))
        let innerItems = findings.first { $0.rule.id == "jetbrains" }?.items.map(\.id) ?? []
        #expect(innerItems.contains(tree.path("Caches/JetBrains") + "/*"))
    }

    @Test("A single-file rule inside another rule's folder isn't counted twice")
    func innerFile() throws {
        let tree = try TempTree()
        try tree.file("Logs/app/big.log", bytes: 300_000)
        try tree.file("Logs/app/small.log", bytes: 20_000)
        try tree.file("Logs/other/x.log", bytes: 50_000)
        let outer = Rule(id: "logs", name: "Logs", paths: [tree.path("Logs")])
        let inner = Rule(id: "big", name: "Big log", paths: [tree.path("Logs/app/big.log")])
        let result = try scan(tree.root)

        let findings = RuleEngine(rules: [outer, inner]).evaluate(result)
        let total = findings.reduce(UInt64(0)) { $0 + $1.size }
        #expect(total == result.node(at: tree.path("Logs"))!.size)
        let outerFinding = try #require(findings.first { $0.rule.id == "logs" })
        #expect(outerFinding.items.first { $0.kind == .looseFiles }?.size == tree.allocated("Logs/app/small.log"))
    }
}

@Suite("Incremental updates with loose files")
struct LooseFilesUpdateTests {
    func analysis() throws -> (TempTree, Analysis) {
        let tree = try TempTree()
        try tree.file("cache/a/blob", bytes: 300_000)
        try tree.file("cache/b/blob", bytes: 100_000)
        try tree.file("cache/top.bin", bytes: 40_000)
        try tree.file("cache/second.bin", bytes: 20_000)
        let rule = Rule(id: "cache", name: "Cache", paths: [tree.path("cache")], granularity: .children, action: ActionSpec(remove: true))
        let scanned = try scan(tree.root)
        return (tree, Analysis(findings: RuleEngine(rules: [rule]).evaluate(scanned), tree: scanned))
    }

    func looseSize(_ analysis: Analysis) -> UInt64? {
        analysis.finding(ruleID: "cache")?.items.first { $0.kind == .looseFiles }?.size
    }

    @Test("Removing a sibling folder leaves the folder's loose-files item alone")
    func siblingFolder() throws {
        let (tree, before) = try analysis()
        var after = before
        after.apply([Removal(path: tree.path("cache/a"), kind: .directory, bytes: tree.allocated("cache/a/blob"))])
        #expect(looseSize(after) == looseSize(before))
        #expect(after.finding(ruleID: "cache")?.items.contains { $0.path == tree.path("cache/a") } == false)
    }

    @Test("Removing a file directly in the folder shrinks the loose-files item")
    func directFile() throws {
        let (tree, before) = try analysis()
        var after = before
        let top = tree.allocated("cache/top.bin")
        after.apply([Removal(path: tree.path("cache/top.bin"), kind: .file, bytes: top)])
        #expect(looseSize(after) == looseSize(before)! - top)
    }

    @Test("Removing a file deeper down doesn't touch the loose-files item")
    func deeperFile() throws {
        let (tree, before) = try analysis()
        var after = before
        after.apply([Removal(path: tree.path("cache/b/blob"), kind: .file, bytes: tree.allocated("cache/b/blob"))])
        #expect(looseSize(after) == looseSize(before))
    }
}
