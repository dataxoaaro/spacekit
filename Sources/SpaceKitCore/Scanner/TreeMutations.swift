import Foundation

/// In-place updates that keep a finished `ScanTree` in step with the disk after SpaceKit (or something else)
/// changes it, without rescanning everything.
///
/// Invariants preserved by every mutation (checked by `inconsistencies()` and the tests):
/// - `directFileSize == Σ files.size + otherFilesSize`, `directFileCount == files.count + otherFilesCount`
/// - `size == directFileSize + Σ children.size`
/// - `fileCount == directFileCount + Σ children.fileCount`, `dirCount == Σ (children.dirCount + 1)`
///
/// Mutations must happen on one thread at a time, after the scan finished (the app uses the main actor).
extension ScanTree {
    // MARK: Removal

    /// Updates the tree after `path` was removed from disk. Returns the bytes taken out of the tree.
    ///
    /// - Parameters:
    ///   - looseFilesOnly: plain files directly inside `path` were removed. The cleanup may have skipped some
    ///     of them, so the folder is re-read to see which are left.
    ///   - bytes: the removed size, if known. Needed for small files, which the tree only knows as a
    ///     per-folder total.
    @discardableResult
    public func applyRemoval(of path: String, looseFilesOnly: Bool = false, bytes hint: UInt64? = nil) -> UInt64 {
        if looseFilesOnly {
            guard let node = node(at: path) else { return 0 }
            return dropRemovedLooseFiles(of: node, at: path)
        }
        if let node = node(at: path), let parent = node.parent {
            detach(node, from: parent)
            return node.size
        }
        guard let parent = node(at: PathUtil.parent(path)) else { return 0 }
        return takeFile(named: PathUtil.lastComponent(path), from: parent, hint: hint)?.size ?? 0
    }

    // MARK: Move

    /// Updates the tree after `path` was moved to `destination` (for example into the Trash). If the
    /// destination's folder is part of the tree, the item reappears there under its new name, so totals
    /// stay correct: moving to the Trash doesn't free space until the Trash is emptied.
    /// Returns `true` if the item was re-attached at the destination.
    @discardableResult
    public func applyMove(of path: String, to destination: String, bytes hint: UInt64? = nil) -> Bool {
        let newName = PathUtil.lastComponent(destination)
        guard let target = node(at: PathUtil.parent(destination)), !PathUtil.isAncestorOrEqual(path, of: target.path) else {
            applyRemoval(of: path, bytes: hint)
            return false
        }
        if let node = node(at: path), let parent = node.parent {
            detach(node, from: parent)
            node.name = newName
            attach(node, to: target)
            return true
        }
        guard let parent = node(at: PathUtil.parent(path)),
            let leaf = takeFile(named: PathUtil.lastComponent(path), from: parent, hint: hint)
        else { return false }
        putFile(FileLeaf(name: newName, size: leaf.size, modified: leaf.modified), into: target)
        return true
    }

    // MARK: Refresh

    /// Replaces the folder at `path` with a fresh scan of it (`fresh` must be a single-root scan of `path`).
    /// If the folder is new, it's added under its parent. Use it to resync one folder (say, the Trash after
    /// it was emptied in Finder) without rescanning the disk.
    public func splice(_ fresh: ScanTree, at path: String) {
        let path = PathUtil.standardize(path)
        let source = fresh.root
        guard !fresh.isMultiRoot, source.name == path || fresh.roots.first == path else { return }
        if let target = node(at: path) {
            let delta = (
                bytes: Int64(source.size) - Int64(target.size),
                files: Int64(source.fileCount) - Int64(target.fileCount),
                dirs: Int64(source.dirCount) - Int64(target.dirCount)
            )
            target.children = source.children
            for child in target.children { child.setParent(target) }
            target.files = source.files
            target.otherFilesSize = source.otherFilesSize
            target.otherFilesCount = source.otherFilesCount
            target.directFileSize = source.directFileSize
            target.directFileCount = source.directFileCount
            target.markers = source.markers
            target.newestModified = source.newestModified
            target.newestAccessed = source.newestAccessed
            target.flags = source.flags
            target.size = source.size
            target.fileCount = source.fileCount
            target.dirCount = source.dirCount
            target.subtreeMarkers = source.subtreeMarkers
            target.subtreeNewestModified = source.subtreeNewestModified
            target.subtreeNewestAccessed = source.subtreeNewestAccessed
            renumberDepths(target)
            if let parent = target.parent {
                adjust(from: parent, bytes: delta.bytes, files: delta.files, dirs: delta.dirs)
                parent.children.sort { $0.size > $1.size }
            }
        } else if let parent = node(at: PathUtil.parent(path)) {
            source.name = PathUtil.lastComponent(path)
            attach(source, to: parent)
        }
    }

    // MARK: Verification

    /// Folders whose stored totals don't match their contents. Always empty unless there's a bug.
    public func inconsistencies(limit: Int = 20) -> [String] {
        var problems: [String] = []
        root.forEachDescendant { node in
            guard problems.count < limit else { return false }
            let leafBytes = node.files.reduce(UInt64(0)) { $0 + $1.size } + node.otherFilesSize
            let size = node.directFileSize + node.children.reduce(UInt64(0)) { $0 + $1.size }
            let files = UInt64(node.directFileCount) + node.children.reduce(UInt64(0)) { $0 + $1.fileCount }
            let dirs = node.children.reduce(UInt64(0)) { $0 + $1.dirCount + 1 }
            if node.name.isEmpty {
                if node.size != size { problems.append("(roots): size \(node.size) ≠ \(size)") }
                return true
            }
            if leafBytes != node.directFileSize { problems.append("\(node.path): files \(leafBytes) ≠ direct \(node.directFileSize)") }
            if node.size != size { problems.append("\(node.path): size \(node.size) ≠ \(size)") }
            if node.fileCount != files { problems.append("\(node.path): fileCount \(node.fileCount) ≠ \(files)") }
            if node.dirCount != dirs { problems.append("\(node.path): dirCount \(node.dirCount) ≠ \(dirs)") }
            for child in node.children where child.parent !== node { problems.append("\(child.path): wrong parent") }
            return true
        }
        return problems
    }

