import Foundation

// MARK: - Recordings API (LESSON-RECORDINGS-API.md)

/// A recording as the website reports it.
public struct RemoteRecording: Codable, Sendable, Equatable {
    public var recordingId: String
    public var noteId: String?
    public var uploadId: String?
    public var title: String?
    public var originalFilename: String?
    public var sizeBytes: Int64?
    public var durationSec: Int?
    public var mimeType: String?
    /// uploading | ready | failed | delete_pending | deleted
    public var status: String
    public var replacementPending: Bool?
    public var lastError: String?
    public var uploadedAt: String?
    public var createdAt: String?
    public var updatedAt: String?

    enum CodingKeys: String, CodingKey {
        case recordingId = "recording_id", noteId = "note_id", uploadId = "upload_id", title, originalFilename = "original_filename",
             sizeBytes = "size_bytes", durationSec = "duration_sec", mimeType = "mime_type", status,
             replacementPending = "replacement_pending", lastError = "last_error", uploadedAt = "uploaded_at",
             createdAt = "created_at", updatedAt = "updated_at"
    }

    public init(recordingId: String, noteId: String? = nil, uploadId: String? = nil, status: String, sizeBytes: Int64? = nil,
                replacementPending: Bool? = nil, lastError: String? = nil) {
        self.recordingId = recordingId; self.noteId = noteId; self.uploadId = uploadId; self.status = status
        self.sizeBytes = sizeBytes; self.replacementPending = replacementPending; self.lastError = lastError
    }

    public var isReady: Bool { status == "ready" }
    public var isGone: Bool { status == "deleted" || status == "delete_pending" }
}

/// A signed, expiring URL on the media server (never stored on disk — re-requested on restart).
public struct SignedUpload: Codable, Sendable, Equatable {
    public var method: String
    public var url: URL
    public var headers: [String: String]?
    public var expiresAt: String?
    enum CodingKeys: String, CodingKey { case method, url, headers, expiresAt = "expires_at" }
    public init(method: String = "PUT", url: URL, headers: [String: String]? = ["Content-Type": "video/mp4"], expiresAt: String? = nil) {
        self.method = method; self.url = url; self.headers = headers; self.expiresAt = expiresAt
    }
}

public struct RecordingUploadResponse: Codable, Sendable, Equatable {
    public var recording: RemoteRecording
    public var replayed: Bool?
    /// nil when the recording is already ready.
    public var upload: SignedUpload?
    public init(recording: RemoteRecording, replayed: Bool? = nil, upload: SignedUpload?) {
        self.recording = recording; self.replayed = replayed; self.upload = upload
    }
}

public struct RecordingEnvelope: Codable, Sendable, Equatable {
    public var recording: RemoteRecording
    public var replayed: Bool?
    public var deleted: Bool?
    public init(recording: RemoteRecording, replayed: Bool? = nil, deleted: Bool? = nil) {
        self.recording = recording; self.replayed = replayed; self.deleted = deleted
    }
}

public struct NoteRecordingsResponse: Codable, Sendable, Equatable {
    public var noteId: String?
    public var recordings: [RemoteRecording]
    enum CodingKeys: String, CodingKey { case noteId = "note_id", recordings }
    public init(noteId: String?, recordings: [RemoteRecording]) { self.noteId = noteId; self.recordings = recordings }
}

public struct RecordingAvailability: Codable, Sendable, Equatable {
    public var recordingId: String?
    public var status: String?
    public var available: Bool
    public var reason: String?
    enum CodingKeys: String, CodingKey { case recordingId = "recording_id", status, available, reason }
    public init(recordingId: String?, status: String?, available: Bool, reason: String?) {
        self.recordingId = recordingId; self.status = status; self.available = available; self.reason = reason
    }
}

public struct RecordingPlayback: Codable, Sendable, Equatable {
    public var recordingId: String?
    public var url: URL
    public var expiresAt: String?
    enum CodingKeys: String, CodingKey { case recordingId = "recording_id", url, expiresAt = "expires_at" }
    public init(recordingId: String?, url: URL, expiresAt: String?) { self.recordingId = recordingId; self.url = url; self.expiresAt = expiresAt }
}

