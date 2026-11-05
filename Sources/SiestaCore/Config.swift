import Foundation

/// User configuration. Missing file means defaults: every running profile, 60 idle minutes, a check every hour.
/// Idle time is measured between checks, so a profile stops after one to two hours of real idleness.
public struct Config: Codable, Sendable, Equatable {
    /// Colima profiles to watch. Empty means every profile `colima list` reports.
    public var profiles: [String] = []
    /// Minutes a profile must stay idle before it is stopped.
    public var idleMinutes: Int = 60
    /// Seconds between launchd runs of `siesta check`.
    public var checkIntervalSeconds: Int = 3600
    /// A profile with running containers is never idle.
    public var runningContainersMeanBusy: Bool = true
    /// Any process holding the docker or containerd socket open counts as a client.
    public var dockerClientsMeanBusy: Bool = true
    /// An interactive `colima ssh` session counts as busy.
    public var sshSessionsMeanBusy: Bool = true
    /// If set, the guest's 1-minute load average above this value counts as busy. Costs one ssh round trip per check.
    public var guestLoadThreshold: Double? = nil
    /// Seconds allowed for `colima stop` before it is abandoned.
    public var stopTimeoutSeconds: Int = 120
    /// Directories searched for colima and docker, in order. launchd agents get a minimal PATH, so this is explicit.
    public var binPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "/usr/bin", "/bin"]

    public init() {}

    public static func load(from url: URL) throws -> Config {
        guard FileManager.default.fileExists(atPath: url.path) else { return Config() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Config.self, from: data)
    }

    public func save(to url: URL) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    public var idleInterval: TimeInterval { TimeInterval(idleMinutes * 60) }
}
