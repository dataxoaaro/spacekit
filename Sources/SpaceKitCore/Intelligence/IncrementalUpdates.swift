import Foundation

/// Something a cleanup removed, as reported by `CleanupExecutor`.
public struct Removal: Sendable, Hashable {
    public var path: String
    public var kind: FindingItem.Kind
    public var bytes: UInt64
    /// Where the item went if it was moved to the Trash.
    public var trashedTo: String?

    public init(path: String, kind: FindingItem.Kind, bytes: UInt64, trashedTo: String? = nil) {
        self.path = path
        self.kind = kind
        self.bytes = bytes
        self.trashedTo = trashedTo
    }

    /// Successful removals in a report (including zero-byte ones, so the tree still drops them).
    public static func from(_ report: CleanupReport) -> [Removal] {
        report.items.compactMap { entry in
            entry.outcome.isRemoved
                ? Removal(path: entry.item.path, kind: entry.item.kind, bytes: entry.outcome.freedBytes, trashedTo: entry.outcome.trashedTo)
                : nil
        }
    }

    /// Applies this removal to a tree: trashed items move into the Trash folder (if the tree has it),
    /// deleted ones disappear. Returns true if the tree changed.
    @discardableResult
    public func apply(to tree: ScanTree) -> Bool {
        if kind == .looseFiles { return tree.applyRemoval(of: path, looseFilesOnly: true) > 0 }
        let before = tree.root.size
        let existed = tree.node(at: path) != nil || tree.node(at: PathUtil.parent(path)) != nil
        if let trashedTo {
            tree.applyMove(of: path, to: trashedTo, bytes: bytes)
        } else {
            tree.applyRemoval(of: path, bytes: bytes)
        }
        return existed && (tree.root.size != before || tree.node(at: path) == nil)
    }

    /// True if this removal took away everything at `path` (the item itself or a folder containing it).
    func covers(_ path: String) -> Bool {
        kind != .looseFiles && PathUtil.isAncestorOrEqual(self.path, of: path)
    }
}

extension Analysis {
    /// Updates findings after a cleanup without re-scanning: removed items disappear, items that lost
    /// something inside them shrink, and findings left empty are dropped.
    /// Returns the ids of the rules whose findings changed.
    @discardableResult
    public mutating func apply(_ removals: [Removal]) -> Set<String> {
        guard !removals.isEmpty else { return [] }
        var touched = Set<String>()
        var updated: [Finding] = []
        for finding in findings {
            var changed = false
            var items: [FindingItem] = []
            for var item in finding.items {
                if removals.contains(where: { removal in
                    removal.covers(item.path) || (removal.kind == .looseFiles && item.kind == .looseFiles && removal.path == item.path)
                }) {
                    changed = true
                    continue
                }
                // Something inside this item went away: shrink it.
                for removal in removals where item.kind != .file {
                    let inside =
                        removal.kind == .looseFiles
                        ? (item.kind == .directory && PathUtil.isAncestorOrEqual(item.path, of: removal.path))
                        : PathUtil.isStrictAncestor(item.path, of: removal.path)
                    if inside {
                        item.size -= min(item.size, removal.bytes)
                        changed = true
                    }
                }
                if item.size > 0 { items.append(item) } else { changed = true }
            }
            if changed { touched.insert(finding.rule.id) }
            if !items.isEmpty { updated.append(Finding(rule: finding.rule, items: items)) }
        }
        findings = updated.sorted { $0.size > $1.size }
        return touched
    }

    /// Replaces the findings of `ruleIDs` with fresh ones (from a targeted re-evaluation).
    public mutating func replaceFindings(for ruleIDs: Set<String>, with fresh: [Finding]) {
        findings.removeAll { ruleIDs.contains($0.rule.id) }
        findings += fresh.filter { ruleIDs.contains($0.rule.id) && !$0.items.isEmpty }
        findings.sort { $0.size > $1.size }
    }
}

extension CategoryBreakdown {
    /// The category `compute(tree:findings:)` would attribute `path` to.
    public static func category(for path: String, findings: [Finding], home: String = PathUtil.home) -> StorageCategory {
        var current = path
        while !current.isEmpty {
            for finding in findings where finding.items.contains(where: { $0.kind == .directory && $0.path == current }) {
                switch finding.rule.topCategory {
                case "developer": return .developer
                case "ai": return .ai
                case "cache": return .caches
                default: break
                }
            }
            if let category = builtinLocations(home: home).first(where: { $0.0 == current })?.1 { return category }
            if current == "/" { break }
            current = PathUtil.parent(current)
        }
        return .other
    }

    /// Subtracts removed bytes from the matching categories instead of recomputing the whole breakdown.
    public static func subtracting(
        _ removals: [Removal], from slices: [CategorySlice], findings: [Finding],
        home: String = PathUtil.home
    ) -> [CategorySlice] {
        var result = slices
        for removal in removals {
            let category = category(for: removal.path, findings: findings, home: home)
            if let index = result.firstIndex(where: { $0.category == category }) {
                result[index].size -= min(result[index].size, removal.bytes)
            }
        }
        return result.filter { $0.size > 0 }.sorted { $0.size > $1.size }
    }
}

extension AIReport {
    /// Replaces the models that came from `ruleIDs` with those in `partial` (built from a targeted re-scan),
    /// keeping every other tool's models as they were.
    public func replacingModels(from ruleIDs: Set<String>, with partial: AIReport) -> AIReport {
        var byTool: [String: [AIModel]] = [:]
        var order: [String] = []
        for tool in tools + partial.tools {
            if byTool[tool.name] == nil { order.append(tool.name) }
            byTool[tool.name, default: []] += []
        }
        for tool in tools { byTool[tool.name, default: []] += tool.models.filter { !ruleIDs.contains($0.ruleID) } }
        for tool in partial.tools { byTool[tool.name, default: []] += tool.models.filter { ruleIDs.contains($0.ruleID) } }
        let merged = order.compactMap { name -> AITool? in
            let models = (byTool[name] ?? []).sorted { $0.size > $1.size }
            return models.isEmpty ? nil : AITool(name: name, models: models)
        }
        return AIReport(tools: merged.sorted { $0.size > $1.size }, activeWindow: activeWindow)
    }
}
