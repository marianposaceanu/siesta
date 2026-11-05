import Foundation

/// Writes and manages the launchd agent. The agent runs `siesta check` on an interval; nothing stays resident.
/// Conventions: reverse-DNS label, plist in ~/Library/LaunchAgents, absolute program path, explicit PATH,
/// Background process type with low CPU and I/O priority, stdout/stderr under ~/Library/Logs, gui domain, no sudo.
public struct LaunchAgent: Sendable {
    public let paths: Paths
    public let shell: Shell
    public init(paths: Paths, shell: Shell) { self.paths = paths; self.shell = shell }

    public var domain: String { "gui/\(getuid())" }
    public var target: String { "\(domain)/\(Paths.label)" }

    public func plist(config: Config) -> [String: Any] {
        [
            "Label": Paths.label,
            "ProgramArguments": [paths.installedBinary.path, "check"],
            "StartInterval": config.checkIntervalSeconds,
            "RunAtLoad": true,
            "ProcessType": "Background",
            "Nice": 10,
            "LowPriorityIO": true,
            "LowPriorityBackgroundIO": true,
            "StandardOutPath": paths.launchdOut.path,
            "StandardErrorPath": paths.launchdOut.path,
            "EnvironmentVariables": ["PATH": shell.binPaths.joined(separator: ":"), "HOME": paths.home.path],
        ]
    }

    public func writePlist(config: Config) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist(config: config), format: .xml, options: 0)
        try FileManager.default.createDirectory(at: paths.agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: paths.agentPlist, options: .atomic)
    }

    public func bootstrap() throws {
        _ = shell.run("/bin/launchctl", ["bootout", target], timeout: 20)   // ignore: not loaded yet is fine
        let r = shell.run("/bin/launchctl", ["bootstrap", domain, paths.agentPlist.path], timeout: 20)
        guard r.ok else { throw SiestaError.command("launchctl bootstrap", r) }
        _ = shell.run("/bin/launchctl", ["enable", target], timeout: 20)
    }

    public func bootout() {
        _ = shell.run("/bin/launchctl", ["bootout", target], timeout: 20)
    }

    public func kickstart() throws {
        let r = shell.run("/bin/launchctl", ["kickstart", target], timeout: 20)
        guard r.ok else { throw SiestaError.command("launchctl kickstart", r) }
    }

    public struct Status: Sendable {
        public var loaded: Bool
        public var state: String
        public var lastExit: String
        public var runs: String
        public var interval: String
    }

    public func status() -> Status {
        let r = shell.run("/bin/launchctl", ["print", target], timeout: 20)
        guard r.ok else { return Status(loaded: false, state: "not loaded", lastExit: "-", runs: "-", interval: "-") }
        func grab(_ key: String) -> String {
            for line in r.stdout.split(separator: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix(key + " = ") { return String(t.dropFirst(key.count + 3)) }
            }
            return "-"
        }
        return Status(loaded: true, state: grab("state"), lastExit: grab("last exit code"), runs: grab("runs"), interval: grab("run interval"))
    }
}