    // MARK: Helpers

    private func detach(_ node: DirNode, from parent: DirNode) {
        parent.children.removeAll { $0 === node }
        adjust(from: parent, bytes: -Int64(node.size), files: -Int64(node.fileCount), dirs: -Int64(node.dirCount + 1))
    }

    private func attach(_ node: DirNode, to parent: DirNode) {
        node.setParent(parent)
        renumberDepths(node)
        let index = parent.children.firstIndex { $0.size < node.size } ?? parent.children.count
        parent.children.insert(node, at: index)
        adjust(from: parent, bytes: Int64(node.size), files: Int64(node.fileCount), dirs: Int64(node.dirCount + 1))
        var cursor: DirNode? = parent
        while let ancestor = cursor {
            ancestor.subtreeMarkers |= node.subtreeMarkers
            ancestor.subtreeNewestModified = max(ancestor.subtreeNewestModified, node.subtreeNewestModified)
            cursor = ancestor.parent
        }
    }

    /// Keeps only the direct files of `node` that are still on disk. Never grows the folder: files that
    /// appeared since the scan aren't counted, and small files are capped at the folder's known total.
    private func dropRemovedLooseFiles(of node: DirNode, at path: String) -> UInt64 {
        // An unreadable folder is treated as emptied, matching what the cleanup reported.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
        var remaining: [String: UInt64] = [:]
        for name in names {
            var st = stat()
            guard lstat(PathUtil.join(path, name), &st) == 0, (st.st_mode & S_IFMT) != S_IFDIR else { continue }
            remaining[name] = UInt64(max(0, st.st_blocks)) * 512
        }
        let files = node.files.filter { remaining[$0.name] != nil }
        let tracked = Set(node.files.map(\.name))
        let small = remaining.filter { !tracked.contains($0.key) }
        let otherSize = min(node.otherFilesSize, small.values.reduce(0, &+))
        let otherCount = min(node.otherFilesCount, UInt32(small.count))
        let directSize = files.reduce(0) { $0 &+ $1.size } &+ otherSize
        let directCount = UInt32(files.count) + otherCount

        let bytes = node.directFileSize - min(node.directFileSize, directSize)
        let count = node.directFileCount - min(node.directFileCount, directCount)
        node.files = files
        node.otherFilesSize = otherSize
        node.otherFilesCount = otherCount
        node.directFileSize = directSize
        node.directFileCount = directCount
        adjust(from: node, bytes: -Int64(bytes), files: -Int64(count), dirs: 0)
        return bytes
    }

    /// Removes a file from a folder's direct contents. Small files only exist as a total, so `hint` gives their size.
    private func takeFile(named name: String, from parent: DirNode, hint: UInt64?) -> FileLeaf? {
        let leaf: FileLeaf
        if let index = parent.files.firstIndex(where: { $0.name == name }) {
            leaf = parent.files.remove(at: index)
        } else if let hint, parent.otherFilesCount > 0 {
            let size = min(hint, parent.otherFilesSize)
            parent.otherFilesSize -= size
            parent.otherFilesCount -= 1
            leaf = FileLeaf(name: name, size: size, modified: 0)
        } else {
            return nil
        }
        parent.directFileSize -= min(parent.directFileSize, leaf.size)
        parent.directFileCount -= min(parent.directFileCount, 1)
        adjust(from: parent, bytes: -Int64(leaf.size), files: -1, dirs: 0)
        return leaf
    }

    private func putFile(_ leaf: FileLeaf, into parent: DirNode) {
        if leaf.size >= options.minFileSize && leaf.size > 0 {
            let index = parent.files.firstIndex { $0.size < leaf.size } ?? parent.files.count
            parent.files.insert(leaf, at: index)
        } else {
            parent.otherFilesSize += leaf.size
            parent.otherFilesCount += 1
        }
        parent.directFileSize += leaf.size
        parent.directFileCount += 1
        adjust(from: parent, bytes: Int64(leaf.size), files: 1, dirs: 0)
    }

    /// Adds signed deltas to `start` and every ancestor.
    private func adjust(from start: DirNode, bytes: Int64, files: Int64, dirs: Int64) {
        func apply(_ value: inout UInt64, _ delta: Int64) {
            value = delta >= 0 ? value &+ UInt64(delta) : value - min(value, UInt64(-delta))
        }
        var cursor: DirNode? = start
        while let node = cursor {
            apply(&node.size, bytes)
            apply(&node.fileCount, files)
            apply(&node.dirCount, dirs)
            cursor = node.parent
        }
    }

    private func renumberDepths(_ start: DirNode) {
        start.depth = (start.parent?.depth ?? -1) + 1
        var stack = start.children
        while let node = stack.popLast() {
            node.depth = (node.parent?.depth ?? -1) + 1
            stack.append(contentsOf: node.children)
        }
    }
}
