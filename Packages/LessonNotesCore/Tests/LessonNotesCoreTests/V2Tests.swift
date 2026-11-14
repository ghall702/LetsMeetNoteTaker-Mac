import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

func notesJSON(title: String = "Triangles", overview: String = "We sorted triangles.", learning: String = "## Triangles\n- Equilateral: 3 equal sides",
               worked: [String] = ["**Example:** 5, 5, 8 → isosceles"], quotes: [String] = [], homework: String = "", praise: String = "",
               keyPoints: [String] = ["A right angle is 90°"], privateNotes: String = "") -> String {
    let obj: [String: Any] = ["title": title, "overview": overview, "key_points": keyPoints, "next_steps": [], "homework": homework,
                              "vocabulary": ["isosceles"], "praise": praise, "key_quotes": quotes, "learning_content": learning,
                              "worked_examples": worked, "private_notes": privateNotes]
    return String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), encoding: .utf8)!
}

/// Performer that returns scripted results in order.
final class ScriptPerformer: ResponsesPerforming, @unchecked Sendable {
    let requests = Box<[ResponsesRequest]>([])
    var script: [Result<ResponsesResult, Error>]
    init(_ script: [Result<ResponsesResult, Error>]) { self.script = script }
    static func ok(_ text: String) -> Result<ResponsesResult, Error> {
        .success(ResponsesResult(outputText: text, refusal: nil, status: "completed", incompleteReason: nil, model: "m"))
    }
    func perform(_ request: ResponsesRequest, onProgress: (@Sendable (Int) -> Void)?) async throws -> ResponsesResult {
        let n = requests.value.count
        requests.mutate { $0.append(request) }
        switch script[min(n, script.count - 1)] {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
}

final class MockReplacer: NoteReplacing, @unchecked Sendable {
    let bodies = Box<[Data]>([])
    let ids = Box<[String]>([])
    var results: [Result<NoteReplaceResponse, Error>] = []
    var statusVersion: Int? = 7
    var statusResult: NoteStatus = .published
    func replace(noteId: String, body: Data) async throws -> NoteReplaceResponse {
        let n = bodies.value.count
        bodies.mutate { $0.append(body) }
        ids.mutate { $0.append(noteId) }
        if results.isEmpty { return NoteReplaceResponse(noteId: noteId, submissionId: nil, status: .pending, version: 3, previousStatus: .published) }
        switch results[min(n, results.count - 1)] {
        case .success(let r): return r
        case .failure(let e): throw e
        }
    }
    func status(of id: String) async throws -> NoteStatusResponse {
        NoteStatusResponse(noteId: id, submissionId: id, status: statusResult, version: statusVersion)
    }
}

extension Harness {
    func engine(replacer: MockReplacer) -> JobEngine {
        let ex = extractor, tr = transcriber, no = notes, su = submitter, on = online, cl = clock
        let deps = EngineDependencies(extractor: ex, transcriber: tr, makeNotesProducer: { no }, makeSubmitter: { su },
                                      isOnline: { on.value }, appVersion: "2.0.0-test", makeReplacer: { replacer })
        return JobEngine(store: store, deps: deps, tempRoot: tempRoot, retryPolicy: RetryPolicy(jitterFraction: 0), now: { cl.value })
    }

    /// A lesson processed end to end and submitted (website version 2).
    func submittedLesson(replacer: MockReplacer) async throws -> (Lesson, JobEngine) {
        let l = try addLesson(mode: .single, recordings: 1)
        submitter.results = [.success(NoteStatusResponse(noteId: "note-1", submissionId: "", status: .published, version: 2))]
        let e = engine(replacer: replacer)
        await e.runUntilIdle()
        return (store.lesson(id: l.id)!, e)
    }
}

struct FixedProducer: NotesProducing {
    var notes: GeneratedNotes
    var model = "regen-model"
    let calls = Box<[String]>([])
    func produceNotes(transcript: String, context: NotesRequestContext, instructions: String,
                      progress: @escaping @Sendable (Double, String) -> Void) async throws -> ProducedNotes {
        calls.mutate { $0.append(instructions + "\n<<TRANSCRIPT>>\n" + transcript) }
        return ProducedNotes(notes: notes, model: model, effort: .high)
    }
}

// MARK: - Expanded fields, schema, empty handling

final class ExpandedNotesTests: XCTestCase {
    func testAllFieldsParsedAndSubmitted() throws {
        let n = try NotesSchema.parse(notesJSON(quotes: ["\"Two sides the same means isosceles.\""]))
        XCTAssertEqual(n.learningContent, "## Triangles\n- Equilateral: 3 equal sides")
        XCTAssertEqual(n.workedExamples, ["**Example:** 5, 5, 8 → isosceles"])
        XCTAssertEqual(n.keyQuotes.count, 1)
        let s = NotesSchema.summary(from: n)
        let obj = try JSONSerialization.jsonObject(with: JSONCoding.encoder().encode(s)) as! [String: Any]
        XCTAssertEqual(Set(obj.keys), ["overview", "key_points", "next_steps", "homework", "vocabulary", "praise",
                                       "learning_content", "worked_examples", "key_quotes"])
        XCTAssertEqual(obj["homework"] as? String, "", "empty text stays \"\"")
        XCTAssertEqual((obj["next_steps"] as? [String])?.count, 0, "empty arrays stay []")
        XCTAssertEqual(obj["learning_content"] as? String, "## Triangles\n- Equilateral: 3 equal sides", "Markdown preserved verbatim")
    }

    func testSchemaIsStrictAndComplete() {
        let s = NotesSchema.jsonSchema
        XCTAssertEqual(s["additionalProperties"] as? Bool, false)
        let props = s["properties"] as! [String: [String: Any]]
        XCTAssertEqual(Set(props.keys), Set(NotesSchema.requiredFields))
        XCTAssertEqual(props["learning_content"]?["type"] as? String, "string")
        XCTAssertEqual(props["worked_examples"]?["type"] as? String, "array")
        XCTAssertEqual(props["key_quotes"]?["type"] as? String, "array")
        // The schema does not depend on the editable prompt.
        let body = ResponsesRequest(model: "m", instructions: "anything at all", userContent: "u").body(stream: true)
        let format = (body["text"] as! [String: Any])["format"] as! [String: Any]
        XCTAssertEqual((format["schema"] as! [String: Any])["required"] as! [String], NotesSchema.requiredFields)
    }

    func testMissingNewFieldIsRejected() {
        var obj = try! JSONSerialization.jsonObject(with: Data(notesJSON().utf8)) as! [String: Any]
        obj["learning_content"] = nil
        let text = String(data: try! JSONSerialization.data(withJSONObject: obj), encoding: .utf8)!
        XCTAssertThrowsError(try NotesSchema.parse(text))
        XCTAssertThrowsError(try NotesSchema.parse(notesJSON().replacingOccurrences(of: #""key_quotes":[]"#, with: #""key_quotes":"none""#)))
    }

    func testWhitespaceAndFillerBecomeEmpty() {
        let n = GeneratedNotes(title: " Fractions ", overview: "   \n ", keyPoints: ["", "  ", "Real point", "N/A", "real point"],
                               nextSteps: ["The pupil should continue practising.", "Practise column subtraction with exchanging"],
                               homework: "No homework was assigned.", vocabulary: ["None"], praise: "There was insufficient information to provide feedback.",
                               keyQuotes: ["No relevant quotations were identified."], learningContent: "  ",
                               workedExamples: ["No worked examples were discussed.", "  "], privateNotes: "No further observations.")
        let out = NotesSchema.normalise(n).notes
        XCTAssertEqual(out.title, "Fractions")
        XCTAssertEqual(out.overview, "")
        XCTAssertEqual(out.keyPoints, ["Real point"])
        XCTAssertEqual(out.nextSteps, ["Practise column subtraction with exchanging"])
        XCTAssertEqual(out.homework, "")
        XCTAssertEqual(out.vocabulary, [])
        XCTAssertEqual(out.praise, "")
        XCTAssertEqual(out.keyQuotes, [])
        XCTAssertEqual(out.learningContent, "")
        XCTAssertEqual(out.workedExamples, [])
        XCTAssertEqual(out.privateNotes, "")
    }

    func testFillerDetectionDoesNotRemoveRealContent() {
        for real in ["No calculators: use the column method.", "None of the angles is obtuse, so it is acute-angled.",
                     "Complete page 4, questions 1–6, by Friday.", "There was no remainder because 24 divides by 6.",
                     "Keep practising your 7 times table using the grid we made."] {
            XCTAssertFalse(NotesSchema.isEmptyOrFiller(real), real)
        }
        for filler in ["None", "N/A", "no homework", "Nothing to report.", "No homework was set this lesson.", "**None**", "- n/a"] {
            XCTAssertTrue(NotesSchema.isEmptyOrFiller(filler), filler)
        }
    }

    func testNoPlaceholdersInsertedForEmptyNotes() throws {
        let h = try Harness()
        h.notes.failWith = nil
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.store.updateJob(id: l.jobs[0].id) { _ in }
        // Notes with only a title: every other section must be sent empty.
        let empty = GeneratedNotes(title: "Homework check")
        let sub = SubmissionBuilder.build(lesson: l, job: l.jobs[0], notes: empty, transcriptText: "[00:00] Hi", appVersion: "t",
                                          transcriptionModel: "w", summaryModel: "m")
        let json = String(data: try sub.jsonData(), encoding: .utf8)!
        for placeholder in ["None", "N/A", "No homework", "Not applicable", "Nothing to report"] { XCTAssertFalse(json.contains(placeholder)) }
        XCTAssertNil(sub.privateNotes)
        XCTAssertEqual(sub.summary.workedExamples, [])
        XCTAssertTrue(SubmissionValidator.validate(sub).isEmpty)
    }

    func testNewFieldLimitsValidated() {
        var s = NoteSummary(learningContent: String(repeating: "x", count: 20_001), workedExamples: Array(repeating: "e", count: 21),
                            keyQuotes: [String(repeating: "q", count: 501)])
        let sub = NoteSubmission(submissionId: "mac-TEST-0000-a-abc123", roomId: roomEE, lessonDate: "2026-11-14", startedAt: nil, endedAt: nil,
                                 title: "T", summary: s, transcript: "x", privateNotes: nil, recordings: [], mode: .single, generator: nil)
        let fields = Set(SubmissionValidator.validate(sub).map(\.field))
        XCTAssertTrue(fields.contains("summary.learning_content"))
        XCTAssertTrue(fields.contains("summary.worked_examples"))
        XCTAssertTrue(fields.contains("summary.key_quotes.0"))
        s.workedExamples = [""]
        XCTAssertTrue(SubmissionValidator.validate(NoteSubmission(submissionId: "mac-TEST-0000-a-abc123", roomId: roomEE, lessonDate: "2026-11-14",
                                                                  startedAt: nil, endedAt: nil, title: "T", summary: s, transcript: "x", privateNotes: nil,
                                                                  recordings: [], mode: .single, generator: nil)).contains { $0.field == "summary.worked_examples.0" })
    }

    func testLongLearningContentKeptWhenWithinLimit() {
        let section = "## Section\nA complete explanatory sentence about the method.\n\n"
        let long = String(repeating: section, count: 300).trimmingCharacters(in: .whitespacesAndNewlines) // ~19,000 chars
        XCTAssertLessThan(long.utf16.count, NoteLimits.learningContent)
        let out = NotesSchema.normalise(GeneratedNotes(title: "T", learningContent: long))
        XCTAssertEqual(out.notes.learningContent, long, "no silent shortening")
        XCTAssertTrue(out.adjustments.isEmpty)
    }

    func testOverLimitTrimmedAtCleanBoundaryAndReported() {
        let section = "## Part\nThis sentence ends properly. Another full sentence follows here.\n\n"
        let long = String(repeating: section, count: 400) + "```\ncode block never closed"
        let out = NotesSchema.normalise(GeneratedNotes(title: "T", learningContent: long))
        let lc = out.notes.learningContent
        XCTAssertLessThanOrEqual(lc.utf16.count, NoteLimits.learningContent)
        XCTAssertTrue(lc.hasSuffix("follows here."), "ends at a complete sentence/section, not mid-word")
        XCTAssertEqual(lc.components(separatedBy: "```").count % 2, 1, "no unterminated code fence")
        XCTAssertEqual(out.adjustments.count, 1)
        XCTAssertTrue(out.adjustments[0].contains("learning_content"))
        // Too many items: kept in order, reported.
        let many = NotesSchema.normalise(GeneratedNotes(title: "T", workedExamples: (1...25).map { "Example \($0)" }))
        XCTAssertEqual(many.notes.workedExamples.count, 20)
        XCTAssertEqual(many.notes.workedExamples.last, "Example 20")
        XCTAssertTrue(many.adjustments[0].contains("worked_examples"))
    }
}

// MARK: - Truncation / completion

final class CompletionTests: XCTestCase {
    func testStreamWithoutCompletionEventIsNotAccepted() async throws {
        // Deltas arrive but the stream stops before `response.completed` (e.g. dropped connection).
        let partial = String(notesJSON().prefix(60))
        let escaped = String(data: try JSONSerialization.data(withJSONObject: [partial]), encoding: .utf8)!.dropFirst().dropLast()
        let sse = "data: {\"type\":\"response.output_text.delta\",\"delta\":\(escaped)}\n"
        let c = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, sse) })
        do { _ = try await c.streamResponse(ResponsesRequest(model: "m", instructions: "", userContent: "")); XCTFail("accepted partial") }
        catch let e as OpenAIError { XCTAssertEqual(e, .streamInterrupted); XCTAssertTrue(e.isRetryable) }
    }

    func testStreamCompletedAssemblesFullText() async throws {
        let full = notesJSON(learning: String(repeating: "Line of teaching content.\n", count: 400))
        var lines: [String] = []
        var i = full.startIndex
        while i < full.endIndex {
            let j = full.index(i, offsetBy: 37, limitedBy: full.endIndex) ?? full.endIndex
            let d = String(data: try JSONSerialization.data(withJSONObject: [String(full[i..<j])]), encoding: .utf8)!.dropFirst().dropLast()
            lines.append("event: response.output_text.delta\ndata: {\"type\":\"response.output_text.delta\",\"delta\":\(d)}\n")
            i = j
        }
        let fullEscaped = String(data: try JSONSerialization.data(withJSONObject: [full]), encoding: .utf8)!.dropFirst().dropLast()
        lines.append("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\(fullEscaped)}]}]}}\n")
        let c = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, lines.joined(separator: "\n")) })
        let r = try await c.streamResponse(ResponsesRequest(model: "m", instructions: "", userContent: ""))
        XCTAssertEqual(r.outputText, full)
        XCTAssertEqual(try NotesSchema.parse(r.outputText).learningContent.count, 26 * 400)
    }

    func testIncompleteEventRejectedEvenWithText() async throws {
        let partial = String(notesJSON().prefix(80))
        let esc = String(data: try JSONSerialization.data(withJSONObject: [partial]), encoding: .utf8)!.dropFirst().dropLast()
        let sse = "data: {\"type\":\"response.incomplete\",\"response\":{\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\(esc)}]}]}}\n"
        let c = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, sse) })
        do { _ = try await c.streamResponse(ResponsesRequest(model: "m", instructions: "", userContent: "")); XCTFail() }
        catch let e as OpenAIError { XCTAssertEqual(e, .incomplete("max_output_tokens")) }
    }

    func testOutputLimitRecoveredBySplitGeneration() async throws {
        let teaching = notesJSON(title: "Triangles", overview: "", learning: "## Long teaching section\nFull detail.", worked: ["Ex 1", "Ex 2"], keyPoints: [])
        let rest = notesJSON(title: "Triangles", overview: "We sorted triangles.", learning: "", worked: [], homework: "Page 4")
        let p = ScriptPerformer([.failure(OpenAIError.incomplete("max_output_tokens")), ScriptPerformer.ok(teaching), ScriptPerformer.ok(rest)])
        let g = NotesGenerator(performer: p, model: "m", effort: .modelDefault)
        let r = try await g.generateDetailed(transcript: "t", context: NotesRequestContext(pupilName: "E", lessonDate: "2026-11-14"), instructions: "I")
        XCTAssertTrue(r.usedSplitGeneration)
        XCTAssertEqual(r.notes.learningContent, "## Long teaching section\nFull detail.")
        XCTAssertEqual(r.notes.workedExamples, ["Ex 1", "Ex 2"])
        XCTAssertEqual(r.notes.overview, "We sorted triangles.")
        XCTAssertEqual(r.notes.homework, "Page 4")
        XCTAssertEqual(p.requests.value.count, 3)
        XCTAssertTrue(p.requests.value[1].instructions.contains("part 1 of 2"))
        XCTAssertTrue(p.requests.value[2].instructions.contains("part 2 of 2"))
    }

    func testStillIncompleteAfterSplitFailsWithoutSavingNotes() async throws {
        let h = try Harness()
        let p = ScriptPerformer([.failure(OpenAIError.incomplete("max_output_tokens"))])
        let deps = EngineDependencies(extractor: h.extractor, transcriber: h.transcriber,
                                      makeNotesProducer: { OpenAINotesProducer(generator: NotesGenerator(performer: p, model: "m", effort: .modelDefault)) },
                                      makeSubmitter: { h.submitter }, isOnline: { true }, appVersion: "t")
        let engine = JobEngine(store: h.store, deps: deps, tempRoot: h.tempRoot, now: { h.clock.value })
        let l = try h.addLesson(mode: .single, recordings: 1)
        await engine.runUntilIdle()
        let job = h.store.job(id: l.jobs[0].id)!
        XCTAssertEqual(job.stage, .failed)
        XCTAssertNil(job.notes, "incomplete notes are never saved")
        XCTAssertEqual(h.submitter.bodies.value.count, 0, "nothing submitted")
        XCTAssertTrue(job.error!.message.contains("output limit"))
        XCTAssertTrue(h.store.transcriptExists(jobId: job.id), "transcript kept for a retry")
    }

    func testMaxOutputTokensSentOnlyWhenConfigured() {
        XCTAssertNil(ResponsesRequest(model: "m", instructions: "", userContent: "").body(stream: true)["max_output_tokens"])
        XCTAssertEqual(ResponsesRequest(model: "m", instructions: "", userContent: "", maxOutputTokens: 64_000).body(stream: true)["max_output_tokens"] as? Int, 64_000)
    }
}

