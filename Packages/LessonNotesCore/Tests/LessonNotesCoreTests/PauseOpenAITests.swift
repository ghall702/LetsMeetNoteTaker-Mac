import XCTest
@testable import LessonNotesCore

final class PauseOpenAITests: XCTestCase {
    /// Harness lessons are dated 2027-01-15, the harness clock's day ("today").
    func makeOld(_ h: Harness) throws -> Lesson {
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.store.updateLesson(id: l.id) { $0.lessonDate = "2026-05-20" }
        return h.store.lesson(containingJob: l.jobs[0].id)!
    }

    func testPausedTranscribesButDoesNotUseOpenAI() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.timeZoneIdentifier = "Europe/London"; $0.openAIPaused = true }
        let old = try makeOld(h)
        let engine = h.engine()
        await engine.runUntilIdle()
        let j = h.store.job(id: old.jobs[0].id)!
        XCTAssertEqual(h.transcriber.calls.value, 1, "transcription carries on")
        XCTAssertTrue(j.hasTranscript)
        XCTAssertNil(j.notes)
        XCTAssertEqual(h.notes.calls.value, 0, "no OpenAI request while paused")
        XCTAssertTrue(h.submitter.bodies.value.isEmpty)
        XCTAssertEqual(j.statusMessage, JobEngine.openAIPausedMessage)
        XCTAssertTrue(j.stage.isActive, "still in the queue, not failed")

        // Resume: notes are written from the saved transcript without transcribing again.
        h.store.updateSettings { $0.openAIPaused = false }
        await engine.tick()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: old.jobs[0].id)?.stage, .submitted)
        XCTAssertEqual(h.notes.calls.value, 1)
        XCTAssertEqual(h.transcriber.calls.value, 1)
    }

    func testTodaysLessonsStillGetNotesWhenAllowed() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.timeZoneIdentifier = "Europe/London"; $0.openAIPaused = true; $0.openAIPauseAllowsToday = true }
        let today = try h.addLesson(mode: .single, recordings: 1)
        let old = try makeOld(h)
        await h.engine().runUntilIdle()
        XCTAssertEqual(h.store.job(id: today.jobs[0].id)?.stage, .submitted)
        XCTAssertNil(h.store.job(id: old.jobs[0].id)?.notes)
        XCTAssertEqual(h.notes.calls.value, 1)
    }

    func testTodayExceptionCanBeTurnedOff() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.timeZoneIdentifier = "Europe/London"; $0.openAIPaused = true; $0.openAIPauseAllowsToday = false }
        let today = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        XCTAssertNil(h.store.job(id: today.jobs[0].id)?.notes)
        XCTAssertEqual(h.notes.calls.value, 0)
    }

    func testWriteNotesNowOverridesPause() async throws {
        let h = try Harness()
        h.store.updateSettings { $0.timeZoneIdentifier = "Europe/London"; $0.openAIPaused = true }
        let a = try makeOld(h), b = try makeOld(h)
        let engine = h.engine()
        await engine.runUntilIdle()
        h.store.updateJob(id: a.jobs[0].id) { $0.openAIOverride = true }
        await engine.tick()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: a.jobs[0].id)?.stage, .submitted)
        XCTAssertNil(h.store.job(id: b.jobs[0].id)?.notes)
    }

    func testAlreadyWrittenNotesStillUpload() async throws {
        // Pausing OpenAI does not hold website uploads of notes that already exist.
        let h = try Harness()
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 503, code: "server_error", message: "busy")), .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        h.store.updateSettings { $0.timeZoneIdentifier = "Europe/London" }
        let l = try makeOld(h)
        h.online.value = true
        let engine = h.engine()
        await engine.runUntilIdle()
        XCTAssertNotNil(h.store.job(id: l.jobs[0].id)?.notes)
        h.store.updateSettings { $0.openAIPaused = true }
        h.store.updateJob(id: l.jobs[0].id) { $0.nextAttemptAt = nil }
        await engine.tick()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: l.jobs[0].id)?.stage, .submitted)
        XCTAssertEqual(h.notes.calls.value, 1)
    }

    func testSettingsDecodeWithoutPauseFields() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(s.openAIPaused)
        XCTAssertTrue(s.openAIPauseAllowsToday)
    }
}

final class DeferredWriteTests: XCTestCase {
    func testDeferredWritesAreCoalescedAndFlushed() throws {
        let h = try Harness()
        h.store.deferredWrites = true
        let l = try h.addLesson(mode: .single, recordings: 1)
        for i in 0..<50 { h.store.updateJob(id: l.jobs[0].id) { $0.statusMessage = "step \(i)" } }
        h.store.flush()
        let reopened = try LibraryStore(directory: h.store.directory)
        XCTAssertEqual(reopened.job(id: l.jobs[0].id)?.statusMessage, "step 49")
    }

    func testDeferredWritesLandWithoutFlush() throws {
        let h = try Harness()
        h.store.deferredWrites = true
        h.store.updateSettings { $0.globalPrompt = "SAVED LATER" }
        let exp = expectation(description: "saved")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { exp.fulfill() }
        wait(for: [exp], timeout: 3)
        XCTAssertEqual(try LibraryStore(directory: h.store.directory).settings.globalPrompt, "SAVED LATER")
    }
}
