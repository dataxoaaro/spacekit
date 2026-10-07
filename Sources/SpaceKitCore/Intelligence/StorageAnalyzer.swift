import Foundation

/// The result of evaluating rules.
public struct Analysis: Sendable {
    public var findings: [Finding]
    public var tree: ScanTree

    public init(findings: [Finding], tree: ScanTree) {
        self.findings = findings
        self.tree = tree
    }

    public func findings(_ level: SafetyLevel) -> [Finding] { findings.filter { $0.safety == level } }

    public func total(_ level: SafetyLevel) -> UInt64 { findings(level).reduce(0) { $0 &+ $1.size } }

    /// Findings grouped by `rule.group` (Xcode, JavaScript, Ollama, …), largest group first.
    public var groups: [FindingGroup] {
        Dictionary(grouping: findings, by: \.rule.group)
            .map { FindingGroup(name: $0.key, findings: $0.value.sorted { $0.size > $1.size }) }
            .sorted { $0.size != $1.size ? $0.size > $1.size : $0.name < $1.name }
    }

    public func finding(ruleID: String) -> Finding? { findings.first { $0.rule.id == ruleID } }
}

public struct FindingGroup: Sendable, Identifiable {
    public var name: String
    public var findings: [Finding]
    public var id: String { name }
    public var size: UInt64 { findings.reduce(0) { $0 &+ $1.size } }
}

/// Runs the scans that rules need and evaluates them.
public struct StorageAnalyzer: Sendable {
    public var library: RuleLibrary
    public var scanOptions: ScanOptions
    public var devRoots: [String]

    public init(library: RuleLibrary, scanOptions: ScanOptions = ScanOptions(), devRoots: [String] = ["~"]) {
        self.library = library
        var options = scanOptions
        // Pattern rules read these marker bits, so the scan must record exactly this library's markers.
        options.markers = library.markerRegistry
        self.scanOptions = options
        self.devRoots = devRoots
    }

    /// Evaluates `rules` (all rules by default). If `tree` already covers every location the rules need,
    /// no scanning happens; otherwise the needed locations are scanned in one parallel pass. With nothing
    /// to look at, the home folder is scanned and there are no findings.
    public func analyze(
        rules: [Rule]? = nil,
        reusing tree: ScanTree? = nil,
        progress: ScanProgress = ScanProgress()
    ) async throws -> Analysis {
        let (engine, roots) = prepare(rules)
        if let tree, roots.allSatisfy(tree.covers) { return evaluate(engine, roots: roots, on: tree) }
        let scanned = try await Scanner(options: scanOptions).scan(roots: roots.isEmpty ? [PathUtil.home] : roots, progress: progress)
        return evaluate(engine, roots: roots, on: scanned)
    }

    /// Synchronous variant of `analyze` for command-line use.
    public func analyzeSync(rules: [Rule]? = nil, reusing tree: ScanTree? = nil, progress: ScanProgress = ScanProgress()) throws
        -> Analysis
    {
        let (engine, roots) = prepare(rules)
        if let tree, roots.allSatisfy(tree.covers) { return evaluate(engine, roots: roots, on: tree) }
        let scanned = try Scanner(options: scanOptions).scan(roots: roots.isEmpty ? [PathUtil.home] : roots, progress: progress)
        return evaluate(engine, roots: roots, on: scanned)
    }

    private func prepare(_ rules: [Rule]?) -> (RuleEngine, [String]) {
        let engine = RuleEngine(rules: rules ?? library.rules, devRoots: devRoots)
        return (engine, engine.requiredRoots())
    }

    private func evaluate(_ engine: RuleEngine, roots: [String], on tree: ScanTree) -> Analysis {
        Analysis(findings: roots.isEmpty ? [] : engine.evaluate(tree), tree: tree)
    }
}
