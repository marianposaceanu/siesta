import Foundation

/// What one check observed and decided for one profile.
public struct Observation: Codable, Sendable, Equatable {
    public var at: Date
    public var running: Bool
    public var containers: Int
    public var dockerClients: Int
    public var sshSessions: Int
    public var guestLoad: Double?
    public var verdict: String
    public init(at: Date, running: Bool, containers: Int, dockerClients: Int, sshSessions: Int, guestLoad: Double?, verdict: String) {
        self.at = at; self.running = running; self.containers = containers; self.dockerClients = dockerClients
        self.sshSessions = sshSessions; self.guestLoad = guestLoad; self.verdict = verdict
    }
}

public struct ProfileState: Codable, Sendable, Equatable {
    /// First moment the profile was seen idle in the current idle streak.
    public var idleSince: Date?
    public var lastObservation: Observation?
    public var lastStop: Date?
    public var stops: Int = 0
    public init() {}
}

/// Persisted between runs. The binary is not resident, so this file is its only memory.
public struct State: Codable, Sendable, Equatable {
    public var profiles: [String: ProfileState] = [:]
    public var pausedUntil: Date?
    public var lastCheck: Date?
    public init() {}

    public static func load(from url: URL) -> State {
        guard let data = try? Data(contentsOf: url), let s = try? State.decoder.decode(State.self, from: data) else { return State() }
        return s
    }

    public func save(to url: URL) throws {
        try State.encoder.encode(self).write(to: url, options: .atomic)
    }

    public func isPaused(at now: Date) -> Bool {
        if let p = pausedUntil { return p > now }
        return false
    }

    private static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }
}
