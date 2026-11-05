import Foundation

/// Asks Colima, Docker and the host about profiles. Every call is a bounded subprocess; every probe that
/// fails answers nil so the policy can refuse to call the profile idle.
public struct ColimaBackend: VMBackend {
    public let runner: CommandRunner
    public let paths: Paths

    public init(runner: CommandRunner, paths: Paths) { self.runner = runner; self.paths = paths }

    public func profiles() throws -> [ProfileInfo] {
        let result = runner.run("colima", ["list", "-j"], timeout: 20)
        guard result.ok else { throw SiestaError.command("colima list", result) }
        return result.lines.compactMap(ProfileInfo.init(colimaJSONLine:))
    }

    public func observe(_ profile: ProfileInfo, probes: ProbeOptions) -> Facts {
        guard profile.running else { return .stopped }
        let table = (probes.dockerClients || probes.sshSessions) ? ProcessTable(runner: runner) : nil
        return Facts(
            running: true,
            containers: probes.containers ? runningContainers(profile: profile.name) : 0,
            dockerClients: probes.dockerClients ? dockerClients(profile: profile.name, table: table) : 0,
            sshSessions: probes.sshSessions ? table?.sshSessions(instance: paths.limaInstance(profile: profile.name)) : 0,
            guestLoad: probes.guestLoad ? guestLoad(profile: profile.name) : nil
        )
    }

    public func bootSession(of profile: String) -> String? {
        guard let text = try? String(contentsOf: paths.haPid(profile: profile), encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func stop(_ profile: String, timeout: TimeInterval) throws {
        let result = runner.run("colima", ["stop", "-p", profile], timeout: timeout)
        guard result.ok else { throw SiestaError.command("colima stop", result) }
    }

    // MARK: probes

    /// Running containers, over the profile's own socket so no docker context is needed.
    private func runningContainers(profile: String) -> Int? {
        let socket = paths.dockerSocket(profile: profile)
        guard FileManager.default.fileExists(atPath: socket.path) else { return nil }
        let result = runner.run("docker", ["--host", "unix://\(socket.path)", "ps", "-q"], timeout: 10)
        return result.ok ? result.lines.count : nil
    }

    /// Processes other than Lima's own that hold the docker or containerd socket open: a docker command,
    /// compose, an IDE, a build. `lsof -U` lists unix sockets only, which keeps it to tens of milliseconds.
    private func dockerClients(profile: String, table: ProcessTable?) -> Int? {
        guard let table else { return nil }
        let result = runner.run("/usr/sbin/lsof", ["-U", "-n", "-P", "-F", "pcn"], timeout: 10)
        guard !result.timedOut, !result.stdout.isEmpty else { return nil }
        let sockets = [paths.dockerSocket(profile: profile).path, paths.containerdSocket(profile: profile).path]
        let ignored = table.limaInfrastructure(instance: paths.limaInstance(profile: profile))
            .union([ProcessInfo.processInfo.processIdentifier])
        var current: pid_t = 0
        var clients = Set<pid_t>()
        for line in result.lines {
            switch line.first {
            case "p": current = pid_t(line.dropFirst()) ?? 0
            case "n" where sockets.contains(where: { line.hasSuffix($0) }) && !ignored.contains(current): clients.insert(current)
            default: break
            }
        }
        return clients.count
    }

    /// Guest 1-minute load average. One ssh round trip; only used when configured.
    private func guestLoad(profile: String) -> Double? {
        let result = runner.run("colima", ["ssh", "-p", profile, "--", "cat", "/proc/loadavg"], timeout: 15)
        guard result.ok, let first = result.stdout.split(separator: " ").first else { return nil }
        return Double(first)
    }
}

/// One `ps` snapshot, read once per check and queried by the probes that need it.
struct ProcessTable {
    struct Entry { let pid: pid_t; let args: Substring }
    let entries: [Entry]

    init?(runner: CommandRunner) {
        let result = runner.run("/bin/ps", ["-axo", "pid=,args="], timeout: 10)
        guard result.ok else { return nil }
        entries = result.lines.compactMap { line in
            let trimmed = line.drop(while: \.isWhitespace)
            guard let gap = trimmed.firstIndex(of: " "), let pid = pid_t(trimmed[..<gap]) else { return nil }
            return Entry(pid: pid, args: trimmed[gap...])
        }
    }

    /// Lima's plumbing for an instance: limactl processes and the ssh multiplex master that forwards the sockets.
    func limaInfrastructure(instance: String) -> Set<pid_t> {
        Set(entries.filter { $0.args.contains("limactl") || ($0.args.contains("\(instance)/ssh") && $0.args.contains("[mux]")) }.map(\.pid))
    }

    /// Interactive ssh sessions into the instance, the multiplex master excluded.
    func sshSessions(instance: String) -> Int {
        entries.filter { $0.args.contains("\(instance)/ssh") && !$0.args.contains("[mux]") }.count
    }
}

private extension ProfileInfo {
    /// `colima list -j` prints one JSON object per line.
    init?(colimaJSONLine line: Substring) {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["name"] as? String else { return nil }
        self.init(name: name,
                  running: (object["status"] as? String)?.lowercased() == "running",
                  memoryBytes: (object["memory"] as? NSNumber)?.int64Value ?? 0,
                  cpus: (object["cpus"] as? NSNumber)?.intValue ?? 0)
    }
}
