import Foundation

/// User configuration. A missing file means the defaults: every profile, sixty idle minutes, a check every hour.
/// Idle time is only sampled at checks, so a profile stops after one to two hours of real idleness.
public struct Config: Codable, Sendable, Equatable {
    /// Colima profiles to watch. Empty means every profile `colima list` reports.
    public var profiles: [String] = []
    /// Minutes a profile must stay idle before it is stopped.
    public var idleMinutes: Int = 60
    /// Seconds between launchd runs of `siesta check`.
    public var checkIntervalSeconds: Int = 3600
    /// A profile with running containers is never idle.
    public var runningContainersMeanBusy = true
    /// Any process other than Lima's own holding the docker or containerd socket counts as a client.
    public var dockerClientsMeanBusy = true
    /// An interactive `colima ssh` session counts as busy.
    public var sshSessionsMeanBusy = true
    /// When set, a guest 1-minute load average above this counts as busy. Costs one ssh round trip per check.
    public var guestLoadThreshold: Double? = nil
    /// Seconds allowed for `colima stop` before it is abandoned.
    public var stopTimeoutSeconds: Int = 120
    /// Directories searched for colima and docker. launchd agents get almost no PATH, so this is explicit.
    public var binPaths: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin", "/usr/bin", "/bin"]

    public init() {}

    public static func load(from url: URL) throws -> Config { try JSONFile.load(Config.self, from: url) ?? Config() }
    public func save(to url: URL) throws { try JSONFile.save(self, to: url) }

    public var idleInterval: TimeInterval { TimeInterval(idleMinutes * 60) }
    public var stopTimeout: TimeInterval { TimeInterval(stopTimeoutSeconds) }

    /// Which probes a check runs, derived from the switches above.
    public var probes: ProbeOptions {
        ProbeOptions(containers: runningContainersMeanBusy, dockerClients: dockerClientsMeanBusy,
                     sshSessions: sshSessionsMeanBusy, guestLoad: guestLoadThreshold != nil)
    }
}

public struct ProbeOptions: Sendable, Equatable {
    public var containers: Bool
    public var dockerClients: Bool
    public var sshSessions: Bool
    public var guestLoad: Bool
    public init(containers: Bool = true, dockerClients: Bool = true, sshSessions: Bool = true, guestLoad: Bool = false) {
        self.containers = containers; self.dockerClients = dockerClients; self.sshSessions = sshSessions; self.guestLoad = guestLoad
    }
}