// MARK: - Prompts & migration

final class PromptV2Tests: XCTestCase {
    func testNewDefaultPrompt() {
        let p = PromptLibrary.starterGlobalPrompt
        XCTAssertTrue(p.hasPrefix("Role and Purpose"))
        XCTAssertTrue(p.contains("Strict Empty Field Rules — Mandatory"))
        XCTAssertTrue(p.contains("learning_content"))
        XCTAssertTrue(p.hasSuffix("Do not include commentary or Markdown code fences outside the structured output."))
        XCTAssertEqual(AppSettings().globalPrompt, p, "fresh installs use the new default")
    }

    func testUntouchedOldDefaultUpgradedButCustomPromptsKept() throws {
        let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let dir = tempDir()
        for name in ["v1-custom", "v1-untouched"] {
            try FileManager.default.copyItem(at: base.appendingPathComponent(name), to: dir.appendingPathComponent(name))
        }
        let untouched = try LibraryStore(directory: dir.appendingPathComponent("v1-untouched"))
        XCTAssertEqual(untouched.settings.globalPrompt, PromptLibrary.starterGlobalPrompt)
        let custom = try LibraryStore(directory: dir.appendingPathComponent("v1-custom"))
        XCTAssertEqual(custom.settings.globalPrompt, "MY CUSTOM GLOBAL PROMPT v1")
        XCTAssertEqual(custom.mappings.first?.customPrompt, "ELLIE CUSTOM PROMPT")
        XCTAssertEqual(custom.mappings.first?.promptMode, .custom)
    }

