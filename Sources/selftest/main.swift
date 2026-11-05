// Self-contained checks for the pure parts of siesta: policy, state, config, plist.
// Runs with `swift run selftest` on a bare Command Line Tools install, which has neither XCTest nor swift-testing.
import Foundation
import SiestaCore

var failures = 0
@MainActor func check(_ name: String, _ cond: @autoclosure () -> Bool, file: String = #fileID, line: Int = #line) {
    if cond() { print("ok    \(name)") } else { failures += 1; print("FAIL  \(name)  (\(file):\(line))") }
}

let t0 = Date(timeIntervalSince1970: 1_800_000_000)
var cfg = Config(); cfg.idleMinutes = 60

// Policy
do {
    let (d, since) = Policy.decide(facts: Facts(running: false), config: cfg, idleSince: t0, now: t0)
    check("not running clears idle", d == .notRunning && since == nil)
}
do {
    let f = Facts(running: true, containers: 2, dockerClients: 1, sshSessions: 0)
    let (d, since) = Policy.decide(facts: f, config: cfg, idleSince: t0, now: t0)
    check("busy lists reasons and resets clock", d == .busy(reasons: ["2 container(s) running", "1 docker client(s)"]) && since == nil)
}
do {
    let (d, since) = Policy.decide(facts: Facts(running: true), config: cfg, idleSince: nil, now: t0)
    check("first idle observation starts the clock", since == t0 && d == .idle(since: t0, remaining: 3600))
}
do {
    let (d, since) = Policy.decide(facts: Facts(running: true), config: cfg, idleSince: t0, now: t0.addingTimeInterval(3600))
    check("stops at the threshold", d == .stop(idleFor: 3600) && since == t0)
}
do {
    let (d, _) = Policy.decide(facts: Facts(running: true), config: cfg, idleSince: t0, now: t0.addingTimeInterval(3599))
    check("one second under waits", d == .idle(since: t0, remaining: 1))
}
do {
    var c = cfg
    let f = Facts(running: true, guestLoad: 1.5)
    check("guest load ignored unless configured", Policy.decide(facts: f, config: c, idleSince: nil, now: t0).0 == .idle(since: t0, remaining: 3600))
    c.guestLoadThreshold = 0.5
    check("guest load counts when configured", Policy.decide(facts: f, config: c, idleSince: nil, now: t0).0 == .busy(reasons: ["guest load 1.50"]))
}
do {
    var c = cfg; c.runningContainersMeanBusy = false
    check("containers ignored when disabled", Policy.decide(facts: Facts(running: true, containers: 3), config: c, idleSince: nil, now: t0).0 == .idle(since: t0, remaining: 3600))
}
check("summary: not running", Decision.notRunning.summary == "not running")
check("summary: busy", Decision.busy(reasons: ["a", "b"]).summary == "busy: a, b")
check("summary: idle rounds up", Decision.idle(since: t0, remaining: 90).summary == "idle, 2 min until stop")
check("summary: stop", Decision.stop(idleFor: 3700).summary == "stopping after 61 idle min")

// State
do {
    var s = State(); var p = ProfileState(); p.idleSince = t0; p.stops = 2; s.profiles["pr-qa"] = p; s.pausedUntil = t0
    let url = FileManager.default.temporaryDirectory.appending(path: "siesta-selftest-\(UUID().uuidString).json")
    try s.save(to: url); defer { try? FileManager.default.removeItem(at: url) }
    check("state round-trips through JSON", State.load(from: url) == s)
    check("paused before pausedUntil", s.isPaused(at: t0.addingTimeInterval(-1)))
    check("not paused at pausedUntil", !s.isPaused(at: t0))
    check("missing state file gives defaults", State.load(from: URL(fileURLWithPath: "/nonexistent/x.json")) == State())
}

// Config
do {
    let c = try Config.load(from: URL(fileURLWithPath: "/nonexistent/siesta.json"))
    check("missing config gives defaults", c == Config() && c.checkIntervalSeconds == 3600 && c.idleMinutes == 60)
    let url = FileManager.default.temporaryDirectory.appending(path: "siesta-selftest-\(UUID().uuidString).json")
    var w = Config(); w.profiles = ["pr-qa"]; w.guestLoadThreshold = 0.7
    try w.save(to: url); defer { try? FileManager.default.removeItem(at: url) }
    let loaded = try Config.load(from: url)
    check("config round-trips through JSON", loaded == w)
}

// Paths and plist
do {
    let home = URL(fileURLWithPath: "/Users/test")
    let paths = Paths(home: home)
    check("lima instance name for a profile", paths.limaInstance(profile: "pr-qa") == "colima-pr-qa")
    check("lima instance name for default", paths.limaInstance(profile: "default") == "colima")
    check("docker socket path", paths.dockerSocket(profile: "pr-qa").path == "/Users/test/.colima/pr-qa/docker.sock")
    var c = Config(); c.checkIntervalSeconds = 3600
    let agent = LaunchAgent(paths: paths, shell: Shell(binPaths: c.binPaths, home: home))
    let p = agent.plist(config: c)
    check("plist label", p["Label"] as? String == "com.marianposaceanu.siesta")
    check("plist runs the installed binary with `check`", p["ProgramArguments"] as? [String] == ["/Users/test/.local/bin/siesta", "check"])
    check("plist interval", p["StartInterval"] as? Int == 3600)
    check("plist background process type", p["ProcessType"] as? String == "Background")
    check("plist run at load", p["RunAtLoad"] as? Bool == true)
    check("plist low priority io", p["LowPriorityIO"] as? Bool == true)
    check("plist explicit PATH", (p["EnvironmentVariables"] as? [String: String])?["PATH"] == "/opt/homebrew/bin:/usr/local/bin:/Users/test/.local/bin:/usr/bin:/bin")
    check("plist logs under ~/Library/Logs", p["StandardOutPath"] as? String == "/Users/test/Library/Logs/siesta/launchd.log")
    check("plist serialises", (try? PropertyListSerialization.data(fromPropertyList: p, format: .xml, options: 0)) != nil)
}

// Shell
do {
    let sh = Shell(binPaths: ["/bin", "/usr/bin"], home: FileManager.default.homeDirectoryForCurrentUser)
    let r = sh.run("echo", ["hi"])
    check("shell runs a command", r.ok && r.stdout == "hi\n")
    let t = sh.run("sleep", ["5"], timeout: 0.3)
    check("shell enforces timeout", t.timedOut)
    check("shell reports missing tool", sh.run("no-such-tool-xyz", []).status == 127)
}

print(failures == 0 ? "all checks passed" : "\(failures) check(s) failed")
exit(failures == 0 ? 0 : 1)
