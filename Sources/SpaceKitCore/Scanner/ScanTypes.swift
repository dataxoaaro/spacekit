import Foundation
import Synchronization

/// Options controlling a scan.
public struct ScanOptions: Sendable {
    public enum Boundary: String, Sendable, Codable, CaseIterable {
        /// Stay on the device of the scan root.
        case device
        /// Stay inside the APFS container of the scan root. Scanning `/` this way covers System, Data,
        /// swap (VM), Preboot and Update volumes, which is how the whole disk adds up.
        case container
        /// Follow every mount except virtual file systems (devfs, autofs).
        case unrestricted
    }

    /// Files smaller than this are folded into a per-directory "smaller files" total instead of being
    /// stored individually. Set to 0 to keep every file.
    public var minFileSize: UInt64 = 1_000_000
    public var boundary: Boundary = .container
    /// Absolute paths or globs (`~` allowed) that are not descended into.
    public var exclude: [String] = []
    public var threads: Int = ScanOptions.defaultThreadCount
    /// Names whose presence in a directory is recorded as a bit (e.g. `package.json`, `.git`).
    public var markers: MarkerRegistry = MarkerRegistry(names: [])
    /// Directories up to this depth keep a live running total during the scan (for progressive UI).
    public var liveDepth: Int = 2

    public init() {}

    /// Directory listing on APFS is limited by kernel locks, not CPU: on an M-series Mac, wall time
    /// improves up to ~6 threads and gets *worse* beyond ~8 as threads contend in the kernel
    /// (measured: 1 thread 5.8s, 4 → 2.7s, 6 → 2.7s, 24 → 5.4s for 185k directories).
    public static var defaultThreadCount: Int {
        min(max(ProcessInfo.processInfo.activeProcessorCount / 2 - 1, 4), 8)
    }
}

/// Maps a small set of file names to bits so the scanner can record "this directory contains
/// `package.json`" without keeping every file name in memory.
public struct MarkerRegistry: Sendable {
    public private(set) var names: [String] = []
    private var bitsByName: [String: UInt64] = [:]
    /// Lookup table by UTF-8 length for the scanner's hot loop.
    private(set) var byLength: [[(bytes: [UInt8], bit: UInt64)]] = Array(repeating: [], count: 256)

    /// `.git` is always registered first so the safety guard can see repositories.
    public init(names: some Sequence<String>) {
        for name in [".git"] + Array(names) { register(name) }
    }

    private mutating func register(_ name: String) {
        guard bitsByName[name] == nil, names.count < 64 else { return }
        let bit = UInt64(1) << UInt64(names.count)
        names.append(name)
        bitsByName[name] = bit
        let bytes = Array(name.utf8)
        if bytes.count < 256 { byLength[bytes.count].append((bytes, bit)) }
    }

    public func bit(for name: String) -> UInt64 { bitsByName[name] ?? 0 }

    public func contains(_ name: String, in mask: UInt64) -> Bool {
        let b = bit(for: name)
        return b != 0 && mask & b != 0
    }

    @inline(__always)
    func lookup(_ pointer: UnsafePointer<UInt8>, length: Int) -> UInt64 {
        guard length < 256 else { return 0 }
        for candidate in byLength[length] where memcmp(pointer, candidate.bytes, length) == 0 {
            return candidate.bit
        }
        return 0
    }
}

/// Live counters for a running scan. Safe to read from any thread.
public final class ScanProgress: Sendable {
    let files = Atomic<UInt64>(0)
    let directories = Atomic<UInt64>(0)
    let bytes = Atomic<UInt64>(0)
    let errors = Atomic<UInt64>(0)
    let cancelled = Atomic<Bool>(false)
    let currentPath = Mutex<String>("")
    let root = Mutex<DirNode?>(nil)
    let rootChildren = Mutex<[DirNode]>([])

    public init() {}

    public struct Snapshot: Sendable {
        public var files: UInt64
        public var directories: UInt64
        public var bytes: UInt64
        public var errors: UInt64
        public var currentPath: String
    }

    public var snapshot: Snapshot {
        Snapshot(
            files: files.load(ordering: .relaxed),
            directories: directories.load(ordering: .relaxed),
            bytes: bytes.load(ordering: .relaxed),
            errors: errors.load(ordering: .relaxed),
            currentPath: currentPath.withLock { $0 }
        )
    }

