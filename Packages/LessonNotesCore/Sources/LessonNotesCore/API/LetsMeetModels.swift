import Foundation

public enum NoteStatus: String, Codable, Sendable, CaseIterable {
    case pending, published, rejected, deleted

    public var label: String {
        switch self {
        case .pending: return "Waiting for approval"
        case .published: return "Published"
        case .rejected: return "Rejected"
        case .deleted: return "Deleted"
        }
    }

    /// Published notes can be unpublished, so only rejected/deleted are truly final.
    public var isFinal: Bool { self == .rejected || self == .deleted }
}

public struct PingResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var keyId: String?
    public var serverTime: String?
    public var apiVersion: Int?
    enum CodingKeys: String, CodingKey { case ok, keyId = "key_id", serverTime = "server_time", apiVersion = "api_version" }
}

public struct RoomsResponse: Codable, Sendable {
    public var rooms: [Room]
}

public struct NoteSummary: Codable, Sendable, Equatable {
    public var overview: String?
    public var keyPoints: [String]?
    public var nextSteps: [String]?
    public var homework: String?
    public var vocabulary: [String]?
    public var praise: String?
    public var learningContent: String?
    public var workedExamples: [String]?
    public var keyQuotes: [String]?

    enum CodingKeys: String, CodingKey {
        case overview, keyPoints = "key_points", nextSteps = "next_steps", homework, vocabulary, praise,
             learningContent = "learning_content", workedExamples = "worked_examples", keyQuotes = "key_quotes"
    }

    public init(overview: String? = nil, keyPoints: [String]? = nil, nextSteps: [String]? = nil, homework: String? = nil,
                vocabulary: [String]? = nil, praise: String? = nil, learningContent: String? = nil,
                workedExamples: [String]? = nil, keyQuotes: [String]? = nil) {
        self.overview = overview
        self.keyPoints = keyPoints
        self.nextSteps = nextSteps
        self.homework = homework
        self.vocabulary = vocabulary
        self.praise = praise
        self.learningContent = learningContent
        self.workedExamples = workedExamples
        self.keyQuotes = keyQuotes
    }
}

public struct SubmissionRecording: Codable, Sendable, Equatable {
    public var filename: String
    public var durationSec: Int
    public var recordedAt: String?
    public var order: Int
    public var sha256: String?

    enum CodingKeys: String, CodingKey { case filename, durationSec = "duration_sec", recordedAt = "recorded_at", order, sha256 }

    public init(filename: String, durationSec: Int, recordedAt: String?, order: Int, sha256: String?) {
        self.filename = filename
        self.durationSec = durationSec
        self.recordedAt = recordedAt
        self.order = order
        self.sha256 = sha256
    }
}

public struct SubmissionGenerator: Codable, Sendable, Equatable {
    public var appVersion: String
    public var transcriptionModel: String
    public var summaryModel: String
    enum CodingKeys: String, CodingKey { case appVersion = "app_version", transcriptionModel = "transcription_model", summaryModel = "summary_model" }
    public init(appVersion: String, transcriptionModel: String, summaryModel: String) {
        self.appVersion = appVersion
        self.transcriptionModel = transcriptionModel
        self.summaryModel = summaryModel
    }
}

/// Body of `POST /notes` (spec §8.3). Only documented fields exist — there is
/// deliberately no way to attach audio or video.
public struct NoteSubmission: Codable, Sendable, Equatable {
    public var submissionId: String
    public var roomId: String
    public var lessonDate: String
    public var startedAt: String?
    public var endedAt: String?
    public var title: String
    public var summary: NoteSummary
    /// `nil` encodes as JSON `null` (transcript kept locally only).
    public var transcript: String?
    public var privateNotes: String?
    public var recordings: [SubmissionRecording]
    public var mode: ProcessingMode
    public var generator: SubmissionGenerator?

    enum CodingKeys: String, CodingKey {
        case submissionId = "submission_id", roomId = "room_id", lessonDate = "lesson_date", startedAt = "started_at",
             endedAt = "ended_at", title, summary, transcript, privateNotes = "private_notes", recordings, mode, generator
    }

    public init(submissionId: String, roomId: String, lessonDate: String, startedAt: String?, endedAt: String?, title: String,
                summary: NoteSummary, transcript: String?, privateNotes: String?, recordings: [SubmissionRecording],
                mode: ProcessingMode, generator: SubmissionGenerator?) {
        self.submissionId = submissionId
        self.roomId = roomId
        self.lessonDate = lessonDate
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.title = title
        self.summary = summary
        self.transcript = transcript
        self.privateNotes = privateNotes
        self.recordings = recordings
        self.mode = mode
        self.generator = generator
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(submissionId, forKey: .submissionId)
        try c.encode(roomId, forKey: .roomId)
        try c.encode(lessonDate, forKey: .lessonDate)
        try c.encodeIfPresent(startedAt, forKey: .startedAt)
        try c.encodeIfPresent(endedAt, forKey: .endedAt)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        if let transcript { try c.encode(transcript, forKey: .transcript) } else { try c.encodeNil(forKey: .transcript) }
        try c.encodeIfPresent(privateNotes, forKey: .privateNotes)
        try c.encode(recordings, forKey: .recordings)
        try c.encode(mode, forKey: .mode)
        try c.encodeIfPresent(generator, forKey: .generator)
    }

