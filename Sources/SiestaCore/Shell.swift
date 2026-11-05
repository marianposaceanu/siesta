import Foundation
import Darwin

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var ok: Bool { status == 0 && !timedOut }
    public var lines: [Substring] { stdout.split(separator: "\n", omittingEmptySubsequences: true) }
}

/// Runs external commands. A protocol so the selftest can substitute canned answers.
public protocol CommandRunner: Sendable {
    func which(_ name: String) -> String?
    func run(_ name: String, _ args: [String], timeout: TimeInterval) -> CommandResult
}

public extension CommandRunner {
    func run(_ name: String, _ args: [String]) -> CommandResult { run(name, args, timeout: 15) }
}

/// Runs one external command with a hard timeout, a fixed PATH and a minimal environment.
public struct Shell: CommandRunner {
    public let binPaths: [String]
    public let home: URL

    public init(binPaths: [String], home: URL) {
        self.binPaths = binPaths.map { $0.hasPrefix("~") ? home.path + $0.dropFirst() : $0 }
        self.home = home
    }

    public func which(_ name: String) -> String? {
        let candidates = name.hasPrefix("/") ? [name] : binPaths.map { ($0 as NSString).appendingPathComponent(name) }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func run(_ name: String, _ args: [String], timeout: TimeInterval) -> CommandResult {
        guard let exe = which(name) else {
            return CommandResult(status: 127, stdout: "", stderr: "\(name): not found in \(binPaths.joined(separator: ":"))", timedOut: false)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = ["HOME": home.path, "PATH": binPaths.joined(separator: ":"), "LANG": "C", "TERM": "dumb"]
        process.standardInput = FileHandle.nullDevice
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        do { try process.run() } catch {
            return CommandResult(status: 126, stdout: "", stderr: "\(exe): \(error.localizedDescription)", timedOut: false)
        }

        let watchdog = Watchdog(pid: process.processIdentifier, after: timeout)
        let output = PipeDrain(stdout: stdout, stderr: stderr)   // drain before waiting, or a chatty child blocks
        process.waitUntilExit()
        output.finish()
        watchdog.cancel()
        return CommandResult(status: process.terminationStatus, stdout: output.stdout, stderr: output.stderr, timedOut: watchdog.fired)
    }
}

/// Sends SIGTERM to a pid after a deadline unless cancelled first. Remembers whether it fired.
private final class Watchdog: @unchecked Sendable {
    private let flag = LockedFlag()
    private let item: DispatchWorkItem

    init(pid: pid_t, after timeout: TimeInterval) {
        let flag = self.flag
        item = DispatchWorkItem { flag.set(); kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: item)
    }

    var fired: Bool { flag.isSet }
    func cancel() { item.cancel() }
}

/// A boolean that may be set from one thread and read from another.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Reads both pipes on background threads and hands the bytes back under a lock.
private final class PipeDrain: @unchecked Sendable {
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var out = Data(), err = Data()

    init(stdout: Pipe, stderr: Pipe) {
        read(stdout) { [self] d in lock.lock(); out = d; lock.unlock() }
        read(stderr) { [self] d in lock.lock(); err = d; lock.unlock() }
    }

    private func read(_ pipe: Pipe, into store: @escaping @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global().async { [group] in store(pipe.fileHandleForReading.readDataToEndOfFile()); group.leave() }
    }

    func finish() { group.wait() }
    var stdout: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var stderr: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
