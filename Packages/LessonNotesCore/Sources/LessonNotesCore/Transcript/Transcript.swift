import Foundation

public struct TranscriptSegment: Codable, Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) { self.start = start; self.end = end; self.text = text }
}

public struct TranscriptPart: Codable, Equatable, Sendable {
    public var recordingId: UUID
    public var filename: String
    public var recordedAt: Date?
    public var durationSec: Int
    public var segments: [TranscriptSegment]
    public init(recordingId: UUID, filename: String, recordedAt: Date?, durationSec: Int, segments: [TranscriptSegment]) {
        self.recordingId = recordingId
        self.filename = filename
        self.recordedAt = recordedAt
        self.durationSec = durationSec
        self.segments = segments
    }
}

/// A locally stored transcript (with timestamps and recording boundaries).
public struct StoredTranscript: Codable, Equatable, Sendable {
    public var jobId: UUID
    public var savedAt: Date
    public var model: String
    public var language: String
    public var parts: [TranscriptPart]

    public init(jobId: UUID, savedAt: Date, model: String, language: String, parts: [TranscriptPart]) {
        self.jobId = jobId
        self.savedAt = savedAt
        self.model = model
        self.language = language
        self.parts = parts
    }

    /// Plain text with `[mm:ss]` timestamps and `--- Part 2 (14:32) ---` dividers.
    public func renderedText(timeZone: TimeZone) -> String {
        var out: [String] = []
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_GB")
        tf.timeZone = timeZone
        tf.dateFormat = "HH:mm"
        for (i, part) in parts.enumerated() {
            if parts.count > 1 && i > 0 {
                let label = part.recordedAt.map { tf.string(from: $0) } ?? part.filename
                out.append("--- Part \(i + 1) (\(label)) ---")
            }
            for seg in part.segments {
                let t = TranscriptCleaner.clean(seg.text)
                if t.isEmpty { continue }
                out.append("[\(CoreFormat.timestamp(seg.start))] \(t)")
            }
        }
        return out.joined(separator: "\n")
    }

    public var wordCount: Int {
        parts.reduce(0) { $0 + $1.segments.reduce(0) { $0 + $1.text.split(whereSeparator: { $0.isWhitespace }).count } }
    }
}

public enum TranscriptCleaner {
    /// Strips Whisper special tokens such as `<|startoftranscript|>` / `<|0.00|>` and
    /// non-speech markers like `[BLANK_AUDIO]`.
    public static func clean(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"<\|[^|>]*\|>"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"\[(BLANK_AUDIO|MUSIC|NO_SPEECH|SILENCE)\]"#, with: "", options: [.regularExpression, .caseInsensitive])
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