public struct RegisterUploadRequest: Codable, Sendable, Equatable {
    public var uploadId: String
    public var noteId: String
    public var title: String
    public var originalFilename: String
    public var sizeBytes: Int64
    public var mimeType: String = "video/mp4"
    enum CodingKeys: String, CodingKey {
        case uploadId = "upload_id", noteId = "note_id", title, originalFilename = "original_filename", sizeBytes = "size_bytes", mimeType = "mime_type"
    }
    public init(uploadId: String, noteId: String, title: String, originalFilename: String, sizeBytes: Int64) {
        self.uploadId = uploadId; self.noteId = noteId; self.title = title; self.originalFilename = originalFilename; self.sizeBytes = sizeBytes
    }
}

public struct ReplaceUploadRequest: Codable, Sendable, Equatable {
    public var uploadId: String
    public var originalFilename: String
    public var sizeBytes: Int64
    enum CodingKeys: String, CodingKey { case uploadId = "upload_id", originalFilename = "original_filename", sizeBytes = "size_bytes" }
    public init(uploadId: String, originalFilename: String, sizeBytes: Int64) {
        self.uploadId = uploadId; self.originalFilename = originalFilename; self.sizeBytes = sizeBytes
    }
}

public struct CompleteUploadRequest: Codable, Sendable, Equatable {
    public var sizeBytes: Int64
    public var durationSec: Int?
    public var mimeType: String = "video/mp4"
    enum CodingKeys: String, CodingKey { case sizeBytes = "size_bytes", durationSec = "duration_sec", mimeType = "mime_type" }
    public init(sizeBytes: Int64, durationSec: Int?) { self.sizeBytes = sizeBytes; self.durationSec = durationSec }
}

public enum VideoLimits {
    /// `size_bytes` may be at most 8 GiB.
    public static let maxBytes: Int64 = 8 * 1024 * 1024 * 1024
}

// MARK: - Local state

/// Video upload for one lesson job, persisted in library.json. Separate from note processing:
/// a video failure never affects the job's notes, transcript or submission.
public struct VideoUploadState: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable {
        case queued        // waiting to start (note id / existing video / source checks next)
        case merging       // combining recordings into one MP4
        case registering   // POST /recordings/upload
        case uploading     // PUT to the signed URL
        case completing    // POST /recordings/{id}/complete
        case ready         // the website confirmed status "ready"
        case failed        // needs George (or waiting for an automatic retry, see nextAttemptAt)
        case skipped       // nothing to do (note deleted on the website)
        case deleted       // the remote recording was deleted by George

        public var isActive: Bool { [.queued, .merging, .registering, .uploading, .completing].contains(self) }
    }
    public enum Origin: String, Codable, Sendable { case automatic, backfill, manual }
    public enum ErrorKind: String, Codable, Sendable {
        case network, server, rateLimited, authentication, recordingsMissing, mergeFailed, tooLarge, noteMissing, noteDeleted,
             remoteDeleted, rejected, other
    }

    public var origin: Origin
    public var stage: Stage
    /// Idempotency key for `POST /recordings/upload`; stable for this job.
    public var uploadId: String
    public var noteId: String?
    public var recordingId: String?
    public var sourceRecordingIds: [UUID]
    public var needsMerge: Bool
    /// File name of the merged MP4 inside the videos folder (combined lessons only).
    public var mergedFilename: String?
    public var fileSize: Int64?
    public var durationSec: Int?
    public var originalFilename: String
    public var title: String
    /// Stage reached last ("resolved", "checked", "merged", "registered", "uploaded", "ready").
    public var lastCompletedStage: String?
    public var checkedExisting: Bool
    public var attempts: Int
    public var reuploads: Int
    public var nextAttemptAt: Date?
    public var firstRetryAt: Date?
    public var lastError: String?
    public var errorKind: ErrorKind?
    public var remoteStatus: String?
    /// Adopted from an existing website recording instead of uploading.
    public var adoptedExisting: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var completedAt: Date?
    public var replacement: VideoReplacement?
    /// DELETE returned 202: hidden from pupils, file not yet removed.
    public var deletePending: Bool
    /// Stage to resume from when George presses Retry after a failure.
    public var resumeStage: Stage?
    /// Bumped when a new upload id is needed (e.g. after the remote recording was deleted).
    public var generation: Int = 1

    public init(origin: Origin, uploadId: String, noteId: String?, sourceRecordingIds: [UUID], originalFilename: String, title: String, now: Date) {
        self.origin = origin
        self.stage = .queued
        self.uploadId = uploadId
        self.noteId = noteId
        self.sourceRecordingIds = sourceRecordingIds
        self.needsMerge = sourceRecordingIds.count > 1
        self.originalFilename = originalFilename
        self.title = title
        self.checkedExisting = false
        self.attempts = 0
        self.reuploads = 0
        self.adoptedExisting = false
        self.createdAt = now
        self.updatedAt = now
        self.deletePending = false
    }

    public static func uploadId(for jobId: UUID, generation: Int = 1) -> String {
        "mac-video-\(jobId.uuidString.lowercased())" + (generation > 1 ? "-\(generation)" : "")
    }
}

