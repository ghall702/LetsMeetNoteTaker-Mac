import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

/// Writes a ZIP with stored (uncompressed) entries — enough to test the Office readers.
func makeZip(_ files: [(String, String)]) -> Data {
    var out = Data(), central = Data()
    func le16(_ v: Int) -> Data { Data([UInt8(v & 0xff), UInt8((v >> 8) & 0xff)]) }
    func le32(_ v: Int) -> Data { le16(v & 0xffff) + le16((v >> 16) & 0xffff) }
    for (name, text) in files {
        let n = Data(name.utf8), d = Data(text.utf8), offset = out.count
        var local = le32(0x04034b50)
        for v in [20, 0, 0, 0, 0] { local += le16(v) }
        local += le32(0); local += le32(d.count); local += le32(d.count)
        local += le16(n.count); local += le16(0); local += n; local += d
        out += local
        var c = le32(0x02014b50)
        for v in [20, 20, 0, 0, 0, 0] { c += le16(v) }
        c += le32(0); c += le32(d.count); c += le32(d.count)
        for v in [n.count, 0, 0, 0, 0] { c += le16(v) }
        c += le32(0); c += le32(offset); c += n
        central += c
    }
    let cdOffset = out.count
    out += central
    out += le32(0x06054b50)
    for v in [0, 0, files.count, files.count] { out += le16(v) }
    out += le32(central.count); out += le32(cdOffset); out += le16(0)
    return out
}

final class AttachmentTests: XCTestCase {
    func write(_ data: Data, _ name: String) throws -> URL {
        let d = tempDir().appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let u = d.appendingPathComponent(name)
        try data.write(to: u)
        return u
    }

    // MARK: Rules

    func testRules() {
        XCTAssertNil(AttachmentRules.check(filename: "Homework.PDF", byteCount: 10))
        XCTAssertEqual(AttachmentRules.check(filename: "lesson.mp4", byteCount: 10), .unsupportedType("lesson.mp4"))
        XCTAssertEqual(AttachmentRules.check(filename: "audio.m4a", byteCount: 10), .unsupportedType("audio.m4a"))
        XCTAssertEqual(AttachmentRules.check(filename: "page.html", byteCount: 10), .unsupportedType("page.html"))
        XCTAssertEqual(AttachmentRules.check(filename: "a.pdf", byteCount: 0), .empty("a.pdf"))
        XCTAssertNil(AttachmentRules.check(filename: "a.pdf", byteCount: 20_000_000))
        XCTAssertEqual(AttachmentRules.check(filename: "a.pdf", byteCount: 20_000_001), .tooLarge("a.pdf", 20_000_001))
        XCTAssertFalse(AttachmentRules.isValidFilename("a/b.pdf"))
        XCTAssertFalse(AttachmentRules.isValidFilename("a\\b.pdf"))
        XCTAssertFalse(AttachmentRules.isValidFilename("a\u{7}.pdf"))
        XCTAssertEqual(AttachmentRules.sanitisedFilename("a/b\u{1}.pdf"), "a-b-.pdf")
        let long = String(repeating: "x", count: 300) + ".pdf"
        XCTAssertEqual(AttachmentRules.sanitisedFilename(long).count, 200)
        XCTAssertTrue(AttachmentRules.sanitisedFilename(long).hasSuffix(".pdf"))
        let six = (0..<6).map { LessonAttachment(filename: "f\($0).pdf", byteCount: 1, sha256: "x") }
        XCTAssertEqual(AttachmentRules.check(six, noteJSONBytes: 100), .tooMany)
        let five = (0..<5).map { LessonAttachment(filename: "f\($0).pdf", byteCount: 20_000_000, sha256: "x") }
        XCTAssertNil(AttachmentRules.check(five, noteJSONBytes: 6_000_000 - 1), "5 × 20 MB + 6 MB note fits under 106.1 MB")
        XCTAssertNotNil(AttachmentRules.check(five, noteJSONBytes: 6_100_000))
    }

    // MARK: Multipart

