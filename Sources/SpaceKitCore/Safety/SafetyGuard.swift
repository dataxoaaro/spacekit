import Foundation

/// Who is asking to remove something, and under what terms.
public enum CleanupContext: Sendable {
    /// A person picked this in the app, the TUI or the CLI. `confirmed` means they acknowledged a warning.
    case manual(confirmed: Bool)
    /// A scheduled job is running unattended.
    case automatic(AutomationContext)

    public var isAutomatic: Bool {
        if case .automatic = self { return true }
        return false
    }
}

public struct AutomationContext: Sendable {
    public var jobID: String
    /// The job explicitly opted in to cleaning 🟡 review items.
    public var allowReview: Bool
    /// Folders the user explicitly listed in the job (rather than rules).
    public var customPaths: [String]
    public var olderThan: Age?
    public var usesTrash: Bool

    public init(jobID: String, allowReview: Bool = false, customPaths: [String] = [], olderThan: Age? = nil, usesTrash: Bool = true) {
        self.jobID = jobID
        self.allowReview = allowReview
        self.customPaths = customPaths
        self.olderThan = olderThan
        self.usesTrash = usesTrash
    }
}

public struct SafetyVerdict: Sendable, Equatable {
    public enum Decision: Int, Sendable, Comparable {
        case allow, confirm, block
        public static func < (lhs: Decision, rhs: Decision) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var decision: Decision
    public var reasons: [String]

    public static let allow = SafetyVerdict(decision: .allow, reasons: [])

    public var isBlocked: Bool { decision == .block }

    /// True if the operation may go ahead given whether the person confirmed.
    public func permits(confirmed: Bool) -> Bool {
        decision == .allow || (decision == .confirm && confirmed)
    }

    mutating func raise(_ decision: Decision, _ reason: String) {
        if decision > self.decision { self.decision = decision }
        if !reasons.contains(reason) { reasons.append(reason) }
    }
}

/// The single gate every removal passes through, in every front end.
///
/// The built-in protections below are not configurable. The config can only *add* protected paths.
/// See `docs/SAFETY.md` for the reasoning behind each rule.
public struct SafetyGuard: Sendable {
    public let home: String
    public let userProtectedPaths: [String]
    public let protectedRules: [Rule]
    public let volumes: VolumeTable
    public let isRunningAsRoot: Bool

    /// An automatic job may not remove a single item bigger than this share of the volume's used space.
    public static let maxAutomaticVolumeShare = 0.25
    /// A manual removal bigger than this share of used space needs confirmation.
    public static let confirmVolumeShare = 0.10

    public init(
        home: String = PathUtil.home, userProtectedPaths: [String] = [], protectedRules: [Rule] = [],
        volumes: VolumeTable = .current(), isRunningAsRoot: Bool = geteuid() == 0
    ) {
        self.home = home
        self.userProtectedPaths = userProtectedPaths.map { PathUtil.expand($0, home: home) }
        self.protectedRules = protectedRules.filter { $0.safety.level == .protected }
        self.volumes = volumes
        self.isRunningAsRoot = isRunningAsRoot
    }

    // MARK: Built-in lists

    /// Never removed, and nothing that *contains* them is ever removed either. This is what makes
    /// "delete the whole disk", "delete my home folder" or "delete /Users" impossible.
    public var criticalPaths: [String] {
        let h = home
        return [
            "/", "/System", "/System/Volumes", "/System/Volumes/Data", "/System/Volumes/Preboot", "/System/Volumes/VM",
            "/System/Volumes/Update", "/usr", "/bin", "/sbin", "/etc", "/var", "/tmp", "/private", "/private/etc",
            "/private/var", "/private/var/db", "/private/tmp", "/Library", "/Applications", "/Users", "/Volumes", "/opt", "/cores", "/dev",
            "/Library/Keychains", "/Library/Developer",
            h, "\(h)/Library", "\(h)/Library/Keychains", "\(h)/Library/Application Support", "\(h)/Library/Containers",
            "\(h)/Library/Group Containers", "\(h)/Library/Preferences", "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage",
            "\(h)/Library/Mail", "\(h)/Library/Messages", "\(h)/Library/Caches", "\(h)/Library/Developer",
            "\(h)/Library/Application Support/AddressBook", "\(h)/Library/Calendars", "\(h)/Library/Photos",
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music", "\(h)/Public",
            "\(h)/Applications", "\(h)/Developer",
            "\(h)/.ssh", "\(h)/.gnupg", "\(h)/.aws", "\(h)/.kube", "\(h)/.config", "\(h)/.docker", "\(h)/.cache", "\(h)/.local",
            "\(h)/.Trash",
            "\(h)/Library/Containers/com.docker.docker/Data/vms",
        ]
    }