/// Replacing an uploaded video with another MP4 chosen by George (POST /recordings/{id}/replace).
public struct VideoReplacement: Codable, Sendable, Equatable {
    public enum Stage: String, Codable, Sendable { case registering, uploading, completing, failed }
    public var uploadId: String
    public var filename: String
    public var path: String
    public var bookmark: Data?
    public var fileSize: Int64
    public var durationSec: Int?
    public var stage: Stage
    public var attempts: Int
    public var nextAttemptAt: Date?
    public var firstRetryAt: Date?
    public var lastError: String?
    public var createdAt: Date

    public init(filename: String, path: String, bookmark: Data?, fileSize: Int64, durationSec: Int?, now: Date) {
        self.uploadId = "mac-video-replace-" + UUID().uuidString.lowercased()
        self.filename = filename; self.path = path; self.bookmark = bookmark; self.fileSize = fileSize; self.durationSec = durationSec
        self.stage = .registering; self.attempts = 0; self.createdAt = now
    }
}

/// What a check of the website found for a historical note (before backfilling).
public struct VideoProbe: Codable, Sendable, Equatable {
    public var checkedAt: Date
    public var noteId: String?
    public var noteDeleted: Bool
    public var existingRecordingId: String?
    public var existingStatus: String?
    public var error: String?
    public init(checkedAt: Date, noteId: String?, noteDeleted: Bool = false, existingRecordingId: String? = nil, existingStatus: String? = nil, error: String? = nil) {
        self.checkedAt = checkedAt; self.noteId = noteId; self.noteDeleted = noteDeleted
        self.existingRecordingId = existingRecordingId; self.existingStatus = existingStatus; self.error = error
    }
}

/// Video upload settings.
public struct VideoSettings: Codable, Sendable, Equatable {
    /// Upload the lesson video automatically after the notes are submitted (new lessons only).
    public var autoUpload = true
    /// Simultaneous video uploads (1–3).
    public var maxConcurrentUploads = 1
    /// Retry network/server errors automatically.
    public var autoRetry = true
    /// Give up retrying after this many hours.
    public var retryWindowHours = 24
    /// Pauses all video work (automatic and backfill).
    public var paused = false
    /// Delete a merged MP4 once the website confirms the upload.
    public var deleteMergedAfterUpload = true
    /// Custom folder for merged MP4s (security-scoped bookmark); nil = the app's own data folder.
    public var mergedFolderBookmark: Data?
    public var mergedFolderPath: String?
    /// Lessons submitted from this time on are uploaded automatically; older ones need the backfill.
    public var automaticSince: Date?

    public init() {}

    enum CodingKeys: String, CodingKey {
        case autoUpload, maxConcurrentUploads, autoRetry, retryWindowHours, paused, deleteMergedAfterUpload, mergedFolderBookmark, mergedFolderPath, automaticSince
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = VideoSettings()
        autoUpload = try c.decodeIfPresent(Bool.self, forKey: .autoUpload) ?? d.autoUpload
        maxConcurrentUploads = min(3, max(1, try c.decodeIfPresent(Int.self, forKey: .maxConcurrentUploads) ?? 1))
        autoRetry = try c.decodeIfPresent(Bool.self, forKey: .autoRetry) ?? d.autoRetry
        retryWindowHours = min(168, max(1, try c.decodeIfPresent(Int.self, forKey: .retryWindowHours) ?? 24))
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? d.paused
        deleteMergedAfterUpload = try c.decodeIfPresent(Bool.self, forKey: .deleteMergedAfterUpload) ?? d.deleteMergedAfterUpload
        mergedFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .mergedFolderBookmark)
        mergedFolderPath = try c.decodeIfPresent(String.self, forKey: .mergedFolderPath)
        automaticSince = try c.decodeIfPresent(Date.self, forKey: .automaticSince)
    }
}
