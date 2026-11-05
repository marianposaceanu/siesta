import Foundation
import Darwin

public struct CommandResult: Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String
    public var timedOut: Bool
    public var ok: Bool { status == 0 && !timedOut }
}

/// Runs one external command with a hard timeout and a fixed PATH. Never inherits the caller's environment beyond HOME.
public struct Shell: Sendable {
    public var binPaths: [String]
    public var home: URL

    public init(binPaths: [String], home: URL) {
        self.binPaths = binPaths.map { $0.hasPrefix("~") ? home.path + $0.dropFirst() : $0 }
        self.home = home
    }

    public func which(_ name: String) -> String? {
        if name.hasPrefix("/") { return FileManager.default.isExecutableFile(atPath: name) ? name : nil }
        for dir in binPaths {
            let p = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    @discardableResult
    public func run(_ name: String, _ args: [String], timeout: TimeInterval = 15, extraEnv: [String: String] = [:]) -> CommandResult {
        guard let exe = which(name) else {
            return CommandResult(status: 127, stdout: "", stderr: "\(name): not found in \(binPaths.joined(separator: ":"))", timedOut: false)
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ["HOME": home.path, "PATH": binPaths.joined(separator: ":"), "LANG": "C", "TERM": "dumb"]
        for (k, v) in extraEnv { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            return CommandResult(status: 126, stdout: "", stderr: "\(exe): \(error.localizedDescription)", timedOut: false)
        }
        let pid = p.processIdentifier
        let killer = DispatchWorkItem { kill(pid, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        // Drain both pipes before waiting, or a chatty child blocks on a full pipe.
        let group = DispatchGroup()
        let box = OutputBox()
        group.enter(); DispatchQueue.global().async { box.setOut(out.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        group.enter(); DispatchQueue.global().async { box.setErr(err.fileHandleForReading.readDataToEndOfFile()); group.leave() }
        p.waitUntilExit()
        group.wait()
        let timedOut = !killer.isCancelled && p.terminationReason == .uncaughtSignal
        killer.cancel()
        return CommandResult(status: p.terminationStatus, stdout: box.outString, stderr: box.errString, timedOut: timedOut)
    }
}

/// Lets two reader threads hand their bytes back under a lock, which keeps Swift 6 happy about shared state.
final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data(), err = Data()
    func setOut(_ d: Data) { lock.lock(); out = d; lock.unlock() }
    func setErr(_ d: Data) { lock.lock(); err = d; lock.unlock() }
    var outString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: out, as: UTF8.self) }
    var errString: String { lock.lock(); defer { lock.unlock() }; return String(decoding: err, as: UTF8.self) }
}
