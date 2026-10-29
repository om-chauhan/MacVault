import Foundation

/// Byte formatting using decimal (SI) units, matching how Finder and macOS
/// storage settings report capacity (1 GB = 1,000,000,000 bytes).
public enum ByteFormat {
    private static let units = ["bytes", "KB", "MB", "GB", "TB", "PB", "EB"]

    public static func string(_ bytes: Int64) -> String {
        if bytes == 1 { return "1 byte" }
        if abs(bytes) < 1000 { return "\(bytes) bytes" }
        var value = Double(bytes)
        var unit = 0
        while abs(value) >= 1000 && unit < units.count - 1 {
            value /= 1000
            unit += 1
        }
        let digits = abs(value) >= 100 ? 0 : (abs(value) >= 10 ? 1 : 2)
        return String(format: "%.\(digits)f %@", value, units[unit])
    }

    /// "Unknown" for nil — never renders an unknown size as zero.
    public static func string(_ bytes: Int64?, unknown: String = "Unknown") -> String {
        guard let bytes else { return unknown }
        return string(bytes)
    }
}

public enum Timestamp {
    private static func formatter() -> ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }

    /// UTC ISO-8601 with milliseconds, e.g. 2026-10-29T17:19:03.123Z. Lexicographically sortable.
    public static func string(_ date: Date) -> String { formatter().string(from: date) }

    public static func date(_ string: String) -> Date? { formatter().date(from: string) }
}
