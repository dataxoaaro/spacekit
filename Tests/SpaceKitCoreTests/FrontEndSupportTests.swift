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
}