    func testMultipartFormat() throws {
        let note = Data(#"{"submission_id":"s"}"#.utf8)
        let files = [UploadFile(filename: "home\"work.pdf", contentType: "application/pdf", data: Data([0, 1, 2])),
                     UploadFile(filename: "slides.pptx", contentType: AttachmentRules.contentType(forExtension: "pptx"), data: Data("PK".utf8))]
        let body = MultipartBody.build(noteJSON: note, files: files, boundary: "BOUND")
        let text = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("--BOUND\r\nContent-Disposition: form-data; name=\"note\"\r\nContent-Type: application/json; charset=utf-8\r\n\r\n{\"submission_id\":\"s\"}\r\n"))
        XCTAssertTrue(text.contains("--BOUND\r\nContent-Disposition: form-data; name=\"file_uploads\"; filename=\"home%22work.pdf\"\r\nContent-Type: application/pdf\r\n\r\n"))
        XCTAssertTrue(text.hasSuffix("--BOUND--\r\n"))
        XCTAssertEqual(text.components(separatedBy: "name=\"file_uploads\"").count - 1, 2)
        XCTAssertEqual(text.components(separatedBy: "name=\"note\"").count - 1, 1)
        XCTAssertLessThan(text.range(of: "home%22work.pdf")!.lowerBound, text.range(of: "slides.pptx")!.lowerBound, "file order kept")
        // Size estimate matches the real body when the boundary has the app's length.
        let b = MultipartBody.makeBoundary()
        let real = MultipartBody.build(noteJSON: note, files: files, boundary: b).count
        XCTAssertEqual(MultipartBody.estimatedSize(noteJSONBytes: note.count, files: files.map { ($0.filename, $0.contentType, $0.data.count) }), real)
    }

