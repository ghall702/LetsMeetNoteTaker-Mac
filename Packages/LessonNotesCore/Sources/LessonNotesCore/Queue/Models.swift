import Foundation

public enum ProcessingMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case single, combined, separate
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .single: return "Single recording"
        case .combined: return "Combine into one set of notes"
        case .separate: return "Process separately"
        }
    }
}

public enum JobStage: String, Codable, Sendable, CaseIterable {
    case held          // confirmed, waiting for "Start" (auto-process off)
    case queued
    case extracting
    case transcribing
    case summarising
    case submitting
    case submitted
    case failed
    case cancelled

    public var label: String {
        switch self {
        case .held: return "Ready to start"
        case .queued: return "Queued"
        case .extracting: return "Extracting audio"
        case .transcribing: return "Transcribing"
        case .summarising: return "Summarising"
        case .submitting: return "Submitting"
        case .submitted: return "Submitted"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Stages that the engine still has work to do for.
    public var isActive: Bool { [.queued, .extracting, .transcribing, .summarising, .submitting].contains(self) }
    public var needsNetwork: Bool { self == .summarising || self == .submitting }
}

public struct JobError: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case general
        /// Upload exceeds the website size limits: needs attention, never retried automatically.
        case payloadTooLarge
        case submissionConflict
        case validation
        case authentication
        case openAI
        case recordingMissing
        case cancelled
        /// OpenAI billing: credits/quota exhausted. Needs George to add credit; never auto-retried.
        case openAICredits
        /// OpenAI key, permission or model problem: fix in Settings, then retry.
        case openAISettings
        /// Blocked by the local free-allowance protection.
        case allowanceProtection
    }
    public var message: String
    public var kind: Kind
    public var httpStatus: Int?
    public var code: String?
    public var occurredAt: Date
    /// Original technical message, when `message` is a friendlier rewrite.
    public var detail: String?
    public init(message: String, kind: Kind = .general, httpStatus: Int? = nil, code: String? = nil, occurredAt: Date = Date(), detail: String? = nil) {
        self.message = message
        self.kind = kind
        self.httpStatus = httpStatus
        self.code = code
        self.occurredAt = occurredAt
        self.detail = detail
    }

    public static let openAIBillingURL = URL(string: "https://platform.openai.com/settings/organization/billing/overview")!
    public static let creditsMessage = "OpenAI API credits exhausted. Your transcription has been saved. Add credits to your OpenAI account, then click Fix & Retry to generate the lesson notes."

    /// Recognises OpenAI "no credits / insufficient quota / billing" wording in any error text.
    public static func looksLikeOpenAICredits(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("insufficient_quota") || t.contains("no credits") || t.contains("credits remaining")
            || t.contains("exceeded your current quota") || t.contains("billing") && t.contains("openai")
            || t.contains("add credits")
    }
}

/// A recording as stored with a lesson.
public struct RecordingRef: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var filename: String
    /// Last known path (display + fallback when the bookmark cannot be resolved).
    public var path: String
    /// Security-scoped bookmark (sandbox access across launches).
    public var bookmark: Data?
    public var durationSec: Int
    public var recordedAt: Date?
    public var sha256: String?
    public var fileSize: Int64
    public var order: Int

    public init(id: UUID = UUID(), filename: String, path: String, bookmark: Data? = nil, durationSec: Int, recordedAt: Date?,
                sha256: String?, fileSize: Int64, order: Int) {
        self.id = id
        self.filename = filename
        self.path = path
        self.bookmark = bookmark
        self.durationSec = durationSec
        self.recordedAt = recordedAt
        self.sha256 = sha256
        self.fileSize = fileSize
        self.order = order
    }
}

