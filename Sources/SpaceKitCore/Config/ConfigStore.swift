import Foundation
import Yams

public enum ConfigError: Error, LocalizedError {
    case invalid(file: String, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalid(let file, let message): return "\(PathUtil.abbreviate(file)): \(message)"
        }
    }
}

/// Reads and writes the YAML config.
public struct ConfigStore: Sendable {
    public let file: String

    public init(file: String) { self.file = file }

    public var exists: Bool { FileManager.default.fileExists(atPath: file) }

    /// Loads the config. A missing file yields the defaults.
    public func load() throws -> SpaceKitConfig {
        guard exists else { return SpaceKitConfig() }
        let text = try String(contentsOfFile: file, encoding: .utf8)
        do {
            return try ConfigStore.parse(text)
        } catch {
            throw ConfigError.invalid(file: file, message: RuleLibrary.describe(error))
        }
    }

    public static func parse(_ yaml: String) throws -> SpaceKitConfig {
        let trimmed = yaml.trimmingCharacters(in: .whitespacesAndNewlines)
        // A file of only comments decodes as null; treat it as defaults.
        if trimmed.isEmpty || trimmed.split(separator: "\n").allSatisfy({ $0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }) {
            return SpaceKitConfig()
        }
        let config = try YAMLDecoder().decode(SpaceKitConfig.self, from: yaml)
        try validate(config)
        return config
    }

    /// Semantic checks beyond YAML syntax.
    public static func validate(_ config: SpaceKitConfig) throws {
        var ids = Set<String>()
        for job in config.jobs {
            guard ids.insert(job.id).inserted else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Duplicate job id '\(job.id)'"))
            }
            if job.rules.isEmpty && job.paths.isEmpty {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Job '\(job.id)' needs `rules` or `paths`"))
            }
        }
    }

    /// Saves the config, keeping the previous file as `config.yaml.bak`.
    public func save(_ config: SpaceKitConfig) throws {
        try ConfigStore.validate(config)
        let body = try YAMLEncoder().encode(config)
        let text = ConfigStore.savedHeader + body
        try FileManager.default.createDirectory(atPath: PathUtil.parent(file), withIntermediateDirectories: true)
        if exists {
            let backup = file + ".bak"
            try? FileManager.default.removeItem(atPath: backup)
            try? FileManager.default.copyItem(atPath: file, toPath: backup)
        }
        try LockedFile.write(Data(text.utf8), to: file)
    }

    /// Writes the commented starter config if no config exists.
    @discardableResult
    public func initialize(force: Bool = false) throws -> Bool {
        guard force || !exists else { return false }
        try FileManager.default.createDirectory(atPath: PathUtil.parent(file), withIntermediateDirectories: true)
        try LockedFile.write(Data(ConfigStore.template.utf8), to: file)
        return true
    }

    static let savedHeader = """
        # SpaceKit configuration — see docs/CONFIGURATION.md
        # This file was last written by SpaceKit. Your previous version is in config.yaml.bak.

        """

    /// The documented starter configuration written by `spacekit config init`.
    public static let template = """
        # SpaceKit configuration
        # Docs: docs/CONFIGURATION.md · Validate with: spacekit config validate
        #
        # Every key is optional. Sizes accept 500MB / 30GB / 1.5TB; ages accept 14d / 2w / 3mo / 1y.
        version: 1

        scan:
          defaultPath: /            # what Explore scans (/ = the whole startup disk, hidden folders included)
          minFileSize: 1MB          # smaller files are summarised per folder (keeps big scans fast and light)
          boundary: container       # device | container | unrestricted
          devRoots: [~]             # where to look for node_modules, target/, __pycache__, …
          exclude: []               # paths or globs never scanned, e.g. ~/VirtualMachines

        safety:
          trash: always             # always = move to Trash; rules = regenerable caches may be deleted directly
          maxBytesPerRun: 100GB     # an automatic run never removes more than this
          protectedPaths: []        # your own never-touch list, e.g. [~/Work/client-archive]
          allowedCommands: []       # extra tools rule commands may run (built-ins: brew, docker, xcrun, npm, …)

        rules:
          disabled: []              # rule ids to ignore, e.g. [node.node-modules]
          directories: [~/.config/spacekit/rules]   # your own rule files (same format as the built-in library)

        automation:
          notifications: true
          checkEvery: 1h            # how often the background agent looks for due jobs
          snapshot: sunday 04:00    # full storage snapshot for History ("what grew?"); or: never
          activeModelWindow: 90d    # AI models used within this window count as active

        # Jobs: observe = notify me · suggest = prepare a cleanup and ask · automatic = clean (safe items only)
        jobs:
          - id: xcode-derived-data
            name: Xcode DerivedData
            rules: [xcode.derived-data]
            mode: automatic
            schedule: sunday 03:00
            when:
              sizeAbove: 30GB
              keepRecent: 14d       # keep projects used within 14 days

          - id: stale-node-modules
            name: node_modules
            rules: [node.node-modules]
            mode: suggest
            schedule: weekly
            when:
              olderThan: 60d        # projects untouched for 60 days

          - id: package-caches
            name: npm / pnpm / Homebrew caches
            rules: [node.npm-cache, node.pnpm-store, homebrew.cache]
            mode: suggest
            schedule: monthly

        ui:
          visualization: sunburst   # sunburst | treemap
          colorBy: branch           # branch | category | safety | age
          mapDepth: 4

        """
}