    func testRegenerationPromptChoices() {
        let m = StudentMapping(roomId: roomDT, displayName: "Daniel", promptMode: .custom, customPrompt: "GCSE prompt")
        let current = PromptResolver.adding("Focus on AO2.", to: PromptResolver.resolve(globalPrompt: "G", mapping: m))
        XCTAssertTrue(current.effectiveInstructions.hasPrefix("GCSE prompt"))
        XCTAssertTrue(current.effectiveInstructions.contains("Additional instructions for this version of the notes:\nFocus on AO2."))
        XCTAssertTrue(current.effectiveInstructions.contains("Required rules"))
        let temp = PromptResolver.temporary("One-off prompt")
        XCTAssertEqual(temp.source, .temporary)
        XCTAssertTrue(temp.effectiveInstructions.hasPrefix("One-off prompt"))
        XCTAssertTrue(temp.effectiveInstructions.contains("Required rules"))
    }
}

// MARK: - Upgrade persistence

final class UpgradeTests: XCTestCase {
    func testVersion1DataLoadsWithEverythingPreserved() throws {
        let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!
        let dir = tempDir().appendingPathComponent("v1")
        try FileManager.default.copyItem(at: base.appendingPathComponent("v1-custom"), to: dir)
        let store = try LibraryStore(directory: dir)
        let s = store.settings
        XCTAssertEqual(s.openAIModel, "gpt-chosen-model")
        XCTAssertEqual(s.reasoningEffort, .medium)
        XCTAssertEqual(s.transcriptionModel, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(s.zoomFolderPath, "/Users/george/Documents/Zoom")
        XCTAssertEqual(s.zoomFolderBookmark, Data([1, 2, 3]))
        XCTAssertEqual(s.retention, .days90)
        XCTAssertEqual(s.installId, UUID(uuidString: "6F1C2A9E-0000-4000-8000-000000000001"))
        XCTAssertNil(s.maxOutputTokens)
        XCTAssertEqual(store.rooms.rooms.count, 1)
        XCTAssertEqual(store.mappings.count, 1)
        XCTAssertEqual(store.allLessons.count, 2, "history preserved (no 'unreadable' reset)")
        let job = try XCTUnwrap(store.job(id: UUID(uuidString: "44444444-4444-4444-8444-444444444444")!))
        XCTAssertEqual(job.stage, .submitted)
        XCTAssertEqual(job.remoteStatus, .published)
        XCTAssertEqual(job.notes?.title, "Fractions")
        XCTAssertEqual(job.notes?.homework, "Page 4")
        XCTAssertEqual(job.notes?.learningContent, "", "new fields default to empty")
        XCTAssertEqual(job.notes?.workedExamples, [])
        XCTAssertEqual(job.notes?.keyQuotes, [])
        XCTAssertNil(job.remoteVersion)
        XCTAssertEqual(job.allNoteVersions.count, 1, "original version synthesised")
        XCTAssertEqual(store.transcript(jobId: job.id)?.parts.first?.segments.first?.text, "Hello Ellie.")
        XCTAssertEqual(store.job(id: UUID(uuidString: "66666666-6666-4666-8666-666666666666")!)?.stage, .summarising, "queue state preserved")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertFalse(files.contains { $0.contains("unreadable") })
        // Saving in the new format and reopening keeps everything.
        store.updateJob(id: job.id) { $0.remoteVersion = 2 }
        let reopened = try LibraryStore(directory: dir)
        XCTAssertEqual(reopened.job(id: job.id)?.remoteVersion, 2)
        XCTAssertEqual(reopened.settings.globalPrompt, "MY CUSTOM GLOBAL PROMPT v1")
    }
}

// MARK: - Regeneration, version history, replacement

final class RegenerationTests: XCTestCase {
    let regenerated = GeneratedNotes(title: "Recognising and classifying triangles", overview: "We sorted triangles by their **sides**.",
                                     keyPoints: ["A right-angled triangle has one 90° angle"], learningContent: "## 1. Triangles\n- Equilateral: 3 equal sides",
                                     workedExamples: ["**Example:** 5, 5, 8 → *isosceles*."], privateNotes: "Mixes up scalene and isosceles.")