public struct Job: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var submissionId: String
    public var partLetter: String
    /// Recordings processed by this job, in order (several for combined mode).
    public var recordingIds: [UUID]
    public var stage: JobStage
    /// Stage to resume at after a failure or cancellation.
    public var resumeStage: JobStage?
    public var statusMessage: String?
    public var error: JobError?
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var firstRetryAt: Date?
    public var hasTranscript: Bool
    public var transcriptPurgedAt: Date?
    public var transcriptionModel: String?
    public var summaryModel: String?
    public var reasoningEffort: ReasoningEffort?
    public var promptSnapshot: ResolvedPrompt?
    public var notes: GeneratedNotes?
    /// Exact JSON body sent; retries resend it so the content never changes under the same id.
    public var submissionPayload: Data?
    public var noteId: String?
    public var remoteStatus: NoteStatus?
    public var remoteCheckedAt: Date?
    public var remoteUpdatedAt: String?
    public var submittedAt: Date?
    public var publishedAt: Date?
    public var replayed: Bool?
    public var createdAt: Date
    public var updatedAt: Date
    public var completedStagesAt: [String: Date]
    // Added in version 2 (optional so data saved by version 1 still loads).
    /// Website content `version` last seen (base for replacements).
    public var remoteVersion: Int?
    /// Local history of generated notes (original + regenerated versions).
    public var noteVersions: [NoteVersion]?
    /// A replacement queued for `PATCH /notes/{id}`.
    public var replacement: PendingReplacement?
    /// Anything changed to fit the website limits when the current notes were generated.
    public var notesAdjustments: [String]?
    // Added in 1.4: lesson length sync (website `lesson_length`, seconds).
    /// Value the website is known to hold (from a submission or the lesson-length endpoint).
    public var lessonLengthSynced: Int?
    public var lessonLengthNextAttemptAt: Date?
    public var lessonLengthAttempts: Int?
    /// Set when the website rejected the value (not retried automatically).
    public var lessonLengthError: String?
    /// "Write Notes Now": this job may use OpenAI even while OpenAI is paused.
    public var openAIOverride: Bool?
    /// Lesson files (copies kept in the app's storage). Editable until notes are written.
    public var attachments: [LessonAttachment]?
    /// The files frozen with the upload payload (sent identically on every retry).
    public var submittedAttachments: [LessonAttachment]?

    /// Files can be added or removed until notes are written and the upload is prepared.
    public var attachmentsEditable: Bool {
        notes == nil && submissionPayload == nil && ![.submitted, .submitting, .cancelled].contains(stage)
    }

    public init(id: UUID = UUID(), submissionId: String, partLetter: String, recordingIds: [UUID], stage: JobStage = .queued,
                createdAt: Date = Date()) {
        self.id = id
        self.submissionId = submissionId
        self.partLetter = partLetter
        self.recordingIds = recordingIds
        self.stage = stage
        self.attempts = 0
        self.hasTranscript = false
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.completedStagesAt = [:]
    }

    /// Single status chip for the UI.
    public var displayStatus: String {
        switch stage {
        case .submitted: return (remoteStatus ?? .pending).label
        case .failed:
            switch error?.kind {
            case .payloadTooLarge?: return "Needs attention"
            case .openAICredits?: return "OpenAI credits needed"
            default: return "Failed"
            }
        default: return stage.label
        }
    }
}

public struct Lesson: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var roomId: String
    public var studentId: UUID?
    public var pupilName: String
    public var roomName: String
    /// `YYYY-MM-DD` local lesson date.
    public var lessonDate: String
    public var startedAt: Date?
    public var endedAt: Date?
    public var dateSource: DateSource
    public var mode: ProcessingMode
    public var meetingTopic: String
    public var sourceFolder: String
    public var timeZoneIdentifier: String
    public var recordings: [RecordingRef]
    public var jobs: [Job]
    public var createdAt: Date
    public var reprocessOf: UUID?

    public init(id: UUID = UUID(), roomId: String, studentId: UUID?, pupilName: String, roomName: String, lessonDate: String,
                startedAt: Date?, endedAt: Date?, dateSource: DateSource, mode: ProcessingMode, meetingTopic: String,
                sourceFolder: String, timeZoneIdentifier: String, recordings: [RecordingRef], jobs: [Job] = [],
                createdAt: Date = Date(), reprocessOf: UUID? = nil) {
        self.id = id
        self.roomId = roomId
        self.studentId = studentId
        self.pupilName = pupilName
        self.roomName = roomName
        self.lessonDate = lessonDate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.dateSource = dateSource
        self.mode = mode
        self.meetingTopic = meetingTopic
        self.sourceFolder = sourceFolder
        self.timeZoneIdentifier = timeZoneIdentifier
        self.recordings = recordings
        self.jobs = jobs
        self.createdAt = createdAt
        self.reprocessOf = reprocessOf
    }

    public var timeZone: TimeZone { TimeZone(identifier: timeZoneIdentifier) ?? .current }

    public func recordings(for job: Job) -> [RecordingRef] {
        job.recordingIds.compactMap { id in recordings.first { $0.id == id } }
    }

    public var title: String {
        jobs.compactMap { $0.notes?.title }.first ?? meetingTopic
    }
}

/// A lesson the folder watcher found, waiting for George to review.
public struct PendingDetection: Codable, Identifiable, Equatable, Sendable {
    public var id: String { folderPath }
    public var folderPath: String
    public var recordings: [ScannedRecording]
    public var detectedAt: Date
    public var notified: Bool
    public init(folderPath: String, recordings: [ScannedRecording], detectedAt: Date = Date(), notified: Bool = false) {
        self.folderPath = folderPath
        self.recordings = recordings
        self.detectedAt = detectedAt
        self.notified = notified
    }
}

public enum SubmissionID {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz0123456789")

    /// `mac-<install UUID>-<lesson date>-<HHmm>-<part letter>-<random 6>` (spec §8.4).
    public static func make(installId: UUID, lessonDate: String, startedAt: Date?, timeZone: TimeZone, partLetter: String,
                            random: () -> String = { randomSuffix() }) -> String {
        let hhmm = startedAt.map { CoreFormat.hourMinute($0, timeZone: timeZone) } ?? "0000"
        let date = lessonDate.isEmpty ? "0000-00-00" : lessonDate
        return "mac-\(installId.uuidString)-\(date)-\(hhmm)-\(partLetter)-\(random())"
    }

    public static func randomSuffix() -> String {
        String((0..<6).map { _ in alphabet.randomElement()! })
    }

    public static func partLetter(_ index: Int) -> String {
        let letters = Array("abcdefghijklmnopqrstuvwxyz")
        if index < letters.count { return String(letters[index]) }
        return String(letters[index / 26 - 1]) + String(letters[index % 26])
    }
}
