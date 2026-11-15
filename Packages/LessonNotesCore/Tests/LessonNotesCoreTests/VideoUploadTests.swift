import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

// MARK: - Mocks (no real recordings, no network)

final class MockRecordingsAPI: RecordingsAPI, @unchecked Sendable {
    let calls = Box<[String]>([])
    let registered = Box<[RegisterUploadRequest]>([])
    let completed = Box<[CompleteUploadRequest]>([])
    var existing: [String: [RemoteRecording]] = [:]       // note id → recordings
    var noteIds: [String: NoteStatusResponse] = [:]       // submission id → status
    var registerErrors: [Error] = []
    var completeErrors: [Error] = []
    var completeStatus = "ready"
    var deleteFully = true
    var counter = 0
    var byUpload: [String: String] = [:]

    func log(_ s: String) { calls.mutate { $0.append(s) } }

    func registerUpload(_ r: RegisterUploadRequest) async throws -> RecordingUploadResponse {
        log("register \(r.uploadId)")
        registered.mutate { $0.append(r) }
        if !registerErrors.isEmpty { throw registerErrors.removeFirst() }
        let id = byUpload[r.uploadId] ?? { counter += 1; let n = "rec-\(counter)"; byUpload[r.uploadId] = n; return n }()
        return RecordingUploadResponse(recording: RemoteRecording(recordingId: id, noteId: r.noteId, uploadId: r.uploadId, status: "uploading"),
                                       replayed: false, upload: SignedUpload(url: URL(string: "https://media.test/u?t=\(id)-\(registered.value.count)")!))
    }
    func completeUpload(recordingId: String, _ r: CompleteUploadRequest) async throws -> RecordingEnvelope {
        log("complete \(recordingId)")
        completed.mutate { $0.append(r) }
        if !completeErrors.isEmpty { throw completeErrors.removeFirst() }
        return RecordingEnvelope(recording: RemoteRecording(recordingId: recordingId, status: completeStatus, sizeBytes: r.sizeBytes))
    }
    func recording(id: String) async throws -> RemoteRecording { log("get \(id)"); return RemoteRecording(recordingId: id, status: "ready") }
    func recordings(noteId: String) async throws -> [RemoteRecording] { log("list \(noteId)"); return existing[noteId] ?? [] }
    func availability(recordingId: String) async throws -> RecordingAvailability { RecordingAvailability(recordingId: recordingId, status: "ready", available: true, reason: nil) }
    func playback(recordingId: String, download: Bool) async throws -> RecordingPlayback { RecordingPlayback(recordingId: recordingId, url: URL(string: "https://media.test/v")!, expiresAt: nil) }
    func reportFailed(recordingId: String, error: String) async throws -> RemoteRecording { RemoteRecording(recordingId: recordingId, status: "failed") }
    func replaceUpload(recordingId: String, _ r: ReplaceUploadRequest) async throws -> RecordingUploadResponse {
        log("replace \(recordingId) \(r.uploadId)")
        return RecordingUploadResponse(recording: RemoteRecording(recordingId: recordingId, status: "ready", replacementPending: true),
                                       upload: SignedUpload(url: URL(string: "https://media.test/u?t=replace")!))
    }
    func deleteRecording(id: String) async throws -> (RemoteRecording?, Bool) {
        log("delete \(id)")
        return (RemoteRecording(recordingId: id, status: deleteFully ? "deleted" : "delete_pending"), deleteFully)
    }
    func noteStatus(_ ref: String) async throws -> NoteStatusResponse {
        log("status \(ref)")
        return noteIds[ref] ?? NoteStatusResponse(noteId: "resolved-\(ref.suffix(6))", submissionId: ref, status: .published)
    }
}

final class MockUploader: SignedUploading, @unchecked Sendable {
    let puts = Box<[(String, Int64, URL)]>([])
    var errors: [Error] = []
    func upload(file: URL, size: Int64, to target: SignedUpload, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        puts.mutate { $0.append((file.path, size, target.url)) }
        if !errors.isEmpty { throw errors.removeFirst() }
        progress(size / 2, size); progress(size, size)
    }
}