    func testRegenerateUsesLocalTranscriptAndKeepsDraftForReview() async throws {
        let h = try Harness()
        let r = MockReplacer()
        let (l, _) = try await h.submittedLesson(replacer: r)
        let jobId = l.jobs[0].id
        let producer = FixedProducer(notes: regenerated)
        let before = h.store.settings
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId,
                                                       options: RegenerationOptions(prompt: .temporary("One-off prompt"), additionalInstructions: "More detail on angles."),
                                                       producer: producer, now: h.clock.value)
        XCTAssertEqual(h.transcriber.calls.value, 1, "no re-transcription")
        XCTAssertTrue(producer.calls.value[0].contains("We practised fractions."), "used the saved transcript")
        XCTAssertTrue(producer.calls.value[0].hasPrefix("One-off prompt"))
        XCTAssertTrue(producer.calls.value[0].contains("More detail on angles."))
        let job = h.store.job(id: jobId)!
        XCTAssertEqual(job.notes?.title, "Fractions", "original notes untouched until accepted")
        XCTAssertEqual(job.allNoteVersions.map(\.state), [.current, .draft])
        XCTAssertEqual(job.allNoteVersions[0].kind, .original)
        XCTAssertEqual(v.baseVersion, 2)
        XCTAssertEqual(v.model, "regen-model")
        XCTAssertEqual(h.store.settings, before, "saved prompts/model unchanged")
        XCTAssertEqual(job.allNoteVersions[1].notes.changedFields(comparedTo: job.allNoteVersions[0].notes).first, "title")
        // Regenerate again and discard one.
        let v2 = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: producer, now: h.clock.value)
        NotesRegeneration.discard(store: h.store, jobId: jobId, versionId: v2.id)
        XCTAssertEqual(h.store.job(id: jobId)!.allNoteVersions.map(\.state), [.current, .draft, .discarded])
    }

    func testRegenerateWithoutTranscriptFails() async throws {
        let h = try Harness()
        let r = MockReplacer()
        let (l, _) = try await h.submittedLesson(replacer: r)
        h.store.deleteTranscript(jobId: l.jobs[0].id)
        do { _ = try await NotesRegeneration.regenerate(store: h.store, jobId: l.jobs[0].id, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated)); XCTFail() }
        catch { XCTAssertEqual(error as? RegenerationError, .transcriptMissing) }
    }

    func testReplaceSendsPatchAndReturnsToPending() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        XCTAssertEqual(h.store.job(id: jobId)?.remoteVersion, 2)
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        XCTAssertEqual(try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id), .replacementQueued)
        await engine.runUntilIdle()
        XCTAssertEqual(h.submitter.bodies.value.count, 1, "no duplicate POST /notes")
        XCTAssertEqual(rep.ids.value, ["note-1"])
        let body = try JSONSerialization.jsonObject(with: rep.bodies.value[0]) as! [String: Any]
        XCTAssertEqual(Set(body.keys), ["update_id", "base_version", "title", "summary", "private_notes", "generator"])
        XCTAssertNil(body["transcript"]); XCTAssertNil(body["recordings"]); XCTAssertNil(body["room_id"]); XCTAssertNil(body["lesson_date"]); XCTAssertNil(body["mode"])
        XCTAssertEqual(body["base_version"] as? Int, 2)
        XCTAssertEqual(body["title"] as? String, "Recognising and classifying triangles")
        let summary = body["summary"] as! [String: Any]
        XCTAssertEqual(summary.count, 9, "every section sent")
        XCTAssertEqual(summary["homework"] as? String, "")
        XCTAssertEqual(summary["learning_content"] as? String, "## 1. Triangles\n- Equilateral: 3 equal sides")
        XCTAssertEqual((body["generator"] as? [String: Any])?["summary_model"] as? String, "regen-model")
        XCTAssertTrue((body["update_id"] as! String).hasPrefix("mac-replace-"))
        let job = h.store.job(id: jobId)!
        XCTAssertNil(job.replacement)
        XCTAssertEqual(job.remoteStatus, .pending, "replacement returns the note to Waiting for approval")
        XCTAssertEqual(job.remoteVersion, 3)
        XCTAssertEqual(job.notes?.title, "Recognising and classifying triangles")
        XCTAssertEqual(job.allNoteVersions.map(\.state), [.superseded, .current])
        XCTAssertEqual(job.allNoteVersions[1].websiteVersion, 3)
        XCTAssertEqual(job.allNoteVersions[0].notes.title, "Fractions", "previous version preserved locally")
    }

    func testOfflineReplacementRetriesWithSameUpdateIdAndBody() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.results = [.failure(TransportError.network("timed out")),
                       .failure(LetsMeetAPIError(httpStatus: 503, code: "server_error", message: "busy")),
                       .success(NoteReplaceResponse(noteId: "note-1", submissionId: nil, status: .pending, version: 3, replayed: true))]
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        h.online.value = false
        await engine.runUntilIdle()
        XCTAssertEqual(rep.bodies.value.count, 0, "waits while offline")
        XCTAssertEqual(h.store.job(id: jobId)?.replacement?.state, .queued)
        h.online.value = true
        await engine.runUntilIdle()
        XCTAssertEqual(rep.bodies.value.count, 1)
        h.clock.value = h.clock.value.addingTimeInterval(6)
        await engine.runUntilIdle()
        h.clock.value = h.clock.value.addingTimeInterval(16)
        await engine.runUntilIdle()
        XCTAssertEqual(rep.bodies.value.count, 3)
        XCTAssertTrue(rep.bodies.value.allSatisfy { $0 == rep.bodies.value[0] }, "same update_id and body on every retry")
        XCTAssertNil(h.store.job(id: jobId)?.replacement)
        XCTAssertEqual(h.store.job(id: jobId)?.remoteVersion, 3)
    }

    func testReplacementSurvivesRestart() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.results = [.failure(TransportError.network("down")), .success(NoteReplaceResponse(noteId: "note-1", submissionId: nil, status: .pending, version: 3))]
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        await engine.runUntilIdle()
        let frozen = h.store.job(id: jobId)?.replacement?.body
        XCTAssertNotNil(frozen)
        let reopened = try LibraryStore(directory: h.store.directory)
        XCTAssertEqual(reopened.job(id: jobId)?.replacement?.body, frozen)
        let deps = EngineDependencies(extractor: h.extractor, transcriber: h.transcriber, makeNotesProducer: { h.notes }, makeSubmitter: { h.submitter },
                                      isOnline: { true }, appVersion: "t", makeReplacer: { rep })
        let e2 = JobEngine(store: reopened, deps: deps, tempRoot: h.tempRoot, retryPolicy: RetryPolicy(jitterFraction: 0), now: { h.clock.value.addingTimeInterval(10) })
        await e2.runUntilIdle()
        XCTAssertEqual(rep.bodies.value.last, frozen)
        XCTAssertNil(reopened.job(id: jobId)?.replacement)
    }

    func testVersionConflictNeverOverwritesSilently() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.results = [.failure(LetsMeetAPIError(httpStatus: 409, code: "version_conflict", message: "The note changed since your base_version…",
                                                 currentVersion: 4, lastChangedBy: "george", remoteUpdatedAt: "2026-11-14T10:00:00Z")),
                       .success(NoteReplaceResponse(noteId: "note-1", submissionId: nil, status: .pending, version: 5))]
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        await engine.runUntilIdle()
        h.clock.value = h.clock.value.addingTimeInterval(3600)
        await engine.runUntilIdle()
        var job = h.store.job(id: jobId)!
        XCTAssertEqual(rep.bodies.value.count, 1, "no automatic retry on conflict")
        XCTAssertEqual(job.replacement?.state, .conflict)
        XCTAssertEqual(job.replacement?.conflictCurrentVersion, 4)
        XCTAssertEqual(job.replacement?.conflictChangedBy, "george")
        XCTAssertEqual(job.notes?.title, "Fractions", "local notes unchanged")
        let firstUpdateId = (try JSONSerialization.jsonObject(with: rep.bodies.value[0]) as! [String: Any])["update_id"] as! String
        // Replace anyway: new update_id, base_version = current_version.
        NotesRegeneration.replaceAnyway(store: h.store, jobId: jobId)
        await engine.runUntilIdle()
        let second = try JSONSerialization.jsonObject(with: rep.bodies.value[1]) as! [String: Any]
        XCTAssertEqual(second["base_version"] as? Int, 4)
        XCTAssertNotEqual(second["update_id"] as? String, firstUpdateId)
        job = h.store.job(id: jobId)!
        XCTAssertNil(job.replacement)
        XCTAssertEqual(job.remoteVersion, 5)
    }

    func testKeepWebsiteVersionDropsReplacement() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.results = [.failure(LetsMeetAPIError(httpStatus: 409, code: "version_conflict", message: "changed", currentVersion: 4))]
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        await engine.runUntilIdle()
        NotesRegeneration.keepWebsiteVersion(store: h.store, jobId: jobId)
        await engine.runUntilIdle()
        let job = h.store.job(id: jobId)!
        XCTAssertNil(job.replacement)
        XCTAssertEqual(job.allNoteVersions.map(\.state), [.current, .discarded])
        XCTAssertEqual(rep.bodies.value.count, 1)
    }

    func testUpdateIdConflictGeneratesNewIdAndNoChangesTreatedAsDone() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.results = [.failure(LetsMeetAPIError(httpStatus: 409, code: "update_id_conflict", message: "reused")),
                       .failure(LetsMeetAPIError(httpStatus: 422, code: "no_changes", message: "Identical"))]
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        await engine.runUntilIdle()
        let ids = rep.bodies.value.map { (try! JSONSerialization.jsonObject(with: $0) as! [String: Any])["update_id"] as! String }
        XCTAssertEqual(ids.count, 2)
        XCTAssertNotEqual(ids[0], ids[1])
        XCTAssertNil(h.store.job(id: jobId)?.replacement)
        XCTAssertEqual(h.store.job(id: jobId)?.notes?.title, regenerated.title)
    }

    func testDeletedNoteOffersSubmitAsNewNote() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.results = [.failure(LetsMeetAPIError(httpStatus: 404, code: "note_not_found", message: "Not found"))]
        let (l, engine) = try await h.submittedLesson(replacer: rep)
        let jobId = l.jobs[0].id
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: jobId)?.replacement?.state, .noteDeleted)
        XCTAssertEqual(h.store.job(id: jobId)?.remoteStatus, .deleted)
        let newLesson = try NotesRegeneration.submitAsNewNote(store: h.store, jobId: jobId)
        await engine.runUntilIdle()
        let nj = h.store.job(id: newLesson.jobs[0].id)!
        XCTAssertEqual(nj.stage, .submitted)
        XCTAssertNotEqual(nj.submissionId, l.jobs[0].submissionId, "new submission id")
        XCTAssertEqual(h.transcriber.calls.value, 1, "no re-transcription")
        let last = try JSONSerialization.jsonObject(with: h.submitter.bodies.value.last!) as! [String: Any]
        XCTAssertEqual(last["title"] as? String, regenerated.title)
        XCTAssertTrue((last["transcript"] as! String).contains("We practised fractions."), "full transcript sent with the new note")
    }

    func testMissingVersionLookedUpBeforeReplacing() async throws {
        let h = try Harness()
        let rep = MockReplacer()
        rep.statusVersion = 6
        let l = try h.addLesson(mode: .single, recordings: 1)
        let engine = h.engine(replacer: rep)
        await engine.runUntilIdle() // submitted without a version (older website or v1 data)
        let jobId = l.jobs[0].id
        XCTAssertNil(h.store.job(id: jobId)?.remoteVersion)
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id)
        await engine.runUntilIdle()
        let body = try JSONSerialization.jsonObject(with: rep.bodies.value[0]) as! [String: Any]
        XCTAssertEqual(body["base_version"] as? Int, 6)
    }

    func testAcceptBeforeSubmissionReplacesLocallyWithNewSubmissionId() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 422, code: "validation_failed", message: "Bad"))]
        let engine = h.engine(replacer: MockReplacer())
        await engine.runUntilIdle()
        let jobId = l.jobs[0].id
        XCTAssertEqual(h.store.job(id: jobId)?.stage, .failed)
        let oldId = h.store.job(id: jobId)!.submissionId
        let v = try await NotesRegeneration.regenerate(store: h.store, jobId: jobId, options: RegenerationOptions(), producer: FixedProducer(notes: regenerated))
        XCTAssertEqual(try NotesRegeneration.accept(store: h.store, jobId: jobId, versionId: v.id), .replacedLocally)
        let job = h.store.job(id: jobId)!
        XCTAssertEqual(job.notes?.title, regenerated.title)
        XCTAssertNil(job.submissionPayload)
        XCTAssertNotEqual(job.submissionId, oldId, "changed content never reuses a submission id")
        XCTAssertEqual(job.allNoteVersions.map(\.state), [.superseded, .current])
    }

    func testReplaceClientRequestShapeAndErrors() async throws {
        let t = StubTransport { r in
            if r.httpMethod == "PATCH" {
                return StubTransport.json(409, #"{"error":{"code":"version_conflict","message":"The note changed since your base_version…","current_version":4,"updated_at":"2026-11-14T10:00:00Z","last_changed_by":"george","note_id":"3f2a"}}"#)
            }
            return StubTransport.json(200, #"{"note_id":"3f2a","submission_id":"s","status":"published","version":2}"#)
        }
        let c = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_K", transport: t)
        let st = try await c.status(of: "3f2a")
        XCTAssertEqual(st.version, 2)
        let body = try NoteReplacement(updateId: "mac-replace-x-12345678", baseVersion: 2, title: "T", summary: NotesSchema.summary(from: GeneratedNotes(title: "T")),
                                       privateNotes: nil, generator: ReplacementGenerator(appVersion: "2.0.0", summaryModel: "m")).jsonData()
        do { _ = try await c.replace(noteId: "3f2a", body: body); XCTFail() } catch let e as LetsMeetAPIError {
            XCTAssertEqual(e.code, "version_conflict"); XCTAssertEqual(e.currentVersion, 4); XCTAssertEqual(e.lastChangedBy, "george")
        }
        let patch = t.requests.value.last!
        XCTAssertEqual(patch.httpMethod, "PATCH")
        XCTAssertEqual(patch.url?.path, "/api/public/lesson-notes/notes/3f2a")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Authorization"), "Bearer ghln_K")
        XCTAssertEqual(patch.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let obj = bodyJSON(patch)
        XCTAssertTrue(obj.keys.contains("private_notes"))
        XCTAssertTrue(obj["private_notes"] is NSNull, "null clears private notes")
    }

    func testStatusSyncStoresVersion() async throws {
        let h = try Harness()
        let (l, _) = try await h.submittedLesson(replacer: MockReplacer())
        StatusSync.apply([NoteStatusResponse(noteId: "note-1", submissionId: l.jobs[0].submissionId, status: .pending, version: 9)], store: h.store, now: Date())
        XCTAssertEqual(h.store.job(id: l.jobs[0].id)?.remoteVersion, 9)
    }
}

// MARK: - Markdown preview parsing

final class MarkdownTests: XCTestCase {
    func testBlocks() {
        let md = """
        ## 1. Recognising triangles
        We sorted triangles by their **sides**.

        - Equilateral: 3 equal sides
        - Isosceles: 2 equal sides
          (continues here)
        1. Measure
        2. Compare

        | Type | Sides |
        |---|---|
        | Equilateral | 3 |
        | Scalene | 0 |

        > "Two sides the same means isosceles."

        ```
        5 + 5 = 10
        ```
        """
        let b = MarkdownBlocks.parse(md)
        XCTAssertEqual(b[0], .heading(level: 2, text: "1. Recognising triangles"))
        XCTAssertEqual(b[1], .paragraph("We sorted triangles by their **sides**."))
        guard case .list(let items) = b[2] else { return XCTFail("\(b[2])") }
        XCTAssertEqual(items.count, 4)
        XCTAssertEqual(items[1].text, "Isosceles: 2 equal sides (continues here)")
        XCTAssertTrue(items[2].ordered)
        XCTAssertEqual(b[3], .table(header: ["Type", "Sides"], rows: [["Equilateral", "3"], ["Scalene", "0"]]))
        XCTAssertEqual(b[4], .quote("\"Two sides the same means isosceles.\""))
        XCTAssertEqual(b[5], .code("5 + 5 = 10"))
        XCTAssertEqual(MarkdownBlocks.parse(""), [])
    }
}
