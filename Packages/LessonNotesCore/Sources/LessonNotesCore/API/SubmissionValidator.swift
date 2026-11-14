import Foundation

/// Local validation of a submission against spec §8.3, run before sending.
public enum SubmissionValidator {
    public struct Issue: Equatable, Sendable, CustomStringConvertible {
        public var field: String
        public var message: String
        public var description: String { "\(field): \(message)" }
    }

    static let idChars = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._:-")

    static func utf16Count(_ s: String) -> Int { s.utf16.count }

    /// Validates a `PATCH` replacement body (§ Replacing notes).
    public static func validate(_ r: NoteReplacement) -> [Issue] {
        var issues: [Issue] = []
        func add(_ f: String, _ m: String) { issues.append(Issue(field: f, message: m)) }
        if !(8...100).contains(r.updateId.count) || r.updateId.unicodeScalars.contains(where: { !idChars.contains($0) }) {
            add("update_id", "must be 8–100 characters of A–Z, a–z, 0–9 . _ : -")
        }
        if r.baseVersion < 1 { add("base_version", "must be an integer ≥ 1") }
        let t = r.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || utf16Count(r.title) > 200 { add("title", "must be 1–200 characters") }
        if let p = r.privateNotes, utf16Count(p) > 10_000 { add("private_notes", "must be at most 10000 characters") }
        let probe = NoteSubmission(submissionId: "probe-0000", roomId: String(repeating: "0", count: 32), lessonDate: "2026-01-01", startedAt: nil,
                                   endedAt: nil, title: "x", summary: r.summary, transcript: "x", privateNotes: nil, recordings: [], mode: .single, generator: nil)
        issues += validate(probe).filter { $0.field.hasPrefix("summary.") }
        if let body = try? r.jsonData(), body.count > APILimits.maxRequestBodyBytes { add("body", "request is larger than \(APILimits.maxRequestBodyBytes) bytes") }
        return issues
    }

    public static func validate(_ n: NoteSubmission) -> [Issue] {
        var issues: [Issue] = []
        func add(_ f: String, _ m: String) { issues.append(Issue(field: f, message: m)) }

        if !(8...100).contains(n.submissionId.count) || n.submissionId.unicodeScalars.contains(where: { !idChars.contains($0) }) {
            add("submission_id", "must be 8–100 characters of A–Z, a–z, 0–9 . _ : -")
        }
        if !Room.isValidRoomId(n.roomId) { add("room_id", "must be exactly 32 lowercase hex characters") }
        if CoreFormat.parseLessonDate(n.lessonDate, timeZone: TimeZone(identifier: "UTC")!) == nil {
            add("lesson_date", "must be YYYY-MM-DD")
        }
        for (f, v) in [("started_at", n.startedAt), ("ended_at", n.endedAt)] {
            if let v, CoreFormat.parseISO8601(v) == nil { add(f, "must be ISO 8601 with an offset") }
        }
        let t = n.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || utf16Count(n.title) > 200 { add("title", "must be 1–200 characters") }

        func checkString(_ f: String, _ v: String?, _ max: Int) {
            if let v, utf16Count(v) > max { add(f, "must be at most \(max) characters") }
        }
        func checkArray(_ f: String, _ v: [String]?, maxItems: Int, maxLen: Int) {
            guard let v else { return }
            if v.count > maxItems { add(f, "must have at most \(maxItems) items") }
            for (i, item) in v.enumerated() where item.isEmpty || utf16Count(item) > maxLen {
                add("\(f).\(i)", "must be 1–\(maxLen) characters")
            }
        }
        checkString("summary.overview", n.summary.overview, 2000)
        checkArray("summary.key_points", n.summary.keyPoints, maxItems: 30, maxLen: 500)
        checkArray("summary.next_steps", n.summary.nextSteps, maxItems: 20, maxLen: 500)
        checkString("summary.homework", n.summary.homework, 2000)
        checkArray("summary.vocabulary", n.summary.vocabulary, maxItems: 50, maxLen: 200)
        checkString("summary.praise", n.summary.praise, 1000)
        checkString("summary.learning_content", n.summary.learningContent, NoteLimits.learningContent)
        checkArray("summary.worked_examples", n.summary.workedExamples, maxItems: 20, maxLen: 5000)
        checkArray("summary.key_quotes", n.summary.keyQuotes, maxItems: 20, maxLen: 500)
        // The full transcript is mandatory for this app (never omitted or shortened).
        if let tr = n.transcript {
            if tr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { add("transcript", "is empty") }
            if tr.utf8.count > APILimits.maxTranscriptBytes { add("transcript", "must be at most \(APILimits.maxTranscriptBytes) bytes (UTF-8)") }
        } else {
            add("transcript", "is missing — the full transcript must be uploaded")
        }
        checkString("private_notes", n.privateNotes, 10_000)
        if n.recordings.count > 20 { add("recordings", "must have at most 20 items") }
        for (i, r) in n.recordings.enumerated() {
            if r.filename.isEmpty || utf16Count(r.filename) > 260 { add("recordings.\(i).filename", "must be 1–260 characters") }
            if r.durationSec < 0 { add("recordings.\(i).duration_sec", "must not be negative") }
            if let h = r.sha256, !(h.count == 64 && h.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) })) {
                add("recordings.\(i).sha256", "must be 64 lowercase hex characters")
            }
            if let ra = r.recordedAt, CoreFormat.parseISO8601(ra) == nil { add("recordings.\(i).recorded_at", "must be ISO 8601") }
        }
        if let g = n.generator {
            for (f, v) in [("generator.app_version", g.appVersion), ("generator.transcription_model", g.transcriptionModel), ("generator.summary_model", g.summaryModel)]
            where utf16Count(v) > 100 { add(f, "must be at most 100 characters") }
        }
        if let body = try? n.jsonData(), body.count > APILimits.maxRequestBodyBytes {
            add("body", "request is larger than \(APILimits.maxRequestBodyBytes) bytes")
        }
        return issues
    }
}