final class MockMedia: VideoMediaProviding, @unchecked Sendable {
    var sizes: [String: Int64] = [:]        // path → size; missing = not found
    let merges = Box<[[String]]>([])
    var mergeError: Error?
    var mergedSizeOverride: Int64?
    func sourceInfo(_ rec: RecordingRef) async -> SourceFile {
        if let s = sizes[rec.path] { return SourceFile(exists: true, size: s) }
        return SourceFile(exists: false, size: 0)
    }
    func merge(_ recs: [RecordingRef], to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MergedVideo {
        merges.mutate { $0.append(recs.map(\.filename)) }
        if let mergeError { throw mergeError }
        let size = mergedSizeOverride ?? recs.reduce(0) { $0 + (sizes[$1.path] ?? 0) }
        try Data("merged:\(recs.map(\.filename).joined(separator: ","))".utf8).write(to: output)
        progress(1)
        return MergedVideo(size: size, durationSec: recs.reduce(0) { $0 + $1.durationSec })
    }
    func validateMerged(_ url: URL) async -> MergedVideo? {
        FileManager.default.fileExists(atPath: url.path) ? MergedVideo(size: mergedSizeOverride ?? 0, durationSec: 0) : nil
    }
    func withAccess(bookmark: Data?, path: String, _ body: @Sendable (URL) async throws -> Void) async throws {
        try await body(URL(fileURLWithPath: path))
    }
}

struct VideoHarness {
    let h: Harness
    let api = MockRecordingsAPI()
    let uploader = MockUploader()
    let media = MockMedia()
    let videos: URL

    init(automaticSince: Date? = Date(timeIntervalSince1970: 1_799_000_000)) throws {
        h = try Harness()
        videos = tempDir().appendingPathComponent("Videos", isDirectory: true)
        h.store.updateSettings { $0.video.automaticSince = automaticSince }
    }

    func engine() -> VideoUploadEngine {
        let a = api, cl = h.clock, v = videos
        return VideoUploadEngine(store: h.store, deps: VideoDependencies(makeAPI: { a }, media: media, uploader: uploader, isOnline: { true },
                                                                         videosDirectory: { v }), now: { cl.value }, probePacing: 0)
    }

    /// Adds a lesson, makes its recordings "exist" and submits the notes.
    func submitted(_ mode: ProcessingMode, recordings n: Int, sizes: [Int64]? = nil) async throws -> Lesson {
        let l = try h.addLesson(mode: mode, recordings: n)
        for (i, r) in l.recordings.enumerated() { media.sizes[r.path] = sizes?[i] ?? Int64(1_000_000 * (i + 1)) }
        await h.engine().runUntilIdle()
        return h.store.lesson(containingJob: l.jobs[0].id)!
    }
}

final class VideoUploadTests: XCTestCase {
    // MARK: Client

