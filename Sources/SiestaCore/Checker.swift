import Foundation
import Darwin

/// One pass: observe every watched profile, decide, stop what has been idle long enough, persist state.
/// Holds an exclusive file lock for the duration so two launchd runs can never overlap.
public struct Checker: Sendable {
    public struct Outcome: Sendable, Equatable {
        public var profile: String
        public var facts: Facts
        public var decision: Decision
        public var stopped: Bool
        public var error: String?
    }

    public let config: Config
    public let backend: VMBackend
    public let store: StateStore
    public let log: Logging
    public let lockFile: URL?
    public let dryRun: Bool
    /// Stop every profile that is idle right now instead of waiting out the idle interval. Busy profiles are still left alone.
    public let force: Bool

    public init(config: Config, backend: VMBackend, store: StateStore, log: Logging, lockFile: URL?, dryRun: Bool = false, force: Bool = false) {
        self.config = config; self.backend = backend; self.store = store; self.log = log; self.lockFile = lockFile
        self.dryRun = dryRun; self.force = force
    }

    private var policy: Policy {
        var effective = config
        if force { effective.idleMinutes = 0 }
        return Policy(config: effective)
    }

    public func run(now: Date = Date()) throws -> [Outcome] {
        let lock = try lockFile.map(FileLock.init(url:))
        if let lock, !lock.acquired {
            log.warn("another check is running; skipping")
            return []
        }
        var state = store.load()
        state.lastCheck = now
        defer { if !dryRun { try? store.save(state) } }   // a dry run observes and logs but leaves the clocks alone

        if let until = state.pausedUntil, state.isPaused(at: now) {
            log.info("paused until \(Format.timestamp(until)); nothing checked")
            return []
        }
        let watched = try watchedProfiles()
        if watched.isEmpty { log.info("no colima profiles to watch") }
        return watched.map { profile in
            var profileState = state.profiles[profile.name] ?? ProfileState()
            let outcome = check(profile, state: &profileState, now: now)
            state.profiles[profile.name] = profileState
            return outcome
        }
    }

    private func watchedProfiles() throws -> [ProfileInfo] {
        let all = try backend.profiles()
        return config.profiles.isEmpty ? all : all.filter { config.profiles.contains($0.name) }
    }

    private func check(_ profile: ProfileInfo, state: inout ProfileState, now: Date) -> Outcome {
        let tag = "[\(profile.name)]"
        if profile.running, state.adopt(bootSession: backend.bootSession(of: profile.name)) {
            log.info("\(tag) restarted since last check; idle clock reset")
        }
        let facts = backend.observe(profile, probes: config.probes)
        let (decision, idleSince) = policy.decide(facts: facts, idleSince: state.idleSince, now: now)
        state.idleSince = idleSince
        var outcome = Outcome(profile: profile.name, facts: facts, decision: decision, stopped: false, error: nil)

        switch decision {
        case .notRunning:
            break
        case .unknown:
            log.warn("\(tag) \(decision.summary); not touching it")
        case .busy, .idle:
            log.info("\(tag) \(decision.summary) (\(facts.counts))")
        case .stop(let idleFor):
            let reason = force ? "forced, idle now" : "after \(Format.minutes(idleFor)) idle min"
            if dryRun {
                log.info("\(tag) would stop (\(reason), dry run)")
            } else {
                log.info("\(tag) stopping (\(reason))")
                do {
                    try backend.stop(profile.name, timeout: config.stopTimeout)
                    state.recordStop(at: now)
                    outcome.stopped = true
                    log.info("\(tag) stopped")
                } catch {
                    outcome.error = "\(error)"
                    log.error("\(tag) \(error)")
                }
            }
        }
        state.lastObservation = Observation(at: now, facts: facts, verdict: decision.summary)
        return outcome
    }
}

/// An advisory, non-blocking file lock released when the value goes away.
final class FileLock {
    let acquired: Bool
    private let descriptor: Int32

    init(url: URL) throws {
        descriptor = open(url.path, O_CREAT | O_RDWR, 0o644)
        guard descriptor >= 0 else { throw SiestaError.message("cannot open lock file \(url.path)") }
        acquired = flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    deinit {
        if acquired { flock(descriptor, LOCK_UN) }
        close(descriptor)
    }
}
