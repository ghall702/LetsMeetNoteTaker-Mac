import Foundation

/// One generated version of a job's notes, kept locally.
public struct NoteVersion: Codable, Identifiable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case original, regenerated }
    public enum State: String, Codable, Sendable {
        case current      // the notes in use (and on the website, if submitted)
        case draft        // regenerated, waiting for review
        case uploading    // accepted; replacement queued for the website
        case superseded   // an earlier current version
        case discarded    // rejected by George, or the website version was kept
    }

    public var id: UUID
    public var createdAt: Date
    public var kind: Kind
    public var state: State
    public var notes: GeneratedNotes
    public var model: String
    public var effort: ReasoningEffort?
    public var promptSource: ResolvedPrompt.Source?
    /// Effective instructions used (snapshot), for reference.
    public var promptSnapshot: String?
    public var additionalInstructions: String?
    public var adjustments: [String]
    /// Website version this draft was generated against (base for the replacement).
    public var baseVersion: Int?
    /// Website version after this version was uploaded.
    public var websiteVersion: Int?

    public init(id: UUID = UUID(), createdAt: Date, kind: Kind, state: State, notes: GeneratedNotes, model: String,
                effort: ReasoningEffort? = nil, promptSource: ResolvedPrompt.Source? = nil, promptSnapshot: String? = nil,
                additionalInstructions: String? = nil, adjustments: [String] = [], baseVersion: Int? = nil, websiteVersion: Int? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.state = state
        self.notes = notes
        self.model = model
        self.effort = effort
        self.promptSource = promptSource
        self.promptSnapshot = promptSnapshot
        self.additionalInstructions = additionalInstructions
        self.adjustments = adjustments
        self.baseVersion = baseVersion
        self.websiteVersion = websiteVersion
    }
}

/// A replacement of an existing website note, persisted so it survives restarts and offline periods.
public struct PendingReplacement: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case queued       // waiting to send (or retrying)
        case conflict     // website changed since generation: George must choose
        case noteDeleted  // the website note no longer exists
        case failed       // non-retryable error; George can retry or discard
    }

    public var versionId: UUID
    public var updateId: String
    /// Website version the replacement was generated against; nil = look it up before sending.
    public var baseVersion: Int?
    /// Exact body sent (frozen once built) so retries reuse the same `update_id` and content.
    public var body: Data?
    public var state: State
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var firstRetryAt: Date?
    public var message: String?
    public var conflictCurrentVersion: Int?
    public var conflictChangedBy: String?
    public var conflictUpdatedAt: String?
    public var createdAt: Date
    /// When set, the replacement is a multipart PATCH that also replaces the note's files with these.
    public var files: [LessonAttachment]?

    public init(versionId: UUID, updateId: String, baseVersion: Int?, createdAt: Date) {
        self.versionId = versionId
        self.updateId = updateId
        self.baseVersion = baseVersion
        self.state = .queued
        self.attempts = 0
        self.createdAt = createdAt
    }

    public static func makeUpdateId(now: Date = Date(), random: () -> String = { SubmissionID.randomSuffix() + SubmissionID.randomSuffix() }) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return "mac-replace-\(f.string(from: now))-\(random())"
    }
}

extension Job {
    /// Versions including a synthesised "original" entry for notes created before version history existed.
    public var allNoteVersions: [NoteVersion] {
        var v = noteVersions ?? []
        if v.isEmpty, let notes {
            v.append(NoteVersion(id: Self.originalVersionId(for: id), createdAt: completedStagesAt["summarised"] ?? createdAt, kind: .original,
                                 state: .current, notes: notes, model: summaryModel ?? "unknown", effort: reasoningEffort,
                                 promptSource: promptSnapshot?.source, promptSnapshot: promptSnapshot?.effectiveInstructions,
                                 adjustments: notesAdjustments ?? [], websiteVersion: remoteVersion))
        }
        return v
    }

    /// Stable id for the synthesised original version.
    static func originalVersionId(for jobId: UUID) -> UUID {
        var u = jobId.uuid
        u.0 ^= 0xFF
        return UUID(uuid: u)
    }

    public var currentVersion: NoteVersion? { allNoteVersions.last { $0.state == .current } }
    public var draftVersions: [NoteVersion] { allNoteVersions.filter { $0.state == .draft } }

    mutating func materialiseVersions() { noteVersions = allNoteVersions }
}


/// A queued `PUT /notes/{id}/files` (swap files only; approval status unchanged).
public struct PendingFileUpdate: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case queued, failed, noteDeleted }
    public var updateId: String
    /// The exact set sent (frozen, so retries reuse the same `update_id` and files).
    public var files: [LessonAttachment]
    public var state: State
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var firstRetryAt: Date?
    public var message: String?
    public var createdAt: Date

    public init(files: [LessonAttachment], createdAt: Date, updateId: String? = nil) {
        self.files = files
        self.updateId = updateId ?? Self.makeUpdateId(now: createdAt)
        self.state = .queued
        self.attempts = 0
        self.createdAt = createdAt
    }

    public static func makeUpdateId(now: Date = Date()) -> String {
        "mac-files-" + PendingReplacement.makeUpdateId(now: now).dropFirst("mac-replace-".count)
    }
}
