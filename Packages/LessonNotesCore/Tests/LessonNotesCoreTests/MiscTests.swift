import XCTest
@testable import LessonNotesCore

final class MiscTests: XCTestCase {
    func testSHA256KnownVectors() throws {
        XCTAssertEqual(SHA256Hasher.hex(of: "abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(SHA256Hasher.hex(of: ""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        var p = PortableSHA256()
        p.update(Data("abc".utf8))
        XCTAssertEqual(p.finalize().map { String(format: "%02x", $0) }.joined(), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let dir = tempDir()
        let f = dir.appendingPathComponent("a.bin")
        let data = Data((0..<3_000_000).map { UInt8($0 % 251) })
        try data.write(to: f)
        XCTAssertEqual(try SHA256Hasher.hexOfFile(at: f, chunkSize: 1_000_000), SHA256Hasher.hex(of: data))
    }

    func testSubmissionIdFormat() {
        let install = UUID(uuidString: "6F1C2A9E-0000-0000-0000-000000000000")!
        let start = CoreFormat.parseISO8601("2026-11-14T16:00:12Z")!
        let id = SubmissionID.make(installId: install, lessonDate: "2026-11-14", startedAt: start, timeZone: london, partLetter: "a", random: { "abc123" })
        XCTAssertEqual(id, "mac-6F1C2A9E-0000-0000-0000-000000000000-2026-11-14-1600-a-abc123")
        XCTAssertTrue((8...100).contains(id.count))
        XCTAssertNotEqual(SubmissionID.randomSuffix(), SubmissionID.randomSuffix())
        XCTAssertEqual(SubmissionID.partLetter(27), "ab")
    }

    func testRetrySchedule() {
        XCTAssertEqual((1...8).map { RetryPolicy.baseDelay(forAttempt: $0) }, [5, 15, 45, 120, 300, 900, 1800, 1800])
        let p = RetryPolicy(jitterFraction: 0.2)
        let t0 = Date(timeIntervalSince1970: 0)
        let n = p.nextAttempt(attempt: 1, firstRetryAt: t0, now: t0, retryAfter: nil, random: { $0.upperBound })!
        XCTAssertEqual(n.timeIntervalSince(t0), 6)
        XCTAssertEqual(p.nextAttempt(attempt: 1, firstRetryAt: t0, now: t0, retryAfter: 90, random: { _ in 0 })!.timeIntervalSince(t0), 90)
        XCTAssertNil(p.nextAttempt(attempt: 50, firstRetryAt: t0, now: t0.addingTimeInterval(23.9 * 3600), retryAfter: nil, random: { _ in 0 }))
    }

    func testFailureClassification() {
        XCTAssertEqual(FailureClass.classify(TransportError.offline("x")), .offline)
        XCTAssertEqual(FailureClass.classify(CancellationError()), .cancelled)
        for s in [400, 401, 403, 404, 409, 413, 415, 422] {
            guard case .fatal = FailureClass.classify(LetsMeetAPIError(httpStatus: s, code: "c", message: "m")) else { return XCTFail("\(s)") }
        }
        for s in [429, 500, 502, 503] {
            guard case .retryable = FailureClass.classify(LetsMeetAPIError(httpStatus: s, code: "c", message: "m")) else { return XCTFail("\(s)") }
        }
    }

    func testDuplicateDetectionByHash() throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        let prev = h.store.previousProcessing(sha256: l.recordings[0].sha256!)
        XCTAssertEqual(prev.count, 1)
        XCTAssertEqual(prev[0].pupilName, "Ellie")
        XCTAssertEqual(prev[0].status, "Queued")
        XCTAssertTrue(h.store.previousProcessing(sha256: String(repeating: "f", count: 64)).isEmpty)
    }

    func testRetentionPurgesOnlyOldSubmittedTranscripts() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        let jobId = l.jobs[0].id
        XCTAssertTrue(h.store.transcriptExists(jobId: jobId))
        XCTAssertEqual(h.store.applyRetention(.forever, now: h.clock.value.addingTimeInterval(10 * 365 * 86_400)), 0)
        XCTAssertEqual(h.store.applyRetention(.days30, now: h.clock.value.addingTimeInterval(10 * 86_400)), 0)
        XCTAssertEqual(h.store.applyRetention(.days30, now: h.clock.value.addingTimeInterval(31 * 86_400)), 1)
        XCTAssertFalse(h.store.transcriptExists(jobId: jobId))
        let job = h.store.job(id: jobId)!
        XCTAssertFalse(job.hasTranscript)
        XCTAssertNotNil(job.transcriptPurgedAt)
        XCTAssertNotNil(job.notes, "notes are kept")
    }

    func testDeleteLocalDataRemovesTranscripts() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        h.store.deleteLesson(id: l.id)
        XCTAssertNil(h.store.lesson(id: l.id))
        XCTAssertFalse(h.store.transcriptExists(jobId: l.jobs[0].id))
    }

