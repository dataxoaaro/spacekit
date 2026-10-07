import Foundation
import Testing

@testable import SpaceKitCore

/// The guarantees in docs/SAFETY.md. If one of these fails, do not ship.
@Suite("Safety guard")
struct SafetyGuardTests {
    let guardian = testGuard()
    let manual = CleanupContext.manual(confirmed: true)
    let automatic = CleanupContext.automatic(AutomationContext(jobID: "test"))

    @Test(
        "Never removes the disk, a volume, or a top-level folder",
        arguments: [
            "/", "/System", "/Users", "/Applications", "/Library", "/private", "/usr", "/opt", "/Volumes",
            "/System/Volumes/Data", "/Volumes/External",
        ])
    func wholeDiskAndTopLevel(path: String) {
        let verdict = guardian.evaluate(path: path, context: manual)
        #expect(verdict.isBlocked, "\(path) must be blocked")
        #expect(!verdict.permits(confirmed: true))
    }

    @Test(
        "Never removes the home folder or anything that contains protected locations",
        arguments: [
            "/Users/tester", "/Users/tester/Library", "/Users/tester/Documents", "/Users/tester/Desktop",
            "/Users/tester/Pictures", "/Users/tester/Library/Application Support", "/Users/tester/Library/Containers",
            "/Users/tester/.ssh", "/Users/tester/Library/Caches", "/Users/tester/Library/Developer",
        ])
    func homeAndProtectedContainers(path: String) {
        #expect(guardian.evaluate(path: path, context: manual).isBlocked)
    }

    @Test(
        "Never removes anything inside sealed trees",
        arguments: [
            "/System/Library/Frameworks/AppKit.framework", "/usr/bin/ls", "/Users/tester/.ssh/id_ed25519",
            "/Users/tester/Library/Keychains/login.keychain-db", "/Users/tester/Library/Mail/V10",
            "/private/var/db/receipts", "/Users/tester/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw",
        ])
    func sealedTrees(path: String) {
        #expect(guardian.evaluate(path: path, context: manual).isBlocked)
    }

    @Test("Tilde paths are expanded before checking")
    func tildeExpansion() {
        #expect(guardian.evaluate(path: "~", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "~/", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "~/Library/..", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Projects/../Library", context: manual).isBlocked)
    }

    @Test("Relative paths are refused")
    func relativePaths() {
        #expect(guardian.evaluate(path: "Library", context: manual).isBlocked)
    }

    @Test("Git metadata and photo libraries are never edited")
    func gitAndLibraries() {
        #expect(guardian.evaluate(path: "/Users/tester/Projects/app/.git", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Projects/app/.git/objects", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Pictures/Photos Library.photoslibrary/originals/0", context: manual).isBlocked)
    }

    @Test("Repositories need confirmation by hand and are never removed automatically")
    func repositories() {
        let path = "/Users/tester/Projects/app"
        let byHand = guardian.evaluate(path: path, context: .manual(confirmed: false), isRepository: true)
        #expect(byHand.decision == .confirm)
        #expect(guardian.evaluate(path: path, context: automatic, isRepository: true).isBlocked)
    }

    @Test("User-protected paths block the path, its contents and its ancestors")
    func userProtectedPaths() {
        let guardian = testGuard(protectedPaths: ["~/Work/archive"])
        #expect(guardian.evaluate(path: "/Users/tester/Work/archive", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Work/archive/2020", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Work", context: manual).isBlocked)
        #expect(!guardian.evaluate(path: "/Users/tester/Work/scratch", context: manual).isBlocked)
    }

    @Test("Protected rules block their locations")
    func protectedRules() {
        let rule = Rule(
            id: "db.postgres", name: "Postgres data", paths: ["~/Library/Application Support/Postgres"],
            safety: SafetySpec(level: .protected))
        let guardian = testGuard(rules: [rule])
        #expect(guardian.evaluate(path: "/Users/tester/Library/Application Support/Postgres/var-16", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Library/Application Support/Postgres", rule: rule, context: manual).isBlocked)
    }

    @Test("Nothing is removed while running as root")
    func root() {
        let guardian = testGuard(root: true)
        #expect(guardian.evaluate(path: "/Users/tester/Library/Caches/com.example", context: manual).isBlocked)
    }

