import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Path helpers")
struct PathUtilTests {
    let realHome = PathUtil.standardize(FileManager.default.homeDirectoryForCurrentUser.path)

    @Test("SPACEKIT_HOME is ignored unless the build honours it")
    func homeOverride() {
        let environment = ["SPACEKIT_HOME": "/private/tmp/sandbox"]
        #expect(PathUtil.resolveHome(environment: environment, honorsOverride: false) == realHome)
        #expect(PathUtil.resolveHome(environment: environment, honorsOverride: true) == "/private/tmp/sandbox")
        #expect(PathUtil.resolveHome(environment: ["SPACEKIT_HOME": ""], honorsOverride: true) == realHome)
    }

    @Test("Comparison keys fold case and Unicode normalization")
    func comparisonKey() {
        #expect(PathUtil.comparisonKey("/Users/Me/Library") == PathUtil.comparisonKey("/users/me/LIBRARY"))
        #expect(PathUtil.comparisonKey("/x/Caf\u{E9}").unicodeScalars.elementsEqual(PathUtil.comparisonKey("/x/CAFE\u{301}").unicodeScalars))
    }

    @Test("A folder could contain a glob's matches when its components match the glob's leading components")
    func couldContain() {
        #expect(PathUtil.couldContain("/opt/homebrew/var", pattern: "/opt/homebrew/var/postgresql@*"))
        #expect(PathUtil.couldContain("/a/b", pattern: "/a/*/c"))
        #expect(PathUtil.couldContain("/a/b/c/d", pattern: "/a/**/z"))
        #expect(!PathUtil.couldContain("/opt/homebrew/var/postgresql@16", pattern: "/opt/homebrew/var/postgresql@*"))
        #expect(!PathUtil.couldContain("/opt/other", pattern: "/opt/homebrew/var/postgresql@*"))
        #expect(PathUtil.couldContain("/a", pattern: "/a/b"))
        #expect(!PathUtil.couldContain("/a/b", pattern: "/a/b"))
    }
}
