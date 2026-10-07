import Foundation

/// The result of evaluating rules.
public struct Analysis: Sendable {
    public var findings: [Finding]
    public var tree: ScanTree
    public var date: Date

    public init(findings: [Finding], tree: ScanTree, date: Date = Date()) {
        self.findings = findings
        self.tree = tree
        self.date = date
    }

    public func findings(_ level: SafetyLevel) -> [Finding] { findings.filter { $0.safety == level } }

    public func total(_ level: SafetyLevel) -> UInt64 { findings(level).reduce(0) { $0 &+ $1.size } }

    /// Findings grouped by `rule.group` (Xcode, JavaScript, Ollama, …), largest group first.
    public var groups: [FindingGroup] {
        var order: [String] = []
        var byGroup: [String: [Finding]] = [:]
        for finding in findings {
            if byGroup[finding.rule.group] == nil { order.append(finding.rule.group) }
            byGroup[finding.rule.group, default: []].append(finding)
        }
        return order.map { FindingGroup(name: $0, findings: byGroup[$0]!.sorted { $0.size > $1.size }) }
            .sorted { $0.size > $1.size }
    }

    public func finding(ruleID: String) -> Finding? { findings.first { $0.rule.id == ruleID } }
}

public struct FindingGroup: Sendable, Identifiable {
    public var name: String
    public var findings: [Finding]
    public var id: String { name }
    public var size: UInt64 { findings.reduce(0) { $0 &+ $1.size } }
    public var category: String { findings.first?.rule.topCategory ?? "other" }
}

/// Runs the scans that rules need and evaluates them.
public struct StorageAnalyzer: Sendable {
    public var library: RuleLibrary
    public var scanOptions: ScanOptions
    public var devRoots: [String]

    public init(library: RuleLibrary, scanOptions: ScanOptions = ScanOptions(), devRoots: [String] = ["~"]) {
        self.library = library
        var options = scanOptions
        options.markers = library.markerRegistry
        self.scanOptions = options
        self.devRoots = devRoots
    }

    /// Evaluates `rules` (all rules by default). If `tree` already covers every location the rules need,
    /// no scanning happens; otherwise the needed locations are scanned in one parallel pass.
    public func analyze(
        rules: [Rule]? = nil,
        reusing tree: ScanTree? = nil,
        progress: ScanProgress = ScanProgress()
    ) async throws -> Analysis {
        let engine = RuleEngine(rules: rules ?? library.rules, devRoots: devRoots)
        let roots = engine.requiredRoots()
        let scanTree: ScanTree
        if let tree, roots.allSatisfy(tree.covers) {
            scanTree = tree
        } else if roots.isEmpty {
            scanTree = try await Scanner(options: scanOptions).scan(roots: [PathUtil.home], progress: progress)
            return Analysis(findings: [], tree: scanTree)
        } else {
            scanTree = try await Scanner(options: scanOptions).scan(roots: roots, progress: progress)
        }
        return Analysis(findings: engine.evaluate(scanTree), tree: scanTree)
    }

    /// Synchronous variant for command-line use.
    public func analyzeSync(rules: [Rule]? = nil, reusing existing: ScanTree? = nil, progress: ScanProgress = ScanProgress()) throws
        -> Analysis
    {
        let engine = RuleEngine(rules: rules ?? library.rules, devRoots: devRoots)
        let roots = engine.requiredRoots()
        if let existing, !roots.isEmpty, roots.allSatisfy(existing.covers) {
            return Analysis(findings: engine.evaluate(existing), tree: existing)
        }
        let tree = try Scanner(options: scanOptions).scan(roots: roots.isEmpty ? [PathUtil.home] : roots, progress: progress)
        return Analysis(findings: roots.isEmpty ? [] : engine.evaluate(tree), tree: tree)
    }
}
