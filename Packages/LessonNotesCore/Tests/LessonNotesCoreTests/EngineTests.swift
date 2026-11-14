import XCTest
@testable import LessonNotesCore

final class EngineTests: XCTestCase {
    func submitted(_ h: Harness) -> [[String: Any]] {
        h.submitter.bodies.value.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
    }

    func testSingleRecordingHappyPathUploadsFullTranscript() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        let engine = h.engine()
        await engine.runUntilIdle()
        let job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .submitted)
        XCTAssertEqual(job.remoteStatus, .pending)
        XCTAssertEqual(job.noteId, "note-0")
        let body = submitted(h)[0]
        let transcript = try XCTUnwrap(body["transcript"] as? String)
        let local = h.store.transcript(jobId: job.id)!.renderedText(timeZone: london)
        XCTAssertEqual(transcript, local, "uploaded transcript is the complete local transcript")
        XCTAssertTrue(transcript.contains("[00:00] Hello from"))
        XCTAssertTrue(transcript.contains("[00:05] We practised fractions."))
        XCTAssertEqual(h.notes.lastTranscript.value, local, "OpenAI received the same full transcript")
        XCTAssertEqual(body["title"] as? String, "Fractions")
        XCTAssertEqual(body["private_notes"] as? String, "Watch numerator/denominator.")
        XCTAssertEqual(body["mode"] as? String, "single")
        XCTAssertEqual((body["generator"] as? [String: Any])?["transcription_model"] as? String, "whisperkit/test-model")
        // Temporary audio was deleted.
        XCTAssertFalse(h.extractor.created.value.contains { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testCombinedModeOneSubmissionWithAllPartsInOrder() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .combined, recordings: 3)
        await h.engine().runUntilIdle()
        XCTAssertEqual(h.submitter.bodies.value.count, 1)
        let body = submitted(h)[0]
        let recs = body["recordings"] as! [[String: Any]]
        XCTAssertEqual(recs.map { $0["filename"] as! String }, ["zoom_0.mp4", "zoom_1.mp4", "zoom_2.mp4"])
        XCTAssertEqual(recs.map { $0["order"] as! Int }, [0, 1, 2])
        XCTAssertEqual(body["mode"] as? String, "combined")
        let transcript = body["transcript"] as! String
        XCTAssertEqual(h.transcriber.calls.value, 3)
        // Boundaries with recording start times, in chronological order, nothing dropped.
        let p2 = transcript.range(of: "--- Part 2 (")!, p3 = transcript.range(of: "--- Part 3 (")!
        XCTAssertLessThan(p2.lowerBound, p3.lowerBound)
        XCTAssertEqual(transcript.components(separatedBy: "We practised fractions.").count - 1, 3)
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .submitted)
    }

    func testSeparateModeThreeSubmissionsWithOwnTranscripts() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .separate, recordings: 3)
        XCTAssertEqual(l.jobs.count, 3)
        await h.engine().runUntilIdle()
        let bodies = submitted(h)
        XCTAssertEqual(bodies.count, 3)
        XCTAssertEqual(Set(bodies.map { $0["submission_id"] as! String }).count, 3)
        XCTAssertTrue(bodies.allSatisfy { $0["mode"] as? String == "separate" })
        XCTAssertTrue(bodies.allSatisfy { ($0["recordings"] as! [Any]).count == 1 })
        for b in bodies {
            let t = b["transcript"] as! String
            XCTAssertFalse(t.contains("--- Part"))
            XCTAssertTrue(t.contains("We practised fractions."))
        }
        XCTAssertEqual(Set(l.jobs.map(\.partLetter)), ["a", "b", "c"])
    }

    func testUploadFailureRetriesWithoutRetranscribingAndReusesSubmissionId() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(TransportError.network("timed out")),
                               .failure(LetsMeetAPIError(httpStatus: 503, code: "server_error", message: "busy")),
                               .success(NoteStatusResponse(noteId: "n1", submissionId: "", status: .pending, replayed: true))]
        let engine = h.engine()
        await engine.runUntilIdle()
        var job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .submitting)
        XCTAssertEqual(job.attempts, 1)
        XCTAssertEqual(job.nextAttemptAt, h.clock.value.addingTimeInterval(5))
        h.clock.value = h.clock.value.addingTimeInterval(6)
        await engine.runUntilIdle()
        job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.attempts, 2)
        XCTAssertEqual(job.nextAttemptAt, h.clock.value.addingTimeInterval(15))
        h.clock.value = h.clock.value.addingTimeInterval(16)
        await engine.runUntilIdle()
        job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1, "no re-transcription")
        XCTAssertEqual(h.notes.calls.value, 1, "no re-summarisation")
        let bodies = h.submitter.bodies.value
        XCTAssertEqual(bodies.count, 3)
        XCTAssertTrue(bodies.allSatisfy { $0 == bodies[0] }, "identical payload and submission id on every retry")
        XCTAssertEqual(submitted(h)[0]["submission_id"] as? String, l.jobs[0].submissionId)
    }

    func testRateLimitHonoursRetryAfter() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 429, code: "rate_limited", message: "slow", retryAfter: 120)),
                               .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        await h.engine().runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].nextAttemptAt, h.clock.value.addingTimeInterval(120))
    }

    func testNonRetryableErrorsFailImmediatelyWithServerMessage() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 422, code: "unknown_room", message: "That room does not exist."))]
        await h.engine().runUntilIdle()
        let job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .failed)
        XCTAssertEqual(job.resumeStage, .submitting)
        XCTAssertTrue(job.error!.message.contains("That room does not exist."))
        XCTAssertEqual(h.submitter.bodies.value.count, 1)
    }

    func testManualRetryAfterFixResubmitsSameIdWithoutRetranscription() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 401, code: "unauthorized", message: "Bad key")),
                               .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        let engine = h.engine()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].error?.kind, .authentication)
        await engine.retry(jobId: l.jobs[0].id)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1)
        XCTAssertEqual(h.submitter.bodies.value[0], h.submitter.bodies.value[1])
    }

    func testOversizedTranscriptNeedsAttentionAndIsNeverSentOrRetried() async throws {
        let h = try Harness()
        h.transcriber.textFor = { _ in [TranscriptSegment(start: 0, end: 1, text: String(repeating: "é", count: 2_600_000))] } // 5.2 MB
        let l = try h.addLesson(mode: .single, recordings: 1)
        let engine = h.engine()
        await engine.runUntilIdle()
        var job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .failed)
        XCTAssertEqual(job.error?.kind, .payloadTooLarge)
        XCTAssertEqual(job.displayStatus, "Needs attention")
        XCTAssertTrue(job.error!.message.contains("5,000,000"))
        XCTAssertNil(job.nextAttemptAt)
        XCTAssertEqual(h.submitter.bodies.value.count, 0, "nothing uploaded")
        XCTAssertNotNil(job.notes, "notes kept")
        XCTAssertEqual(h.store.transcript(jobId: job.id)!.parts[0].segments[0].text.count, 2_600_000, "full transcript kept locally")
        // Time passes: still not retried automatically.
        h.clock.value = h.clock.value.addingTimeInterval(3600)
        await engine.runUntilIdle()
        job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .failed)
        XCTAssertEqual(h.submitter.bodies.value.count, 0)
        // Retention never purges a transcript that hasn't been uploaded.
        XCTAssertEqual(h.store.applyRetention(.days30, now: h.clock.value.addingTimeInterval(400 * 86_400)), 0)
    }

    func testServer413IsNotRetried() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 413, code: "payload_too_large", message: "Body too large"))]
        let engine = h.engine()
        await engine.runUntilIdle()
        h.clock.value = h.clock.value.addingTimeInterval(7200)
        await engine.runUntilIdle()
        XCTAssertEqual(h.submitter.bodies.value.count, 1)
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].error?.kind, .payloadTooLarge)
    }

    func testOfflineWaitsThenSubmitsOnce() async throws {
        let h = try Harness()
        h.online.value = false
        let l = try h.addLesson(mode: .single, recordings: 1)
        let engine = h.engine()
        await engine.runUntilIdle()
        var job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .summarising, "transcription runs offline; summarising waits")
        XCTAssertEqual(job.statusMessage, "Waiting for internet")
        XCTAssertEqual(h.notes.calls.value, 0)
        h.online.value = true
        await engine.runUntilIdle()
        job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .submitted)
        XCTAssertEqual(h.submitter.bodies.value.count, 1)
    }

    func testOfflineErrorDuringSubmitDoesNotConsumeRetries() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(TransportError.offline("no connection")), .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        let engine = h.engine()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].attempts, 0)
        h.clock.value = h.clock.value.addingTimeInterval(31)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .submitted)
        XCTAssertEqual(Set(h.submitter.bodies.value).count, 1)
    }

    func testQueueRecoveryAfterRestart() async throws {
        let h = try Harness()
        let a = try h.addLesson(mode: .single, recordings: 1)
        let b = try h.addLesson(mode: .single, recordings: 1)
        // Simulate a quit mid-transcription (a) and mid-upload (b, transcript + notes saved).
        h.store.updateJob(id: a.jobs[0].id) { $0.stage = .transcribing }
        try h.store.saveTranscript(StoredTranscript(jobId: b.jobs[0].id, savedAt: Date(), model: "m", language: "en",
                                                    parts: [TranscriptPart(recordingId: b.recordings[0].id, filename: "zoom_0.mp4", recordedAt: nil, durationSec: 600,
                                                                           segments: [TranscriptSegment(start: 0, end: 1, text: "Saved transcript")])]))
        h.store.updateJob(id: b.jobs[0].id) { $0.stage = .submitting; $0.notes = GeneratedNotes(title: "Saved notes") }
        // Leftover temp audio from the crashed run.
        try FileManager.default.createDirectory(at: h.tempRoot.appendingPathComponent("old"), withIntermediateDirectories: true)
        try Data([1]).write(to: h.tempRoot.appendingPathComponent("old/a.wav"))

        let reopened = try LibraryStore(directory: h.store.directory)
        XCTAssertEqual(reopened.job(id: a.jobs[0].id)?.stage, .transcribing, "state persisted to disk")
        let deps = EngineDependencies(extractor: h.extractor, transcriber: h.transcriber, makeNotesProducer: { h.notes },
                                      makeSubmitter: { h.submitter }, isOnline: { true }, appVersion: "t")
        let engine = JobEngine(store: reopened, deps: deps, tempRoot: h.tempRoot, now: { h.clock.value })
        await engine.recoverAfterLaunch()
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.tempRoot.appendingPathComponent("old/a.wav").path))
        XCTAssertEqual(reopened.job(id: a.jobs[0].id)?.stage, .queued)
        await engine.runUntilIdle()
        XCTAssertEqual(reopened.job(id: a.jobs[0].id)?.stage, .submitted)
        XCTAssertEqual(reopened.job(id: b.jobs[0].id)?.stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1, "only the interrupted transcription was redone")
        XCTAssertEqual(h.notes.calls.value, 1)
        let bBody = h.submitter.bodies.value.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] }
            .first { ($0["submission_id"] as! String) == b.jobs[0].submissionId }!
        XCTAssertEqual(bBody["transcript"] as? String, "[00:00] Saved transcript")
    }

    func testTempAudioDeletedWhenTranscriptionFails() async throws {
        let h = try Harness()
        h.transcriber.failWith = NSError(domain: "whisper", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model failed"])
        let l = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        let job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .failed)
        XCTAssertEqual(job.error?.message, "Model failed")
        XCTAssertFalse(h.extractor.created.value.contains { FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual((try? FileManager.default.contentsOfDirectory(atPath: h.tempRoot.path))?.count ?? 0, 0)
    }

    func testOpenAIErrors() async throws {
        let h = try Harness()
        h.notes.failWith = OpenAIError.invalidKey("bad")
        let l = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        let job = h.store.lesson(id: l.id)!.jobs[0]
        XCTAssertEqual(job.stage, .failed)
        XCTAssertEqual(job.resumeStage, .summarising)
        XCTAssertTrue(job.error!.message.contains("Check your OpenAI key"))

        let h2 = try Harness()
        h2.notes.failWith = OpenAIError.rateLimited("slow", retryAfter: 30)
        let l2 = try h2.addLesson(mode: .single, recordings: 1)
        await h2.engine().runUntilIdle()
        XCTAssertEqual(h2.store.lesson(id: l2.id)!.jobs[0].stage, .summarising)
        XCTAssertEqual(h2.store.lesson(id: l2.id)!.jobs[0].nextAttemptAt, h2.clock.value.addingTimeInterval(30))

        let h3 = try Harness()
        h3.notes.failWith = OpenAIError.refusal("")
        let l3 = try h3.addLesson(mode: .single, recordings: 1)
        await h3.engine().runUntilIdle()
        XCTAssertTrue(h3.store.lesson(id: l3.id)!.jobs[0].error!.message.contains("OpenAI declined to write notes"))
    }

    func testHeldJobsWaitForStart() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let engine = h.engine()
        await engine.runUntilIdle()
        XCTAssertEqual(h.transcriber.calls.value, 0)
        await engine.startHeld(jobId: l.jobs[0].id)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .submitted)
    }

    func testCancelAndResume() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let engine = h.engine()
        await engine.cancel(jobId: l.jobs[0].id)
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .cancelled)
        await engine.runUntilIdle()
        XCTAssertEqual(h.transcriber.calls.value, 0)
        await engine.retry(jobId: l.jobs[0].id)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .submitted)
    }

    func testReprocessCreatesNewSubmissionIds() throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .separate, recordings: 2)
        let again = try LessonFactory.reprocess(l, settings: h.store.settings, held: false)
        XCTAssertEqual(again.reprocessOf, l.id)
        XCTAssertTrue(Set(again.jobs.map(\.submissionId)).isDisjoint(with: l.jobs.map(\.submissionId)))
        XCTAssertEqual(again.recordings.map(\.sha256), l.recordings.map(\.sha256))
    }
}
