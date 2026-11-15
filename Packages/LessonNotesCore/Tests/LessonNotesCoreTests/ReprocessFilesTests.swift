import XCTest
@testable import LessonNotesCore

final class ReprocessFilesTests: XCTestCase {
    func src(_ data: String, _ name: String) throws -> URL {
        let d = tempDir().appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try Data(data.utf8).write(to: u)
        return u
    }

    func testSwapFilesAfterNotesBeforeUpload() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        let old = try h.store.addAttachment(from: try src("old", "old.txt"), toJob: jid)
        h.store.updateJob(id: jid) { $0.stage = .queued }
        // Upload fails with a validation error after the payload was frozen.
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 422, code: "validation_failed", message: "bad")),
                               .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        let engine = h.engine()
        await engine.runUntilIdle()
        var j = h.store.job(id: jid)!
        XCTAssertEqual(j.stage, .failed)
        XCTAssertNotNil(j.submissionPayload)
        XCTAssertTrue(j.attachmentsEditable, "failed and not uploaded: files can be swapped")
        let oldSid = j.submissionId
        // Swap the file.
        try h.store.removeAttachment(jobId: jid, id: old.id)
        try h.store.addAttachment(from: try src("new", "new.txt"), toJob: jid, role: .exemplar)
        j = h.store.job(id: jid)!
        XCTAssertNil(j.submissionPayload, "prepared upload discarded")
        XCTAssertNil(j.submittedAttachments)
        XCTAssertNotEqual(j.submissionId, oldSid, "new submission id (same id + different files = conflict)")
        XCTAssertEqual(j.filesChangedSinceNotes, true)
        // Retry uploads the new file under the new id.
        await engine.retry(jobId: jid)
        await engine.runUntilIdle()
        j = h.store.job(id: jid)!
        XCTAssertEqual(j.stage, .submitted)
        XCTAssertEqual(h.submitter.files.value.last?.map(\.filename), ["new.txt"])
        let body = try JSONSerialization.jsonObject(with: h.submitter.bodies.value.last!) as! [String: Any]
        XCTAssertEqual(body["submission_id"] as? String, j.submissionId)
    }

    func testRunningJobWithNotesIsLocked() throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.store.updateJob(id: l.jobs[0].id) { $0.notes = GeneratedNotes(title: "T"); $0.stage = .submitting }
        XCTAssertFalse(h.store.job(id: l.jobs[0].id)!.attachmentsEditable)
        h.store.updateJob(id: l.jobs[0].id) { $0.stage = .submitted }
        XCTAssertFalse(h.store.job(id: l.jobs[0].id)!.attachmentsEditable)
    }

    func testContextOnlyFilesOnUploadedNoteAndRegeneration() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        let uploaded = try h.store.addAttachment(from: try src("slide text", "slides.txt"), toJob: jid, role: .slides)
        h.store.updateJob(id: jid) { $0.stage = .queued }
        await h.engine().runUntilIdle()
        XCTAssertEqual(h.store.job(id: jid)?.stage, .submitted)
        XCTAssertThrowsError(try h.store.addAttachment(from: try src("x", "x.txt"), toJob: jid), "uploaded note: files fixed")
        // Context-only files can be added to an uploaded note, and the uploaded file excluded from context.
        let extra = try h.store.addAttachment(from: try src("pupil essay", "essay.txt"), toJob: jid, role: .studentWork, contextOnly: true)
        h.store.setAttachmentIncluded(jobId: jid, id: uploaded.id, included: false)
        XCTAssertEqual(h.store.job(id: jid)?.filesChangedSinceNotes, true)
        XCTAssertEqual(h.store.job(id: jid)?.uploadAttachments.map(\.filename), ["slides.txt"])
        XCTAssertEqual(h.store.job(id: jid)?.stage, .submitted, "nothing re-uploaded")
        _ = try await NotesRegeneration.regenerate(store: h.store, jobId: jid, options: RegenerationOptions(), producer: h.notes)
        let ctx = try XCTUnwrap(h.notes.lastContext.value)
        XCTAssertEqual(ctx.materials.map(\.filename), ["essay.txt"], "regeneration uses the current file choices")
        XCTAssertEqual(ctx.materials.first?.role, .studentWork)
        // Context-only files can be removed at any time.
        try h.store.removeAttachment(jobId: jid, id: extra.id)
        XCTAssertEqual(h.store.job(id: jid)?.attachments?.count, 1)
        XCTAssertEqual(h.submitter.bodies.value.count, 1)
    }

    func testRedoWithDifferentFilesReusesTranscript() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        try h.store.addAttachment(from: try src("v1", "worksheet.txt"), toJob: jid, role: .studentWork)
        h.store.updateJob(id: jid) { $0.stage = .queued }
        let engine = h.engine()
        await engine.runUntilIdle()
        let original = h.store.job(id: jid)!
        XCTAssertEqual(original.stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1)

        let redo = try RedoFromTranscript.make(store: h.store, jobId: jid)
        let nid = redo.jobs[0].id
        var nj = h.store.job(id: nid)!
        XCTAssertEqual(nj.stage, .held, "waits so files can be changed first")
        XCTAssertNotEqual(nj.submissionId, original.submissionId)
        XCTAssertEqual(store(h).transcriptState(jobId: nid), .valid)
        XCTAssertEqual(nj.attachments?.map(\.filename), ["worksheet.txt"])
        XCTAssertEqual(nj.attachments?.first?.role, .studentWork)
        XCTAssertTrue(nj.attachmentsEditable)
        // Swap the file, then start.
        try h.store.removeAttachment(jobId: nid, id: nj.attachments![0].id)
        try h.store.addAttachment(from: try src("v2", "worksheet-v2.txt"), toJob: nid, role: .exemplar)
        await engine.startHeld(jobId: nid)
        await engine.runUntilIdle()
        nj = h.store.job(id: nid)!
        XCTAssertEqual(nj.stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1, "no re-transcription")
        XCTAssertEqual(h.notes.lastContext.value?.materials.map(\.filename), ["worksheet-v2.txt"])
        XCTAssertEqual(h.submitter.files.value.last?.map(\.filename), ["worksheet-v2.txt"])
        let body = try JSONSerialization.jsonObject(with: h.submitter.bodies.value.last!) as! [String: Any]
        XCTAssertEqual(body["submission_id"] as? String, nj.submissionId, "submitted as a new note")
        XCTAssertEqual(h.store.job(id: jid)?.submissionId, original.submissionId, "original untouched")
    }

    func store(_ h: Harness) -> LibraryStore { h.store }
}
