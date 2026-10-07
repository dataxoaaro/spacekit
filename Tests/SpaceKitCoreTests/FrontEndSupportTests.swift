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
}
