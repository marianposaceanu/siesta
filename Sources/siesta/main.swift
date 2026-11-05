import Foundation
import SiestaCore

let version = "0.1.0"
let paths = Paths()
var args = Array(CommandLine.arguments.dropFirst())
let dryRun = args.contains("--dry-run"); args.removeAll { $0 == "--dry-run" }
let verbose = args.contains("-v") || args.contains("--verbose"); args.removeAll { $0 == "-v" || $0 == "--verbose" }
let command = args.first ?? "help"
let rest = Array(args.dropFirst())

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data("siesta: \(msg)\n".utf8))
    exit(code)
}

func loadConfig() -> Config {
    do { return try Config.load(from: paths.configFile) } catch { fail("config \(paths.configFile.path): \(error)") }
}

func fmtBytes(_ b: Int64) -> String { String(format: "%.1f GiB", Double(b) / 1_073_741_824) }
func fmtTime(_ d: Date?) -> String { d.map { Log.stamp($0) } ?? "never" }
func fmtAgo(_ d: Date?, now: Date = Date()) -> String {
    guard let d else { return "never" }
    let s = Int(now.timeIntervalSince(d))
    if s < 90 { return "\(s) s ago" }
    if s < 5400 { return "\(s / 60) min ago" }
    return "\(s / 3600) h \((s % 3600) / 60) min ago"
}

let config = loadConfig()
let shell = Shell(binPaths: config.binPaths, home: paths.home)
let colima = Colima(shell: shell, paths: paths)
let agent = LaunchAgent(paths: paths, shell: shell)

switch command {
case "check":
    // What launchd runs. Also fine by hand; --dry-run observes and logs but never stops anything.
    try? paths.ensureDirectories()
    let log = Log(file: paths.logFile, echo: verbose || dryRun)
    let checker = Checker(paths: paths, config: config, colima: colima, log: log, dryRun: dryRun)
    do {
        let outcomes = try checker.run()
        if dryRun || verbose {
            for o in outcomes { print("\(o.profile): \(o.decision.summary)\(o.stopped ? " [stopped]" : "")\(o.error.map { " error: \($0)" } ?? "")") }
        }
    } catch { log.error("check failed: \(error)"); fail("\(error)") }

case "status":
    let now = Date()
    let state = State.load(from: paths.stateFile)
    let profiles = (try? colima.list()) ?? []
    let watched = config.profiles.isEmpty ? profiles : profiles.filter { config.profiles.contains($0.name) }
    if watched.isEmpty { print("profiles     none found by `colima list`") }
    for p in watched {
        let ps = state.profiles[p.name]
        print("profile      \(p.name)  \(p.running ? "running" : "stopped")  \(fmtBytes(p.memoryBytes)), \(p.cpus) cpus")
        if p.running {
            let c = colima.runningContainers(profile: p.name).map(String.init) ?? "?"
            print("live         \(c) container(s), \(colima.dockerClients(profile: p.name)) docker client(s), \(colima.sshSessions(profile: p.name)) ssh session(s)")
        }
        if let since = ps?.idleSince {
            let left = max(0, config.idleInterval - now.timeIntervalSince(since))
            print("idle         since \(Log.stamp(since)), stop after \(Int(left / 60)) more min")
        } else if p.running {
            print("idle         no (or not yet observed)")
        }
        if let o = ps?.lastObservation { print("last check   \(Log.stamp(o.at)) (\(fmtAgo(o.at, now: now))): \(o.verdict)") }
        print("last stop    \(fmtTime(ps?.lastStop)), \(ps?.stops ?? 0) total")
    }
    if state.isPaused(at: now) { print("paused       until \(Log.stamp(state.pausedUntil!))") }
    let a = agent.status()
    if a.loaded {
        print("agent        loaded, \(a.state), every \(config.checkIntervalSeconds) s, last exit \(a.lastExit), runs \(a.runs)")
    } else {
        print("agent        not installed (run `siesta install`)")
    }
    print("config       \(paths.configFile.path)\(FileManager.default.fileExists(atPath: paths.configFile.path) ? "" : " (defaults)")")
    print("log          \(paths.logFile.path)")

case "logs":
    var n = 50, follow = false
    var i = 0
    while i < rest.count {
        if rest[i] == "-f" { follow = true }
        else if rest[i] == "-n", i + 1 < rest.count { n = Int(rest[i + 1]) ?? n; i += 1 }
        i += 1
    }
    guard let h = try? FileHandle(forReadingFrom: paths.logFile) else { print("no log yet at \(paths.logFile.path)"); exit(0) }
    let data = h.readDataToEndOfFile()
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    for l in lines.suffix(n) { print(l) }
    if follow {
        var offset = UInt64(data.count)
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard let fh = try? FileHandle(forReadingFrom: paths.logFile) else { continue }
            try? fh.seek(toOffset: offset)
            let more = fh.readDataToEndOfFile()
            if !more.isEmpty { FileHandle.standardOutput.write(more); offset += UInt64(more.count) }
            try? fh.close()
        }
    }