/// Everything a front end needs, wired up from the config. CLI, TUI, app and agent all start here.
public struct SpaceKitContext: Sendable {
    public var paths: SpaceKitPaths
    public var config: SpaceKitConfig
    public var library: RuleLibrary
    /// Set when the config file exists but couldn't be read; defaults are used instead.
    public var configError: String?

    public init(paths: SpaceKitPaths, config: SpaceKitConfig, library: RuleLibrary, configError: String? = nil) {
        self.paths = paths
        self.config = config
        self.library = library
        self.configError = configError
    }

    public static func load(paths: SpaceKitPaths = .standard) -> SpaceKitContext {
        var configError: String?
        let config: SpaceKitConfig
        do {
            config = try ConfigStore(file: paths.configFile).load()
        } catch {
            configError = error.localizedDescription
            config = SpaceKitConfig()
        }
        var directories = config.rules.directories
        if !directories.contains(where: { PathUtil.expand($0) == paths.userRulesDirectory }) {
            directories.append(paths.userRulesDirectory)
        }
        let library = RuleLibrary.load(directories: directories, disabled: Set(config.rules.disabled))
        return SpaceKitContext(paths: paths, config: config, library: library, configError: configError)
    }

    public var configStore: ConfigStore { ConfigStore(file: paths.configFile) }
    public var journal: Journal { Journal(file: paths.journalFile) }
    public var history: HistoryStore { HistoryStore(file: paths.historyFile) }
    public var jobStates: JobStateStore { JobStateStore(file: paths.jobStateFile) }
    public var suggestions: SuggestionStore { SuggestionStore(file: paths.suggestionsFile) }

    public var scanOptions: ScanOptions { config.scan.options(markers: library.markerRegistry) }

    public var analyzer: StorageAnalyzer {
        StorageAnalyzer(library: library, scanOptions: scanOptions, devRoots: config.scan.devRoots)
    }

    public var safetyGuard: SafetyGuard {
        SafetyGuard(userProtectedPaths: config.safety.protectedPaths, protectedRules: library.rules)
    }

    public var executor: CleanupExecutor {
        CleanupExecutor(
            safety: safetyGuard, journal: journal, rules: library.rules,
            extraAllowedCommands: Set(config.safety.allowedCommands),
            maxBytesPerAutomaticRun: config.safety.maxBytesPerRun.bytes)
    }

    /// `true` to force the Trash, `nil` to follow rules.
    public func trashPreference(for action: Job.Action = .trash) -> Bool? {
        if config.safety.trash == .always { return true }
        switch action {
        case .trash: return true
        case .delete: return false
        case .rule: return nil
        }
    }

    public var notifier: Notifier? { config.automation.notifications ? AppleScriptNotifier() : nil }
}
