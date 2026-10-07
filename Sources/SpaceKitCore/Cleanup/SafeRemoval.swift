import Foundation

/// Removal through a directory handle, so the folder that was checked is the folder that is changed.
///
/// The executor resolves an item's parent folder before asking the `SafetyGuard`. Between that check and the
/// removal, a parent could be swapped for a symlink to somewhere protected. Opening the checked path with no
/// symlinks allowed anywhere, confirming the handle's path, and then removing by name relative to that handle
/// closes the gap. Moving to the Trash has no handle-based API, so for that the path is re-verified immediately
/// before the move.
enum SafeRemoval {
    struct Refused: LocalizedError {
        var errorDescription: String?
    }

    /// Opens `path` as a directory, refusing symlinks in any component and a handle whose path isn't `expected`.
    static func openDirectory(_ path: String, expecting expected: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        guard let actual = currentPath(of: fd), sameLocation(actual, expected) else {
            close(fd)
            throw Refused(errorDescription: "\(path) changed after it was checked; nothing was removed")
        }
        return fd
    }

    static func openDirectory(_ path: String) throws -> Int32 {
        try openDirectory(path, expecting: path)
    }

    /// The path the kernel has for an open handle.
    static func currentPath(of fd: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) != -1 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Deletes `name` (recursively if it's a folder; a symlink is removed as a link) inside the checked folder.
    static func delete(_ name: String, inDirectory directory: String) throws {
        let fd = try openDirectory(directory)
        defer { close(fd) }
        try delete(name, in: fd, directory: directory)
    }

    static func delete(_ name: String, in fd: Int32, directory: String) throws {
        let state = removefile_state_alloc()
        defer { removefile_state_free(state) }
        if removefileat(fd, name, state, removefile_flags_t(REMOVEFILE_RECURSIVE)) != 0 {
            throw posixError(PathUtil.join(directory, name))
        }
    }

    /// Confirms `directory` still resolves to itself (no symlink swapped in) right before a path-based operation.
    static func verifyUnchanged(_ directory: String) throws {
        close(try openDirectory(directory))
    }

    /// APFS is case- and normalization-insensitive, so two spellings can name the same folder.
    static func sameLocation(_ a: String, _ b: String) -> Bool {
        comparisonKey(a) == comparisonKey(b)
    }

    static func comparisonKey(_ path: String) -> String { PathUtil.comparisonKey(path) }

    static func posixError(_ path: String) -> Error {
        let code = errno
        return CocoaError(
            .fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
