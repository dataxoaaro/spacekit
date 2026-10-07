import Foundation

/// Installs the background agent as a per-user launchd job that runs `spacekit agent run` periodically.
/// Nothing runs as root and nothing is installed system-wide.
public struct LaunchAgent: Sendable {
    public static let label = "dev.spacekit.agent"

    public let paths: SpaceKitPaths

    public init(paths: SpaceKitPaths) { self.paths = paths }

    public var plistPath: String { PathUtil.home + "/Library/LaunchAgents/\(LaunchAgent.label).plist" }

    public struct Status: Sendable {
        public var installed: Bool
        public var loaded: Bool
        public var executable: String?
        public var interval: Int?
    }

    public func status() -> Status {
        let plist = NSDictionary(contentsOfFile: plistPath)
        let arguments = plist?["ProgramArguments"] as? [String]
        let result = Shell.run("/bin/launchctl", ["print", "gui/\(getuid())/\(LaunchAgent.label)"], timeout: 10)
        return Status(
            installed: plist != nil, loaded: result.status == 0, executable: arguments?.first,
            interval: plist?["StartInterval"] as? Int)
    }

    public func plist(executable: String, interval: Int) -> [String: Any] {
        var environment = ["SPACEKIT_AGENT": "1"]
        let env = ProcessInfo.processInfo.environment
        if let config = env["SPACEKIT_CONFIG"] { environment["SPACEKIT_CONFIG"] = config }
        if let state = env["SPACEKIT_STATE_DIR"] { environment["SPACEKIT_STATE_DIR"] = state }
        return [
            "Label": LaunchAgent.label,
            "ProgramArguments": [executable, "agent", "run"],
            "StartInterval": interval,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "LowPriorityIO": true,
            "Nice": 10,
            "StandardOutPath": paths.logDirectory + "/agent.log",
            "StandardErrorPath": paths.logDirectory + "/agent.log",
            "EnvironmentVariables": environment,
        ]
    }

    /// Writes the plist and (re)loads it.
    public func install(executable: String, interval: TimeInterval) throws {
        try paths.ensureDirectories()
        try FileManager.default.createDirectory(atPath: PathUtil.parent(plistPath), withIntermediateDirectories: true)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist(executable: executable, interval: max(300, Int(interval))), format: .xml, options: 0)
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(LaunchAgent.label)"], timeout: 10)
        try data.write(to: URL(fileURLWithPath: plistPath), options: .atomic)
        let result = Shell.run("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistPath], timeout: 10)
        if result.status != 0 {
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(result.output)"])
        }
    }

    public func uninstall() throws {
        _ = Shell.run("/bin/launchctl", ["bootout", "gui/\(getuid())/\(LaunchAgent.label)"], timeout: 10)
        if FileManager.default.fileExists(atPath: plistPath) {
            try FileManager.default.removeItem(atPath: plistPath)
        }
    }

    /// Asks launchd to run the agent now.
    public func kickstart() {
        _ = Shell.run("/bin/launchctl", ["kickstart", "gui/\(getuid())/\(LaunchAgent.label)"], timeout: 10)
    }
}
