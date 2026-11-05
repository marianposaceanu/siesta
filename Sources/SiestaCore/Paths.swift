import Foundation

/// Every file siesta reads or writes, following macOS conventions: config under ~/.config so it can live in a
/// dotfiles repo, state under Application Support, logs under ~/Library/Logs, the launchd plist under
/// ~/Library/LaunchAgents, the binary under ~/.local/bin.
public struct Paths: Sendable {
    public static let label = "com.marianposaceanu.siesta"
    public static let name = "siesta"

    public let home: URL

    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home }

    public var configFile: URL { home.appending(path: ".config/siesta/config.json") }
    public var stateDir: URL { home.appending(path: "Library/Application Support/siesta") }
    public var stateFile: URL { stateDir.appending(path: "state.json") }
    public var lockFile: URL { stateDir.appending(path: "check.lock") }
    public var logDir: URL { home.appending(path: "Library/Logs/siesta") }
    public var logFile: URL { logDir.appending(path: "siesta.log") }
    public var launchdLog: URL { logDir.appending(path: "launchd.log") }
    public var agentPlist: URL { home.appending(path: "Library/LaunchAgents/\(Paths.label).plist") }
    public var installedBinary: URL { home.appending(path: ".local/bin/siesta") }

    private var colimaDir: URL { home.appending(path: ".colima") }

    /// Lima names the instance "colima-<profile>", except the default profile, which is plain "colima".
    public func limaInstance(profile: String) -> String { profile == "default" ? "colima" : "colima-\(profile)" }
    public func dockerSocket(profile: String) -> URL { colimaDir.appending(path: "\(profile)/docker.sock") }
    public func containerdSocket(profile: String) -> URL { colimaDir.appending(path: "\(profile)/containerd.sock") }
    /// Rewritten by Lima on every start of the instance, which makes it a boot-session marker.
    public func haPid(profile: String) -> URL { colimaDir.appending(path: "_lima/\(limaInstance(profile: profile))/ha.pid") }

    public func ensureDirectories() throws {
        for dir in [configFile.deletingLastPathComponent(), stateDir, logDir, agentPlist.deletingLastPathComponent()] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }
}
