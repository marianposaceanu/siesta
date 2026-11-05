import Foundation

public struct ProfileInfo: Sendable, Equatable {
    public var name: String
    public var running: Bool
    public var memoryBytes: Int64
    public var cpus: Int
    public init(name: String, running: Bool, memoryBytes: Int64 = 0, cpus: Int = 0) {
        self.name = name; self.running = running; self.memoryBytes = memoryBytes; self.cpus = cpus
    }
}

/// The VM manager siesta drives. Colima is the only implementation; the selftest uses a fake.
public protocol VMBackend: Sendable {
    func profiles() throws -> [ProfileInfo]
    func observe(_ profile: ProfileInfo, probes: ProbeOptions) -> Facts
    func bootSession(of profile: String) -> String?
    func stop(_ profile: String, timeout: TimeInterval) throws
}

public enum SiestaError: Error, CustomStringConvertible {
    case command(String, CommandResult)
    case message(String)

    public var description: String {
        switch self {
        case .command(let name, let result):
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name) failed (exit \(result.status)\(result.timedOut ? ", timed out" : "")): \(detail)"
        case .message(let text): return text
        }
    }
}
