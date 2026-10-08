import Foundation

extension RuleLibrary {
    /// `overrideProblems` as errors on the override, which then doesn't load.
    static func overrideIssues(builtin: Rule, override: Rule) -> [RuleIssue] {
        overrideProblems(builtin: builtin, override: override).map {
            RuleIssue(severity: .error, source: override.source ?? inlineSource, ruleID: override.id, message: $0)
        }
    }

    /// Why `override` may not take the place of the built-in rule with the same id; empty when it may.
    ///
    /// Jobs and the starter config name rules by id, and jobs from 🟢 rules run automatically. So a file in the user
    /// rules folder, which any program running as the person can write, would otherwise widen what an existing
    /// automatic job removes just by reusing an id. An override may only narrow the built-in rule: keep its paths
    /// within the built-in ones, add exclusions, raise its thresholds and ages, schedule its jobs less often, keep or
    /// raise its safety level, drop its action. Turning it into a `protected` rule only adds protection, so that is
    /// always allowed. Anything new has to be a rule of its own.
    static func overrideProblems(builtin: Rule, override: Rule) -> [String] {
        if builtin.safety.level == .protected {
            return ["can't replace the built-in protected rule with the same id; protected rules keep SpaceKit from touching that data"]
        }
        if override.safety.level < builtin.safety.level {
            return [
                "can't lower the safety level of the built-in rule from \(builtin.safety.level.rawValue) to "
                    + "\(override.safety.level.rawValue); add it to rules.disabled to turn it off instead"
            ]
        }
        if override.safety.level == .protected { return [] }

        let widened = locationProblems(builtin, override) + actionProblems(builtin, override) + policyProblems(builtin, override)
        guard !widened.isEmpty else { return [] }
        return widened.map {
            "can't widen the built-in rule: \($0). A rule with a built-in id may only narrow it (add exclusions, raise "
                + "thresholds and ages, raise the safety level); give a new rule its own id"
        }
    }

    private static func locationProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        var problems: [String] = []
        for path in override.paths where !builtin.paths.contains(where: { covers($0, path) }) {
            problems.append("adds the path '\(path)'")
        }
        switch (builtin.match, override.match) {
        case (nil, .some):
            problems.append("adds a name pattern (match)")
        case (.some(let original), .some(let pattern)):
            for name in pattern.names where !original.names.contains(name) { problems.append("adds the name '\(name)' to its pattern") }
            if pattern.sibling != original.sibling || pattern.contains != original.contains || pattern.roots != original.roots {
                problems.append("changes where its pattern matches (match sibling, contains or roots)")
            }
            for glob in original.exclude where !pattern.exclude.contains(glob) {
                problems.append("drops '\(glob)' from its pattern's exclude")
            }
        default:
            break
        }
        if override.granularity != builtin.granularity { problems.append("changes its granularity") }
        for exclusion in builtin.exclusions where !override.exclusions.contains(exclusion) {
            problems.append("drops the exclusion '\(exclusion)'")
        }
        return problems
    }

    private static func actionProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        var problems: [String] = []
        let action = override.action
        if action.remove && !builtin.action.remove { problems.append("adds remove to its action") }
        if let command = action.command, command != builtin.action.command { problems.append("changes its command") }
        if let command = action.itemCommand, command != builtin.action.itemCommand { problems.append("changes its itemCommand") }
        if let ai = override.ai {
            if ai.layout != builtin.ai?.layout || ai.tool != builtin.ai?.tool { problems.append("changes its ai layout") }
            if let command = ai.removeCommand, command != builtin.ai?.removeCommand { problems.append("changes its ai.removeCommand") }
        }
        if builtin.safety.trash && !override.safety.trash { problems.append("turns off the Trash (safety.trash)") }
        return problems
    }

    private static func policyProblems(_ builtin: Rule, _ override: Rule) -> [String] {
        let original = builtin.policy
        let policy = override.policy
        var problems = [
            lowered("threshold", from: original?.threshold, to: policy?.threshold),
            lowered("olderThan", from: original?.olderThan, to: policy?.olderThan),
            lowered("keepRecent", from: original?.keepRecent, to: policy?.keepRecent),
        ].compactMap { $0 }
        let job = Job.suggested(for: override)
        let originalJob = Job.suggested(for: builtin)
        if job.mode > originalJob.mode {
            problems.append("makes jobs from it start in \(job.mode.rawValue) mode instead of \(originalJob.mode.rawValue)")
        }
        if job.schedule.every < originalJob.schedule.every {
            problems.append("makes jobs from it run \(job.schedule.every.rawValue) instead of \(originalJob.schedule.every.rawValue)")
        }
        return problems
    }

    /// A limit the built-in rule's policy sets that the override lowers or leaves out (no limit is the lowest).
    private static func lowered<Limit: Comparable>(_ name: String, from original: Limit?, to limit: Limit?) -> String? {
        guard let original, limit.map({ $0 < original }) ?? true else { return nil }
        return "lowers its policy \(name) below \(original)"
    }

    /// True when every location `path` describes lies in one `builtin` describes. Both are compared where the engine
    /// looks for them (`enginePath`), and `path` may be the same location, one inside it, or a glob whose names are a
    /// subset: a built-in segment `X*` covers `X<more>*`.
    static func covers(_ builtin: String, _ path: String) -> Bool {
        let outer = PathUtil.components(enginePath(builtin))
        let inner = PathUtil.components(enginePath(path))
        guard inner.count >= outer.count else { return false }
        for (pattern, segment) in zip(outer, inner) {
            if pattern == "**" { return true }
            guard covers(segment: segment, pattern: pattern) else { return false }
        }
        return true
    }

    /// `path` as the engine looks for it: through `PathUtil.canonicalPattern`, the function `RuleEngine.canonical` runs
    /// every rule path through, then expanded as `PathUtil.glob` expands it, and case-folded as the guard compares paths.
    /// Comparing the text instead would let a symlinked folder inside a built-in path lead an override anywhere.
    private static func enginePath(_ path: String) -> String {
        PathUtil.comparisonKey(PathUtil.expand(PathUtil.canonicalPattern(path)))
    }

    /// True when every name `segment` matches, `pattern` matches too. `**` crosses folders and may match none, so a
    /// segment holding it is covered only by the same segment.
    private static func covers(segment: Substring, pattern: Substring) -> Bool {
        if segment == pattern { return true }
        if segment.contains("**") { return false }
        if !PathUtil.isGlob(String(segment)) { return fnmatch(String(pattern), String(segment), 0) == 0 }
        guard pattern.hasSuffix("*"), !pattern.hasSuffix("**") else { return false }
        let prefix = pattern.dropLast()
        return !PathUtil.isGlob(String(prefix)) && segment.hasPrefix(prefix)
    }
}
