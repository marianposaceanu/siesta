import Foundation
import Darwin

/// One pass: observe every watched profile, decide, stop what has been idle long enough, persist state.
/// Holds an exclusive lock for the duration so two launchd runs can never overlap.
public struct Checker: Sendable {
    public let paths: Paths
    public let config: Config
    public let colima: Colima
    public let log: Log
    public var dryRun: Bool

    public init(paths: Paths, config: Config, colima: Colima, log: Log, dryRun: Bool = false) {
        self.paths = paths; self.config = config; self.colima = colima; self.log = log; self.dryRun = dryRun
    }

    public struct Outcome: Sendable {
        public var profile: String
        public var facts: Facts
        public var decision: Decision
        public var stopped: Bool
        public var error: String?
    }

    public func run(now: Date = Date()) throws -> [Outcome] {
        try paths.ensureDirectories()
        let fd = open(paths.lockFile.path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else { throw SiestaError.message("cannot open lock file \(paths.lockFile.path)") }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            log.warn("another check is running; skipping")
            return []
        }
        defer { flock(fd, LOCK_UN) }

        var state = State.load(from: paths.stateFile)
        state.lastCheck = now
        defer { try? state.save(to: paths.stateFile) }

        if state.isPaused(at: now) {
            log.info("paused until \(Log.stamp(state.pausedUntil!)); nothing checked")
            return []
        }

        let all = try colima.list()
        let watched = config.profiles.isEmpty ? all : all.filter { config.profiles.contains($0.name) }
        if watched.isEmpty { log.info("no colima profiles to watch") }

        var outcomes: [Outcome] = []
        for p in watched {
            var ps = state.profiles[p.name] ?? ProfileState()
            var facts = Facts(running: p.running)
            if p.running {
                facts.containers = colima.runningContainers(profile: p.name) ?? 0
                facts.dockerClients = config.dockerClientsMeanBusy ? colima.dockerClients(profile: p.name) : 0
                facts.sshSessions = config.sshSessionsMeanBusy ? colima.sshSessions(profile: p.name) : 0
                if config.guestLoadThreshold != nil { facts.guestLoad = colima.guestLoad(profile: p.name) }
            }
            let (decision, idleSince) = Policy.decide(facts: facts, config: config, idleSince: ps.idleSince, now: now)
            ps.idleSince = idleSince
            var stopped = false
            var err: String?
            switch decision {
            case .stop(let idleFor):
                if dryRun {
                    log.info("[\(p.name)] would stop (idle \(Int(idleFor / 60)) min) — dry run")
                } else {
                    log.info("[\(p.name)] stopping after \(Int(idleFor / 60)) idle min")
                    let r = colima.stop(profile: p.name, timeout: TimeInterval(config.stopTimeoutSeconds))
                    if r.ok {
                        stopped = true
                        ps.lastStop = now; ps.stops += 1; ps.idleSince = nil
                        log.info("[\(p.name)] stopped")
                    } else {
                        err = SiestaError.command("colima stop", r).description
                        log.error("[\(p.name)] \(err!)")
                    }
                }
            case .notRunning:
                break
            default:
                log.info("[\(p.name)] \(decision.summary) (containers \(facts.containers), clients \(facts.dockerClients), ssh \(facts.sshSessions))")
            }
            ps.lastObservation = Observation(at: now, running: facts.running, containers: facts.containers,
                                             dockerClients: facts.dockerClients, sshSessions: facts.sshSessions,
                                             guestLoad: facts.guestLoad, verdict: decision.summary)
            state.profiles[p.name] = ps
            outcomes.append(Outcome(profile: p.name, facts: facts, decision: decision, stopped: stopped, error: err))
        }
        return outcomes
    }
}
