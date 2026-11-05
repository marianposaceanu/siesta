import Foundation

public struct ProfileInfo: Sendable, Equatable {
    public var name: String
    public var running: Bool
    public var memoryBytes: Int64
    public var cpus: Int
}

/// Everything siesta asks Colima, Docker and the host about one profile. Each call is bounded by a timeout.
public struct Colima: Sendable {
    public let shell: Shell
    public let paths: Paths

    public init(shell: Shell, paths: Paths) { self.shell = shell; self.paths = paths }

    /// `colima list -j` prints one JSON object per line.
    public func list() throws -> [ProfileInfo] {
        let r = shell.run("colima", ["list", "-j"], timeout: 20)
        guard r.ok else { throw SiestaError.command("colima list", r) }
        var out: [ProfileInfo] = []
        for line in r.stdout.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["name"] as? String else { continue }
            let status = (obj["status"] as? String) ?? ""
            out.append(ProfileInfo(name: name, running: status.lowercased() == "running",
                                   memoryBytes: (obj["memory"] as? NSNumber)?.int64Value ?? 0,
                                   cpus: (obj["cpus"] as? NSNumber)?.intValue ?? 0))
        }
        return out
    }

    /// Running containers, via the profile's own socket so no docker context is needed.
    public func runningContainers(profile: String) -> Int? {
        let sock = paths.dockerSocket(profile: profile)
        guard FileManager.default.fileExists(atPath: sock.path) else { return nil }
        let r = shell.run("docker", ["--host", "unix://\(sock.path)", "ps", "-q"], timeout: 10)
        guard r.ok else { return nil }
        return r.stdout.split(separator: "\n").count
    }

    /// PIDs that belong to Lima's own plumbing for this instance: limactl processes and the ssh multiplex
    /// master that forwards the docker socket. They always hold the sockets and never mean the user is busy.
    public func infrastructurePIDs(profile: String) -> Set<String> {
        let r = shell.run("/bin/ps", ["-axo", "pid=,args="], timeout: 10)
        let marker = "\(paths.limaInstance(profile: profile))/ssh"
        var pids = Set<String>()
        for line in r.stdout.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let sp = t.firstIndex(of: " ") else { continue }
            let pid = String(t[..<sp]), args = t[sp...]
            if args.contains("limactl") || (args.contains(marker) && args.contains("[mux]")) { pids.insert(pid) }
        }
        return pids
    }

    /// Processes other than Lima's own that hold the profile's docker or containerd socket open:
    /// a docker CLI mid-command, compose, an IDE, a build. lsof -U lists unix sockets only, so it stays fast.
    public func dockerClients(profile: String) -> Int {
        let r = shell.run("/usr/sbin/lsof", ["-U", "-n", "-P", "-F", "pcn"], timeout: 10)
        guard r.ok || !r.stdout.isEmpty else { return 0 }
        let targets = [paths.dockerSocket(profile: profile).path, paths.containerdSocket(profile: profile).path]
        let skip = infrastructurePIDs(profile: profile).union([String(ProcessInfo.processInfo.processIdentifier)])
        var pid = "", clients = Set<String>()
        for line in r.stdout.split(separator: "\n") {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = value
            case "n": if targets.contains(where: { value.hasSuffix($0) }), !skip.contains(pid) { clients.insert(pid) }
            default: break
            }
        }
        return clients.count
    }

    /// Interactive ssh sessions into the instance. Lima's multiplex master is excluded.
    public func sshSessions(profile: String) -> Int {
        let r = shell.run("/bin/ps", ["-axo", "pid=,args="], timeout: 10)
        let marker = "\(paths.limaInstance(profile: profile))/ssh"
        return r.stdout.split(separator: "\n").filter { $0.contains(marker) && !$0.contains("[mux]") }.count
    }

    /// 1-minute load average inside the guest. One ssh round trip; only used when configured.
    public func guestLoad(profile: String) -> Double? {
        let r = shell.run("colima", ["ssh", "-p", profile, "--", "cat", "/proc/loadavg"], timeout: 15)
        guard r.ok, let first = r.stdout.split(separator: " ").first else { return nil }
        return Double(first)
    }

    public func stop(profile: String, timeout: TimeInterval) -> CommandResult {
        shell.run("colima", ["stop", "-p", profile], timeout: timeout)
    }
}

public enum SiestaError: Error, CustomStringConvertible {
    case command(String, CommandResult)
    case message(String)
    public var description: String {
        switch self {
        case .command(let name, let r):
            return "\(name) failed (exit \(r.status)\(r.timedOut ? ", timed out" : "")): \(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        case .message(let m): return m
        }
    }
}
