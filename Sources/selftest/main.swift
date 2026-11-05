// Checks for the parts of siesta that do not need Colima: policy, state, config, formatting, the launchd plist,
// the subprocess runner, and the checker end to end against a fake backend.
// Runs with `swift run selftest` on a bare Command Line Tools install, which has neither XCTest nor swift-testing.
import Foundation
import SiestaCore

@MainActor final class Suite {
    private(set) var failures = 0
    func check(_ name: String, _ condition: Bool, line: Int = #line) {
        if condition { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name)  (line \(line))") }
    }
}

/// A scripted VM backend: fixed profiles, canned facts per profile, a boot marker, and a record of stops.
final class FakeBackend: VMBackend, @unchecked Sendable {
    var known: [ProfileInfo] = [ProfileInfo(name: "pr-qa", running: true, memoryBytes: 6 << 30, cpus: 2)]
    var facts = Facts(running: true)
    var boot = "boot-1"
    var stopped: [String] = []
    var failStop = false
    func profiles() throws -> [ProfileInfo] { known }
    func observe(_ profile: ProfileInfo, probes: ProbeOptions) -> Facts { profile.running ? facts : .stopped }
    func bootSession(of profile: String) -> String? { boot }
    func stop(_ profile: String, timeout: TimeInterval) throws {
        if failStop { throw SiestaError.message("colima stop refused") }
        stopped.append(profile)
        known = known.map { ProfileInfo(name: $0.name, running: false) }
    }
}

final class MemoryStateStore: StateStore, @unchecked Sendable {
    var state = State()
    var saves = 0
    func load() -> State { state }
    func save(_ state: State) throws { self.state = state; saves += 1 }
}

let suite = Suite()
let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var cfg = Config(); cfg.idleMinutes = 60
let policy = Policy(config: cfg)
func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

// Policy
suite.check("not running clears the clock", policy.decide(facts: Facts(running: false), idleSince: t0, now: t0) == (.notRunning, nil))
suite.check("busy lists reasons and resets the clock",
            policy.decide(facts: Facts(running: true, containers: 2, dockerClients: 1), idleSince: t0, now: t0)
            == (.busy(reasons: ["2 container(s) running", "1 docker client(s)"]), nil))
suite.check("first idle observation starts the clock",
            policy.decide(facts: Facts(running: true), idleSince: nil, now: t0) == (.idle(since: t0, remaining: 3600), t0))
suite.check("stops at the threshold", policy.decide(facts: Facts(running: true), idleSince: t0, now: at(60)) == (.stop(idleFor: 3600), t0))
suite.check("one second under waits", policy.decide(facts: Facts(running: true), idleSince: t0, now: at(60).addingTimeInterval(-1)).decision == .idle(since: t0, remaining: 1))
suite.check("failed probe is unknown, never idle, and resets the clock",
            policy.decide(facts: Facts(running: true, containers: nil), idleSince: t0, now: at(120)) == (.unknown(missing: ["docker"]), nil))
suite.check("unknown names every missing probe",
            policy.decide(facts: Facts(running: true, containers: nil, dockerClients: nil, sshSessions: nil), idleSince: nil, now: t0).decision
            == .unknown(missing: ["docker", "lsof", "ps"]))
do {
    var relaxed = cfg; relaxed.runningContainersMeanBusy = false
    suite.check("a disabled probe is neither required nor counted",
                Policy(config: relaxed).decide(facts: Facts(running: true, containers: nil), idleSince: nil, now: t0).decision == .idle(since: t0, remaining: 3600))
    var loaded = cfg; loaded.guestLoadThreshold = 0.5
    suite.check("guest load ignored unless configured", policy.decide(facts: Facts(running: true, guestLoad: 1.5), idleSince: nil, now: t0).decision == .idle(since: t0, remaining: 3600))
    suite.check("guest load counts when configured", Policy(config: loaded).decide(facts: Facts(running: true, guestLoad: 1.5), idleSince: nil, now: t0).decision == .busy(reasons: ["guest load 1.50"]))
    suite.check("probe options follow the config", loaded.probes == ProbeOptions(containers: true, dockerClients: true, sshSessions: true, guestLoad: true))
}
suite.check("summaries read well", [Decision.notRunning, .unknown(missing: ["docker"]), .busy(reasons: ["a", "b"]), .idle(since: t0, remaining: 90), .stop(idleFor: 3700)].map(\.summary)
            == ["not running", "unknown: docker not answering", "busy: a, b", "idle, 2 min until stop", "stopping after 61 idle min"])