    func testStatusSyncScheduleAndApply() async throws {
        let h = try Harness()
        let a = try h.addLesson(mode: .single, recordings: 1)
        let b = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        let t = h.clock.value
        XCTAssertTrue(StatusSync.dueSubmissionIds(lessons: h.store.allLessons, now: t).isEmpty, "just checked on submit")
        XCTAssertEqual(StatusSync.dueSubmissionIds(lessons: h.store.allLessons, now: t.addingTimeInterval(600)).count, 2)
        let changes = StatusSync.apply([NoteStatusResponse(noteId: "n", submissionId: a.jobs[0].submissionId, status: .published, publishedAt: CoreFormat.iso8601(t)),
                                        NoteStatusResponse(noteId: nil, submissionId: b.jobs[0].submissionId, status: .deleted)],
                                       store: h.store, now: t.addingTimeInterval(600))
        XCTAssertEqual(changes.map(\.to), [.published, .deleted])
        XCTAssertEqual(h.store.job(id: b.jobs[0].id)?.displayStatus, "Deleted")
        // Published: daily for 30 days; deleted: never again.
        XCTAssertTrue(StatusSync.dueSubmissionIds(lessons: h.store.allLessons, now: t.addingTimeInterval(3600)).isEmpty)
        XCTAssertEqual(StatusSync.dueSubmissionIds(lessons: h.store.allLessons, now: t.addingTimeInterval(86_400 + 700)), [a.jobs[0].submissionId])
        XCTAssertTrue(StatusSync.dueSubmissionIds(lessons: h.store.allLessons, now: t.addingTimeInterval(31 * 86_400)).isEmpty)
        // Unpublished → pending again.
        StatusSync.apply([NoteStatusResponse(noteId: "n", submissionId: a.jobs[0].submissionId, status: .pending)], store: h.store, now: t.addingTimeInterval(90_000))
        XCTAssertEqual(h.store.job(id: a.jobs[0].id)?.remoteStatus, .pending)
    }

    func testLessonFactoryValidation() throws {
        let h = try Harness()
        let s = h.store.settings
        func conf(_ mode: ProcessingMode, _ n: Int, room: String = roomEE, date: String = "2026-11-14") -> LessonConfirmation {
            LessonConfirmation(roomId: room, roomName: "", studentId: nil, pupilName: "E", lessonDate: date, startedAt: nil, dateSource: .manual,
                               mode: mode, meetingTopic: "", sourceFolder: "", recordings: h.makeRecordings(n))
        }
        XCTAssertThrowsError(try LessonFactory.make(conf(.single, 2), settings: s, held: false))
        XCTAssertThrowsError(try LessonFactory.make(conf(.combined, 0), settings: s, held: false))
        XCTAssertThrowsError(try LessonFactory.make(conf(.single, 1, room: "nope"), settings: s, held: false))
        XCTAssertThrowsError(try LessonFactory.make(conf(.single, 1, date: "2026-02-30"), settings: s, held: false))
        let combined = try LessonFactory.make(conf(.combined, 3), settings: s, held: false)
        XCTAssertEqual(combined.jobs.count, 1)
        XCTAssertEqual(combined.jobs[0].recordingIds.count, 3)
        XCTAssertNotNil(combined.endedAt)
    }

    func testSettingsDefaultsAndBackwardCompatibleDecoding() throws {
        let s = try JSONCoding.decoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(s.websiteBaseURL, "https://georgehalltuition.com/api/public/lesson-notes")
        XCTAssertEqual(s.zoomFolderPath, "~/Documents/Zoom")
        XCTAssertTrue(s.autoProcessAfterConfirm)
        XCTAssertTrue(s.watchFolder)
        XCTAssertEqual(s.transcriptionLanguage, "en")
        XCTAssertEqual(s.retention, .forever)
        XCTAssertEqual(s.reasoningEffort, .modelDefault)
    }

    func testTranscriptCleanerKeepsSpeech() {
        XCTAssertEqual(TranscriptCleaner.clean("<|startoftranscript|><|en|> Hello  there <|0.00|>"), "Hello there")
        XCTAssertEqual(TranscriptCleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptCleaner.clean("Page [4] of the book"), "Page [4] of the book")
    }
}