case "stop":
    // Manual stop of one or every watched profile, same code path the agent uses.
    let profiles = (try? colima.list()) ?? []
    let names = rest.isEmpty ? (config.profiles.isEmpty ? profiles.filter(\.running).map(\.name) : config.profiles) : rest
    if names.isEmpty { print("nothing running"); exit(0) }
    let log = Log(file: paths.logFile, echo: true)
    for name in names {
        log.info("[\(name)] manual stop")
        let r = colima.stop(profile: name, timeout: TimeInterval(config.stopTimeoutSeconds))
        if r.ok { log.info("[\(name)] stopped") } else { log.error("[\(name)] \(SiestaError.command("colima stop", r))") }
    }

case "pause":
    // siesta pause 2h | 30m | off
    var state = State.load(from: paths.stateFile)
    try? paths.ensureDirectories()
    guard let spec = rest.first else { fail("usage: siesta pause <duration like 2h or 45m | off>") }
    if spec == "off" {
        state.pausedUntil = nil
        try? state.save(to: paths.stateFile); print("resumed"); exit(0)
    }
    let unit = spec.last!, num = Double(spec.dropLast())
    guard let num, "hm".contains(unit) else { fail("duration must look like 2h or 45m") }
    let until = Date().addingTimeInterval(num * (unit == "h" ? 3600 : 60))
    state.pausedUntil = until
    try? state.save(to: paths.stateFile)
    Log(file: paths.logFile).info("paused until \(Log.stamp(until))")
    print("paused until \(Log.stamp(until))")

case "install":
    // Copies this binary to ~/.local/bin, writes the plist, loads the agent in the gui domain.
    do {
        try paths.ensureDirectories()
        let me = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let exe = Bundle.main.executableURL?.resolvingSymlinksInPath() ?? me
        if exe.path != paths.installedBinary.path {
            try FileManager.default.createDirectory(at: paths.installedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: paths.installedBinary.path) { try FileManager.default.removeItem(at: paths.installedBinary) }
            try FileManager.default.copyItem(at: exe, to: paths.installedBinary)
            print("binary       \(paths.installedBinary.path)")
        }
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            try Config().save(to: paths.configFile)
            print("config       \(paths.configFile.path) (written with defaults)")
        }
        try agent.writePlist(config: config)
        print("plist        \(paths.agentPlist.path)")
        try agent.bootstrap()
        print("agent        loaded in \(agent.domain), `siesta check` every \(config.checkIntervalSeconds) s")
        print("log          \(paths.logFile.path)")
    } catch { fail("install: \(error)") }

case "uninstall":
    agent.bootout()
    try? FileManager.default.removeItem(at: paths.agentPlist)
    print("agent unloaded and plist removed; binary, config, state and logs kept")
    if rest.contains("--purge") {
        for u in [paths.installedBinary, paths.stateDir, paths.logDir, paths.configDir] { try? FileManager.default.removeItem(at: u) }
        print("purged binary, state, logs and config")
    }

case "run-now":
    do { try agent.kickstart(); print("kicked; see `siesta logs`") } catch { fail("\(error)") }

case "config":
    if rest.first == "--init" {
        try? paths.ensureDirectories()
        if FileManager.default.fileExists(atPath: paths.configFile.path) { print("exists: \(paths.configFile.path)") }
        else { try? Config().save(to: paths.configFile); print("written: \(paths.configFile.path)") }
    } else {
        print(paths.configFile.path)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        print(String(decoding: (try? enc.encode(config)) ?? Data(), as: UTF8.self))
    }

case "doctor":
    var ok = true
    for tool in ["colima", "docker", "/usr/sbin/lsof", "/bin/launchctl"] {
        if let p = shell.which(tool) { print("ok      \(tool) -> \(p)") } else { print("MISSING \(tool) (searched \(shell.binPaths.joined(separator: ":")))"); ok = false }
    }
    print(FileManager.default.fileExists(atPath: paths.agentPlist.path) ? "ok      plist \(paths.agentPlist.path)" : "--      plist not written")
    print(FileManager.default.fileExists(atPath: paths.installedBinary.path) ? "ok      binary \(paths.installedBinary.path)" : "--      binary not installed")
    let a = agent.status(); print(a.loaded ? "ok      agent loaded, \(a.state)" : "--      agent not loaded")
    if let list = try? colima.list() { print("ok      colima list: \(list.map { "\($0.name)=\($0.running ? "running" : "stopped")" }.joined(separator: " "))") }
    else { print("FAIL    colima list"); ok = false }
    exit(ok ? 0 : 1)

case "version", "--version":
    print("siesta \(version)")

default:
    print("""
    siesta \(version) — stops idle Colima VMs. Not resident: launchd runs `siesta check` on an interval.

      siesta check [--dry-run] [-v]   observe, decide, stop what has been idle long enough (what the agent runs)
      siesta status                   profiles, live counts, idle clock, agent state
      siesta logs [-n N] [-f]         tail the log
      siesta stop [profile ...]       stop now, by hand
      siesta pause <2h|45m|off>       hold off automatic stops
      siesta install | uninstall [--purge]
      siesta run-now                  make launchd run a check immediately
      siesta config [--init]          show (or create) \(paths.configFile.path)
      siesta doctor                   check tools, plist, agent
    """)
}
