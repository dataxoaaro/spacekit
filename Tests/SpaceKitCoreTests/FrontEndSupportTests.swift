import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Front-end support")
struct FrontEndSupportTests {
    @Test("Starting a new request makes every earlier tag stale")
    func requestGenerations() {
        var generation = RequestGeneration()
        let first = generation.next()
        #expect(generation.isCurrent(first))
        let second = generation.next()
        #expect(!generation.isCurrent(first))
        #expect(generation.isCurrent(second))
    }

    @Test("Rule docs open only as https links")
    func docsLinks() {
        func url(_ docs: String?) -> URL? { Rule(id: "r", name: "r", docs: docs).docsURL }
        #expect(url("https://docs.example.com/cache")?.host == "docs.example.com")
        #expect(url("HTTPS://example.com") != nil)
        #expect(url(nil) == nil)
        #expect(url("http://example.com") == nil)
        #expect(url("file:///Applications/Calculator.app") == nil)
        #expect(url("x-apple.systempreferences:com.apple.preference.security") == nil)
        #expect(url("javascript:alert(1)") == nil)
        #expect(url("https:///no-host") == nil)
        #expect(url("not a url") == nil)
    }

    @Test("Emptying the Trash plans each top-level entry and the loose files, deleted, under the Trash rule")
    func trashPlan() throws {
        let tree = try TempTree()
        let home = tree.path("home")
        try tree.file("home/.Trash/old project/a.bin", bytes: 8_000)
        try tree.file("home/.Trash/loose.dmg", bytes: 4_000)
        try tree.directory("home/.Trash/empty")
        let rule = Rule(id: "system.trash", name: "Trash", paths: ["~/.Trash"])
        let other = Rule(id: "other", name: "Other", paths: ["~/Downloads"])
        #expect(Trash.rules(in: [other, rule], home: home).map(\.id) == ["system.trash"])

        let created = Date()
        let plan = Trash.emptyingPlan(try scan(Trash.path(home: home)), rules: [other, rule], created: created, home: home)
        #expect(!plan.useTrash)
        #expect(plan.created == created)
        #expect(plan.items.map(\.kind) == [.directory, .looseFiles])
        #expect(plan.items.map(\.path) == [tree.path("home/.Trash/old project"), tree.path("home/.Trash")])
        #expect(plan.items.allSatisfy { $0.ruleID == "system.trash" })
    }

    @Test("Spinner frames cycle, also for negative ticks")
    func spinner() {
        #expect(Spinner.frame(0) == Spinner.frames[0])
        #expect(Spinner.frame(Spinner.frames.count + 1) == Spinner.frames[1])
        #expect(Spinner.frames.contains(Spinner.frame(-3)))
    }

    @Test("An Explore entry becomes a cleanup item with its git facts; the smaller-files block can't")
    func diskItemConversion() throws {
        let tree = try TempTree()
        try tree.file("root/work/app/.git/HEAD", bytes: 100)
        try tree.file("root/work/app/main.swift", bytes: 4_000)
        try tree.file("root/big.bin", bytes: 40_000)
        try tree.file("root/tiny.txt", bytes: 10)
        let scanned = try scan(tree.path("root"), minFileSize: 20_000, markers: [".git"])
        let items = scanned.root.items
        let work = try #require(items.first { $0.name == "work" })
        let converted = try #require(CleanupItem(work, markers: scanned.markers, ruleID: "r"))
        #expect(converted.kind == .directory && converted.ruleID == "r")
        #expect(!converted.isRepository && converted.containsRepository)
        let appEntry = try #require(work.directory?.items.first { $0.name == "app" })
        let app = try #require(CleanupItem(appEntry, markers: scanned.markers, ruleID: nil))
        #expect(app.isRepository)
        #expect(CleanupItem(work, markers: nil, ruleID: nil)?.containsRepository == false)
        let fileEntry = try #require(items.first { $0.name == "big.bin" })
        let file = try #require(CleanupItem(fileEntry, markers: scanned.markers, ruleID: nil))
        #expect(file.kind == .file && file.path == tree.path("root/big.bin"))
        let others = try #require(items.first { if case .otherFiles = $0 { return true } else { return false } })
        #expect(CleanupItem(others, markers: scanned.markers, ruleID: nil) == nil)
    }
}