    /// The root node of the scan in progress. Read its subfolders through `liveChildren`, not `children`.
    public var liveRoot: DirNode? { root.withLock { $0 } }

    /// The scan root's subfolders, available once the root is listed. Safe to read while the scan runs
    /// (their `name`, `isListed` and `liveSize`), unlike `liveRoot.children`, which the scan's final pass
    /// sorts in place.
    public var liveChildren: [DirNode] { rootChildren.withLock { $0 } }

    public func cancel() { cancelled.store(true, ordering: .relaxed) }
    public var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
}

public struct ScanStats: Sendable, Codable {
    public var files: UInt64
    public var directories: UInt64
    /// Directories that couldn't be listed plus entries that couldn't be read (usually privacy-protected locations).
    public var errors: UInt64
    public var duration: TimeInterval
    public var cancelled: Bool
}

public enum ScanError: Error, LocalizedError {
    case notFound(String)
    case notADirectory(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .notFound(let path): return "No such directory: \(path)"
        case .notADirectory(let path): return "Not a directory: \(path)"
        case .cancelled: return "Scan cancelled"
        }
    }
}

/// The result of a scan: a directory tree plus statistics. The tree changes only through the mutation
/// methods in `TreeMutations.swift` (see `DirNode` for the threading rules).
public final class ScanTree: @unchecked Sendable {
    public let root: DirNode
    /// The scanned paths. One element for a normal scan, several for a multi-root scan (where `root` is virtual).
    public let roots: [String]
    public let stats: ScanStats
    public let options: ScanOptions
    /// Capacity of the volume containing the first root.
    public let capacity: VolumeCapacity?
    /// Every multiply-linked file in the tree, so a mutation that takes away the link holding a file's bytes can
    /// hand them to a surviving link.
    var hardLinks: [HardLinkKey: HardLinkGroup]

    init(
        root: DirNode, roots: [String], stats: ScanStats, options: ScanOptions, capacity: VolumeCapacity?,
        hardLinks: [HardLinkKey: HardLinkGroup] = [:]
    ) {
        self.root = root
        self.roots = roots
        self.stats = stats
        self.options = options
        self.capacity = capacity
        self.hardLinks = hardLinks
    }

    public var markers: MarkerRegistry { options.markers }
    public var isMultiRoot: Bool { root.name.isEmpty }

    /// True if `path` lies inside one of the scanned roots.
    public func covers(_ path: String) -> Bool {
        roots.contains { PathUtil.isAncestorOrEqual($0, of: path) }
    }

    /// Finds the node for an absolute directory path, or `nil` if it wasn't scanned.
    public func node(at path: String) -> DirNode? {
        let target = PathUtil.standardize(path)
        let anchors = isMultiRoot ? root.children : [root]
        guard
            let anchor =
                anchors
                .filter({ PathUtil.isAncestorOrEqual($0.name, of: target) })
                .max(by: { $0.name.count < $1.name.count })
        else { return nil }
        if anchor.name == target { return anchor }
        let rest = anchor.name == "/" ? String(target.dropFirst()) : String(target.dropFirst(anchor.name.count + 1))
        var node = anchor
        for component in rest.split(separator: "/") {
            guard let next = node.child(named: String(component)) else { return nil }
            node = next
        }
        return node
    }
}

/// Identifies a file whatever name it's reached by.
struct HardLinkKey: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
}

/// One name of a multiply-linked file.
struct HardLink {
    let node: DirNode
    let name: String
    /// The file's bytes are counted under exactly one of its links; the others count as files of 0 bytes.
    var hasBytes: Bool
}

/// A file with several hard links in the tree.
struct HardLinkGroup {
    let size: UInt64
    let modified: Int64
    var links: [HardLink]

    /// The order that picks the link holding the bytes: folder path first, then name. A scan and an in-place update
    /// of the same disk must agree, whatever order the links were reached in.
    static func precedes(folder: String, name: String, folder other: String, name otherName: String) -> Bool {
        folder != other ? folder < other : name < otherName
    }

    /// The link that should hold the bytes, or `nil` if none is left.
    var ownerIndex: Int? {
        var owner: Int?
        var ownerFolder = ""
        for index in links.indices {
            let folder: String = links[index].node.path
            if let current = owner,
                !HardLinkGroup.precedes(folder: folder, name: links[index].name, folder: ownerFolder, name: links[current].name)
            {
                continue
            }
            owner = index
            ownerFolder = folder
        }
        return owner
    }
}
