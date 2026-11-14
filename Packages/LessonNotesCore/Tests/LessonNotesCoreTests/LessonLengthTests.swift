import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

final class MockLengthSetter: LessonLengthSetting, @unchecked Sendable {
    let calls = Box<[(String, Int?)]>([])
    var results: [String: Result<LessonLengthResponse, Error>] = [:]
    func setLessonLength(noteId: String, seconds: Int?) async throws -> LessonLengthResponse {
        calls.mutate { $0.append((noteId, seconds)) }
        if let r = results[noteId] {
            switch r { case .success(let v): return v; case .failure(let e): throw e }
        }
        return LessonLengthResponse(noteId: "n", submissionId: noteId, status: .published, lessonLength: seconds, unchanged: false)
    }
}

final class LessonLengthTests: XCTestCase {
    func testComputedFromRecordings() throws {
        let h = try Harness()
        let combined = try h.addLesson(mode: .combined, recordings: 3) // 600 s each
        XCTAssertEqual(LessonLength.seconds(for: combined, job: combined.jobs[0]), 1_800)
        let separate = try h.addLesson(mode: .separate, recordings: 2)
        XCTAssertEqual(separate.jobs.map { LessonLength.seconds(for: separate, job: $0) }, [600, 600])
        var unknown = combined
        for i in unknown.recordings.indices { unknown.recordings[i].durationSec = 0 }
        unknown.endedAt = nil
        XCTAssertNil(LessonLength.seconds(for: unknown, job: unknown.jobs[0]), "unknown, not invented")
        var long = combined
        long.recordings[0].durationSec = 50_000
        XCTAssertEqual(LessonLength.seconds(for: long, job: long.jobs[0]), 43_200, "capped at the API maximum")
        XCTAssertFalse(LessonLength.isValid(0)); XCTAssertFalse(LessonLength.isValid(43_201)); XCTAssertTrue(LessonLength.isValid(nil))
    }

    func testNewSubmissionsIncludeLessonLength() async throws {
        let h = try Harness()
        _ = try h.addLesson(mode: .combined, recordings: 2)
        await h.engine().runUntilIdle()
        let body = try JSONSerialization.jsonObject(with: h.submitter.bodies.value[0]) as! [String: Any]
        XCTAssertEqual(body["lesson_length"] as? Int, 1_200)
    }

