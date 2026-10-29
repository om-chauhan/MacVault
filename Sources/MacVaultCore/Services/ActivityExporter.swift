import Foundation

/// Exports audit events as JSON or CSV.
///
/// Redaction (`.homeFolder`, the default) replaces the home folder path with `~` and the account
/// name with `<user>` in messages and details. It does not attempt to detect other personal data
/// in file names; choose `.none` only for your own records.
public enum ActivityExporter {
    public enum Format: String, Sendable, CaseIterable {
        case json, csv

        public var fileExtension: String { rawValue }
    }

    public enum Redaction: String, Sendable, CaseIterable {
        case none
        case homeFolder
    }

    public static func export(_ events: [AuditEvent], format: Format, redaction: Redaction = .homeFolder,
                              home: String = NSHomeDirectory(), userName: String = NSUserName()) throws -> Data {
        let redact: (String) -> String = { text in
            redaction == .none ? text : redactHome(text, home: home, userName: userName)
        }
        switch format {
        case .json:
            let rows: [[String: Any]] = events.map { event in
                var row: [String: Any] = [
                    "id": event.id,
                    "time": Timestamp.string(event.createdAt),
                    "eventType": event.eventType,
                    "severity": event.severity.rawValue,
                    "message": redact(event.message),
                ]
                if let op = event.operationId { row["operationId"] = op }
                if let json = event.detailsJSON, let data = json.data(using: .utf8),
                   let details = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    row["details"] = details.mapValues { value -> Any in
                        (value as? String).map(redact) ?? value
                    }
                }
                return row
            }
            let document: [String: Any] = [
                "exportedBy": "MacVault",
                "redaction": redaction.rawValue,
                "eventCount": events.count,
                "events": rows,
            ]
            return try JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])

        case .csv:
            var lines = ["time,severity,event_type,operation_id,message,details"]
            for event in events {
                let fields = [Timestamp.string(event.createdAt), event.severity.rawValue, event.eventType,
                              event.operationId ?? "", redact(event.message), redact(event.detailsJSON ?? "")]
                lines.append(fields.map(csvField).joined(separator: ","))
            }
            return Data((lines.joined(separator: "\r\n") + "\r\n").utf8)
        }
    }

    /// RFC 4180 quoting, plus a leading apostrophe for cells a spreadsheet would treat as a formula.
    static func csvField(_ value: String) -> String {
        var text = value
        if let first = text.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) {
            text = "'" + text
        }
        if text.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) {
            return "\"" + text.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return text
    }

    static func redactHome(_ text: String, home: String, userName: String) -> String {
        var result = text
        let canonicalHome = PathUtilities.canonicalize(home)
        for candidate in Set([home, canonicalHome]) where candidate.count > 1 {
            result = result.replacingOccurrences(of: candidate, with: "~")
        }
        if userName.count >= 2 {
            result = replacingWholeWord(userName, with: "<user>", in: result)
        }
        return result
    }

    private static func replacingWholeWord(_ word: String, with replacement: String, in text: String) -> String {
        let pattern = "(?<![A-Za-z0-9_.-])" + NSRegularExpression.escapedPattern(for: word) + "(?![A-Za-z0-9_-])"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
    }
}
