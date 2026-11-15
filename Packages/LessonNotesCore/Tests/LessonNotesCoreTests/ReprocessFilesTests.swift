import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

final class ReprocessFilesTests: XCTestCase {
    func src(_ data: String, _ name: String) throws -> URL {
        let d = tempDir().appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try Data(data.utf8).write(to: u)
        return u
    }

    /// A lesson uploaded with one shared file, plus an engine with a mock replacer.
    func uploaded(_ h: Harness, replacer: MockReplacer) async throws -> (UUID, JobEngine) {
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        try h.store.addAttachment(from: try src("v1", "worksheet.txt"), toJob: jid, role: .studentWork)
        h.store.updateJob(id: jid) { $0.stage = .queued }
        h.submitter.results = [.success(NoteStatusResponse(noteId: "note-1", submissionId: "", status: .published, version: 2,
                                                          files: [RemoteFile(filename: "worksheet.txt", size: 2)]))]
        let engine = h.engine(replacer: replacer)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: jid)?.stage, .submitted)
        XCTAssertEqual(h.store.job(id: jid)?.remoteFiles, [RemoteFile(filename: "worksheet.txt", size: 2)])
        return (jid, engine)
    }

    func testPDFsGetPreviewPrefix() throws {
        XCTAssertEqual(AttachmentRules.storedFilename("Document1.pdf"), "macOS Preview Document1.pdf")
        XCTAssertEqual(AttachmentRules.storedFilename("Notes.PDF"), "macOS Preview Notes.PDF")
        XCTAssertEqual(AttachmentRules.storedFilename("macOS Preview Document1.pdf"), "macOS Preview Document1.pdf", "not doubled")
        XCTAssertEqual(AttachmentRules.storedFilename("Slides.pptx"), "Slides.pptx")
        XCTAssertEqual(AttachmentRules.storedFilename(String(repeating: "x", count: 250) + ".pdf").count, 200)
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let a = try h.store.addAttachment(from: try src("%PDF", "Document1.pdf"), toJob: l.jobs[0].id)
        XCTAssertEqual(a.filename, "macOS Preview Document1.pdf")
        XCTAssertEqual(try h.store.attachmentData(jobId: l.jobs[0].id, a), Data("%PDF".utf8))
        // Setting off: names kept as they are.
        XCTAssertTrue(AppSettings().pdfPreviewPrefix, "on by default")
        XCTAssertTrue(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).pdfPreviewPrefix)
        h.store.updateSettings { $0.pdfPreviewPrefix = false }
        let b = try h.store.addAttachment(from: try src("%PDF", "Document2.pdf"), toJob: l.jobs[0].id)
        XCTAssertEqual(b.filename, "Document2.pdf")
        XCTAssertEqual(AttachmentRules.storedFilename("Document2.pdf", pdfPreviewPrefix: false), "Document2.pdf")
    }

    func testDecodesFilesInResponses() throws {
        let st = try JSONDecoder().decode(NoteStatusResponse.self, from: Data(#"{"note_id":"n","submission_id":"s","status":"pending","files":[{"filename":"a.pdf","size":154820}]}"#.utf8))
        XCTAssertEqual(st.files, [RemoteFile(filename: "a.pdf", size: 154820)])
        let old = try JSONDecoder().decode(NoteStatusResponse.self, from: Data(#"{"note_id":"n","submission_id":"s","status":"pending"}"#.utf8))
        XCTAssertNil(old.files)
    }

    func testClientFileRequests() async throws {
        let t = StubTransport { _ in StubTransport.json(200, #"{"note_id":"n1","submission_id":"s","status":"published","version":2,"files":[{"filename":"b.png","size":1}]}"#) }
        let c = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_K", transport: t)
        let f = [UploadFile(filename: "b.png", contentType: "image/png", data: Data([1]))]
        let r = try await c.replaceFiles(noteId: "note-1", updateId: "mac-files-123456", files: f)
        XCTAssertEqual(r.files, [RemoteFile(filename: "b.png", size: 1)])
        let put = t.requests.value[0]
        XCTAssertEqual(put.httpMethod, "PUT")
        XCTAssertEqual(put.url?.path, "/api/public/lesson-notes/notes/note-1/files")
        let text = String(decoding: put.httpBody!, as: UTF8.self)
        XCTAssertTrue(text.contains("name=\"note\"\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"update_id\":\"mac-files-123456\"}\r\n"))
        XCTAssertTrue(text.contains("name=\"file_uploads\"; filename=\"b.png\""))
        XCTAssertTrue(put.value(forHTTPHeaderField: "Content-Type")!.hasPrefix("multipart/form-data; boundary="))
        // Zero files = remove all attachments (still one note part, no file parts).
        _ = try await c.replaceFiles(noteId: "note-1", updateId: "mac-files-123457", files: [])
        XCTAssertFalse(String(decoding: t.requests.value[1].httpBody!, as: UTF8.self).contains("file_uploads"))
        // Multipart PATCH with replace_files.
        var rep = NoteReplacement(updateId: "mac-replace-1", baseVersion: 2, title: "T", summary: NoteSummary(), privateNotes: nil,
                                  generator: ReplacementGenerator(appVersion: "1", summaryModel: "m"))
        XCTAssertNil((try JSONSerialization.jsonObject(with: rep.jsonData()) as! [String: Any])["replace_files"], "JSON PATCH unchanged")
        rep.replaceFiles = true
        _ = try await c.replace(noteId: "note-1", body: try rep.jsonData(), files: f)
        let patch = t.requests.value[2]
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.url?.path, "/api/public/lesson-notes/notes/note-1")
        XCTAssertTrue(String(decoding: patch.httpBody!, as: UTF8.self).contains("\"replace_files\":true"))
    }

    func testSwapFilesBeforeUploadUsesNewSubmissionId() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        let old = try h.store.addAttachment(from: try src("old", "old.txt"), toJob: jid)
        h.store.updateJob(id: jid) { $0.stage = .queued }
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 422, code: "validation_failed", message: "bad")),
                               .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        let engine = h.engine()
        await engine.runUntilIdle()
        var j = h.store.job(id: jid)!
        XCTAssertEqual(j.stage, .failed)
        let oldSid = j.submissionId
        try h.store.removeAttachment(jobId: jid, id: old.id)
        try h.store.addAttachment(from: try src("new", "new.txt"), toJob: jid, role: .exemplar)
        j = h.store.job(id: jid)!
        XCTAssertNil(j.submissionPayload)
        XCTAssertNotEqual(j.submissionId, oldSid)
        XCTAssertEqual(j.filesChangedSinceNotes, true)
        await engine.retry(jobId: jid)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: jid)?.stage, .submitted)
        XCTAssertEqual(h.submitter.files.value.last?.map(\.filename), ["new.txt"])
    }

    func testUpdateFilesOnlyOnUploadedNote() async throws {
        let h = try Harness()
        let r = MockReplacer()
        let (jid, engine) = try await uploaded(h, replacer: r)
        let first = h.store.job(id: jid)!.attachments![0]
        // Swap the file locally: nothing is sent until George chooses.
        XCTAssertTrue(h.store.job(id: jid)!.attachmentsEditable)
        try h.store.removeAttachment(jobId: jid, id: first.id)
        try h.store.addAttachment(from: try src("v2", "Document1.pdf"), toJob: jid, role: .slides)
        XCTAssertTrue(FileManager.default.fileExists(atPath: h.store.attachmentURL(jobId: jid, first).path), "copy on LetsMeet kept until replaced")
        XCTAssertTrue(h.store.job(id: jid)!.websiteFilesOutOfDate)
        await engine.tick(); await engine.runUntilIdle()
        XCTAssertTrue(r.fileSets.value.isEmpty, "not sent automatically")
        // Update Files Only.
        try h.store.queueFileUpdate(jobId: jid)
        XCTAssertFalse(h.store.job(id: jid)!.websiteFilesOutOfDate)
        await engine.tick(); await engine.runUntilIdle()
        let j = h.store.job(id: jid)!
        XCTAssertEqual(r.fileSets.value.last?.map(\.filename), ["macOS Preview Document1.pdf"])
        XCTAssertEqual(r.ids.value.last, "note-1")
        XCTAssertTrue(r.bodies.value.isEmpty, "notes not replaced")
        XCTAssertNil(j.fileUpdate)
        XCTAssertEqual(j.submittedAttachments?.map(\.filename), ["macOS Preview Document1.pdf"])
        XCTAssertEqual(j.remoteFiles?.map(\.filename), ["macOS Preview Document1.pdf"])
        XCTAssertEqual(j.remoteStatus, .published, "approval unchanged")
        XCTAssertEqual(j.remoteVersion, 2, "no version bump")
        XCTAssertFalse(j.websiteFilesOutOfDate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.store.attachmentURL(jobId: jid, first).path), "old copy pruned after upload")
    }

    func testFileUpdateRetriesWithSameUpdateId() async throws {
        let h = try Harness()
        let r = MockReplacer()
        r.filesResults = [.failure(LetsMeetAPIError(httpStatus: 503, code: "server_error", message: "busy")),
                          .success(NoteFilesResponse(status: .published, version: 2))]
        let (jid, engine) = try await uploaded(h, replacer: r)
        try h.store.addAttachment(from: try src("x", "extra.png"), toJob: jid)
        try h.store.queueFileUpdate(jobId: jid)
        await engine.tick(); await engine.runUntilIdle()
        XCTAssertNotNil(h.store.job(id: jid)?.fileUpdate?.nextAttemptAt)
        h.store.updateJob(id: jid) { $0.fileUpdate?.nextAttemptAt = nil }
        await engine.tick(); await engine.runUntilIdle()
        XCTAssertEqual(r.fileUpdateIds.value.count, 2)
        XCTAssertEqual(r.fileUpdateIds.value[0], r.fileUpdateIds.value[1])
        XCTAssertEqual(r.fileSets.value[0], r.fileSets.value[1])
        XCTAssertNil(h.store.job(id: jid)?.fileUpdate)
        XCTAssertEqual(h.store.job(id: jid)?.remoteFiles?.map(\.filename), ["worksheet.txt", "extra.png"], "falls back to the files sent")
    }

    func testFileUpdateErrors() async throws {
        let h = try Harness()
        let r = MockReplacer()
        r.filesResults = [.failure(LetsMeetAPIError(httpStatus: 422, code: "invalid_file_uploads", message: "Unsupported file type"))]
        let (jid, engine) = try await uploaded(h, replacer: r)
        try h.store.queueFileUpdate(jobId: jid)
        await engine.tick(); await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: jid)?.fileUpdate?.state, .failed)
        r.filesResults = [.failure(LetsMeetAPIError(httpStatus: 404, code: "note_not_found", message: "gone"))]
        try h.store.queueFileUpdate(jobId: jid)
        await engine.tick(); await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: jid)?.fileUpdate?.state, .noteDeleted)
        XCTAssertEqual(h.store.job(id: jid)?.remoteStatus, .deleted)
    }

    func testRegenerateWithChangedFilesReplacesBoth() async throws {
        let h = try Harness()
        let r = MockReplacer()
        r.results = [.success(NoteReplaceResponse(noteId: "note-1", submissionId: nil, status: .pending, version: 3,
                                                  files: [RemoteFile(filename: "pupil essay.txt", size: 5)]))]
        let (jid, engine) = try await uploaded(h, replacer: r)
        let first = h.store.job(id: jid)!.attachments![0]
        // Untick the old file for sharing (keep it for AI), add a new shared one, and a private model answer.
        try h.store.setAttachmentShared(jobId: jid, id: first.id, shared: false)
        try h.store.addAttachment(from: try src("essay", "pupil essay.txt"), toJob: jid, role: .studentWork)
        try h.store.addAttachment(from: try src("model", "model.txt"), toJob: jid, role: .exemplar, shareWithPupil: false)
        let draft = try await NotesRegeneration.regenerate(store: h.store, jobId: jid, options: RegenerationOptions(), producer: h.notes)
        XCTAssertEqual(h.notes.lastContext.value?.materials.map(\.filename), ["worksheet.txt", "pupil essay.txt", "model.txt"],
                       "AI sees shared and unshared files")
        XCTAssertEqual(try NotesRegeneration.accept(store: h.store, jobId: jid, versionId: draft.id), .replacementQueued)
        XCTAssertEqual(h.store.job(id: jid)?.replacement?.files?.map(\.filename), ["pupil essay.txt"])
        await engine.tick(); await engine.runUntilIdle()
        let j = h.store.job(id: jid)!
        let sent = try JSONSerialization.jsonObject(with: r.bodies.value.last!) as! [String: Any]
        XCTAssertEqual(sent["replace_files"] as? Bool, true)
        XCTAssertEqual(r.fileSets.value.last?.map(\.filename), ["pupil essay.txt"], "only shared files uploaded")
        XCTAssertNil(j.replacement)
        XCTAssertEqual(j.submittedAttachments?.map(\.filename), ["pupil essay.txt"])
        XCTAssertEqual(j.remoteFiles, [RemoteFile(filename: "pupil essay.txt", size: 5)])
        XCTAssertEqual(j.remoteVersion, 3)
        XCTAssertEqual(j.remoteStatus, .pending)
        XCTAssertNil(j.filesChangedSinceNotes)
    }

    func testRegenerateWithoutFileChangesStaysJSON() async throws {
        let h = try Harness()
        let r = MockReplacer()
        r.results = [.success(NoteReplaceResponse(noteId: "note-1", submissionId: nil, status: .pending, version: 3))]
        let (jid, engine) = try await uploaded(h, replacer: r)
        let first = h.store.job(id: jid)!.attachments![0]
        h.store.setAttachmentIncluded(jobId: jid, id: first.id, included: false)
        XCTAssertEqual(h.store.job(id: jid)?.filesChangedSinceNotes, true)
        XCTAssertFalse(h.store.job(id: jid)!.websiteFilesOutOfDate, "AI switch doesn't change the website files")
        let draft = try await NotesRegeneration.regenerate(store: h.store, jobId: jid, options: RegenerationOptions(), producer: h.notes)
        XCTAssertEqual(h.notes.lastContext.value?.materials.count, 0)
        _ = try NotesRegeneration.accept(store: h.store, jobId: jid, versionId: draft.id)
        XCTAssertNil(h.store.job(id: jid)?.replacement?.files)
        await engine.tick(); await engine.runUntilIdle()
        XCTAssertTrue(r.fileSets.value.isEmpty)
        let sent = try JSONSerialization.jsonObject(with: r.bodies.value.last!) as! [String: Any]
        XCTAssertNil(sent["replace_files"])
    }

    func testLegacyContextOnlyDecodesAsNotShared() throws {
        let a = try JSONDecoder().decode(LessonAttachment.self, from: Data(#"{"id":"\#(UUID().uuidString)","filename":"a.pdf","byteCount":1,"sha256":"x","contextOnly":true}"#.utf8))
        XCTAssertFalse(a.shareWithPupil)
        let b = try JSONDecoder().decode(LessonAttachment.self, from: Data(#"{"id":"\#(UUID().uuidString)","filename":"a.pdf","byteCount":1,"sha256":"x"}"#.utf8))
        XCTAssertTrue(b.shareWithPupil)
    }
}