    /// Canonical JSON body.
    public func jsonData() throws -> Data { try JSONCoding.encoder().encode(self) }

    /// Hash of all content fields, used locally to detect "same id, different content".
    public func contentHash() -> String {
        var copy = self
        copy.submissionId = ""
        let data = (try? JSONCoding.encoder().encode(copy)) ?? Data()
        return SHA256Hasher.hex(of: data)
    }
}

public struct NoteStatusResponse: Codable, Sendable, Equatable {
    public var noteId: String?
    public var submissionId: String
    public var roomId: String?
    public var status: NoteStatus
    public var createdAt: String?
    public var updatedAt: String?
    public var publishedAt: String?
    public var replayed: Bool?
    /// Content version (integer, increments on every content change). Base for replacements.
    public var version: Int?

    enum CodingKeys: String, CodingKey {
        case noteId = "note_id", submissionId = "submission_id", roomId = "room_id", status, createdAt = "created_at",
             updatedAt = "updated_at", publishedAt = "published_at", replayed, version
    }

    public init(noteId: String?, submissionId: String, roomId: String? = nil, status: NoteStatus, createdAt: String? = nil,
                updatedAt: String? = nil, publishedAt: String? = nil, replayed: Bool? = nil, version: Int? = nil) {
        self.version = version
        self.noteId = noteId
        self.submissionId = submissionId
        self.roomId = roomId
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.replayed = replayed
    }
}

public struct BatchStatusResponse: Codable, Sendable {
    public var results: [NoteStatusResponse]
}

public struct APIFieldError: Codable, Sendable, Equatable {
    public var field: String
    public var message: String
}

public struct APIErrorBody: Codable, Sendable, Equatable {
    public var code: String
    public var message: String
    public var fields: [APIFieldError]?
    public var noteId: String?
    public var currentVersion: Int?
    public var updatedAt: String?
    public var lastChangedBy: String?
    enum CodingKeys: String, CodingKey {
        case code, message, fields, noteId = "note_id", currentVersion = "current_version", updatedAt = "updated_at", lastChangedBy = "last_changed_by"
    }
}

/// Body of `PATCH /notes/{note_id}` — replaces an existing note's content. The transcript,
/// room, date and recordings are never sent (the website rejects them).
public struct NoteReplacement: Codable, Sendable, Equatable {
    public var updateId: String
    public var baseVersion: Int
    public var title: String
    public var summary: NoteSummary
    /// `nil` clears the private notes on the website.
    public var privateNotes: String?
    public var generator: ReplacementGenerator

    enum CodingKeys: String, CodingKey {
        case updateId = "update_id", baseVersion = "base_version", title, summary, privateNotes = "private_notes", generator
    }

    public init(updateId: String, baseVersion: Int, title: String, summary: NoteSummary, privateNotes: String?, generator: ReplacementGenerator) {
        self.updateId = updateId
        self.baseVersion = baseVersion
        self.title = title
        self.summary = summary
        self.privateNotes = privateNotes
        self.generator = generator
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(updateId, forKey: .updateId)
        try c.encode(baseVersion, forKey: .baseVersion)
        try c.encode(title, forKey: .title)
        try c.encode(summary, forKey: .summary)
        if let privateNotes { try c.encode(privateNotes, forKey: .privateNotes) } else { try c.encodeNil(forKey: .privateNotes) }
        try c.encode(generator, forKey: .generator)
    }

    public func jsonData() throws -> Data { try JSONCoding.encoder().encode(self) }
}

public struct ReplacementGenerator: Codable, Sendable, Equatable {
    public var appVersion: String
    public var summaryModel: String
    enum CodingKeys: String, CodingKey { case appVersion = "app_version", summaryModel = "summary_model" }
    public init(appVersion: String, summaryModel: String) { self.appVersion = appVersion; self.summaryModel = summaryModel }
}

public struct NoteReplaceResponse: Codable, Sendable, Equatable {
    public var noteId: String?
    public var submissionId: String?
    public var status: NoteStatus
    public var version: Int?
    public var updatedAt: String?
    public var publishedAt: String?
    public var fieldsChanged: [String]?
    public var previousStatus: NoteStatus?
    public var replayed: Bool?

    enum CodingKeys: String, CodingKey {
        case noteId = "note_id", submissionId = "submission_id", status, version, updatedAt = "updated_at", publishedAt = "published_at",
             fieldsChanged = "fields_changed", previousStatus = "previous_status", replayed
    }

    public init(noteId: String?, submissionId: String?, status: NoteStatus, version: Int?, updatedAt: String? = nil, publishedAt: String? = nil,
                fieldsChanged: [String]? = nil, previousStatus: NoteStatus? = nil, replayed: Bool? = nil) {
        self.noteId = noteId
        self.submissionId = submissionId
        self.status = status
        self.version = version
        self.updatedAt = updatedAt
        self.publishedAt = publishedAt
        self.fieldsChanged = fieldsChanged
        self.previousStatus = previousStatus
        self.replayed = replayed
    }
}

public struct APIErrorEnvelope: Codable, Sendable {
    public var error: APIErrorBody
}
