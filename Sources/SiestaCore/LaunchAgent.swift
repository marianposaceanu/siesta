import Foundation

/// The launchd agent that runs `siesta check` on an interval. Nothing stays resident between runs.
/// Conventions: reverse-DNS label, plist in ~/Library/LaunchAgents, absolute program path, explicit PATH,
/// Background process type with low CPU and I/O priority, output under ~/Library/Logs, gui domain, no sudo.
public struct LaunchAgent: Sendable {
    public struct Status: Sendable, Equatable {
        public var loaded: Bool
        public var state: String
        public var lastExit: String
        public var runs: String
        /// Switched off in System Settings > General > Login Items & Extensions, or by `launchctl disable`.
        public var disabled: Bool
    }

    public let paths: Paths
    public let runner: CommandRunner
    public let binPaths: [String]

    public init(paths: Paths, runner: CommandRunner, binPaths: [String]) { self.paths = paths; self.runner = runner; self.binPaths = binPaths }

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
            "StandardOutPath": paths.launchdLog.path,
            "StandardErrorPath": paths.launchdLog.path,
            "EnvironmentVariables": ["PATH": binPaths.joined(separator: ":"), "HOME": paths.home.path],
        ]
    }

    public func writePlist(config: Config) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist(config: config), format: .xml, options: 0)
        try data.write(to: paths.agentPlist, options: .atomic)
    }

    /// Loads the agent, replacing any earlier copy. `enable` undoes a previous `launchctl disable`.
    public func load() throws {
        unload()
        let result = runner.run("/bin/launchctl", ["bootstrap", domain, paths.agentPlist.path], timeout: 20)
        guard result.ok else { throw SiestaError.command("launchctl bootstrap", result) }
        _ = runner.run("/bin/launchctl", ["enable", target], timeout: 20)
    }

    public func unload() { _ = runner.run("/bin/launchctl", ["bootout", target], timeout: 20) }

    public func kickstart() throws {
        let result = runner.run("/bin/launchctl", ["kickstart", target], timeout: 20)
        guard result.ok else { throw SiestaError.command("launchctl kickstart", result) }
    }

    public func status() -> Status {
        let result = runner.run("/bin/launchctl", ["print", target], timeout: 20)
        let disabled = isDisabled()
        guard result.ok else { return Status(loaded: false, state: "not loaded", lastExit: "-", runs: "-", disabled: disabled) }
        let fields = LaunchctlPrint(result.stdout)
        return Status(loaded: true, state: fields["state"], lastExit: fields["last exit code"], runs: fields["runs"], disabled: disabled)
    }

    private func isDisabled() -> Bool {
        let result = runner.run("/bin/launchctl", ["print-disabled", domain], timeout: 20)
        return result.lines.contains { $0.contains("\"\(Paths.label)\"") && ($0.contains("disabled") || $0.contains("true")) }
    }
}

/// Reads `key = value` lines out of `launchctl print` output.
private struct LaunchctlPrint {
    private let fields: [String: String]

    init(_ text: String) {
        var parsed: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let range = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[..<range.lowerBound])
            if parsed[key] == nil { parsed[key] = String(trimmed[range.upperBound...]) }
        }
        fields = parsed
    }

    subscript(key: String) -> String { fields[key] ?? "-" }
}