    /// Nothing inside these is ever removed: the OS, credentials, and app databases that break when edited.
    public var sealedTrees: [String] {
        let h = home
        return [
            "/System", "/usr/bin", "/usr/sbin", "/usr/lib", "/usr/libexec", "/usr/share", "/bin", "/sbin", "/private/etc",
            "/private/var/db", "/Library/Keychains", "/System/Volumes/Preboot", "/System/Volumes/VM", "/System/Volumes/Update",
            "\(h)/Library/Keychains", "\(h)/.ssh", "\(h)/.gnupg", "\(h)/.aws", "\(h)/.kube", "\(h)/.config/gcloud", "\(h)/.config/gh",
            "\(h)/Library/Mail", "\(h)/Library/Messages", "\(h)/Library/Application Support/AddressBook", "\(h)/Library/Calendars",
            "\(h)/Library/Containers/com.docker.docker/Data/vms", "\(h)/Library/Group Containers/group.com.docker",
            "\(h)/Library/Application Support/1Password", "\(h)/Library/Group Containers/2BUA8C4S2C.com.1password",
        ]
    }

    /// Personal areas. A person may remove things inside them after confirming; automation only under strict terms.
    public var personalAreas: [String] {
        let h = home
        return [
            "\(h)/Documents", "\(h)/Desktop", "\(h)/Downloads", "\(h)/Pictures", "\(h)/Movies", "\(h)/Music",
            "\(h)/Library/Mobile Documents", "\(h)/Library/CloudStorage", "\(h)/Library/Containers", "\(h)/Library/Group Containers",
            "\(h)/Library/Application Support/MobileSync", "\(h)/Public",
        ]
    }

    /// Name suffixes of package folders whose insides must never be edited piecemeal.
    static let sealedBundleSuffixes = [
        ".photoslibrary", ".photolibrary", ".musiclibrary", ".tvlibrary", ".aplibrary", ".keychain-db", ".keychain",
    ]

    // MARK: Evaluation

    /// Decides whether `path` may be removed.
    ///
    /// - Parameters:
    ///   - size: bytes the removal would free, if known (enables the volume-share checks).
    ///   - rule: the rule that produced the item, if any.
    ///   - isRepository/containsRepository: git working copies at or below `path`, if known from a scan.
    public func evaluate(
        path rawPath: String,
        size: UInt64? = nil,
        rule: Rule? = nil,
        context: CleanupContext,
        isRepository: Bool = false,
        containsRepository: Bool = false
    ) -> SafetyVerdict {
        var verdict = SafetyVerdict.allow

        guard rawPath.hasPrefix("/") || rawPath.hasPrefix("~") else {
            return SafetyVerdict(decision: .block, reasons: ["Path must be absolute"])
        }
        let path = PathUtil.expand(rawPath, home: home)
        // Resolve symlinks in the parent so a link can't smuggle a protected folder in under another name.
        // The final component is not resolved: removing a symlink removes the link, not its target.
        let resolved = PathUtil.resolveParent(path)
        let candidates = Array(Set([path, resolved]))

        if isRunningAsRoot {
            verdict.raise(.block, "SpaceKit never removes files while running as root (sudo)")
        }

        for candidate in candidates {
            checkHardLimits(candidate, into: &verdict)
        }
        if verdict.isBlocked { return verdict }

        if let rule, rule.safety.level == .protected {
            verdict.raise(.block, "\(rule.name) is marked “Don't touch”")
        }
        if isRepository {
            verdict.raise(context.isAutomatic ? .block : .confirm, "This folder is a git repository (source code)")
        } else if containsRepository && (rule == nil || rule!.safety.level != .safe) {
            verdict.raise(context.isAutomatic ? .block : .confirm, "This folder contains git repositories")
        }

        let personal = candidates.contains { candidate in personalAreas.contains { PathUtil.isStrictAncestor($0, of: candidate) } }

        if let size, let capacity = VolumeCapacity.of(path: PathUtil.parent(path)), capacity.used > 0 {
            let share = Double(size) / Double(capacity.used)
            if context.isAutomatic && share > SafetyGuard.maxAutomaticVolumeShare {
                verdict.raise(.block, "Automatic cleanup won't remove a single item holding \(Int(share * 100))% of the disk's used space")
            } else if share > SafetyGuard.confirmVolumeShare {
                verdict.raise(.confirm, "This holds \(Int(share * 100))% of the disk's used space")
            }
        }

        switch context {
        case .manual:
            if let rule {
                if rule.safety.level == .review {
                    verdict.raise(.confirm, "\(rule.name) is marked “Review”: it can be removed but may be slow or costly to get back")
                }
            } else if personal {
                verdict.raise(.confirm, "This is personal data, not a cache")
            } else {
                verdict.raise(.confirm, "No SpaceKit rule recognises this; make sure you don't need it")
            }
        case .automatic(let automation):
            let isCustom = automation.customPaths.contains { PathUtil.isAncestorOrEqual(PathUtil.expand($0, home: home), of: path) }
            if let rule {
                if rule.safety.level == .review && !automation.allowReview {
                    verdict.raise(.block, "\(rule.name) needs review; enable “Include review items” on the job to automate it")
                }
                if !isInsideRuleScope(path, rule: rule) {
                    verdict.raise(.block, "Path is outside the locations rule \(rule.id) covers")
                }
            } else if !isCustom {
                verdict.raise(.block, "Automatic jobs only remove what a rule matched or a folder listed in the job")
            }
            // Rules carry curated knowledge about what's inside personal areas (Mail downloads, app caches in
            // containers); folders a person typed into a job don't, so those get the strict treatment.
            if personal && rule == nil {
                let ageOK = (automation.olderThan?.days ?? 0) >= 7
                if !(isCustom && ageOK && automation.usesTrash) {
                    verdict.raise(
                        .block,
                        "Automatic cleanup inside personal folders requires a folder listed in the job, “older than” of at least 7 days, and moving to Trash"
                    )
                }
            }
        }
        return verdict
    }

