import Foundation

/// Human-readable numbers and dates, in one place so every command prints them the same way.
public enum Format {
    public static func bytes(_ bytes: Int64) -> String { String(format: "%.1f GiB", Double(bytes) / 1_073_741_824) }

    public static func timestamp(_ date: Date) -> String { stampFormatter.string(from: date) }
    public static func timestamp(_ date: Date?) -> String { date.map(timestamp) ?? "never" }

    public static func minutes(_ interval: TimeInterval, roundingUp: Bool = false) -> Int {
        roundingUp ? Int((interval / 60).rounded(.up)) : Int(interval / 60)
    }

    public static func ago(_ date: Date?, now: Date) -> String {
        guard let date else { return "never" }
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<90: return "\(seconds) s ago"
        case ..<5400: return "\(seconds / 60) min ago"
        default: return "\(seconds / 3600) h \(seconds % 3600 / 60) min ago"
        }
    }

    /// "2h" or "45m" to seconds.
    public static func duration(_ spec: String) -> TimeInterval? {
        guard let unit = spec.last, let amount = Double(spec.dropLast()) else { return nil }
        switch unit {
        case "h": return amount * 3600
        case "m": return amount * 60
        default: return nil
        }
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