    func testClientRequestAndResponse() async throws {
        let t = StubTransport { _ in StubTransport.json(200, #"{"note_id":"n1","submission_id":"s1","room_id":"r","status":"published","version":2,"lesson_length":3120,"unchanged":false}"#) }
        let c = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_K", transport: t)
        let r = try await c.setLessonLength(noteId: "mac-ABC-2026-01-01-1600-a-xyz123", seconds: 3120)
        XCTAssertEqual(r.lessonLength, 3120)
        XCTAssertEqual(r.status, .published)
        let req = t.requests.value[0]
        XCTAssertEqual(req.httpMethod, "PATCH")
        XCTAssertEqual(req.url?.path, "/api/public/lesson-notes/notes/mac-ABC-2026-01-01-1600-a-xyz123/lesson-length")
        XCTAssertEqual(bodyJSON(req) as NSDictionary, ["lesson_length": 3120] as NSDictionary, "body contains only lesson_length")
        let st = try JSONDecoder().decode(NoteStatusResponse.self, from: Data(#"{"note_id":"n","submission_id":"s","status":"pending","lesson_length":900}"#.utf8))
        XCTAssertEqual(st.lessonLength, 900)
    }

    func testBackfillsPre13NotesWithoutResendingThem() async throws {
        // Real v1.1.0 data: job 4 was submitted (3,300 s recording) before lesson_length existed.
        let env = try V11Env()
        let setter = MockLengthSetter()
        let deps = EngineDependencies(extractor: env.extractor, transcriber: env.transcriber, makeNotesProducer: { env.notes },
                                      makeSubmitter: { env.submitter }, isOnline: { true }, appVersion: "1.4.0",
                                      makeLessonLengthSetter: { setter })
        let engine = JobEngine(store: env.store, deps: deps, tempRoot: env.dir.deletingLastPathComponent().appendingPathComponent("tmp"),
                               now: { env.clock.value }, lessonLengthPacing: 0)
        await engine.tick()
        await engine.runUntilIdle()
        let sid4 = env.store.job(id: j4)!.submissionId
        XCTAssertTrue(setter.calls.value.contains { $0.0 == sid4 && $0.1 == 3_300 })
        XCTAssertEqual(env.store.job(id: j4)?.lessonLengthSynced, 3_300)
        XCTAssertEqual(env.store.job(id: j4)?.stage, .submitted)
        XCTAssertFalse(env.bodies().contains { ($0["submission_id"] as? String) == sid4 }, "the note itself was not resent")
        XCTAssertEqual(env.store.job(id: j4)?.remoteVersion, 1, "version untouched")
        // Failed / unsent jobs are not patched.
        for id in [j1, j2, j3, j7] { XCTAssertFalse(setter.calls.value.contains { $0.0 == env.store.job(id: id)!.submissionId }) }
        // Synced flag persists: after a restart nothing is sent again.
        let before = setter.calls.value.count
        let env2 = try V11Env(dir: env.dir)
        let engine2 = JobEngine(store: env2.store, deps: EngineDependencies(extractor: env2.extractor, transcriber: env2.transcriber,
                                makeNotesProducer: { env2.notes }, makeSubmitter: { env2.submitter }, isOnline: { true }, appVersion: "1.4.0",
                                makeLessonLengthSetter: { setter }), tempRoot: env.dir.deletingLastPathComponent().appendingPathComponent("tmp2"),
                                now: { env2.clock.value }, lessonLengthPacing: 0)
        await engine2.tick()
        await engine2.runUntilIdle()
        XCTAssertFalse(setter.calls.value.dropFirst(before).contains { $0.0 == sid4 }, "not resent after restart")
    }

    func testErrorsHandledPerSpec() async throws {
        let h = try Harness()
        let a = try h.addLesson(mode: .single, recordings: 1)
        let b = try h.addLesson(mode: .single, recordings: 1)
        let c = try h.addLesson(mode: .single, recordings: 1)
        // Pretend these were submitted by an older version (website returned no lesson_length).
        await h.engine().runUntilIdle()
        for l in [a, b, c] { h.store.updateJob(id: l.jobs[0].id) { $0.lessonLengthSynced = nil } }
        let setter = MockLengthSetter()
        let sa = a.jobs[0].submissionId, sb = b.jobs[0].submissionId, sc = c.jobs[0].submissionId
        setter.results[sa] = .failure(LetsMeetAPIError(httpStatus: 404, code: "not_found", message: "gone"))
        setter.results[sb] = .failure(LetsMeetAPIError(httpStatus: 422, code: "validation_failed", message: "bad value"))
        setter.results[sc] = .failure(LetsMeetAPIError(httpStatus: 429, code: "rate_limited", message: "slow", retryAfter: 90))
        let deps = EngineDependencies(extractor: h.extractor, transcriber: h.transcriber, makeNotesProducer: { h.notes }, makeSubmitter: { h.submitter },
                                      isOnline: { true }, appVersion: "t", makeLessonLengthSetter: { setter })
        let engine = JobEngine(store: h.store, deps: deps, tempRoot: h.tempRoot, now: { h.clock.value }, lessonLengthPacing: 0)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: a.jobs[0].id)?.remoteStatus, .deleted, "404 → deleted locally")
        XCTAssertNotNil(h.store.job(id: b.jobs[0].id)?.lessonLengthError, "422 → not retried")
        let cj = h.store.job(id: c.jobs[0].id)!
        XCTAssertEqual(cj.lessonLengthNextAttemptAt, h.clock.value.addingTimeInterval(90), "429 → Retry-After respected")
        // Later, the rate-limited one succeeds; the others are not tried again.
        setter.results[sc] = nil
        let n = setter.calls.value.count
        h.clock.value = h.clock.value.addingTimeInterval(91)
        await engine.runUntilIdle()
        XCTAssertEqual(setter.calls.value.dropFirst(n).map(\.0), [sc])
        XCTAssertEqual(h.store.job(id: c.jobs[0].id)?.lessonLengthSynced, 600)
    }

    func testSubmissionResponseAndStatusSyncMarkSynced() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending, version: 1, lessonLength: 600))]
        let setter = MockLengthSetter()
        let deps = EngineDependencies(extractor: h.extractor, transcriber: h.transcriber, makeNotesProducer: { h.notes }, makeSubmitter: { h.submitter },
                                      isOnline: { true }, appVersion: "t", makeLessonLengthSetter: { setter })
        await JobEngine(store: h.store, deps: deps, tempRoot: h.tempRoot, now: { h.clock.value }, lessonLengthPacing: 0).runUntilIdle()
        XCTAssertEqual(h.store.job(id: l.jobs[0].id)?.lessonLengthSynced, 600)
        XCTAssertTrue(setter.calls.value.isEmpty, "already set by the submission — no extra request")
        StatusSync.apply([NoteStatusResponse(noteId: "n", submissionId: l.jobs[0].submissionId, status: .published, lessonLength: 650)], store: h.store, now: Date())
        XCTAssertEqual(h.store.job(id: l.jobs[0].id)?.lessonLengthSynced, 650)
    }

    func testValidatorRejectsOutOfRange() {
        var s = NoteSubmission(submissionId: "mac-TEST-0000-a-abc123", roomId: roomEE, lessonDate: "2026-11-14", startedAt: nil, endedAt: nil,
                               title: "T", summary: NoteSummary(), transcript: "x", privateNotes: nil, recordings: [], mode: .single, generator: nil)
        s.lessonLength = 0
        XCTAssertTrue(SubmissionValidator.validate(s).contains { $0.field == "lesson_length" })
        s.lessonLength = 3_120
        XCTAssertFalse(SubmissionValidator.validate(s).contains { $0.field == "lesson_length" })
    }
}
