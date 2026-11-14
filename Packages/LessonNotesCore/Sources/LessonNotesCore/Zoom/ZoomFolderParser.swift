import Foundation

/// Information parsed from a Zoom local-recording folder name such as
/// `2026-11-14 16.00.12 LetsMeet - EE` (local time of the meeting start).
public struct ZoomFolderInfo: Equatable, Sendable {
    public var year: Int
    public var month: Int
    public var day: Int
    public var hour: Int
    public var minute: Int
    public var second: Int
    /// Meeting topic as written in the folder name (meeting ID suffix removed).
    public var topic: String
    /// Topic exactly as it appeared, including any meeting ID suffix.
    public var rawTopic: String
    public var meetingID: String?

    /// `YYYY-MM-DD` — the folder date *is* the local lesson date.
    public var lessonDate: String { String(format: "%04d-%02d-%02d", year, month, day) }

    /// Absolute start time, interpreting the folder timestamp in `timeZone`
    /// (Zoom writes local wall-clock time, never UTC).
    public func startDate(in timeZone: TimeZone) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let comps = DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
        guard let d = cal.date(from: comps) else { return nil }
        // Reject non-existent local times (e.g. inside a DST gap) that Calendar silently shifts.
        let back = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
        guard back.year == year, back.month == month, back.day == day, back.hour == hour, back.minute == minute else { return nil }
        return d
    }
}

public enum ZoomFolderParser {
    // `YYYY-MM-DD HH.MM.SS Topic`; also tolerates `_`/`T` separators and `:` in times.
    private static let pattern = #"^\s*(\d{4})-(\d{2})-(\d{2})[ _T]+(\d{2})[.:](\d{2})[.:](\d{2})(?:\s+(.*))?$"#

    public static func parse(_ folderName: String) -> ZoomFolderInfo? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let ns = folderName as NSString
        guard let m = regex.firstMatch(in: folderName, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func int(_ i: Int) -> Int? { Int(ns.substring(with: m.range(at: i))) }
        guard let y = int(1), let mo = int(2), let d = int(3), let h = int(4), let mi = int(5), let s = int(6) else { return nil }
        guard (1990...2100).contains(y), (1...12).contains(mo), (1...31).contains(d),
              (0...23).contains(h), (0...59).contains(mi), (0...60).contains(s) else { return nil }
        // Validate the day exists in that month.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard let probe = cal.date(from: DateComponents(year: y, month: mo, day: d)),
              cal.component(.day, from: probe) == d else { return nil }

        var raw = ""
        if m.range(at: 7).location != NSNotFound { raw = ns.substring(with: m.range(at: 7)).trimmingCharacters(in: .whitespaces) }
        var topic = raw
        var meetingID: String?
        // Older Zoom versions append the numeric meeting ID: "Topic 98765432101".
        if let idRegex = try? NSRegularExpression(pattern: #"^(.*\S)\s+(\d{9,11})$"#),
           let im = idRegex.firstMatch(in: raw, range: NSRange(location: 0, length: (raw as NSString).length)) {
            topic = (raw as NSString).substring(with: im.range(at: 1))
            meetingID = (raw as NSString).substring(with: im.range(at: 2))
        }
        return ZoomFolderInfo(year: y, month: mo, day: d, hour: h, minute: mi, second: s,
                              topic: topic, rawTopic: raw, meetingID: meetingID)
    }

    /// Zoom cloud-recording file names embed a UTC timestamp:
    /// `GMT20261114-160012_Recording_1920x1080.mp4`.
    public static func parseCloudFileTimestamp(_ filename: String) -> Date? {
        guard let regex = try? NSRegularExpression(pattern: #"GMT(\d{4})(\d{2})(\d{2})-(\d{2})(\d{2})(\d{2})"#) else { return nil }
        let ns = filename as NSString
        guard let m = regex.firstMatch(in: filename, range: NSRange(location: 0, length: ns.length)) else { return nil }
        let v = (1...6).map { Int(ns.substring(with: m.range(at: $0))) ?? -1 }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        guard (1990...2100).contains(v[0]), (1...12).contains(v[1]), (1...31).contains(v[2]),
              (0...23).contains(v[3]), (0...59).contains(v[4]), (0...60).contains(v[5]) else { return nil }
        return cal.date(from: DateComponents(year: v[0], month: v[1], day: v[2], hour: v[3], minute: v[4], second: v[5]))
    }
}

/// Classification of files Zoom writes into a recording folder.
public enum RecordingFileKind: Equatable, Sendable {
    case video          // .mp4
    case audioOnly      // .m4a
    case conversionPlaceholder // .zoom / double_click_to_convert_*.zoom
    case other

    public static func classify(_ filename: String) -> RecordingFileKind {
        let lower = filename.lowercased()
        if lower.hasPrefix(".") { return .other }
        if lower.hasSuffix(".zoom") || lower.hasPrefix("double_click_to_convert") { return .conversionPlaceholder }
        if lower.hasSuffix(".mp4") { return .video }
        if lower.hasSuffix(".m4a") { return .audioOnly }
        return .other
    }

    public var isMedia: Bool { self == .video || self == .audioOnly }
}

/// Pure readiness rules from spec §5. The app supplies observations (sizes over time,
/// playability) and asks whether a file may be processed.
public enum RecordingReadiness {
    public static let stableInterval: TimeInterval = 20
    public static let requiredStableChecks = 2
    public static let minimumDuration: Double = 30

    public struct SizeObservation: Equatable, Sendable {
        public var size: Int64
        public var at: Date
        public init(size: Int64, at: Date) { self.size = size; self.at = at }
    }

    public enum Verdict: Equatable, Sendable {
        case ready
        case notMedia
        case conversionInProgress
        case stillWriting
        case needsMoreObservations
        case notPlayable
        case tooShort
    }

    /// - Parameters:
    ///   - siblings: names of all files in the same folder.
    ///   - observations: size samples, oldest first.
    ///   - playable/duration: from AVURLAsset; nil if not yet checked.
    public static func evaluate(filename: String, siblings: [String], observations: [SizeObservation],
                                playable: Bool?, durationSeconds: Double?, allowAudioOnly: Bool = true) -> Verdict {
        let kind = RecordingFileKind.classify(filename)
        guard kind == .video || (allowAudioOnly && kind == .audioOnly) else { return .notMedia }
        if siblings.contains(where: { RecordingFileKind.classify($0) == .conversionPlaceholder }) { return .conversionInProgress }
        guard isSizeStable(observations) else {
            if observations.count >= 2, let last = observations.last, let prev = observations.dropLast().last, last.size != prev.size {
                return .stillWriting
            }
            return .needsMoreObservations
        }
        guard let playable else { return .needsMoreObservations }
        if !playable { return .notPlayable }
        guard let durationSeconds else { return .needsMoreObservations }
        if durationSeconds <= minimumDuration { return .tooShort }
        return .ready
    }

    /// True when the size has been unchanged over at least `requiredStableChecks`
    /// consecutive checks spanning `stableInterval` each (i.e. ≥ 3 samples, 40 s).
    public static func isSizeStable(_ obs: [SizeObservation]) -> Bool {
        guard obs.count >= requiredStableChecks + 1 else { return false }
        let tail = Array(obs.suffix(requiredStableChecks + 1))
        guard let first = tail.first, first.size > 0 else { return false }
        guard tail.allSatisfy({ $0.size == first.size }) else { return false }
        for i in 1..<tail.count where tail[i].at.timeIntervalSince(tail[i - 1].at) < stableInterval - 0.5 {
            return false
        }
        return true
    }
}
