import Foundation

public enum TranscriptState: Equatable, Sendable {
    case valid
    case missing
    case corrupt(String)
}

/// Copies the data folder (all JSON files and every transcript, including those of failed
/// jobs) into `Backups/<date>-<label>/` and verifies the copy before anything is changed.
/// Whisper models are not copied (they can be downloaded again). Backups are never deleted.
public enum StorageBackup {
    public enum BackupError: Error, LocalizedError {
        case verificationFailed(String)
        public var errorDescription: String? {
            if case .verificationFailed(let m) = self { return "The backup of your data could not be verified (\(m)). Nothing has been changed." }
            return nil
        }
    }

    public static func create(from dir: URL, label: String, now: Date = Date()) throws -> URL {
        let fm = FileManager.default
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        var dest = dir.appendingPathComponent("Backups", isDirectory: true).appendingPathComponent("\(f.string(from: now))-\(label)", isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: dest.path) { dest = dest.deletingLastPathComponent().appendingPathComponent("\(f.string(from: now))-\(label)-\(n)"); n += 1 }
        try fm.createDirectory(at: dest.appendingPathComponent("transcripts"), withIntermediateDirectories: true)

        var copied: [(URL, URL)] = []
        for item in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where item.pathExtension == "json" {
            let to = dest.appendingPathComponent(item.lastPathComponent)
            try fm.copyItem(at: item, to: to)
            copied.append((item, to))
        }
        let tdir = dir.appendingPathComponent("transcripts")
        for item in (try? fm.contentsOfDirectory(at: tdir, includingPropertiesForKeys: nil)) ?? [] where item.pathExtension == "json" {
            let to = dest.appendingPathComponent("transcripts").appendingPathComponent(item.lastPathComponent)
            try fm.copyItem(at: item, to: to)
            copied.append((item, to))
        }
        // Verify: every file byte-identical, and the history readable from the backup.
        for (src, dst) in copied {
            guard let a = try? Data(contentsOf: src), let b = try? Data(contentsOf: dst), a == b else {
                throw BackupError.verificationFailed("\(src.lastPathComponent) differs")
            }
        }
        var lessonCount = 0
        let libCopy = dest.appendingPathComponent("library.json")
        if fm.fileExists(atPath: libCopy.path) {
            guard let data = try? Data(contentsOf: libCopy),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let lessons = obj["lessons"] as? [Any] else { throw BackupError.verificationFailed("library.json is not readable") }
            lessonCount = lessons.count
        }
        let transcripts = copied.filter { $0.1.deletingLastPathComponent().lastPathComponent == "transcripts" }.count
        let manifest: [String: Any] = ["createdAt": CoreFormat.iso8601(now), "label": label, "files": copied.count,
                                       "lessons": lessonCount, "transcripts": transcripts,
                                       "note": "Automatic backup made before upgrading. It is never deleted automatically."]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: dest.appendingPathComponent("backup-manifest.json"))
        return dest
    }
}

/// Repairs job stages from what is actually saved, so earlier work is always reused.
public enum JobRecovery {
    /// - Returns: number of jobs changed.
    @discardableResult
    public static func normalise(_ lessons: inout [Lesson], transcriptState: (UUID) -> TranscriptState) -> Int {
        var changes = 0
        for li in lessons.indices {
            for ji in lessons[li].jobs.indices {
                var j = lessons[li].jobs[ji]
                let original = j
                let state = transcriptState(j.id)
                // Flag follows the file (covers a quit between saving the file and recording it).
                if state == .valid && !j.hasTranscript { j.hasTranscript = true; j.transcriptPurgedAt = nil }
                if state == .missing && j.hasTranscript { j.hasTranscript = false }

                if j.stage != .submitted {
                    let resumeAt: JobStage = j.notes != nil ? .submitting : .summarising
                    switch j.stage {
                    case .queued, .extracting, .transcribing:
                        if state == .valid { j.stage = resumeAt; j.statusMessage = nil }
                    case .summarising:
                        if j.notes != nil { j.stage = .submitting }
                    case .failed, .cancelled:
                        if state == .valid, j.resumeStage == nil || [.queued, .extracting, .transcribing].contains(j.resumeStage!) {
                            j.resumeStage = resumeAt
                        }
                        if j.resumeStage == .summarising && j.notes != nil { j.resumeStage = .submitting }
                    default:
                        break
                    }
                }
                // v1.1 reported exhausted OpenAI credit as an "Unexpected OpenAI response".
                if var e = j.error, e.kind != .openAICredits, JobError.looksLikeOpenAICredits(e.message) {
                    e.detail = e.detail ?? e.message
                    e.message = JobError.creditsMessage
                    e.kind = .openAICredits
                    e.code = "insufficient_quota"
                    j.error = e
                }
                if j != original { lessons[li].jobs[ji] = j; changes += 1 }
            }
        }
        return changes
    }

    public enum RetryPlan: Equatable, Sendable {
        /// Valid transcript saved: OpenAI summarisation only (no Whisper).
        case summarise
        /// Transcript and notes saved: website submission only.
        case submit
        /// Website replacement or other: no pipeline work.
        case resume(JobStage)
        /// Transcription is needed. `reason` is set when a transcript was expected but is unusable.
        case transcribe(reason: String?)
    }

    public static func retryPlan(for job: Job, transcriptState: TranscriptState) -> RetryPlan {
        if job.notes != nil && (job.resumeStage == .submitting || job.submissionPayload != nil) && transcriptState == .valid { return .submit }
        if job.notes != nil && job.resumeStage == .submitting { return .submit }
        switch transcriptState {
        case .valid:
            return job.notes != nil ? .submit : .summarise
        case .missing:
            if let purged = job.transcriptPurgedAt {
                return .transcribe(reason: "The saved transcript was deleted on \(CoreFormat.lessonDateString(purged, timeZone: .current)) by the retention setting or manually, so the recordings must be transcribed again.")
            }
            return .transcribe(reason: job.hasTranscript ? "The saved transcript file is missing, so the recordings must be transcribed again." : nil)
        case .corrupt(let why):
            return .transcribe(reason: "The saved transcript could not be used (\(why)), so the recordings must be transcribed again. The damaged file is kept.")
        }
    }
}
