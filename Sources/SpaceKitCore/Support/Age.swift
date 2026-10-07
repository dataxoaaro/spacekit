import Foundation

/// A span of time written the way people talk about file age: `14d`, `2w`, `3mo`, `1y`, `12h`, `60 days`.
public struct Age: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var seconds: TimeInterval

    public init(seconds: TimeInterval) { self.seconds = seconds }
    public static func days(_ n: Double) -> Age { Age(seconds: n * 86_400) }
    public static func hours(_ n: Double) -> Age { Age(seconds: n * 3600) }

    public var days: Double { seconds / 86_400 }

    public static func < (lhs: Age, rhs: Age) -> Bool { lhs.seconds < rhs.seconds }

    private static let units: [(suffixes: [String], seconds: Double)] = [
        (["years", "year", "yr", "y"], 365 * 86_400),
        (["months", "month", "mo"], 30 * 86_400),
        (["weeks", "week", "wk", "w"], 7 * 86_400),
        (["days", "day", "d"], 86_400),
        (["hours", "hour", "hr", "h"], 3600),
        (["minutes", "minute", "min", "m"], 60),
    ]

    public static func parse(_ text: String) -> Age? {
        let s = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !s.isEmpty else { return nil }
        for (suffixes, multiplier) in units {
            for suffix in suffixes where s.hasSuffix(suffix) {
                let number = s.dropLast(suffix.count).trimmingCharacters(in: .whitespaces)
                if let value = Double(number), value >= 0 { return Age(seconds: value * multiplier) }
            }
        }
        // A bare number means days, the most common unit for cleanup rules.
        if let value = Double(s), value >= 0 { return .days(value) }
        return nil
    }

    /// Compact form for YAML: `14d`, `2w`, `3mo`.
    public var description: String {
        let d = days
        if d >= 365, d.truncatingRemainder(dividingBy: 365) == 0 { return "\(Int(d / 365))y" }
        if d >= 30, d.truncatingRemainder(dividingBy: 30) == 0 { return "\(Int(d / 30))mo" }
        if d >= 7, d.truncatingRemainder(dividingBy: 7) == 0 { return "\(Int(d / 7))w" }
        if d >= 1, d == d.rounded() { return "\(Int(d))d" }
        let h = seconds / 3600
        if h == h.rounded() { return "\(Int(h))h" }
        return "\(Int(seconds / 60))m"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            seconds = number * 86_400
        } else {
            let text = try container.decode(String.self)
            guard let parsed = Age.parse(text) else {
                throw DecodingError.dataCorruptedError(
                    in: container, debugDescription: "Invalid age '\(text)'. Use values like 14d, 2w, 3mo or 1y.")
            }
            seconds = parsed.seconds
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension Date {
    /// "18 days ago", "in 4 days", "just now".
    public func relativeDescription(now: Date = Date()) -> String {
        let delta = now.timeIntervalSince(self)
        if abs(delta) < 60 { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: self, relativeTo: now)
    }
}