    /// Checks that can never be overridden.
    private func checkHardLimits(_ path: String, into verdict: inout SafetyVerdict) {
        let parts = PathUtil.components(path)
        if parts.count < 2 {
            verdict.raise(.block, "Top-level folders and volume roots can't be removed")
        }
        // /Volumes/<name> is where volumes mount; block it even when nothing is mounted right now.
        if (parts.count == 2 && parts[0] == "Volumes") || (parts.count == 3 && parts[0] == "System" && parts[1] == "Volumes") {
            verdict.raise(.block, "Volume roots can't be removed")
        }
        if let critical = criticalPaths.first(where: { PathUtil.isAncestorOrEqual(path, of: $0) }) {
            verdict.raise(
                .block,
                critical == path
                    ? "\(PathUtil.abbreviate(path, home: home)) is a protected system or home location"
                    : "Removing this would also remove \(PathUtil.abbreviate(critical, home: home)), which is protected")
        }
        if let sealed = sealedTrees.first(where: { PathUtil.isStrictAncestor($0, of: path) }) {
            verdict.raise(.block, "Nothing inside \(PathUtil.abbreviate(sealed, home: home)) is ever removed")
        }
        if volumes.isMountPoint(path)
            || volumes.volumes.contains(where: { PathUtil.isStrictAncestor(path, of: $0.mountPoint) && $0.mountPoint != "/" })
        {
            verdict.raise(.block, "This is (or contains) a mounted volume")
        }
        for protected in userProtectedPaths
        where PathUtil.isAncestorOrEqual(protected, of: path) || PathUtil.isAncestorOrEqual(path, of: protected) {
            verdict.raise(.block, "Protected in your configuration: \(PathUtil.abbreviate(protected, home: home))")
        }
        let components = PathUtil.components(path)
        if components.contains(where: { $0 == ".git" }) {
            verdict.raise(.block, "Git metadata is never removed")
        }
        if components.dropLast().contains(where: { component in SafetyGuard.sealedBundleSuffixes.contains { component.hasSuffix($0) } }) {
            verdict.raise(.block, "Files inside libraries such as Photos are managed by their app")
        }
        for rule in protectedRules {
            for pattern in rule.paths {
                let base = PathUtil.expand(pattern, home: home)
                let matches =
                    base.contains("*")
                    ? PathUtil.matches(path, glob: base) || PathUtil.matches(path, glob: base + "/**")
                    : PathUtil.isAncestorOrEqual(base, of: path) || PathUtil.isAncestorOrEqual(path, of: base)
                if matches { verdict.raise(.block, "Protected by rule “\(rule.name)”") }
            }
            if let names = rule.match?.names, components.contains(where: { names.contains(String($0)) }) {
                verdict.raise(.block, "Protected by rule “\(rule.name)”")
            }
        }
    }

    /// True if `path` is one of the places `rule` describes (or inside one).
    public func isInsideRuleScope(_ path: String, rule: Rule) -> Bool {
        for pattern in rule.paths {
            let base = PathUtil.expand(pattern, home: home)
            if base.contains("*") {
                if PathUtil.matches(path, glob: base) || PathUtil.matches(path, glob: base + "/**") { return true }
            } else if PathUtil.isAncestorOrEqual(base, of: path) {
                return true
            }
        }
        if let names = rule.match?.names, names.contains(PathUtil.lastComponent(path)) { return true }
        return false
    }
}
