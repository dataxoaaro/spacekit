import Foundation
import Testing

@testable import SpaceKitCore

@Suite("Config updates from front ends")
struct ConfigUpdateTests {
    @Test("An update applies one change to the file as it is now, keeping what others wrote since")
    func updateMergesIntoDisk() throws {
        let tree = try TempTree()
        let store = ConfigStore(file: tree.path("config.yaml"))
        var launched = SpaceKitConfig()
        launched.jobs = [Job(id: "a", name: "A", rules: ["x"])]
        try store.save(launched)

        // Another front end (the CLI) adds a job after the app loaded its copy.
        var onDisk = try store.load()
        onDisk.jobs.append(Job(id: "b", name: "B", rules: ["y"]))
        try store.save(onDisk)

        let saved = try store.update { $0.safety.maxBytesPerRun = .gb(5) }
        #expect(saved.jobs.map(\.id) == ["a", "b"])
        #expect(saved.safety.maxBytesPerRun == .gb(5))
        #expect(try store.load() == saved)
    }

    @Test("An update refuses to overwrite a config file that doesn't parse")
    func updateRefusesInvalidFile() throws {
        let tree = try TempTree()
        let file = tree.path("config.yaml")
        let broken = "safety:\n  trash: sometimes\n"
        try broken.write(toFile: file, atomically: true, encoding: .utf8)
        let store = ConfigStore(file: file)

        #expect(throws: ConfigError.self) { try store.update { $0.ui.mapDepth = 3 } }
        #expect(try String(contentsOfFile: file, encoding: .utf8) == broken)
    }

    @Test("An update without a config file starts from the defaults")
    func updateCreatesFile() throws {
        let tree = try TempTree()
        let store = ConfigStore(file: tree.path("nested/config.yaml"))
        let saved = try store.update { $0.ui.mapDepth = 6 }
        #expect(saved.ui.mapDepth == 6)
        #expect(try store.load().ui.mapDepth == 6)
    }

    @Test("A new job never takes an existing job's id")
    func newJobGetsUniqueID() {
        var config = SpaceKitConfig()
        config.jobs = [Job(id: "clean-downloads", name: "Old", paths: ["~/Downloads"]), Job(id: "clean-downloads-2", name: "Old 2", paths: ["~/x"])]

        let id = config.upsertJob(Job(id: "clean-downloads", name: "New", paths: ["~/Downloads"]), replacing: nil)

        #expect(id == "clean-downloads-3")
        #expect(config.jobs.map(\.id) == ["clean-downloads", "clean-downloads-2", "clean-downloads-3"])
        #expect(config.jobs[0].name == "Old")
    }

    @Test("Editing a job replaces it in place")
    func editReplacesJob() {
        var config = SpaceKitConfig()
        config.jobs = [Job(id: "a", name: "A", rules: ["x"]), Job(id: "b", name: "B", rules: ["y"])]
        var edited = config.jobs[0]
        edited.enabled = false

        let id = config.upsertJob(edited, replacing: "a")

        #expect(id == "a")
        #expect(config.jobs.map(\.id) == ["a", "b"])
        #expect(config.jobs[0].enabled == false)
    }

    @Test("Saving an edit of a job deleted elsewhere adds it back without clobbering another job")
    func editOfDeletedJobAppends() {
        var config = SpaceKitConfig()
        config.jobs = [Job(id: "b", name: "B", rules: ["y"])]

        let id = config.upsertJob(Job(id: "b", name: "Edited A", rules: ["x"]), replacing: "a")

        #expect(id == "b-2")
        #expect(config.jobs.map(\.name) == ["B", "Edited A"])
    }

    @Test("Unique ids fall back to a word when the name has no letters or digits")
    func uniqueIDForEmptySlug() {
        var config = SpaceKitConfig()
        #expect(config.uniqueJobID("") == "job")
        config.jobs = [Job(id: "job", name: "?", rules: ["x"])]
        #expect(config.uniqueJobID("") == "job-2")
    }
}
