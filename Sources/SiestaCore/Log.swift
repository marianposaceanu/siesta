import Foundation
import os

/// Appends one line per event to ~/Library/Logs/siesta/siesta.log and mirrors it to the unified log.
/// Rotates at 1 MiB to siesta.log.1 so the file never grows without bound.
public struct Log: Sendable {
    public let file: URL
    public var echo: Bool
    private let osLog = Logger(subsystem: Paths.label, category: "check")
    private static let maxBytes: UInt64 = 1 << 20

    public init(file: URL, echo: Bool = false) { self.file = file; self.echo = echo }

    public func info(_ msg: String) { write("INFO", msg); osLog.info("\(msg, privacy: .public)") }
    public func warn(_ msg: String) { write("WARN", msg); osLog.warning("\(msg, privacy: .public)") }
    public func error(_ msg: String) { write("ERROR", msg); osLog.error("\(msg, privacy: .public)") }

    private func write(_ level: String, _ msg: String) {
        let line = "\(Log.stamp(Date())) \(level) \(msg)\n"
        if echo { FileHandle.standardError.write(Data(line.utf8)) }
        rotateIfNeeded()
        guard let data = line.data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: file) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: file)
        }
    }

    private func rotateIfNeeded() {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: file.path),
              let size = attrs[.size] as? UInt64, size > Log.maxBytes else { return }
        let old = file.appendingPathExtension("1")
        try? FileManager.default.removeItem(at: old)
        try? FileManager.default.moveItem(at: file, to: old)
    }

    public static func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: d)
    }
}
