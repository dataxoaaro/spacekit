import Foundation

@testable import SpaceKitCore

/// A temporary directory tree for tests, removed on deinit.
final class TempTree {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("spacekit-tests-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        // Resolve /var → /private/var so paths match what the scanner reports.
        root = PathUtil.realpath(base)!
    }

    deinit {
        try? FileManager.default.removeItem(atPath: root)
    }

    func path(_ relative: String) -> String { relative.isEmpty ? root : root + "/" + relative }

    @discardableResult
    func file(_ relative: String, bytes: Int, modified: Date? = nil) throws -> String {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: PathUtil.parent(full), withIntermediateDirectories: true)
        // Random bytes so the file system can't store it sparsely or compressed.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { buffer in
            if let base = buffer.baseAddress { arc4random_buf(base, bytes) }
        }
        try data.write(to: URL(fileURLWithPath: full))
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: full)
        }
        return full
    }

    func directory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// Allocated size the way the scanner measures it.
    func allocated(_ relative: String) -> UInt64 {
        var st = stat()
        guard lstat(path(relative), &st) == 0 else { return 0 }
        return UInt64(st.st_blocks) * 512
    }
}

func scan(_ path: String, minFileSize: UInt64 = 0, markers: [String] = [], configure: (inout ScanOptions) -> Void = { _ in }) throws
    -> ScanTree
{
    var options = ScanOptions()
    options.minFileSize = minFileSize
    options.markers = MarkerRegistry(names: markers)
    options.threads = 4
    configure(&options)
    return try Scanner(options: options).scan(path)
}

/// A volume table with no mounts, so tests don't depend on the machine's disks.
let emptyVolumes = VolumeTable(volumes: [], firmlinks: [])

func testGuard(home: String = "/Users/tester", protectedPaths: [String] = [], rules: [Rule] = [], root: Bool = false) -> SafetyGuard {
    SafetyGuard(home: home, userProtectedPaths: protectedPaths, protectedRules: rules, volumes: emptyVolumes, isRunningAsRoot: root)
}
