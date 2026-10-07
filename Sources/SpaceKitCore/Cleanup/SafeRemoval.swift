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

    /// Opens `path` as a directory, refusing symlinks in any component and a handle whose path isn't exactly
    /// `expected` (the resolved path the guard checked).
    static func openDirectory(_ path: String, expecting expected: String) throws -> Int32 {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw posixError(path) }
        guard currentPath(of: fd) == expected else {
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

    /// Deletes `name` inside the folder open as `fd`, never by path. Every step is relative to a handle opened with
    /// `O_NOFOLLOW`, so a folder swapped for a symlink mid-way is removed as a link, a deep tree never hits
    /// `PATH_MAX`, and losing search permission on a folder above doesn't matter.
    static func delete(_ name: String, in fd: Int32, directory: String) throws {
        let entry = Array(name.utf8CString)
        if removeEntry(entry, in: fd) != 0 { throw posixError(PathUtil.join(directory, name)) }
    }

    /// Removes one entry of the folder open as `parent`. Returns 0, or -1 with `errno` set.
    private static func removeEntry(_ name: [CChar], in parent: Int32) -> Int32 {
        let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            // A file or a symlink (now): remove the entry itself, never what a link points to.
            if errno == ENOTDIR || errno == ELOOP { return unlinkat(parent, name, 0) }
            return -1
        }
        defer { close(fd) }
        // Entries can appear while the folder is emptied; a few passes catch them, then rmdir reports the rest.
        for _ in 0..<SafeRemoval.emptyingPasses {
            if removeContents(of: fd) != 0 { return -1 }
            if unlinkat(parent, name, AT_REMOVEDIR) == 0 { return 0 }
            // Swapped for a link or file after it was opened: what the handle reached is empty; drop the entry.
            if errno == ENOTDIR { return unlinkat(parent, name, 0) }
            if errno != ENOTEMPTY { return -1 }
        }
        return -1
    }

    private static let emptyingPasses = 3

    /// Removes everything inside the folder open as `fd`. Returns 0, or -1 with `errno` set.
    private static func removeContents(of fd: Int32) -> Int32 {
        guard let names = entryNames(of: fd) else { return -1 }
        for name in names {
            if unlinkat(fd, name, 0) == 0 || errno == ENOENT { continue }
            // macOS answers EPERM for unlink on a folder.
            guard errno == EPERM || errno == EISDIR else { return -1 }
            if removeEntry(name, in: fd) != 0, errno != ENOENT { return -1 }
        }
        return 0
    }

    /// Raw names (not decoded, so any byte sequence round-trips) of the entries of the folder open as `fd`.
    private static func entryNames(of fd: Int32) -> [[CChar]]? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let stream = fdopendir(copy) else {
            close(copy)
            return nil
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var names: [[CChar]] = []
        while let entry = readdir(stream) {
            let length = Int(entry.pointee.d_namlen)
            let name: [CChar] = withUnsafeBytes(of: &entry.pointee.d_name) { raw in
                Array(raw.bindMemory(to: CChar.self).prefix(length)) + [0]
            }
            if name == [46, 0] || name == [46, 46, 0] { continue }
            names.append(name)
        }
        return names
    }

    /// Confirms `directory` still resolves to itself (no symlink swapped in) right before a path-based operation.
    static func verifyUnchanged(_ directory: String) throws {
        close(try openDirectory(directory))
    }

    static func posixError(_ path: String) -> Error {
        let code = errno
        return CocoaError(
            .fileWriteUnknown, userInfo: [NSFilePathErrorKey: path, NSLocalizedDescriptionKey: String(cString: strerror(code))])
    }
}
