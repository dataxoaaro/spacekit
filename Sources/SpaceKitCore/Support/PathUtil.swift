import Foundation

/// Path helpers. All SpaceKit paths are plain absolute POSIX strings; `~` is expanded at the edges.
public enum PathUtil {
    /// The real user's home directory, even when `HOME` points elsewhere.
    public static var home: String {
        if let override = ProcessInfo.processInfo.environment["SPACEKIT_HOME"], !override.isEmpty {
            return standardize(override)
        }
        return standardize(FileManager.default.homeDirectoryForCurrentUser.path)
    }

    /// Expands a leading `~` and `$HOME`, then standardizes.
    public static func expand(_ path: String, home: String = PathUtil.home) -> String {
        var p = path.trimmingCharacters(in: .whitespaces)
        if p == "~" {
            p = home
        } else if p.hasPrefix("~/") {
            p = home + p.dropFirst(1)
        }
        p = p.replacingOccurrences(of: "$HOME", with: home)
        return standardize(p)
    }

    /// Replaces the home prefix with `~` for display.
    public static func abbreviate(_ path: String, home: String = PathUtil.home) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    /// Collapses `.`, `..` and duplicate slashes without touching the file system.
    public static func standardize(_ path: String) -> String {
        guard path.hasPrefix("/") else {
            return standardize(FileManager.default.currentDirectoryPath + "/" + path)
        }
        var parts: [Substring] = []
        for component in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch component {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(component)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// Resolves symlinks in every component. Returns `nil` if the path doesn't exist.
    public static func realpath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Resolves symlinks in the parent directory but not the final component,
    /// so a symlink is identified as itself rather than as its target.
    public static func resolveParent(_ path: String) -> String {
        let std = standardize(path)
        if std == "/" { return "/" }
        let parent = (std as NSString).deletingLastPathComponent
        let name = (std as NSString).lastPathComponent
        guard let realParent = realpath(parent) else { return std }
        return realParent == "/" ? "/" + name : realParent + "/" + name
    }

    public static func components(_ path: String) -> [Substring] {
        path.split(separator: "/", omittingEmptySubsequences: true)
    }

    /// True if `ancestor` equals `path` or contains it (component-wise, not string-prefix).
    public static func isAncestorOrEqual(_ ancestor: String, of path: String) -> Bool {
        if ancestor == "/" { return path.hasPrefix("/") }
        return path == ancestor || path.hasPrefix(ancestor + "/")
    }

    public static func isStrictAncestor(_ ancestor: String, of path: String) -> Bool {
        ancestor != path && isAncestorOrEqual(ancestor, of: path)
    }

    public static func join(_ parent: String, _ name: String) -> String {
        parent == "/" ? "/" + name : parent + "/" + name
    }

    public static func lastComponent(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    public static func parent(_ path: String) -> String {
        (path as NSString).deletingLastPathComponent
    }

    /// Expands shell-style globs (`*`, `?`, `[...]`) after `~` expansion. Non-glob paths are returned as-is if they exist.
    public static func glob(_ pattern: String, home: String = PathUtil.home) -> [String] {
        let expanded = expand(pattern, home: home)
        guard expanded.contains(where: { "*?[".contains($0) }) else {
            return FileManager.default.fileExists(atPath: expanded) ? [expanded] : []
        }
        var result = glob_t()
        defer { globfree(&result) }
        guard Darwin.glob(expanded, 0, nil, &result) == 0 else { return [] }
        return (0..<Int(result.gl_pathc)).compactMap { index in
            result.gl_pathv[index].map { String(cString: $0) }
        }
    }

    /// `fnmatch(3)` with `**` support (matches across `/`).
    public static func matches(_ path: String, glob pattern: String, home: String = PathUtil.home) -> Bool {
        let expanded = pattern.hasPrefix("~") ? expand(pattern, home: home) : pattern
        if expanded.contains("**") {
            let regex =
                "^"
                + NSRegularExpression.escapedPattern(for: expanded)
                .replacingOccurrences(of: "\\*\\*/", with: "(.*/)?")
                .replacingOccurrences(of: "\\*\\*", with: ".*")
                .replacingOccurrences(of: "\\*", with: "[^/]*")
                .replacingOccurrences(of: "\\?", with: "[^/]") + "$"
            return path.range(of: regex, options: .regularExpression) != nil
        }
        return fnmatch(expanded, path, FNM_PATHNAME) == 0
    }
}
