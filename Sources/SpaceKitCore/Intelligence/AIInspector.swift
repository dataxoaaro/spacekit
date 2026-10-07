import Foundation

/// One model (or dataset, or cache) belonging to a local AI tool.
public struct AIModel: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable { case model, dataset, cache, orphaned }
    public var name: String
    public var kind: Kind
    public var size: UInt64
    public var lastUsed: Date?
    /// Files or folders that hold the model. For Ollama these are blobs that may be shared with other models.
    public var paths: [String]
    /// Preferred way to remove it, when the tool has one (e.g. `ollama rm llama3:8b`).
    public var removeCommand: [String]?
    public var ruleID: String
    /// The rule says this is regenerable (a true cache), not something you'd want back.
    public var isRegenerable: Bool = false
    public var id: String { ruleID + ":" + name }

    public func isActive(within window: Age, now: Date = Date()) -> Bool {
        guard let lastUsed else { return false }
        return now.timeIntervalSince(lastUsed) < window.seconds
    }
}

public struct AITool: Sendable, Identifiable {
    public var name: String
    public var models: [AIModel]
    public var id: String { name }
    public var size: UInt64 { models.reduce(0) { $0 &+ $1.size } }
}

/// The "AI Development" summary: how much local AI tooling uses, and how much of it is idle.
public struct AIReport: Sendable {
    public var tools: [AITool]
    public var activeWindow: Age

    public var total: UInt64 { tools.reduce(0) { $0 &+ $1.size } }
    private var models: [AIModel] { tools.flatMap(\.models) }

    /// Models used within the active window.
    public func active(now: Date = Date()) -> UInt64 {
        models.filter { $0.kind != .cache && $0.kind != .orphaned && $0.isActive(within: activeWindow, now: now) }
            .reduce(0) { $0 &+ $1.size }
    }

    /// Models not used within the active window.
    public func unused(now: Date = Date()) -> UInt64 {
        models.filter { ($0.kind == .model || $0.kind == .dataset) && !$0.isActive(within: activeWindow, now: now) }
            .reduce(0) { $0 &+ $1.size }
    }

    /// Regenerable caches, orphaned blobs and idle models: what could go without losing anything you're using.
    /// Caches that hold something you might want back (session transcripts, downloads) only count once idle.
    public func reclaimable(now: Date = Date()) -> UInt64 {
        models.filter { model in
            switch model.kind {
            case .orphaned: return true
            case .cache: return model.isRegenerable || !model.isActive(within: activeWindow, now: now)
            case .model, .dataset: return !model.isActive(within: activeWindow, now: now)
            }
        }
        .reduce(0) { $0 &+ $1.size }
    }
}

public enum AIInspector {
    /// Builds the AI report from findings of rules that carry an `ai:` block.
    public static func report(findings: [Finding], tree: ScanTree, activeWindow: Age = .days(90)) -> AIReport {
        var tools: [String: [AIModel]] = [:]
        var order: [String] = []
        for finding in findings {
            guard let ai = finding.rule.ai else { continue }
            if tools[ai.tool] == nil { order.append(ai.tool) }
            let models: [AIModel]
            switch ai.layout {
            case "ollama": models = ollamaModels(finding: finding)
            case "huggingface": models = huggingFaceModels(finding: finding, tree: tree)
            case "lmstudio": models = nestedModels(finding: finding, tree: tree, depth: 2)
            case "children": models = nestedModels(finding: finding, tree: tree, depth: 1)
            default:
                models = [
                    AIModel(
                        name: finding.rule.name, kind: .cache, size: finding.size, lastUsed: finding.lastUsed,
                        paths: finding.items.map(\.path), removeCommand: nil, ruleID: finding.rule.id)
                ]
            }
            let regenerable = finding.rule.safety.level == .safe
            tools[ai.tool, default: []] += models.map { model in
                var model = model
                model.isRegenerable = regenerable
                return model
            }
        }
        let result = order.map { AITool(name: $0, models: tools[$0]!.sorted { $0.size > $1.size }) }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
        return AIReport(tools: result, activeWindow: activeWindow)
    }

    // MARK: Ollama

