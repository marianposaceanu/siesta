import Foundation
import os

public protocol Logging: Sendable {
    func info(_ message: String)
    func warn(_ message: String)
    func error(_ message: String)
}

/// Appends one line per event to the log file, mirrors it to the unified log, and optionally echoes to stderr.
/// Rotates at 1 MiB to <file>.1 so the file never grows without bound.
public struct FileLogger: Logging {
    public let file: URL
    public let echo: Bool
    private let unified = Logger(subsystem: Paths.label, category: "check")
    private static let maxBytes: UInt64 = 1 << 20

    public init(file: URL, echo: Bool = false) { self.file = file; self.echo = echo }

    public func info(_ message: String) { write("INFO", message); unified.info("\(message, privacy: .public)") }
    public func warn(_ message: String) { write("WARN", message); unified.warning("\(message, privacy: .public)") }
    public func error(_ message: String) { write("ERROR", message); unified.error("\(message, privacy: .public)") }

    private func write(_ level: String, _ message: String) {
        let line = Data("\(Format.timestamp(Date())) \(level) \(message)\n".utf8)
        if echo { FileHandle.standardError.write(line) }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: file) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        } else {
            try? line.write(to: file)
        }
    }

    private func rotateIfNeeded() {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64,
              size > FileLogger.maxBytes else { return }
        let rotated = file.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: rotated)
        try? FileManager.default.moveItem(at: file, to: rotated)
    }
}

/// Collects lines in memory. Used by the selftest.
public final class MemoryLogger: Logging, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    public init() {}
    public var lines: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    public func info(_ message: String) { append("INFO \(message)") }
    public func warn(_ message: String) { append("WARN \(message)") }
    public func error(_ message: String) { append("ERROR \(message)") }
    private func append(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
}
