import Foundation

/// The facts one check gathers about a profile. A nil count means that probe failed; a failed probe never reads as idle.
public struct Facts: Codable, Sendable, Equatable {
    public var running: Bool
    public var containers: Int?
    public var dockerClients: Int?
    public var sshSessions: Int?
    public var guestLoad: Double?

    public init(running: Bool, containers: Int? = 0, dockerClients: Int? = 0, sshSessions: Int? = 0, guestLoad: Double? = nil) {
        self.running = running; self.containers = containers; self.dockerClients = dockerClients
        self.sshSessions = sshSessions; self.guestLoad = guestLoad
    }

    public static let stopped = Facts(running: false, containers: nil, dockerClients: nil, sshSessions: nil)

    /// Short form for logs: "containers 0, clients 1, ssh ?".
    public var counts: String {
        func show(_ v: Int?) -> String { v.map(String.init) ?? "?" }
        return "containers \(show(containers)), clients \(show(dockerClients)), ssh \(show(sshSessions))"
    }
}

public enum Decision: Sendable, Equatable {
    case notRunning
    /// A probe the policy relies on gave no answer. Nothing is stopped and the idle clock is reset.
    case unknown(missing: [String])
    case busy(reasons: [String])
    case idle(since: Date, remaining: TimeInterval)
    case stop(idleFor: TimeInterval)

    public var summary: String {
        switch self {
        case .notRunning: "not running"
        case .unknown(let missing): "unknown: \(missing.joined(separator: ", ")) not answering"
        case .busy(let reasons): "busy: \(reasons.joined(separator: ", "))"
        case .idle(_, let remaining): "idle, \(Format.minutes(remaining, roundingUp: true)) min until stop"
        case .stop(let idleFor): "stopping after \(Format.minutes(idleFor)) idle min"
        }
    }
}

/// The pure decision: facts plus config plus the idle clock in, a decision plus the new clock out.
public struct Policy: Sendable {
    public let config: Config
    public init(config: Config) { self.config = config }

    public func decide(facts: Facts, idleSince: Date?, now: Date) -> (decision: Decision, idleSince: Date?) {
        guard facts.running else { return (.notRunning, nil) }
        let missing = missingProbes(in: facts)
        guard missing.isEmpty else { return (.unknown(missing: missing), nil) }
        let reasons = busyReasons(in: facts)
        guard reasons.isEmpty else { return (.busy(reasons: reasons), nil) }
        let since = idleSince ?? now
        let idleFor = now.timeIntervalSince(since)
        if idleFor >= config.idleInterval { return (.stop(idleFor: idleFor), since) }
        return (.idle(since: since, remaining: config.idleInterval - idleFor), since)
    }

    private func missingProbes(in facts: Facts) -> [String] {
        var missing: [String] = []
        if config.runningContainersMeanBusy, facts.containers == nil { missing.append("docker") }
        if config.dockerClientsMeanBusy, facts.dockerClients == nil { missing.append("lsof") }
        if config.sshSessionsMeanBusy, facts.sshSessions == nil { missing.append("ps") }
        if config.guestLoadThreshold != nil, facts.guestLoad == nil { missing.append("guest load") }
        return missing
    }

    private func busyReasons(in facts: Facts) -> [String] {
        var reasons: [String] = []
        if config.runningContainersMeanBusy, let n = facts.containers, n > 0 { reasons.append("\(n) container(s) running") }
        if config.dockerClientsMeanBusy, let n = facts.dockerClients, n > 0 { reasons.append("\(n) docker client(s)") }
        if config.sshSessionsMeanBusy, let n = facts.sshSessions, n > 0 { reasons.append("\(n) ssh session(s)") }
        if let limit = config.guestLoadThreshold, let load = facts.guestLoad, load > limit {
            reasons.append(String(format: "guest load %.2f", load))
        }
        return reasons
    }
}
