import Foundation

/// The facts one check gathers about a profile. Pure data so the decision is testable without Colima.
public struct Facts: Sendable, Equatable {
    public var running: Bool
    public var containers: Int
    public var dockerClients: Int
    public var sshSessions: Int
    public var guestLoad: Double?
    public init(running: Bool, containers: Int = 0, dockerClients: Int = 0, sshSessions: Int = 0, guestLoad: Double? = nil) {
        self.running = running; self.containers = containers; self.dockerClients = dockerClients
        self.sshSessions = sshSessions; self.guestLoad = guestLoad
    }
}

public enum Decision: Sendable, Equatable {
    case notRunning
    case busy(reasons: [String])
    case idle(since: Date, remaining: TimeInterval)
    case stop(idleFor: TimeInterval)

    public var summary: String {
        switch self {
        case .notRunning: return "not running"
        case .busy(let r): return "busy: " + r.joined(separator: ", ")
        case .idle(_, let remaining): return "idle, \(Int(remaining / 60) + (remaining.truncatingRemainder(dividingBy: 60) > 0 ? 1 : 0)) min until stop"
        case .stop(let idleFor): return "stopping after \(Int(idleFor / 60)) idle min"
        }
    }
}

public enum Policy {
    /// Decide what to do with a profile, and return the updated idle-since marker.
    public static func decide(facts: Facts, config: Config, idleSince: Date?, now: Date) -> (Decision, idleSince: Date?) {
        guard facts.running else { return (.notRunning, nil) }
        var reasons: [String] = []
        if config.runningContainersMeanBusy, facts.containers > 0 { reasons.append("\(facts.containers) container(s) running") }
        if config.dockerClientsMeanBusy, facts.dockerClients > 0 { reasons.append("\(facts.dockerClients) docker client(s)") }
        if config.sshSessionsMeanBusy, facts.sshSessions > 0 { reasons.append("\(facts.sshSessions) ssh session(s)") }
        if let t = config.guestLoadThreshold, let l = facts.guestLoad, l > t { reasons.append(String(format: "guest load %.2f", l)) }
        if !reasons.isEmpty { return (.busy(reasons: reasons), nil) }
        let since = idleSince ?? now
        let idleFor = now.timeIntervalSince(since)
        if idleFor >= config.idleInterval { return (.stop(idleFor: idleFor), since) }
        return (.idle(since: since, remaining: config.idleInterval - idleFor), since)
    }
}
