import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

/// Live end-to-end test against the real LetsMeet website and media gateway. Skipped unless
/// LIVE_VIDEO_TEST=1. Uses a synthetic file (LIVE_FILE) and a dedicated test note (LIVE_NOTE_ID),
/// and deletes the uploaded recording afterwards. The API key is supplied by the environment's
/// proxy; nothing secret is in this file.
final class LiveVideoTests: XCTestCase {
    struct FileMedia: VideoMediaProviding {
        func sourceInfo(_ rec: RecordingRef) async -> SourceFile {
            let size = (try? FileManager.default.attributesOfItem(atPath: rec.path)[.size] as? NSNumber)?.int64Value
            return SourceFile(exists: size != nil, size: size ?? 0)
        }
        func merge(_ recs: [RecordingRef], to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MergedVideo { throw CancellationError() }
        func validateMerged(_ url: URL) async -> MergedVideo? { nil }
        func withAccess(bookmark: Data?, path: String, _ body: @Sendable (URL) async throws -> Void) async throws { try await body(URL(fileURLWithPath: path)) }
    }

    /// Streams the file with URLSession (same contract as the Mac app's uploader).
    final class FileUploader: SignedUploading, @unchecked Sendable {
        let sent = Box<[Int64]>([])
        func upload(file: URL, size: Int64, to target: SignedUpload, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            var req = URLRequest(url: target.url)
            req.httpMethod = target.method
            for (k, v) in target.headers ?? [:] { req.setValue(v, forHTTPHeaderField: k) }
            req.setValue(String(size), forHTTPHeaderField: "Content-Length")
            let status: Int = try await withCheckedThrowingContinuation { c in
                URLSession.shared.uploadTask(with: req, fromFile: file) { _, resp, err in
                    if let err { c.resume(throwing: SignedUploadError.network(err.localizedDescription)) }
                    else { c.resume(returning: (resp as? HTTPURLResponse)?.statusCode ?? 0) }
                }.resume()
            }
            switch status {
            case 200, 201: sent.mutate { $0.append(size) }; progress(size, size)
            case 403: throw SignedUploadError.expired
            case 400: throw SignedUploadError.incomplete
            case 413: throw SignedUploadError.tooLarge
            default: throw SignedUploadError.http(status)
            }
        }
    }

    func testLiveSyntheticUploadThroughEngine() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LIVE_VIDEO_TEST"] == "1", let noteId = env["LIVE_NOTE_ID"], let file = env["LIVE_FILE"] else {
            throw XCTSkip("Live test: set LIVE_VIDEO_TEST=1, LIVE_NOTE_ID and LIVE_FILE")
        }
        let client = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_injected_by_proxy",
                                        transport: URLSessionTransport(timeout: 120))
        let h = try Harness()
        h.store.updateSettings { $0.video.automaticSince = Date(timeIntervalSince1970: 0); $0.video.autoUpload = false }
        // A lesson whose single recording is the synthetic file; its note is the dedicated test note.
        var l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        h.store.updateLesson(id: l.id) { $0.recordings[0].path = file; $0.recordings[0].filename = "synthetic-test.mp4"; $0.recordings[0].durationSec = 12 }
        h.store.updateJob(id: jid) { $0.stage = .submitted; $0.noteId = noteId; $0.submittedAt = Date() }
        l = h.store.lesson(containingJob: jid)!
        let uploader = FileUploader()
        let engine = VideoUploadEngine(store: h.store, deps: VideoDependencies(makeAPI: { client }, media: FileMedia(), uploader: uploader,
                                                                               isOnline: { true }, videosDirectory: { tempDir() }))
        await engine.enqueue(jobIds: [jid], origin: .manual)
        await engine.runUntilIdle()
        let v = try XCTUnwrap(h.store.job(id: jid)?.video)
        XCTAssertEqual(v.stage, .ready, v.lastError ?? "")
        let rid = try XCTUnwrap(v.recordingId)
        let size = Int64(try Data(contentsOf: URL(fileURLWithPath: file)).count)
        XCTAssertEqual(uploader.sent.value, [size], "streamed once")
        let remote = try await client.recording(id: rid)
        XCTAssertEqual(remote.status, "ready")
        XCTAssertEqual(remote.sizeBytes, size)
        XCTAssertEqual(remote.noteId, noteId)
        let avail = try await client.availability(recordingId: rid)
        XCTAssertTrue(avail.available)
        // Running again does not upload twice (stable upload id + existing-video check).
        await engine.retry(jobId: jid)
        await engine.runUntilIdle()
        XCTAssertEqual(uploader.sent.value.count, 1)
        // Clean up: delete the test recording.
        let done = try await engine.deleteRemote(jobId: jid)
        XCTAssertTrue(done)
        let after = try await client.recording(id: rid)
        XCTAssertEqual(after.status, "deleted")
        print("LIVE: uploaded and deleted recording \(rid) on test note \(noteId)")
    }
}
