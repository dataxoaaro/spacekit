import Foundation

extension RuleLibrary {
    /// Why `replacement` may not take the place of the built-in rule with the same id; empty when it may.
    ///
    /// Jobs and the starter config name rules by id, and jobs from 🟢 rules run automatically. So a file in the user
    /// rules folder, which any program running as the person can write, would otherwise widen what an existing
    /// automatic job removes just by reusing an id. A replacement may only narrow the built-in rule: add exclusions,
    /// raise its thresholds and ages, keep or raise its safety level, drop its action. Turning it into a
    /// `protected` rule only adds protection, so that is always allowed. Anything new has to be a rule of its own.
    static func overrideProblems(builtin: Rule, replacement: Rule) -> [String] {
        if builtin.safety.level == .protected {
            return ["can't replace the built-in protected rule with the same id; protected rules keep SpaceKit from touching that data"]
        }
        if replacement.safety.level < builtin.safety.level {
            return [
                "can't lower the safety level of the built-in rule from \(builtin.safety.level.rawValue) to "
                    + "\(replacement.safety.level.rawValue); add it to rules.disabled to turn it off instead"
            ]
        }
        if replacement.safety.level == .protected { return [] }

        let widened = locationProblems(builtin, replacement) + actionProblems(builtin, replacement) + policyProblems(builtin, replacement)
        guard !widened.isEmpty else { return [] }
        return widened.map {
            "can't widen the built-in rule: \($0). A rule with a built-in id may only narrow it (add exclusions, raise "
                + "thresholds and ages, raise the safety level); give a new rule its own id"
        }
    }

    private static func locationProblems(_ builtin: Rule, _ replacement: Rule) -> [String] {
        var problems: [String] = []
        for path in replacement.paths where !builtin.paths.contains(path) { problems.append("adds the path '\(path)'") }
        switch (builtin.match, replacement.match) {
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
        if replacement.granularity != builtin.granularity { problems.append("changes its granularity") }
        for exclusion in builtin.exclusions where !replacement.exclusions.contains(exclusion) {
            problems.append("drops the exclusion '\(exclusion)'")
        }
        return problems
    }

    private static func actionProblems(_ builtin: Rule, _ replacement: Rule) -> [String] {
        var problems: [String] = []
        let action = replacement.action
        if action.remove && !builtin.action.remove { problems.append("adds remove to its action") }
        if let command = action.command, command != builtin.action.command { problems.append("changes its command") }
        if let command = action.itemCommand, command != builtin.action.itemCommand { problems.append("changes its itemCommand") }
        if let ai = replacement.ai {
            if ai.layout != builtin.ai?.layout || ai.tool != builtin.ai?.tool { problems.append("changes its ai layout") }
            if let command = ai.removeCommand, command != builtin.ai?.removeCommand { problems.append("changes its ai.removeCommand") }
        }
        if builtin.safety.trash && !replacement.safety.trash { problems.append("turns off the Trash (safety.trash)") }
        return problems
    }

    private static func policyProblems(_ builtin: Rule, _ replacement: Rule) -> [String] {
        var problems: [String] = []
        let original = builtin.policy
        let policy = replacement.policy
        if let threshold = original?.threshold, (policy?.threshold).map({ $0 < threshold }) ?? true {
            problems.append("lowers its policy threshold below \(threshold)")
        }
        if let age = original?.olderThan, (policy?.olderThan).map({ $0 < age }) ?? true {
            problems.append("lowers its policy olderThan below \(age)")
        }
        if let age = original?.keepRecent, (policy?.keepRecent).map({ $0 < age }) ?? true {
            problems.append("lowers its policy keepRecent below \(age)")
        }
        let modes: [Job.Mode] = [.observe, .suggest, .automatic]
        let mode = Job.suggested(for: replacement).mode
        let originalMode = Job.suggested(for: builtin).mode
        if modes.firstIndex(of: mode) ?? 0 > modes.firstIndex(of: originalMode) ?? 0 {
            problems.append("makes jobs from it start in \(mode.rawValue) mode instead of \(originalMode.rawValue)")
        }
        return problems
    }
}