    func testRecordingsClientRequests() async throws {
        let replies: [String: (Int, String)] = [
            "POST /api/public/lesson-notes/recordings/upload": (201, #"{"recording":{"recording_id":"r1","note_id":"n1","upload_id":"mac-video-x","status":"uploading"},"replayed":false,"upload":{"method":"PUT","url":"https://mediahub.test/u?t=abc","headers":{"Content-Type":"video/mp4"},"expires_at":"2026-11-15T18:00:00Z"}}"#),
            "POST /api/public/lesson-notes/recordings/r1/complete": (200, #"{"recording":{"recording_id":"r1","status":"ready"},"replayed":false}"#),
            "GET /api/public/lesson-notes/notes/n1/recordings": (200, #"{"note_id":"n1","recordings":[{"recording_id":"r1","status":"ready","size_bytes":734003200}]}"#),
            "GET /api/public/lesson-notes/recordings/r1/availability": (200, #"{"recording_id":"r1","status":"ready","available":true,"reason":null}"#),
            "GET /api/public/lesson-notes/recordings/r1/playback": (200, #"{"recording_id":"r1","url":"https://mediahub.test/v?t=1","expires_at":"x"}"#),
            "PATCH /api/public/lesson-notes/recordings/r1": (200, #"{"recording":{"recording_id":"r1","status":"failed"}}"#),
            "POST /api/public/lesson-notes/recordings/r1/replace": (200, #"{"recording":{"recording_id":"r1","status":"ready","replacement_pending":true},"upload":{"method":"PUT","url":"https://mediahub.test/u?t=new"},"replayed":false}"#),
            "DELETE /api/public/lesson-notes/recordings/r1": (202, #"{"recording":{"recording_id":"r1","status":"delete_pending"},"deleted":false}"#),
            "GET /api/public/lesson-notes/recordings/r1": (200, #"{"recording":{"recording_id":"r1","status":"ready"}}"#),
        ]
        let t = StubTransport { r in
            let key = "\(r.httpMethod ?? "") \(r.url!.path)"
            let (code, body) = replies[key] ?? (404, #"{"error":{"code":"recording_not_found","message":"no"}}"#)
            return StubTransport.json(code, body)
        }
        let c = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_K", transport: t)
        let reg = try await c.registerUpload(RegisterUploadRequest(uploadId: "mac-video-x", noteId: "n1", title: "Lesson recording", originalFilename: "a.mp4", sizeBytes: 734003200))
        XCTAssertEqual(reg.upload?.url.absoluteString, "https://mediahub.test/u?t=abc")
        XCTAssertEqual(reg.upload?.headers?["Content-Type"], "video/mp4")
        XCTAssertEqual(bodyJSON(t.requests.value[0]) as NSDictionary, ["upload_id": "mac-video-x", "note_id": "n1", "title": "Lesson recording",
                                                                       "original_filename": "a.mp4", "size_bytes": 734003200, "mime_type": "video/mp4"] as NSDictionary)
        XCTAssertEqual(t.requests.value[0].value(forHTTPHeaderField: "Authorization"), "Bearer ghln_K")
        let done = try await c.completeUpload(recordingId: "r1", CompleteUploadRequest(sizeBytes: 734003200, durationSec: 3540))
        XCTAssertTrue(done.recording.isReady)
        XCTAssertEqual(bodyJSON(t.requests.value[1]) as NSDictionary, ["size_bytes": 734003200, "duration_sec": 3540, "mime_type": "video/mp4"] as NSDictionary)
        let listed = try await c.recordings(noteId: "n1")
        XCTAssertEqual(listed.first?.sizeBytes, 734003200)
        let avail = try await c.availability(recordingId: "r1")
        XCTAssertTrue(avail.available)
        _ = try await c.playback(recordingId: "r1", download: true)
        XCTAssertEqual(t.requests.value.last?.url?.query, "download=1")
        _ = try await c.reportFailed(recordingId: "r1", error: "Export crashed")
        XCTAssertEqual(bodyJSON(t.requests.value.last!) as NSDictionary, ["status": "failed", "error": "Export crashed"] as NSDictionary)
        let rep = try await c.replaceUpload(recordingId: "r1", ReplaceUploadRequest(uploadId: "mac-video-replace-1", originalFilename: "fixed.mp4", sizeBytes: 9))
        XCTAssertEqual(rep.recording.replacementPending, true)
        let (_, gone) = try await c.deleteRecording(id: "r1")
        XCTAssertFalse(gone, "202 = delete pending")
        let got = try await c.recording(id: "r1")
        XCTAssertEqual(got.status, "ready")
        do { _ = try await c.recording(id: "zz"); XCTFail() } catch let e as LetsMeetAPIError { XCTAssertEqual(e.code, "recording_not_found") }
    }

    // MARK: Automatic uploads

    func testNewLessonUploadsAutomatically() async throws {
        let v = try VideoHarness()
        let l = try await v.submitted(.single, recordings: 1)
        let jid = l.jobs[0].id
        await v.engine().runUntilIdle()
        let s = try XCTUnwrap(v.h.store.job(id: jid)?.video)
        XCTAssertEqual(s.stage, .ready)
        XCTAssertEqual(s.origin, .automatic)
        XCTAssertEqual(s.uploadId, "mac-video-\(jid.uuidString.lowercased())")
        XCTAssertEqual(s.noteId, "note-0")
        XCTAssertEqual(s.recordingId, "rec-1")
        XCTAssertEqual(v.api.calls.value, ["list note-0", "register \(s.uploadId)", "complete rec-1"])
        XCTAssertEqual(v.api.registered.value.first?.sizeBytes, 1_000_000)
        XCTAssertEqual(v.api.registered.value.first?.originalFilename, "zoom_0.mp4")
        XCTAssertEqual(v.uploader.puts.value.map(\.0), ["/tmp/zoom_0.mp4"], "the original is streamed; nothing merged")
        XCTAssertTrue(v.media.merges.value.isEmpty)
        XCTAssertEqual(v.api.completed.value.first?.durationSec, 600)
        XCTAssertEqual(v.h.submitter.bodies.value.count, 1, "notes not resubmitted")
        XCTAssertEqual(v.h.store.job(id: jid)?.stage, .submitted)
    }

    func testAutomaticUploadsCanBeTurnedOff() async throws {
        let v = try VideoHarness()
        v.h.store.updateSettings { $0.video.autoUpload = false }
        let l = try await v.submitted(.single, recordings: 1)
        await v.engine().runUntilIdle()
        XCTAssertNil(v.h.store.job(id: l.jobs[0].id)?.video)
    }

    func testCombinedRecordingsBecomeOneMP4InSavedOrder() async throws {
        let v = try VideoHarness()
        let l = try await v.submitted(.combined, recordings: 3, sizes: [100, 200, 300])
        let jid = l.jobs[0].id
        // Change the saved order: the merge must follow it.
        v.h.store.updateJob(id: jid) { $0.recordingIds = [l.recordings[2].id, l.recordings[0].id, l.recordings[1].id]; $0.video = nil }
        let lesson = v.h.store.lesson(containingJob: jid)!
        v.h.store.updateJob(id: jid) { $0.video = VideoQueue.makeState(lesson: lesson, job: lesson.jobs[0], origin: .automatic, now: Date()) }
        await v.engine().runUntilIdle()
        let s = try XCTUnwrap(v.h.store.job(id: jid)?.video)
        XCTAssertEqual(s.stage, .ready)
        XCTAssertEqual(v.media.merges.value, [["zoom_2.mp4", "zoom_0.mp4", "zoom_1.mp4"]])
        XCTAssertEqual(v.api.registered.value.count, 1, "one video for the combined note")
        XCTAssertEqual(v.api.registered.value[0].sizeBytes, 600)
        XCTAssertTrue(v.api.registered.value[0].originalFilename.hasSuffix("combined.mp4"))
        XCTAssertEqual(v.uploader.puts.value.count, 1)
        XCTAssertTrue(v.uploader.puts.value[0].0.hasPrefix(v.videos.path))
        XCTAssertEqual(v.api.completed.value.first?.durationSec, 1_800)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v.uploader.puts.value[0].0), "merged file cleaned up after ready")
        XCTAssertNil(s.mergedFilename)
    }

    func testMergedFileKeptWhenCleanupOff() async throws {
        let v = try VideoHarness()
        v.h.store.updateSettings { $0.video.deleteMergedAfterUpload = false }
        let l = try await v.submitted(.combined, recordings: 2)
        await v.engine().runUntilIdle()
        let s = try XCTUnwrap(v.h.store.job(id: l.jobs[0].id)?.video)
        XCTAssertNotNil(s.mergedFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v.videos.appendingPathComponent(s.mergedFilename!).path))
        XCTAssertEqual(VideoQueue.leftoverMergedFiles(store: v.h.store, directory: v.videos).count, 1, "no longer needed: offered for cleanup")
    }

    func testSeparatePartsUploadToTheirOwnNotes() async throws {
        let v = try VideoHarness()
        let l = try await v.submitted(.separate, recordings: 2)
        await v.engine().runUntilIdle()
        let states = l.jobs.map { v.h.store.job(id: $0.id)!.video! }
        XCTAssertEqual(states.map(\.stage), [.ready, .ready])
        XCTAssertEqual(Set(v.api.registered.value.map(\.noteId)), ["note-0", "note-1"])
        XCTAssertEqual(Set(v.uploader.puts.value.map(\.0)), ["/tmp/zoom_0.mp4", "/tmp/zoom_1.mp4"])
        XCTAssertTrue(v.media.merges.value.isEmpty)
        XCTAssertTrue(states.allSatisfy { $0.title.hasPrefix("Lesson recording (part ") })
    }

    // MARK: Recovery & errors

    func testExpiredLinkIsRenewedWithSameUploadId() async throws {
        let v = try VideoHarness()
        v.uploader.errors = [SignedUploadError.expired]
        let l = try await v.submitted(.single, recordings: 1)
        await v.engine().runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: l.jobs[0].id)?.video?.stage, .ready)
        XCTAssertEqual(v.api.registered.value.count, 2)
        XCTAssertEqual(Set(v.api.registered.value.map(\.uploadId)).count, 1, "same upload_id → same recording")
        XCTAssertNotEqual(v.uploader.puts.value[0].2, v.uploader.puts.value[1].2, "fresh URL")
    }

    func testInterruptedUploadResumesAfterRestartWithoutReMerging() async throws {
        let v = try VideoHarness()
        v.h.store.updateSettings { $0.video.deleteMergedAfterUpload = false }
        v.uploader.errors = [SignedUploadError.network("The network connection was lost.")]
        let l = try await v.submitted(.combined, recordings: 2)
        let jid = l.jobs[0].id
        await v.engine().runUntilIdle()
        var s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .registering, "next attempt asks for a fresh link")
        XCTAssertNotNil(s.nextAttemptAt)
        XCTAssertEqual(s.lastCompletedStage, "registered")
        XCTAssertNotNil(s.mergedFilename)
        // Quit and relaunch: a new store and engine read the saved state.
        let reopened = try LibraryStore(directory: v.h.store.directory)
        reopened.updateJob(id: jid) { $0.video?.nextAttemptAt = nil }
        let a = v.api, cl = v.h.clock, dir = v.videos
        let engine2 = VideoUploadEngine(store: reopened, deps: VideoDependencies(makeAPI: { a }, media: v.media, uploader: v.uploader, isOnline: { true },
                                                                                  videosDirectory: { dir }), now: { cl.value }, probePacing: 0)
        await engine2.runUntilIdle()
        s = reopened.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .ready)
        XCTAssertEqual(v.media.merges.value.count, 1, "merged file reused")
        XCTAssertEqual(Set(v.api.registered.value.map(\.uploadId)).count, 1)
        XCTAssertEqual(v.api.calls.value.filter { $0.hasPrefix("complete") }.count, 1)
    }

    func testCompleteRetriesWithoutReuploadThenReuploadsOnFileMissing() async throws {
        let v = try VideoHarness()
        v.api.completeErrors = [LetsMeetAPIError(httpStatus: 503, code: "storage_unavailable", message: "Media server unreachable", retryAfter: 30)]
        let l = try await v.submitted(.single, recordings: 1)
        let jid = l.jobs[0].id
        let engine = v.engine()
        await engine.runUntilIdle()
        var s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .completing, "file is safe on the server; only complete is retried")
        XCTAssertEqual(s.nextAttemptAt, v.h.clock.value.addingTimeInterval(30))
        XCTAssertEqual(v.uploader.puts.value.count, 1)
        v.api.completeErrors = [LetsMeetAPIError(httpStatus: 422, code: "file_missing", message: "The media server doesn't have the file")]
        v.h.store.updateJob(id: jid) { $0.video?.nextAttemptAt = nil }
        await engine.runUntilIdle()
        s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .ready)
        XCTAssertEqual(v.uploader.puts.value.count, 2, "uploaded again after file_missing")
        XCTAssertEqual(s.reuploads, 1)
    }

    func testRateLimitAuthAndConflicts() async throws {
        let v = try VideoHarness()
        v.api.registerErrors = [LetsMeetAPIError(httpStatus: 429, code: "rate_limited", message: "slow", retryAfter: 120)]
        let l = try await v.submitted(.single, recordings: 1)
        let jid = l.jobs[0].id
        let engine = v.engine()
        await engine.runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: jid)?.video?.nextAttemptAt, v.h.clock.value.addingTimeInterval(120))
        // Revoked key: stops, no automatic retry.
        v.api.registerErrors = [LetsMeetAPIError(httpStatus: 403, code: "key_revoked", message: "revoked")]
        v.h.store.updateJob(id: jid) { $0.video?.nextAttemptAt = nil }
        await engine.runUntilIdle()
        var s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .failed)
        XCTAssertEqual(s.errorKind, .authentication)
        XCTAssertNil(s.nextAttemptAt)
        // Duplicate upload id used elsewhere → a new one.
        v.api.registerErrors = [LetsMeetAPIError(httpStatus: 409, code: "upload_conflict", message: "used")]
        await engine.retry(jobId: jid)
        await engine.runUntilIdle()
        v.h.store.updateJob(id: jid) { $0.video?.nextAttemptAt = nil }
        await engine.runUntilIdle()
        s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .ready)
        XCTAssertTrue(s.uploadId.hasSuffix("-2"))
    }

    func testMissingRecordingsAndTooLarge() async throws {
        let v = try VideoHarness()
        let l = try await v.submitted(.single, recordings: 1)
        v.media.sizes = [:]
        await v.engine().runUntilIdle()
        var s = v.h.store.job(id: l.jobs[0].id)!.video!
        XCTAssertEqual(s.stage, .failed)
        XCTAssertEqual(s.errorKind, .recordingsMissing)
        XCTAssertTrue(v.api.registered.value.isEmpty)
        // Too large (> 8 GiB): reported, never uploaded or truncated.
        let v2 = try VideoHarness()
        let l2 = try await v2.submitted(.single, recordings: 1, sizes: [VideoLimits.maxBytes + 1])
        await v2.engine().runUntilIdle()
        s = v2.h.store.job(id: l2.jobs[0].id)!.video!
        XCTAssertEqual(s.errorKind, .tooLarge)
        XCTAssertTrue(v2.api.registered.value.isEmpty)
        // A merged file over the limit is kept for manual handling.
        let v3 = try VideoHarness()
        v3.media.mergedSizeOverride = VideoLimits.maxBytes + 10
        let l3 = try await v3.submitted(.combined, recordings: 2)
        await v3.engine().runUntilIdle()
        s = v3.h.store.job(id: l3.jobs[0].id)!.video!
        XCTAssertEqual(s.errorKind, .tooLarge)
        XCTAssertTrue(FileManager.default.fileExists(atPath: v3.videos.appendingPathComponent(s.mergedFilename!).path))
        XCTAssertTrue(v3.api.registered.value.isEmpty)
    }

    func testMergeFailureAndAutoRetryOff() async throws {
        let v = try VideoHarness()
        v.media.mergeError = NSError(domain: "AVFoundation", code: -11800, userInfo: [NSLocalizedDescriptionKey: "Export failed"])
        let l = try await v.submitted(.combined, recordings: 2)
        let engine = v.engine()
        await engine.runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: l.jobs[0].id)?.video?.errorKind, .mergeFailed)
        v.media.mergeError = nil
        await engine.retry(jobId: l.jobs[0].id)
        await engine.runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: l.jobs[0].id)?.video?.stage, .ready)
        // With automatic retry off, a server error stops for George.
        let v2 = try VideoHarness()
        v2.h.store.updateSettings { $0.video.autoRetry = false }
        v2.api.registerErrors = [LetsMeetAPIError(httpStatus: 500, code: "server_error", message: "oops")]
        let l2 = try await v2.submitted(.single, recordings: 1)
        await v2.engine().runUntilIdle()
        XCTAssertEqual(v2.h.store.job(id: l2.jobs[0].id)?.video?.stage, .failed)
    }

    func testPauseStopsVideoWork() async throws {
        let v = try VideoHarness()
        v.h.store.updateSettings { $0.video.paused = true }
        let l = try await v.submitted(.single, recordings: 1)
        let engine = v.engine()
        await engine.runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: l.jobs[0].id)?.video?.stage, .queued, "queued but not started")
        XCTAssertTrue(v.api.calls.value.isEmpty)
        v.h.store.updateSettings { $0.video.paused = false }
        await engine.runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: l.jobs[0].id)?.video?.stage, .ready)
    }

    // MARK: Existing videos, note ids

    func testExistingVideoIsAdoptedNotDuplicated() async throws {
        let v = try VideoHarness()
        v.api.existing["note-0"] = [RemoteRecording(recordingId: "already", status: "ready"), RemoteRecording(recordingId: "old", status: "deleted")]
        let l = try await v.submitted(.single, recordings: 1)
        await v.engine().runUntilIdle()
        let s = v.h.store.job(id: l.jobs[0].id)!.video!
        XCTAssertEqual(s.stage, .ready)
        XCTAssertTrue(s.adoptedExisting)
        XCTAssertEqual(s.recordingId, "already")
        XCTAssertTrue(v.api.registered.value.isEmpty)
        XCTAssertTrue(v.uploader.puts.value.isEmpty)
    }

    func testNoteIdResolvedFromSubmissionId() async throws {
        let v = try VideoHarness()
        let l = try await v.submitted(.single, recordings: 1)
        let jid = l.jobs[0].id
        let sid = v.h.store.job(id: jid)!.submissionId
        v.h.store.updateJob(id: jid) { $0.noteId = nil; $0.video = nil }
        v.api.noteIds[sid] = NoteStatusResponse(noteId: "real-note", submissionId: sid, status: .published)
        let engine = v.engine()
        await engine.enqueue(jobIds: [jid], origin: .manual)
        await engine.runUntilIdle()
        XCTAssertTrue(v.api.calls.value.contains("status \(sid)"), "resolved via the status API, not guessed")
        XCTAssertEqual(v.api.registered.value.first?.noteId, "real-note")
        // A note deleted on the website is skipped.
        let l2 = try await v.submitted(.single, recordings: 1)
        let j2 = l2.jobs[0].id
        let sid2 = v.h.store.job(id: j2)!.submissionId
        v.h.store.updateJob(id: j2) { $0.noteId = nil; $0.video = nil }
        v.api.noteIds[sid2] = NoteStatusResponse(noteId: nil, submissionId: sid2, status: .deleted)
        await engine.enqueue(jobIds: [j2], origin: .manual)
        await engine.runUntilIdle()
        XCTAssertEqual(v.h.store.job(id: j2)?.video?.stage, .skipped)
    }

    // MARK: Backfill

    func testHistoricalLessonsWaitForBackfill() async throws {
        let v = try VideoHarness(automaticSince: Date(timeIntervalSince1970: 1_900_000_000))  // "installed" after these lessons
        let single = try await v.submitted(.single, recordings: 1)
        let combined = try await v.submitted(.combined, recordings: 3)
        let gone = try await v.submitted(.single, recordings: 1)
        v.h.store.updateLesson(id: gone.id) { $0.recordings[0].path = "/missing/zoom_0.mp4" }
        let deleted = try await v.submitted(.single, recordings: 1)
        v.h.store.updateJob(id: deleted.jobs[0].id) { $0.remoteStatus = .deleted }
        let notYet = try v.h.addLesson(mode: .single, recordings: 1, held: true)   // never submitted
        let engine = v.engine()
        await engine.runUntilIdle()
        XCTAssertTrue(v.api.calls.value.isEmpty, "nothing uploads before Start Backfill")
        let report = VideoBackfill.scan(store: v.h.store) { v.media.sizes[$0.path] }
        XCTAssertEqual(report.total, 4)
        XCTAssertFalse(report.items.contains { $0.jobId == notYet.jobs[0].id })
        XCTAssertEqual(Set(report.eligible.map(\.jobId)), [single.jobs[0].id, combined.jobs[0].id])
        XCTAssertEqual(report.needingMerge, 1)
        XCTAssertEqual(report.count(.missingRecordings), 1)
        XCTAssertEqual(report.count(.noteDeleted), 1)
        XCTAssertEqual(report.estimatedBytes, 1_000_000 + 6_000_000)
        // Check LetsMeet first: the single lesson already has a video there.
        v.api.existing["note-0"] = [RemoteRecording(recordingId: "had-one", status: "ready")]
        await engine.probe(jobIds: report.items.map(\.jobId))
        await engine.runUntilIdle()
        let after = VideoBackfill.scan(store: v.h.store) { v.media.sizes[$0.path] }
        XCTAssertEqual(after.count(.alreadyUploaded), 1)
        XCTAssertEqual(after.eligible.map(\.jobId), [combined.jobs[0].id])
        XCTAssertTrue(v.api.registered.value.isEmpty, "checking is read-only")
        // Start Backfill.
        await engine.enqueue(jobIds: after.eligible.map(\.jobId), origin: .backfill)
        await engine.runUntilIdle()
        let s = v.h.store.job(id: combined.jobs[0].id)!.video!
        XCTAssertEqual(s.stage, .ready)
        XCTAssertEqual(s.origin, .backfill)
        XCTAssertEqual(v.media.merges.value.count, 1)
        XCTAssertEqual(VideoBackfill.scan(store: v.h.store) { v.media.sizes[$0.path] }.count(.succeeded), 1)
        XCTAssertEqual(v.h.submitter.bodies.value.count, 4, "no notes resubmitted by the backfill")
    }

    func testBackfillOnRealV11Library() async throws {
        // Real v1.1.0 data: job 4 was submitted (note-4) and has no video. Nothing else changes.
        let env = try V11Env()
        let before = try Data(contentsOf: env.dir.appendingPathComponent("library.json"))
        XCTAssertNil(env.store.settings.video.automaticSince)
        XCTAssertTrue(env.store.settings.video.autoUpload)
        let report = VideoBackfill.scan(store: env.store) { _ in 3_000_000 }
        XCTAssertEqual(report.items.map(\.jobId), [j4])
        XCTAssertEqual(report.eligible.first?.noteResolved, true)
        XCTAssertEqual(report.estimatedBytes, 3_000_000)
        XCTAssertEqual(try Data(contentsOf: env.dir.appendingPathComponent("library.json")), before, "scanning writes nothing")
        // Upload it.
        let api = MockRecordingsAPI(), up = MockUploader(), media = MockMedia()
        let lesson = env.store.lesson(containingJob: j4)!
        media.sizes[lesson.recordings[0].path] = 3_000_000
        let dir = tempDir()
        let engine = VideoUploadEngine(store: env.store, deps: VideoDependencies(makeAPI: { api }, media: media, uploader: up, isOnline: { true }, videosDirectory: { dir }),
                                       now: { env.clock.value }, probePacing: 0)
        await engine.enqueue(jobIds: [j4], origin: .backfill)
        await engine.runUntilIdle()
        XCTAssertEqual(env.store.job(id: j4)?.video?.stage, .ready)
        XCTAssertEqual(api.registered.value.first?.noteId, "note-4", "the note's real id")
        XCTAssertTrue(env.submitter.bodies.value.isEmpty, "notes not resent")
        XCTAssertEqual(env.store.job(id: j4)?.remoteVersion, 1)
    }

    // MARK: Management

    func testReplaceAndDelete() async throws {
        let v = try VideoHarness()
        let l = try await v.submitted(.single, recordings: 1)
        let jid = l.jobs[0].id
        let engine = v.engine()
        await engine.runUntilIdle()
        try await engine.replace(jobId: jid, filename: "fixed.mp4", path: "/tmp/fixed.mp4", bookmark: nil, size: 4242, durationSec: 610)
        await engine.runUntilIdle()
        var s = v.h.store.job(id: jid)!.video!
        XCTAssertNil(s.replacement)
        XCTAssertEqual(s.fileSize, 4242)
        XCTAssertEqual(s.originalFilename, "fixed.mp4")
        XCTAssertTrue(v.api.calls.value.contains { $0.hasPrefix("replace rec-1 mac-video-replace-") })
        XCTAssertEqual(v.uploader.puts.value.last?.0, "/tmp/fixed.mp4")
        XCTAssertEqual(v.api.completed.value.last?.sizeBytes, 4242, "complete with the NEW size")
        // Delete: 202 → pending (hidden, retry later); then 200 → deleted.
        v.api.deleteFully = false
        let first = try await engine.deleteRemote(jobId: jid)
        XCTAssertFalse(first)
        XCTAssertEqual(v.h.store.job(id: jid)?.video?.deletePending, true)
        v.api.deleteFully = true
        let second = try await engine.deleteRemote(jobId: jid)
        XCTAssertTrue(second)
        s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .deleted)
        XCTAssertFalse(s.deletePending)
        XCTAssertEqual(v.media.sizes["/tmp/zoom_0.mp4"], 1_000_000, "original recording untouched")
        // Upload again later uses a new upload id.
        await engine.uploadAgain(jobId: jid)
        await engine.runUntilIdle()
        s = v.h.store.job(id: jid)!.video!
        XCTAssertEqual(s.stage, .ready)
        XCTAssertTrue(s.uploadId.hasSuffix("-2"))
    }

    func testSettingsDecodeDefaults() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(s.video.autoUpload)
        XCTAssertEqual(s.video.maxConcurrentUploads, 1)
        XCTAssertTrue(s.video.deleteMergedAfterUpload)
        XCTAssertFalse(s.video.paused)
        XCTAssertNil(s.video.automaticSince)
        let clamped = try JSONDecoder().decode(VideoSettings.self, from: Data(#"{"maxConcurrentUploads":9}"#.utf8))
        XCTAssertEqual(clamped.maxConcurrentUploads, 3)
        XCTAssertEqual(s.video.statsRefreshSeconds, 60)
        XCTAssertEqual(s.video.byteUnit, .automatic)
        XCTAssertTrue(s.video.separateTraffic)
        XCTAssertEqual(s.video.lowSpacePercent, 10)
    }
}