    /// Reads Ollama's manifests (`models/manifests/<registry>/<namespace>/<model>/<tag>`) to size each model
    /// from the blobs it references. Blobs no manifest references are reported as orphaned.
    static func ollamaModels(finding: Finding) -> [AIModel] {
        var models: [AIModel] = []
        for root in finding.items.map(\.path) where root.hasSuffix("models") || FileManager.default.fileExists(atPath: root + "/manifests")
        {
            let manifests = root + "/manifests"
            let blobs = root + "/blobs"
            var referenced = Set<String>()
            guard let enumerator = FileManager.default.enumerator(atPath: manifests) else { continue }
            while let relative = enumerator.nextObject() as? String {
                let file = manifests + "/" + relative
                guard let data = FileManager.default.contents(atPath: file),
                    let manifest = try? JSONDecoder().decode(OllamaManifest.self, from: data)
                else { continue }
                let parts = relative.split(separator: "/").map(String.init)
                guard parts.count >= 3 else { continue }
                let tag = parts[parts.count - 1]
                let model = parts[parts.count - 2]
                let namespace = parts[parts.count - 3]
                let registry = parts.count >= 4 ? parts[parts.count - 4] : "registry.ollama.ai"
                var name = namespace == "library" ? model : "\(namespace)/\(model)"
                if registry != "registry.ollama.ai" { name = "\(registry)/\(name)" }
                name += ":" + tag

                var size: UInt64 = 0
                var paths: [String] = []
                var lastUsed: Date?
                for layer in manifest.layers + [manifest.config].compactMap({ $0 }) {
                    let blob = blobs + "/" + layer.digest.replacingOccurrences(of: ":", with: "-")
                    referenced.insert(blob)
                    size &+= UInt64(max(0, layer.size))
                    paths.append(blob)
                    if let accessed = accessDate(blob), accessed > (lastUsed ?? .distantPast) { lastUsed = accessed }
                }
                models.append(
                    AIModel(
                        name: name, kind: .model, size: size, lastUsed: lastUsed, paths: paths,
                        removeCommand: ["ollama", "rm", name], ruleID: finding.rule.id))
            }
            if let blobNames = try? FileManager.default.contentsOfDirectory(atPath: blobs) {
                var orphanSize: UInt64 = 0
                var orphanPaths: [String] = []
                for blob in blobNames.map({ blobs + "/" + $0 }) where !referenced.contains(blob) && !blob.hasSuffix("-partial") {
                    orphanSize &+= allocatedSize(blob)
                    orphanPaths.append(blob)
                }
                if orphanSize > 0 {
                    models.append(
                        AIModel(
                            name: "Unreferenced blobs", kind: .orphaned, size: orphanSize, lastUsed: nil,
                            paths: orphanPaths, removeCommand: nil, ruleID: finding.rule.id))
                }
            }
        }
        return models
    }

    private struct OllamaManifest: Decodable {
        struct Layer: Decodable {
            var digest: String
            var size: Int64
        }
        var layers: [Layer]
        var config: Layer?
    }

    // MARK: Hugging Face

    /// `hub/models--org--name` → `org/name`.
    static func huggingFaceModels(finding: Finding, tree: ScanTree) -> [AIModel] {
        var models: [AIModel] = []
        for item in finding.items {
            guard let node = tree.node(at: item.path) else { continue }
            let hub = node.child(named: "hub") ?? node
            var accounted: UInt64 = 0
            for child in hub.children where child.size > 0 {
                let parts = child.name.components(separatedBy: "--")
                guard parts.count >= 2, ["models", "datasets", "spaces"].contains(parts[0]) else { continue }
                let name = parts.dropFirst().joined(separator: "/")
                models.append(
                    AIModel(
                        name: name, kind: parts[0] == "datasets" ? .dataset : .model, size: child.size,
                        lastUsed: accessOrModified(child), paths: [child.path], removeCommand: nil, ruleID: finding.rule.id))
                accounted &+= child.size
            }
            if node.size > accounted {
                models.append(
                    AIModel(
                        name: "\(PathUtil.lastComponent(item.path)) cache", kind: .cache, size: node.size - accounted,
                        lastUsed: node.lastUsed, paths: [item.path], removeCommand: nil, ruleID: finding.rule.id))
            }
        }
        return models
    }

    // MARK: Folder-per-model layouts

    /// Each folder `depth` levels below the rule's path is a model (`publisher/model` for LM Studio).
    static func nestedModels(finding: Finding, tree: ScanTree, depth: Int) -> [AIModel] {
        var models: [AIModel] = []
        for item in finding.items {
            guard let node = tree.node(at: item.path) else {
                models.append(
                    AIModel(
                        name: item.name, kind: .model, size: item.size, lastUsed: item.lastUsed,
                        paths: [item.path], removeCommand: nil, ruleID: finding.rule.id))
                continue
            }
            var level: [(DirNode, String)] = [(node, "")]
            for _ in 0..<depth {
                level = level.flatMap { parent, prefix in
                    parent.children.filter { $0.size > 0 }.map { ($0, prefix.isEmpty ? $0.name : prefix + "/" + $0.name) }
                }
            }
            if level.isEmpty {
                models.append(
                    AIModel(
                        name: item.name, kind: .model, size: item.size, lastUsed: item.lastUsed,
                        paths: [item.path], removeCommand: nil, ruleID: finding.rule.id))
            }
            for (child, name) in level {
                models.append(
                    AIModel(
                        name: name, kind: .model, size: child.size, lastUsed: accessOrModified(child),
                        paths: [child.path], removeCommand: nil, ruleID: finding.rule.id))
            }
        }
        return models
    }

    // MARK: Helpers

    /// Model weights are read, not written, when used, so access time is the better signal.
    private static func accessOrModified(_ node: DirNode) -> Date? {
        let newest = max(node.subtreeNewestAccessed, node.subtreeNewestModified)
        return newest > 0 ? Date(timeIntervalSince1970: TimeInterval(newest)) : nil
    }

    private static func accessDate(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let newest = max(st.st_atimespec.tv_sec, st.st_mtimespec.tv_sec)
        return Date(timeIntervalSince1970: TimeInterval(newest))
    }

    private static func allocatedSize(_ path: String) -> UInt64 {
        var st = stat()
        guard lstat(path, &st) == 0 else { return 0 }
        return UInt64(max(0, st.st_blocks)) * 512
    }
}
