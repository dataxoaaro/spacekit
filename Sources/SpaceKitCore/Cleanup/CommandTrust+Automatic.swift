import Foundation

/// Which tools an automatic run may start. The agent runs as the person, with Full Disk Access and nobody watching, so a
/// program any process of theirs could swap for its own (one in `~/.local/bin`, `~/go/bin`, or a Homebrew prefix they
/// own) runs only when they start it themselves. In an automatic run a tool runs only when neither its file nor any
/// folder or symlink on the way to it is theirs or writable by them: `/usr/bin`, `/bin`, a root-owned `/usr/local/bin`.
extension CommandTrust {
    /// How many symlinks the walk follows before it gives up, as the system does.
    static let symlinkLimit = 32

    /// Why the tool found at `executable` doesn't start in an automatic run, or `nil` when it may. `changeable` finds
    /// what the person could change on the way to it (`changeablePart(of:)`; tests stand in their own).
    func automaticRefusal(at executable: String?, context: CleanupContext, changeable: (String) -> String?) -> String? {
        guard context.isAutomatic, let executable, let part = changeable(executable) else { return nil }
        return "\(TerminalText.sanitize(part)) can be replaced by any program of yours, so "
            + "'\(TerminalText.sanitize(PathUtil.lastComponent(executable)))' runs only when you start it"
    }

    /// The first file, folder or symlink on the way to `path` that the person owns or can write, following every
    /// symlink to the file it leads to; `nil` when there is none. A part that can't be read counts as changeable, so a
    /// walk that can't be finished refuses the tool.
    public static func changeablePart(of path: String) -> String? {
        let user = getuid()
        func isChangeable(_ part: String, _ st: stat) -> Bool {
            st.st_uid == user || faccessat(AT_FDCWD, part, W_OK, AT_SYMLINK_NOFOLLOW) == 0
        }
        var st = stat()
        guard path.hasPrefix("/"), lstat("/", &st) == 0, !isChangeable("/", st) else { return "/" }
        // Components still to walk, the next one last. Every folder in `current` is a real folder that was checked, so a
        // `..` after it goes back to its parent.
        var pending = PathUtil.components(path).reversed().map(String.init)
        var current = "/"
        var followed = 0
        while let next = pending.popLast() {
            if next == "." { continue }
            if next == ".." {
                current = PathUtil.parent(current)
                continue
            }
            let part = PathUtil.join(current, next)
            guard lstat(part, &st) == 0, !isChangeable(part, st) else { return part }
            guard st.st_mode & S_IFMT == S_IFLNK else {
                current = part
                continue
            }
            followed += 1
            guard followed <= symlinkLimit, let target = readLink(part) else { return part }
            if target.hasPrefix("/") { current = "/" }
            pending += PathUtil.components(target).reversed().map(String.init)
        }
        return nil
    }

    private static func readLink(_ path: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let count = readlink(path, &buffer, buffer.count - 1)
        guard count > 0 else { return nil }
        return String(decoding: buffer[..<count].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