suite.check("facts print counts with ? for failed probes", Facts(running: true, containers: 0, dockerClients: nil, sshSessions: 2).counts == "containers 0, clients ?, ssh 2")

// Checker against the fake backend
do {
    let backend = FakeBackend(), store = MemoryStateStore(), log = MemoryLogger()
    let checker = Checker(config: cfg, backend: backend, store: store, log: log, lockFile: nil)
    var outcomes = try checker.run(now: t0)
    suite.check("first idle check arms the clock, stops nothing", outcomes.map(\.decision) == [.idle(since: t0, remaining: 3600)] && backend.stopped.isEmpty)
    suite.check("state is persisted with the clock and boot marker", store.state.profiles["pr-qa"]?.idleSince == t0 && store.state.profiles["pr-qa"]?.bootSession == "boot-1")
    outcomes = try checker.run(now: at(30))
    suite.check("half way: still idle, still nothing stopped", outcomes.first?.decision == .idle(since: t0, remaining: 1800) && backend.stopped.isEmpty)
    backend.facts = Facts(running: true, dockerClients: 1)
    outcomes = try checker.run(now: at(45))
    suite.check("a client resets the clock", outcomes.first?.decision == .busy(reasons: ["1 docker client(s)"]) && store.state.profiles["pr-qa"]?.idleSince == nil)
    backend.facts = Facts(running: true)
    _ = try checker.run(now: at(50))
    outcomes = try checker.run(now: at(110))
    suite.check("idle for an hour since the reset: stopped",
                outcomes.first?.decision == .stop(idleFor: 3600) && outcomes.first?.stopped == true && backend.stopped == ["pr-qa"])
    suite.check("stop is recorded and the clock cleared", store.state.profiles["pr-qa"]?.stops == 1 && store.state.profiles["pr-qa"]?.lastStop == at(110) && store.state.profiles["pr-qa"]?.idleSince == nil)
    outcomes = try checker.run(now: at(120))
    suite.check("a stopped profile is reported not running", outcomes.first?.decision == .notRunning)
    suite.check("log carries the story", log.lines.contains("INFO [pr-qa] stopping (after 60 idle min)") && log.lines.contains("INFO [pr-qa] stopped"))
}
do {
    let backend = FakeBackend(), store = MemoryStateStore()
    let checker = Checker(config: cfg, backend: backend, store: store, log: MemoryLogger(), lockFile: nil)
    _ = try checker.run(now: t0)
    backend.boot = "boot-2"   // the user stopped and started Colima between checks
    let outcomes = try checker.run(now: at(90))
    suite.check("a restarted VM gets a fresh clock instead of an immediate stop",
                outcomes.first?.decision == .idle(since: at(90), remaining: 3600) && backend.stopped.isEmpty && store.state.profiles["pr-qa"]?.bootSession == "boot-2")
}
do {
    let backend = FakeBackend(), store = MemoryStateStore(), log = MemoryLogger()
    _ = try Checker(config: cfg, backend: backend, store: store, log: log, lockFile: nil).run(now: t0)
    backend.facts = Facts(running: true, containers: nil)
    let outcomes = try Checker(config: cfg, backend: backend, store: store, log: log, lockFile: nil).run(now: at(120))
    suite.check("a failed probe after a long idle does not stop the VM",
                outcomes.first?.decision == .unknown(missing: ["docker"]) && backend.stopped.isEmpty && store.state.profiles["pr-qa"]?.idleSince == nil)
    suite.check("the warning is logged", log.lines.contains("WARN [pr-qa] unknown: docker not answering; not touching it"))
}
do {
    let backend = FakeBackend(), store = MemoryStateStore()
    let dry = Checker(config: cfg, backend: backend, store: store, log: MemoryLogger(), lockFile: nil, dryRun: true)
    _ = try dry.run(now: t0)
    suite.check("a dry run saves nothing", store.saves == 0 && store.state == State())
    store.state.profiles["pr-qa"] = { var p = ProfileState(); p.idleSince = t0; p.bootSession = "boot-1"; return p }()
    let outcomes = try dry.run(now: at(60))
    suite.check("a dry run reports a would-be stop without stopping", outcomes.first?.decision == .stop(idleFor: 3600) && outcomes.first?.stopped == false && backend.stopped.isEmpty)
}
do {
    let backend = FakeBackend(), store = MemoryStateStore()
    backend.failStop = true
    store.state.profiles["pr-qa"] = { var p = ProfileState(); p.idleSince = t0; p.bootSession = "boot-1"; return p }()
    let outcomes = try Checker(config: cfg, backend: backend, store: store, log: MemoryLogger(), lockFile: nil).run(now: at(60))
    suite.check("a refused stop is reported and the clock kept", outcomes.first?.error == "colima stop refused" && store.state.profiles["pr-qa"]?.idleSince == t0)
}
do {
    let backend = FakeBackend(), store = MemoryStateStore()
    let forced = Checker(config: cfg, backend: backend, store: store, log: MemoryLogger(), lockFile: nil, force: true)
    let outcomes = try forced.run(now: t0)
    suite.check("force stops a profile that is idle right now", outcomes.first?.stopped == true && backend.stopped == ["pr-qa"])
    let busyBackend = FakeBackend(); busyBackend.facts = Facts(running: true, containers: 1)
    let left = try Checker(config: cfg, backend: busyBackend, store: MemoryStateStore(), log: MemoryLogger(), lockFile: nil, force: true).run(now: t0)
    suite.check("force never stops a busy profile", left.first?.decision == .busy(reasons: ["1 container(s) running"]) && busyBackend.stopped.isEmpty)
    let dryBackend = FakeBackend()
    let dry = try Checker(config: cfg, backend: dryBackend, store: MemoryStateStore(), log: MemoryLogger(), lockFile: nil, dryRun: true, force: true).run(now: t0)
    suite.check("force with dry run reports and stops nothing", dry.first?.stopped == false && dryBackend.stopped.isEmpty)
}
do {
    let store = MemoryStateStore()
    store.state.pausedUntil = at(120)
    let outcomes = try Checker(config: cfg, backend: FakeBackend(), store: store, log: MemoryLogger(), lockFile: nil).run(now: at(60))
    suite.check("paused means no profile is examined", outcomes.isEmpty)
    var only = cfg; only.profiles = ["other"]
    suite.check("profiles filter applies", try Checker(config: only, backend: FakeBackend(), store: MemoryStateStore(), log: MemoryLogger(), lockFile: nil).run(now: t0).isEmpty)
}