    @Test("Regenerable rule items are allowed, by hand and automatically")
    func safeRuleItems() {
        let rule = Rule(
            id: "xcode.derived-data", name: "DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"],
            granularity: .children, safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        let path = "/Users/tester/Library/Developer/Xcode/DerivedData/App-abc"
        #expect(guardian.evaluate(path: path, rule: rule, context: .manual(confirmed: false)).decision == .allow)
        #expect(guardian.evaluate(path: path, rule: rule, context: automatic).decision == .allow)
    }

    @Test("Automatic runs stay inside the rule's locations")
    func automaticScope() {
        let rule = Rule(
            id: "xcode.derived-data", name: "DerivedData", paths: ["~/Library/Developer/Xcode/DerivedData"],
            granularity: .children, safety: SafetySpec(level: .safe), action: ActionSpec(remove: true))
        #expect(guardian.evaluate(path: "/Users/tester/Projects/app", rule: rule, context: automatic).isBlocked)
    }

    @Test("Review items need opt-in for automation")
    func reviewItems() {
        let rule = Rule(
            id: "xcode.archives", name: "Archives", paths: ["~/Library/Developer/Xcode/Archives"],
            granularity: .children, safety: SafetySpec(level: .review), action: ActionSpec(remove: true))
        let path = "/Users/tester/Library/Developer/Xcode/Archives/2024-01-01"
        #expect(guardian.evaluate(path: path, rule: rule, context: automatic).isBlocked)
        let optedIn = CleanupContext.automatic(AutomationContext(jobID: "a", allowReview: true))
        #expect(guardian.evaluate(path: path, rule: rule, context: optedIn).decision == .allow)
        #expect(guardian.evaluate(path: path, rule: rule, context: .manual(confirmed: false)).decision == .confirm)
    }

    @Test("Automatic runs never remove unrecognised folders the job didn't list")
    func automaticUnknown() {
        #expect(guardian.evaluate(path: "/Users/tester/Projects/app/build", context: automatic).isBlocked)
    }

    @Test("Personal folders: by hand with confirmation; automatically only under strict terms")
    func personalAreas() {
        let file = "/Users/tester/Downloads/installer.dmg"
        #expect(guardian.evaluate(path: file, context: .manual(confirmed: false)).decision == .confirm)
        #expect(guardian.evaluate(path: file, context: automatic).isBlocked)

        let strict = CleanupContext.automatic(
            AutomationContext(jobID: "dl", customPaths: ["~/Downloads"], olderThan: .days(30), usesTrash: true))
        #expect(guardian.evaluate(path: file, context: strict).decision == .allow)

        let noAge = CleanupContext.automatic(AutomationContext(jobID: "dl", customPaths: ["~/Downloads"], olderThan: nil, usesTrash: true))
        #expect(guardian.evaluate(path: file, context: noAge).isBlocked)

        let noTrash = CleanupContext.automatic(
            AutomationContext(jobID: "dl", customPaths: ["~/Downloads"], olderThan: .days(30), usesTrash: false))
        #expect(guardian.evaluate(path: file, context: noTrash).isBlocked)
    }

    @Test("Mount points are never removed")
    func mountPoints() {
        let volumes = VolumeTable(
            volumes: [
                MountedVolume(
                    mountPoint: "/Users/tester/Library/Developer/CoreDevice/DeviceFS", device: "devices", fileSystem: "devicefs",
                    deviceID: 99, isReadOnly: false, isBrowsable: false, isLocal: true)
            ], firmlinks: [])
        let guardian = SafetyGuard(home: "/Users/tester", volumes: volumes, isRunningAsRoot: false)
        #expect(guardian.evaluate(path: "/Users/tester/Library/Developer/CoreDevice/DeviceFS", context: manual).isBlocked)
        #expect(guardian.evaluate(path: "/Users/tester/Library/Developer/CoreDevice", context: manual).isBlocked)
    }

    @Test("Symlinked parents are resolved before checking")
    func symlinkedParents() throws {
        let tree = try TempTree()
        try tree.directory("real/.git")
        try FileManager.default.createSymbolicLink(atPath: tree.path("link"), withDestinationPath: tree.path("real/.git"))
        let guardian = SafetyGuard(home: tree.root, volumes: emptyVolumes, isRunningAsRoot: false)
        // Removing something through the link means removing it inside .git.
        #expect(guardian.evaluate(path: tree.path("link/objects"), context: manual).isBlocked)
    }
}
