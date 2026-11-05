import Foundation
import SiestaCore

let siestaVersion = "0.2.1"

/// What launchd runs. By hand, --dry-run observes and logs but never stops anything and never touches the clocks.
struct CheckCommand: Command {
    static let name = "check"
    static let usage = "check [--dry-run] [-v]"
    static let summary = "observe, decide, stop what has been idle long enough"

    func run(_ context: Context, _ args: Arguments) throws {
        try context.paths.ensureDirectories()
        let dryRun = args.has("--dry-run"), verbose = args.has("-v", "--verbose")
        let outcomes = try context.checker(dryRun: dryRun, echo: dryRun || verbose).run()
        guard dryRun || verbose else { return }
        for outcome in outcomes {
            let suffix = outcome.stopped ? " [stopped]" : outcome.error.map { " error: \($0)" } ?? ""
            context.output.line("\(outcome.profile): \(outcome.decision.summary)\(suffix)")
        }
    }
}

struct StatusCommand: Command {
    static let name = "status"
    static let usage = "status"
    static let summary = "profiles, live counts, idle clock, agent state"

    func run(_ context: Context, _ args: Arguments) throws {
        let now = Date(), out = context.output
        let state = context.store.load()
        let profiles = try context.watchedProfiles()
        if profiles.isEmpty { out.row("profiles", "none found by `colima list`") }
        for profile in profiles {
            let profileState = state.profiles[profile.name]
            out.row("profile", "\(profile.name)  \(profile.running ? "running" : "stopped")  \(Format.bytes(profile.memoryBytes)), \(profile.cpus) cpus")
            if profile.running {
                out.row("live", context.backend.observe(profile, probes: context.config.probes).counts)
                if let since = profileState?.idleSince {
                    let left = max(0, context.config.idleInterval - now.timeIntervalSince(since))
                    out.row("idle", "since \(Format.timestamp(since)), stop after \(Format.minutes(left, roundingUp: true)) more min")
                } else {
                    out.row("idle", "no, or not observed yet")
                }
            }
            if let last = profileState?.lastObservation {
                out.row("last check", "\(Format.timestamp(last.at)) (\(Format.ago(last.at, now: now))): \(last.verdict)")
            }
            out.row("last stop", "\(Format.timestamp(profileState?.lastStop)), \(profileState?.stops ?? 0) total")
        }
        if let until = state.pausedUntil, state.isPaused(at: now) { out.row("paused", "until \(Format.timestamp(until))") }
        let agent = context.agent.status()
        let disabledNote = agent.disabled ? ", DISABLED in Login Items & Extensions" : ""
        out.row("agent", agent.loaded
            ? "loaded, \(agent.state), every \(context.config.checkIntervalSeconds) s, last exit \(agent.lastExit), runs \(agent.runs)\(disabledNote)"
            : "not installed (run `siesta install`)\(disabledNote)")
        let configNote = FileManager.default.fileExists(atPath: context.paths.configFile.path) ? "" : " (defaults)"
        out.row("config", context.paths.configFile.path + configNote)
        out.row("log", context.paths.logFile.path)
    }
}

struct LogsCommand: Command {
    static let name = "logs"
    static let usage = "logs [-n N] [-f]"
    static let summary = "tail the log"

    func run(_ context: Context, _ args: Arguments) throws {
        let file = context.paths.logFile
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            context.output.line("no log yet at \(file.path)"); return
        }
        let data = handle.readDataToEndOfFile()
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        lines.suffix(args.int("-n", default: 50)).forEach { context.output.line(String($0)) }
        guard args.has("-f") else { return }
        var offset = UInt64(data.count)
        while true {
            Thread.sleep(forTimeInterval: 1)
            guard let tail = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? tail.close() }
            try? tail.seek(toOffset: offset)
            let more = tail.readDataToEndOfFile()
            guard !more.isEmpty else { continue }
            context.output.raw(more)
            offset += UInt64(more.count)
        }
    }
}

/// Manual stop of the named profiles, or of every running watched profile, through the same backend the agent uses.
struct StopCommand: Command {
    static let name = "stop"
    static let usage = "stop [profile ...]"
    static let summary = "stop now, by hand"

    func run(_ context: Context, _ args: Arguments) throws {
        let names = args.positional.isEmpty ? try context.watchedProfiles().filter(\.running).map(\.name) : args.positional
        guard !names.isEmpty else { context.output.line("nothing running"); return }
        let log = context.logger(echo: true)
        for name in names {
            log.info("[\(name)] manual stop")
            do { try context.backend.stop(name, timeout: context.config.stopTimeout); log.info("[\(name)] stopped") }
            catch { log.error("[\(name)] \(error)") }
        }
    }
}

struct PauseCommand: Command {
    static let name = "pause"
    static let usage = "pause <2h|45m|off>"
    static let summary = "hold off automatic stops"

    func run(_ context: Context, _ args: Arguments) throws {
        guard let spec = args.positional.first else { throw CommandFailure("usage: siesta \(Self.usage)") }
        var state = context.store.load()
        if spec == "off" {
            state.pausedUntil = nil
            try context.store.save(state)
            context.output.line("resumed"); return
        }
        guard let seconds = Format.duration(spec) else { throw CommandFailure("duration must look like 2h or 45m") }
        let until = Date().addingTimeInterval(seconds)
        state.pausedUntil = until
        try context.store.save(state)
        context.logger(echo: false).info("paused until \(Format.timestamp(until))")
        context.output.line("paused until \(Format.timestamp(until))")
    }
}

