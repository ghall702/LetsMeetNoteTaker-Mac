import Foundation

public enum CoreFormat {
    /// `YYYY-MM-DD` in the given time zone.
    public static func lessonDateString(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    public static func parseLessonDate(_ s: String, timeZone: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: s), f.string(from: d) == s else { return nil }
        return d
    }

    /// ISO 8601 with an explicit offset in the given zone, e.g. `2026-11-14T16:00:12+00:00`.
    public static func iso8601(_ date: Date, timeZone: TimeZone = TimeZone(identifier: "UTC")!) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: date)
    }

    public static func parseISO8601(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// `HHmm` in the given zone.
    public static func hourMinute(_ date: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "HHmm"
        return f.string(from: date)
    }

    /// Long UK style date, e.g. `14 November 2026`.
    public static func longUKDate(_ lessonDate: String) -> String {
        let utc = TimeZone(identifier: "UTC")!
        guard let d = parseLessonDate(lessonDate, timeZone: utc) else { return lessonDate }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = utc
        f.dateFormat = "d MMMM yyyy"
        return f.string(from: d)
    }

    /// `hh:mm:ss` or `mm:ss` timestamp.
    public static func timestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    public static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = (seconds % 3600) / 60, s = seconds % 60
        if h > 0 { return "\(h)h \(m)m" }
        if m > 0 { return "\(m)m \(s)s" }
        return "\(s)s"
    }

    /// Truncate to at most `maxCharacters` characters (Swift characters, which is
    /// conservative compared with the server's code-unit counting for emoji).
    public static func truncate(_ s: String, maxCharacters: Int) -> String {
        if s.count <= maxCharacters { return s }
        return String(s.prefix(max(0, maxCharacters - 1))) + "…"
    }
}

public enum JSONCoding {
    public static func encoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, enc in
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            var c = enc.singleValueContainer()
            try c.encode(f.string(from: date))
        }
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { dec in
            let c = try dec.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = CoreFormat.parseISO8601(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Bad date \(s)")
        }
        return d
    }
}

/// Finder-like natural ordering ("zoom_2" < "zoom_10").
public func naturalLess(_ a: String, _ b: String) -> Bool {
    a.compare(b, options: [.numeric, .caseInsensitive]) == .orderedAscending
}
