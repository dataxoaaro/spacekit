import Foundation

/// Config and rule files decide what SpaceKit removes and which tools it runs, and the background agent reads
/// them unattended. A file another account could have written (or could still replace) is not read.
enum FileTrust {
    /// Why `path` can't be trusted, or `nil` if only this user (or root) can change it. A missing file is not a
    /// problem here; callers handle that on their own.
    static func problem(with path: String, owner uid: uid_t = geteuid()) -> String? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        if st.st_uid != uid && st.st_uid != 0 { return "is owned by another user" }
        if st.st_mode & (S_IWGRP | S_IWOTH) != 0 { return "can be changed by other users (group or world writable)" }
        // The folder of the path and, for a symlink, of its target: others could replace the file there.
        let folders = Set([PathUtil.parent(path), PathUtil.parent(PathUtil.realpath(path) ?? path)])
        for folder in folders.sorted() where isOpenToOthers(folder) {
            return "is in a folder other users can change (\(PathUtil.abbreviate(folder)))"
        }
        return nil
    }

    /// Writable by group or others without the sticky bit, which would stop them replacing this user's files.
    private static func isOpenToOthers(_ folder: String) -> Bool {
        var st = stat()
        guard stat(folder, &st) == 0 else { return false }
        return st.st_mode & (S_IWGRP | S_IWOTH) != 0 && st.st_mode & S_ISVTX == 0
    }
}
