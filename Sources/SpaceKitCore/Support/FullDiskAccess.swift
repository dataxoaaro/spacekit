import Foundation

/// Full Disk Access (TCC) status. Without it, macOS hides Mail, Messages, Safari, other apps' containers
/// and parts of Library from every process, so scans undercount and those folders show as "no access".
public enum FullDiskAccess {
    /// True if this process can read a file only readable with Full Disk Access.
    public static var isGranted: Bool {
        let probes = [
            "/Library/Application Support/com.apple.TCC/TCC.db",
            PathUtil.home + "/Library/Application Support/com.apple.TCC/TCC.db",
            PathUtil.home + "/Library/Safari/CloudTabs.db",
        ]
        for probe in probes where FileManager.default.fileExists(atPath: probe) {
            let fd = open(probe, O_RDONLY)
            if fd >= 0 {
                close(fd)
                return true
            }
            if errno == EPERM || errno == EACCES { return false }
        }
        return false
    }

    /// Opens System Settings at Privacy & Security → Full Disk Access.
    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
}