/// Writes the config if absent, resets the idle clocks, writes the plist and loads the agent. A binary that
/// came from a package build is copied to ~/.local/bin first; an installed one, Homebrew's for example, is used where it is.
struct InstallCommand: Command {
    static let name = "install"
    static let usage = "install"
    static let summary = "load the hourly agent for this binary"

    func run(_ context: Context, _ args: Arguments) throws {
        let paths = context.paths, out = context.output
        try paths.ensureDirectories()
        let program = try installedProgram(fallback: paths.installedBinary)
        out.row("binary", program.path)
        if !FileManager.default.fileExists(atPath: paths.configFile.path) {
            try Config().save(to: paths.configFile)
            out.row("config", "\(paths.configFile.path) (written with defaults)")
        }
        var state = context.store.load()
        state.resetIdleClocks()   // the RunAtLoad check must never stop anything on the spot
        try context.store.save(state)
        try context.agent.writePlist(config: context.config, program: program)
        out.row("plist", paths.agentPlist.path)
        try context.agent.load()
        out.row("agent", "loaded in \(context.agent.domain), `siesta check` every \(context.config.checkIntervalSeconds) s")
        out.row("log", paths.logFile.path)
    }

    private func installedProgram(fallback destination: URL) throws -> URL {
        let invoked = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])).standardizedFileURL
        let real = invoked.resolvingSymlinksInPath()
        // An installed binary is used by the path it was invoked through, so a Homebrew symlink such as
        // /opt/homebrew/bin/siesta keeps working after an upgrade replaces the Cellar directory behind it.
        guard real.path.contains("/.build/") else { return invoked }
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) { try fm.removeItem(at: destination) }
        try fm.copyItem(at: real, to: destination)
        return destination
    }
}

struct UninstallCommand: Command {
    static let name = "uninstall"
    static let usage = "uninstall [--purge]"
    static let summary = "unload the agent; --purge also removes binary, config, state and logs"

    func run(_ context: Context, _ args: Arguments) throws {
        let paths = context.paths
        context.agent.unload()
        try? FileManager.default.removeItem(at: paths.agentPlist)
        context.output.line("agent unloaded and plist removed; binary, config, state and logs kept")
        guard args.has("--purge") else { return }
        for url in [paths.installedBinary, paths.stateDir, paths.logDir, paths.configFile.deletingLastPathComponent()] {
            try? FileManager.default.removeItem(at: url)
        }
        context.output.line("purged binary, state, logs and config")
    }
}

struct RunNowCommand: Command {
    static let name = "run-now"
    static let usage = "run-now"
    static let summary = "make launchd run a check immediately"

    func run(_ context: Context, _ args: Arguments) throws {
        try context.agent.kickstart()
        context.output.line("kicked; see `siesta logs`")
    }
}

struct ConfigCommand: Command {
    static let name = "config"
    static let usage = "config [--init]"
    static let summary = "show, or create, the config file"

    func run(_ context: Context, _ args: Arguments) throws {
        let file = context.paths.configFile
        if args.has("--init") {
            guard !FileManager.default.fileExists(atPath: file.path) else { context.output.line("exists: \(file.path)"); return }
            try Config().save(to: file)
            context.output.line("written: \(file.path)"); return
        }
        context.output.line(file.path)
        context.output.line(JSONFile.render(context.config))
    }
}

struct DoctorCommand: Command {
    static let name = "doctor"
    static let usage = "doctor"
    static let summary = "check tools, plist, agent"

    func run(_ context: Context, _ args: Arguments) throws {
        let out = context.output, paths = context.paths
        var healthy = true
        for tool in ["colima", "docker", "/usr/sbin/lsof", "/bin/launchctl"] {
            if let found = context.runner.which(tool) { out.row("ok", "\(tool) -> \(found)") }
            else { out.row("MISSING", "\(tool) (searched \(context.runner.binPaths.joined(separator: ":")))"); healthy = false }
        }
        func report(_ url: URL, _ what: String, missing: String) {
            let present = FileManager.default.fileExists(atPath: url.path)
            out.row(present ? "ok" : "--", present ? "\(what) \(url.path)" : missing)
        }
        report(paths.agentPlist, "plist", missing: "plist not written")
        report(paths.installedBinary, "binary", missing: "binary not installed")
        let agent = context.agent.status()
        out.row(agent.loaded ? "ok" : "--", agent.loaded ? "agent loaded, \(agent.state)" : "agent not loaded")
        do {
            let profiles = try context.backend.profiles()
            out.row("ok", "colima list: " + profiles.map { "\($0.name)=\($0.running ? "running" : "stopped")" }.joined(separator: " "))
        } catch { out.row("FAIL", "colima list: \(error)"); healthy = false }
        if !healthy { throw CommandFailure("doctor found problems") }
    }
}

struct VersionCommand: Command {
    static let name = "version"
    static let usage = "version"
    static let summary = "print the version"
    func run(_ context: Context, _ args: Arguments) throws { context.output.line("siesta \(siestaVersion)") }
}

struct HelpCommand: Command {
    static let name = "help"
    static let usage = "help"
    static let summary = "this list"

    func run(_ context: Context, _ args: Arguments) throws {
        let out = context.output
        out.line("siesta \(siestaVersion) — stops idle Colima VMs. Not resident: launchd runs `siesta check` on an interval.")
        out.line()
        let width = Commands.all.map { $0.usage.count }.max() ?? 0
        for command in Commands.all {
            out.line("  siesta \(command.usage.padding(toLength: width, withPad: " ", startingAt: 0))  \(command.summary)")
        }
    }
}