// State and config files
do {
    var state = State(); var p = ProfileState(); p.idleSince = t0; p.stops = 2; state.profiles["pr-qa"] = p; state.pausedUntil = t0
    let url = FileManager.default.temporaryDirectory.appending(path: "siesta-selftest-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = FileStateStore(url: url)
    try store.save(state)
    suite.check("state round-trips through the file store", store.load() == state)
    suite.check("missing state file gives defaults", FileStateStore(url: URL(fileURLWithPath: "/nonexistent/x.json")).load() == State())
    suite.check("paused only before pausedUntil", state.isPaused(at: t0.addingTimeInterval(-1)) && !state.isPaused(at: t0))
    state.resetIdleClocks()
    suite.check("resetIdleClocks clears every profile", state.profiles["pr-qa"]?.idleSince == nil && state.profiles["pr-qa"]?.stops == 2)
    var fresh = ProfileState(); fresh.idleSince = t0
    suite.check("adopting a new boot session clears the clock and says so", fresh.adopt(bootSession: "b") && fresh.idleSince == nil && !fresh.adopt(bootSession: "b"))
}
do {
    suite.check("missing config gives defaults", try Config.load(from: URL(fileURLWithPath: "/nonexistent/siesta.json")) == Config())
    suite.check("defaults are hourly checks and sixty idle minutes", Config().checkIntervalSeconds == 3600 && Config().idleMinutes == 60)
    let url = FileManager.default.temporaryDirectory.appending(path: "siesta-cfg-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: url) }
    var written = Config(); written.profiles = ["pr-qa"]; written.guestLoadThreshold = 0.7
    try written.save(to: url)
    let loaded = try Config.load(from: url)
    suite.check("config round-trips through JSON", loaded == written)
    suite.check("config file keeps slashes readable", String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("/opt/homebrew/bin"))
}

// Formatting
suite.check("bytes", Format.bytes(6 << 30) == "6.0 GiB")
suite.check("minutes round down by default and up on request", Format.minutes(119) == 1 && Format.minutes(61, roundingUp: true) == 2)
suite.check("ago", Format.ago(at(-0.5), now: t0) == "30 s ago" && Format.ago(at(-30), now: t0) == "30 min ago" && Format.ago(at(-150), now: t0) == "2 h 30 min ago" && Format.ago(nil, now: t0) == "never")
suite.check("duration parsing", Format.duration("2h") == 7200 && Format.duration("45m") == 2700 && Format.duration("x") == nil && Format.duration("5d") == nil)

// Paths and the launchd plist
do {
    let home = URL(fileURLWithPath: "/Users/test")
    let paths = Paths(home: home)
    suite.check("lima instance names", paths.limaInstance(profile: "pr-qa") == "colima-pr-qa" && paths.limaInstance(profile: "default") == "colima")
    suite.check("socket and ha.pid paths", paths.dockerSocket(profile: "pr-qa").path == "/Users/test/.colima/pr-qa/docker.sock"
                && paths.haPid(profile: "pr-qa").path == "/Users/test/.colima/_lima/colima-pr-qa/ha.pid")
    var config = Config(); config.checkIntervalSeconds = 3600
    let shell = Shell(binPaths: config.binPaths, home: home)
    let plist = LaunchAgent(paths: paths, runner: shell, binPaths: shell.binPaths).plist(config: config)
    suite.check("plist label and program", plist["Label"] as? String == "com.marianposaceanu.siesta" && plist["ProgramArguments"] as? [String] == ["/Users/test/.local/bin/siesta", "check"])
    suite.check("plist interval, background type, run at load, low priority io",
                plist["StartInterval"] as? Int == 3600 && plist["ProcessType"] as? String == "Background" && plist["RunAtLoad"] as? Bool == true && plist["LowPriorityIO"] as? Bool == true)
    suite.check("plist explicit PATH with ~ expanded", (plist["EnvironmentVariables"] as? [String: String])?["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/Users/test/.local/bin:/usr/bin:/bin")
    suite.check("plist logs under ~/Library/Logs", plist["StandardOutPath"] as? String == "/Users/test/Library/Logs/siesta/launchd.log")
    suite.check("plist serialises", (try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)) != nil)
}

// Shell
do {
    let shell = Shell(binPaths: ["/bin", "/usr/bin"], home: FileManager.default.homeDirectoryForCurrentUser)
    suite.check("shell runs a command", shell.run("echo", ["hi"]).stdout == "hi\n")
    suite.check("shell enforces the timeout", shell.run("sleep", ["5"], timeout: 0.3).timedOut)
    let killed = shell.run("sh", ["-c", "kill -TERM $$"])
    suite.check("a child killed by a signal is not a timeout", !killed.timedOut && killed.status != 0)
    suite.check("shell reports a missing tool", shell.run("no-such-tool-xyz", []).status == 127)
    suite.check("which finds absolute and searched paths", shell.which("/bin/ls") == "/bin/ls" && shell.which("ls") == "/bin/ls" && shell.which("nope-xyz") == nil)
}

print(suite.failures == 0 ? "all checks passed" : "\(suite.failures) check(s) failed")
exit(suite.failures == 0 ? 0 : 1)