    func testClientSendsMultipartOnlyWithFiles() async throws {
        let t = StubTransport { _ in StubTransport.json(201, #"{"note_id":"n1","submission_id":"s","status":"pending"}"#) }
        let c = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_K", transport: t)
        let note = Data(#"{"submission_id":"s"}"#.utf8)
        _ = try await c.submit(body: note, files: [])
        _ = try await c.submit(body: note, files: [UploadFile(filename: "a.png", contentType: "image/png", data: Data([9]))])
        let (json, multi) = (t.requests.value[0], t.requests.value[1])
        XCTAssertEqual(json.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(json.httpBody, note)
        let ct = try XCTUnwrap(multi.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(ct.hasPrefix("multipart/form-data; boundary="))
        let boundary = String(ct.dropFirst("multipart/form-data; boundary=".count))
        XCTAssertTrue(String(decoding: multi.httpBody!, as: UTF8.self).hasPrefix("--\(boundary)\r\n"))
        XCTAssertEqual(multi.httpMethod, "POST")
        XCTAssertEqual(multi.url?.path, "/api/public/lesson-notes/notes")
        XCTAssertEqual(multi.value(forHTTPHeaderField: "Authorization"), "Bearer ghln_K")
    }

    // MARK: Store

    func testAddRemoveAndLock() throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        let src = try write(Data("worksheet".utf8), "Worksheet.txt")
        let a = try h.store.addAttachment(from: src, toJob: jid, role: .studentWork)
        XCTAssertEqual(a.byteCount, 9)
        XCTAssertEqual(a.sha256, SHA256Hasher.hex(of: Data("worksheet".utf8)))
        XCTAssertEqual(try h.store.attachmentData(jobId: jid, a), Data("worksheet".utf8))
        try Data("changed".utf8).write(to: src) // the original changing later does not affect the stored copy
        XCTAssertEqual(try h.store.attachmentData(jobId: jid, a), Data("worksheet".utf8))
        XCTAssertThrowsError(try h.store.addAttachment(from: try write(Data([1]), "clip.mov"), toJob: jid))
        for i in 0..<4 { try h.store.addAttachment(from: try write(Data([UInt8(i)]), "p\(i).png"), toJob: jid) }
        XCTAssertThrowsError(try h.store.addAttachment(from: try write(Data([1]), "six.png"), toJob: jid)) { XCTAssertEqual($0 as? AttachmentRules.Problem, .tooMany) }
        try h.store.removeAttachment(jobId: jid, id: a.id)
        XCTAssertEqual(h.store.job(id: jid)?.attachments?.count, 4)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.store.attachmentURL(jobId: jid, a).path))
        // Role can change any time; files are locked only while the note is being uploaded.
        let first = h.store.job(id: jid)!.attachments![0]
        h.store.updateJob(id: jid) { $0.notes = GeneratedNotes(title: "T"); $0.stage = .submitting }
        h.store.setAttachmentRole(jobId: jid, id: first.id, role: .slides)
        XCTAssertEqual(h.store.job(id: jid)?.attachments?.first?.role, .slides)
        XCTAssertThrowsError(try h.store.addAttachment(from: src, toJob: jid)) { XCTAssertEqual($0 as? LibraryStore.AttachmentError, .notEditable) }
        XCTAssertThrowsError(try h.store.removeAttachment(jobId: jid, id: first.id))
        // Deleting the lesson deletes the stored copies.
        h.store.deleteLesson(id: l.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: h.store.attachmentURL(jobId: jid, first).path))
    }

    func testOldJobsDecodeWithoutAttachments() throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        var obj = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(l.jobs[0])) as! [String: Any]
        obj["attachments"] = nil; obj["submittedAttachments"] = nil
        let j = try JSONCoding.decoder().decode(Job.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertNil(j.attachments)
        let a = try JSONDecoder().decode(LessonAttachment.self, from: Data(#"{"id":"\#(UUID().uuidString)","filename":"a.pdf","byteCount":1,"sha256":"x"}"#.utf8))
        XCTAssertEqual(a.role, .other)
    }

    // MARK: Engine

    func testFilesGoToOpenAIAndAreUploadedIdentically() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        let pdf = Data("%PDF-1.4\n1 0 obj << /Type /Page >> endobj\n".utf8)
        try h.store.addAttachment(from: try write(pdf, "Slides.pdf"), toJob: jid, role: .slides)
        try h.store.addAttachment(from: try write(Data([0x89, 0x50, 0x4e, 0x47]), "pupil-answer.png"), toJob: jid, role: .studentWork)
        try h.store.addAttachment(from: try write(Data("Model paragraph".utf8), "model.txt"), toJob: jid, role: .exemplar)
        let privateFile = try h.store.addAttachment(from: try write(Data("Answers".utf8), "answers.txt"), toJob: jid, role: .exemplar)
        h.store.setAttachmentIncluded(jobId: jid, id: privateFile.id, included: false)
        h.store.updateJob(id: jid) { $0.stage = .queued }
        // First upload attempt fails with a retryable error; the retry must send identical bytes.
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 503, code: "server_error", message: "busy")),
                               .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        let engine = h.engine()
        await engine.runUntilIdle()
        let ctx = try XCTUnwrap(h.notes.lastContext.value)
        XCTAssertEqual(ctx.materials.map(\.filename), ["macOS Preview Slides.pdf", "pupil-answer.png", "model.txt"], "excluded file not sent to OpenAI")
        XCTAssertFalse(ctx.header().contains("answers.txt"))
        XCTAssertEqual(ctx.materials[0].content, .pdf(base64: pdf.base64EncodedString()), "PDFs go to OpenAI as the PDF itself")
        XCTAssertEqual(ctx.materials[1].content, .image(mimeType: "image/png", base64: Data([0x89, 0x50, 0x4e, 0x47]).base64EncodedString()))
        XCTAssertEqual(ctx.materials[2].content, .text("Model paragraph", truncated: false))
        XCTAssertTrue(ctx.header().contains("“macOS Preview Slides.pdf” — the tutor's lesson slides"))
        XCTAssertTrue(ctx.header().contains("“pupil-answer.png” — work produced by the pupil (student-produced"))
        XCTAssertTrue(ctx.header().contains("“model.txt” — exemplar modelling material written by the tutor"))
        XCTAssertNotNil(h.store.job(id: jid)?.submittedAttachments)
        h.store.updateJob(id: jid) { $0.nextAttemptAt = nil }
        await engine.tick()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: jid)?.stage, .submitted)
        let sent = h.submitter.files.value
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], sent[1], "retry sends the same files in the same order")
        XCTAssertEqual(sent[0].map(\.filename), ["macOS Preview Slides.pdf", "pupil-answer.png", "model.txt", "answers.txt"], "excluded file still uploaded for the pupil")
        XCTAssertEqual(sent[0].map(\.contentType), ["application/pdf", "image/png", "text/plain", "text/plain"])
        XCTAssertEqual(h.submitter.bodies.value[0], h.submitter.bodies.value[1])
        let body = try JSONSerialization.jsonObject(with: h.submitter.bodies.value[0]) as! [String: Any]
        XCTAssertNil(body["file_uploads"], "files are separate multipart parts, not in the note JSON")
        XCTAssertNil(body["attachments"])
    }

    func testNoFilesKeepsJSONSubmission() async throws {
        let h = try Harness()
        _ = try h.addLesson(mode: .single, recordings: 1)
        await h.engine().runUntilIdle()
        XCTAssertTrue(h.submitter.files.value.isEmpty)
        XCTAssertEqual(h.submitter.bodies.value.count, 1)
    }

    func testMissingStoredFileNeedsAttention() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1, held: true)
        let jid = l.jobs[0].id
        let a = try h.store.addAttachment(from: try write(Data("x".utf8), "a.txt"), toJob: jid)
        try FileManager.default.removeItem(at: h.store.attachmentURL(jobId: jid, a))
        h.store.updateJob(id: jid) { $0.stage = .queued }
        await h.engine().runUntilIdle()
        let j = h.store.job(id: jid)!
        XCTAssertEqual(j.stage, .failed)
        XCTAssertEqual(j.error?.kind, .validation)
        XCTAssertTrue(h.submitter.bodies.value.isEmpty, "nothing sent")
    }

    // MARK: OpenAI request

    func testResponsesBodyCarriesFiles() throws {
        let mats = [ContextMaterial(filename: "s.pdf", role: .slides, content: .pdf(base64: "UERG")),
                    ContextMaterial(filename: "w.jpg", role: .studentWork, content: .image(mimeType: "image/jpeg", base64: "SlBH")),
                    ContextMaterial(filename: "m.docx", role: .exemplar, content: .text("Model", truncated: true)),
                    ContextMaterial(filename: "old.ppt", role: .slides, content: .unreadable)]
        let req = ResponsesRequest(model: "m", instructions: "i", userContent: "TRANSCRIPT", materials: mats)
        let input = (req.body(stream: true)["input"] as! [[String: Any]])[0]["content"] as! [[String: Any]]
        XCTAssertEqual(input[0]["type"] as? String, "input_text")
        XCTAssertEqual(input[0]["text"] as? String, "TRANSCRIPT")
        XCTAssertEqual(input.compactMap { $0["type"] as? String }, ["input_text", "input_text", "input_file", "input_text", "input_image", "input_text", "input_text"])
        let file = input.first { $0["type"] as? String == "input_file" }!
        XCTAssertEqual(file["filename"] as? String, "s.pdf")
        XCTAssertEqual(file["file_data"] as? String, "data:application/pdf;base64,UERG")
        XCTAssertEqual(input.first { $0["type"] as? String == "input_image" }?["image_url"] as? String, "data:image/jpeg;base64,SlBH")
        XCTAssertTrue((input[5]["text"] as! String).contains("Only the first part"))
        // Without files the request is unchanged (plain text content).
        let plain = ResponsesRequest(model: "m", instructions: "i", userContent: "T").body(stream: false)
        XCTAssertEqual((plain["input"] as! [[String: Any]])[0]["content"] as? String, "T")
        XCTAssertGreaterThan(OpenAIClient.roughInputEstimate(req), OpenAIClient.roughInputEstimate(ResponsesRequest(model: "m", instructions: "i", userContent: "TRANSCRIPT")) + 3_000)
    }

    func testChunkedNotesSendFilesOnlyWhenCombining() async throws {
        final class Recorder: ResponsesPerforming, @unchecked Sendable {
            let requests = Box<[ResponsesRequest]>([])
            func perform(_ request: ResponsesRequest, onProgress: (@Sendable (Int) -> Void)?) async throws -> ResponsesResult {
                requests.mutate { $0.append(request) }
                return ResponsesResult(outputText: validNotesJSON, refusal: nil, status: "completed", incompleteReason: nil, model: "m")
            }
        }
        let r = Recorder()
        let g = NotesGenerator(performer: r, model: "m", effort: .modelDefault, chunkThresholdTokens: 4_000)
        let ctx = NotesRequestContext(pupilName: "P", lessonDate: "2026-11-15",
                                      materials: [ContextMaterial(filename: "s.pdf", role: .slides, content: .pdf(base64: "UERG"))])
        _ = try await g.generate(transcript: String(repeating: "word ", count: 30_000), context: ctx, instructions: "i")
        let reqs = r.requests.value
        XCTAssertGreaterThan(reqs.count, 2)
        XCTAssertTrue(reqs.dropLast().allSatisfy { $0.materials.isEmpty })
        XCTAssertEqual(reqs.last?.materials.count, 1)
    }

    // MARK: Office text

    func testOfficeText() {
        let docx = makeZip([("word/document.xml", #"<w:document><w:body><w:p><w:r><w:t>Paragraph one</w:t></w:r></w:p><w:p><w:r><w:t>Two</w:t></w:r><w:r><w:t xml:space="preserve"> parts</w:t></w:r></w:p></w:body></w:document>"#)])
        XCTAssertEqual(OfficeText.extract(docx, kind: "docx", inflate: nil), "Paragraph one\nTwo parts")
        let pptx = makeZip([("ppt/slides/slide10.xml", #"<p:sld><a:p><a:r><a:t>Ten</a:t></a:r></a:p></p:sld>"#),
                            ("ppt/slides/slide2.xml", #"<p:sld><a:p><a:r><a:t>Metaphor</a:t></a:r></a:p><a:p><a:r><a:t>Simile</a:t></a:r></a:p></p:sld>"#),
                            ("ppt/slides/_rels/slide2.xml.rels", "<x/>")])
        XCTAssertEqual(OfficeText.extract(pptx, kind: "pptx", inflate: nil), "Slide 1:\nMetaphor\nSimile\n\nSlide 2:\nTen")
        let xlsx = makeZip([("xl/sharedStrings.xml", #"<sst><si><t>Name</t></si><si><t>Score</t></si></sst>"#),
                            ("xl/worksheets/sheet1.xml", #"<worksheet><sheetData><row><c><v>12</v></c><c><v>7</v></c></row></sheetData></worksheet>"#)])
        XCTAssertEqual(OfficeText.extract(xlsx, kind: "xlsx", inflate: nil), "Name\nScore\n12\t7")
        XCTAssertNil(OfficeText.extract(Data("not a zip".utf8), kind: "docx", inflate: nil))
    }

    func testLoaderReadsTextAndMarksUnreadable() throws {
        let loader = MaterialLoader(inflate: nil)
        let docxURL = try write(makeZip([("word/document.xml", "<w:p><w:t>Hello</w:t></w:p>")]), "notes.docx")
        let a = LessonAttachment(filename: "notes.docx", byteCount: 1, sha256: "", role: .exemplar)
        XCTAssertEqual(loader.load(a, at: docxURL).content, .text("Hello", truncated: false))
        let ppt = LessonAttachment(filename: "old.ppt", byteCount: 1, sha256: "")
        XCTAssertEqual(loader.load(ppt, at: try write(Data([1]), "old.ppt")).content, .unreadable)
        let big = try write(Data(String(repeating: "a", count: MaterialLoader.maxTextCharacters + 10).utf8), "big.txt")
        if case .text(let t, let truncated) = loader.load(LessonAttachment(filename: "big.txt", byteCount: 1, sha256: ""), at: big).content {
            XCTAssertTrue(truncated); XCTAssertEqual(t.count, MaterialLoader.maxTextCharacters)
        } else { XCTFail() }
    }
}
