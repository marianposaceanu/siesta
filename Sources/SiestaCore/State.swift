import Foundation

/// What one check observed and decided for one profile.
public struct Observation: Codable, Sendable, Equatable {
    public var at: Date
    public var facts: Facts
    public var verdict: String
    public init(at: Date, facts: Facts, verdict: String) { self.at = at; self.facts = facts; self.verdict = verdict }
}

public struct ProfileState: Codable, Sendable, Equatable {
    /// First moment the profile was seen idle in the current idle streak.
    public var idleSince: Date?
    /// Boot-session marker of the VM the idle clock belongs to.
    public var bootSession: String?
    public var lastObservation: Observation?
    public var lastStop: Date?
    public var stops = 0
    public init() {}

    /// A stop-and-start between two checks must not inherit the old clock.
    public mutating func adopt(bootSession session: String?) -> Bool {
        guard session != bootSession else { return false }
        let hadClock = idleSince != nil
        idleSince = nil
        bootSession = session
        return hadClock
    }

    public mutating func recordStop(at date: Date) {
        lastStop = date
        stops += 1
        idleSince = nil
    }
}

/// Persisted between runs. The binary is not resident, so this file is its only memory.
public struct State: Codable, Sendable, Equatable {
    public var profiles: [String: ProfileState] = [:]
    public var pausedUntil: Date?
    public var lastCheck: Date?
    public init() {}

    public func isPaused(at now: Date) -> Bool { pausedUntil.map { $0 > now } ?? false }

    public mutating func resetIdleClocks() {
        for key in profiles.keys { profiles[key]?.idleSince = nil }
    }
}

/// Where state is kept. The file store is the real one; the selftest uses an in-memory one.
public protocol StateStore: Sendable {
    func load() -> State
    func save(_ state: State) throws
}

public struct FileStateStore: StateStore {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() -> State { (try? JSONFile.load(State.self, from: url)) ?? State() }
    public func save(_ state: State) throws { try JSONFile.save(state, to: url) }
}
