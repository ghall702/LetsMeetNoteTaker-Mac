import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

let j1 = UUID(uuidString: "B1000000-0000-4000-8000-000000000001")! // transcript, OpenAI credits failure
let j2 = UUID(uuidString: "B2000000-0000-4000-8000-000000000002")! // failed transcription, no transcript
let j3 = UUID(uuidString: "B3000000-0000-4000-8000-000000000003")! // transcript + notes, submission failed
let j4 = UUID(uuidString: "B4000000-0000-4000-8000-000000000004")! // submitted
let j5 = UUID(uuidString: "B5000000-0000-4000-8000-000000000005")! // interrupted transcription
let j6 = UUID(uuidString: "B6000000-0000-4000-8000-000000000006")! // transcript file saved, flag not recorded
let j7 = UUID(uuidString: "B7000000-0000-4000-8000-000000000007")! // credits failure, wrong resume stage

/// Copy of the real v1.1.0 data folder (written by the v1.1.0 engine) in a temp directory.
func v11Folder() throws -> URL {
    let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("v1_1")
    let dir = tempDir().appendingPathComponent("LessonNotes")
    try FileManager.default.copyItem(at: base, to: dir)
    return dir
}

final class CountingExtractor: AudioExtracting, @unchecked Sendable {
    let calls = Box<Int>(0)
    func extractAudio(for recording: RecordingRef, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.mutate { $0 += 1 }
        let u = directory.appendingPathComponent(recording.id.uuidString + ".wav")
        try Data([1]).write(to: u)
        return u
    }
}

struct V11Env {
    let dir: URL
    let store: LibraryStore
    let extractor = CountingExtractor()
    let transcriber = MockTranscriber()
    let notes = MockNotes()
    let submitter = MockSubmitter()
    let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_100_000))

    init(dir: URL? = nil, appVersion: String = "1.2.0") throws {
        self.dir = try dir ?? v11Folder()
        store = try LibraryStore(directory: self.dir, appVersion: appVersion, now: Date(timeIntervalSince1970: 1_800_100_000))
    }

    func engine() -> JobEngine {
        let ex = extractor, tr = transcriber, no = notes, su = submitter, cl = clock
        return JobEngine(store: store, deps: EngineDependencies(extractor: ex, transcriber: tr, makeNotesProducer: { no }, makeSubmitter: { su },
                                                               isOnline: { true }, appVersion: "1.2.0"),
                         tempRoot: dir.deletingLastPathComponent().appendingPathComponent("tmp"), retryPolicy: RetryPolicy(jitterFraction: 0), now: { cl.value })
    }

    func bodies() -> [[String: Any]] { submitter.bodies.value.map { try! JSONSerialization.jsonObject(with: $0) as! [String: Any] } }
}

// MARK: - Upgrade from real v1.1.0 data

final class V11UpgradeTests: XCTestCase {
    func testBackupIsCompleteVerifiedAndKept() throws {
        let original = try v11Folder()
        let env = try V11Env(dir: original)
        let backup = try XCTUnwrap(env.store.health.backupPath.map { URL(fileURLWithPath: $0) })
        XCTAssertNil(env.store.health.backupError)
        XCTAssertFalse(env.store.health.readOnly)
        XCTAssertEqual(env.store.health.migratedFromSchema, 1)
        let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("v1_1")
        // Byte-identical copy of the original history and every transcript (incl. failed jobs').
        XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("library.json")), try Data(contentsOf: base.appendingPathComponent("library.json")))
        for id in [j1, j3, j4, j6, j7] {
            let name = "transcripts/\(id.uuidString).json"
            XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent(name)), try Data(contentsOf: base.appendingPathComponent(name)), name)
        }
        for f in ["settings.json", "mappings.json", "rooms.json"] { XCTAssertTrue(FileManager.default.fileExists(atPath: backup.appendingPathComponent(f).path)) }
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: backup.appendingPathComponent("backup-manifest.json"))) as! [String: Any]
        XCTAssertEqual(manifest["lessons"] as? Int, 7)
        XCTAssertEqual(manifest["transcripts"] as? Int, 5)
        // Reopening the same version makes no new backup; a later upgrade adds one and keeps the first.
        _ = try LibraryStore(directory: original, appVersion: "1.2.0")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.store.backupsDirectory.path).count, 1)
        _ = try LibraryStore(directory: original, appVersion: "1.3.0", now: Date(timeIntervalSince1970: 1_800_200_000))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: env.store.backupsDirectory.path).count, 2)
    }

    func testEverythingPreservedAndStagesRecovered() throws {
        let env = try V11Env()
        let s = env.store
        XCTAssertEqual(s.allLessons.count, 7, "no lesson lost")
        XCTAssertEqual(s.settings.globalPrompt, "GEORGE'S CUSTOMISED GLOBAL PROMPT (v1.1)")
        XCTAssertEqual(s.settings.openAIModel, "gpt-5-mini")
        XCTAssertEqual(s.settings.transcriptionModel, "openai_whisper-large-v3-v20240930_turbo")
        XCTAssertEqual(s.settings.zoomFolderBookmark, Data([7, 7, 7]))
        XCTAssertEqual(s.settings.installId, UUID(uuidString: "6F1C2A9E-0000-4000-8000-000000000011"))
        XCTAssertEqual(s.settings.maxConcurrentTranscriptions, 1, "new setting defaults to 1")
        XCTAssertEqual(s.mappings.first?.customPrompt, "DANIEL GCSE CUSTOM PROMPT")
        XCTAssertEqual(s.rooms.rooms.count, 2)
        for l in s.allLessons {
            XCTAssertEqual(l.pupilName, "Daniel")
            XCTAssertEqual(l.lessonDate, "2027-01-15")
            XCTAssertEqual(l.recordings.first?.filename, "zoom_0.mp4")
            XCTAssertEqual(l.studentId, UUID(uuidString: "D0000000-0000-4000-8000-000000000001"))
        }
        // 1. credits failure: recoverable at summarising, reclassified, transcript intact.
        let a = try XCTUnwrap(s.job(id: j1))
        XCTAssertEqual(a.stage, .failed)
        XCTAssertEqual(a.resumeStage, .summarising)
        XCTAssertEqual(a.error?.kind, .openAICredits)
        XCTAssertEqual(a.error?.message, JobError.creditsMessage)
        XCTAssertEqual(a.error?.detail, "Unexpected OpenAI response: You have no credits remaining. Add credits to continue using the API.")
        XCTAssertEqual(s.transcriptState(jobId: j1), .valid)
        // 2. no transcript: stays a transcription retry.
        XCTAssertEqual(s.job(id: j2)?.resumeStage, .queued)
        XCTAssertEqual(s.transcriptState(jobId: j2), .missing)
        // 3. notes + frozen payload kept for a submission retry.
        XCTAssertEqual(s.job(id: j3)?.resumeStage, .submitting)
        XCTAssertNotNil(s.job(id: j3)?.submissionPayload)
        XCTAssertNotNil(s.job(id: j3)?.notes)
        // 4. submitted lesson untouched.
        XCTAssertEqual(s.job(id: j4)?.stage, .submitted)
        XCTAssertEqual(s.job(id: j4)?.noteId, "note-4")
        // 5. interrupted, nothing saved: still needs transcription.
        XCTAssertEqual(s.job(id: j5)?.stage, .transcribing)
        // 6. transcript saved but not recorded: recovered, goes to summarising.
        XCTAssertEqual(s.job(id: j6)?.hasTranscript, true)
        XCTAssertEqual(s.job(id: j6)?.stage, .summarising)
        // 7. wrong resume stage repaired.
        XCTAssertEqual(s.job(id: j7)?.resumeStage, .summarising)
        XCTAssertEqual(s.job(id: j7)?.error?.kind, .openAICredits)
        // Persisted in the new format and readable again.
        let reopened = try LibraryStore(directory: env.dir, appVersion: "1.2.0")
        XCTAssertEqual(reopened.job(id: j6)?.stage, .summarising)
        XCTAssertEqual(reopened.allLessons.count, 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.dir.appendingPathComponent("storage-info.json").path))
    }

    func testFixAndRetryAfterCreditsReusesTranscriptWithoutWhisper() async throws {
        let env = try V11Env()
        let engine = env.engine()
        let transcribedAt = env.store.job(id: j1)?.completedStagesAt["transcribed"]
        XCTAssertNotNil(transcribedAt)
        await engine.recoverAfterLaunch()
        let plan = await engine.retry(jobId: j1)
        XCTAssertEqual(plan, .summarise)
        await engine.runUntilIdle()
        let job = try XCTUnwrap(env.store.job(id: j1))
        XCTAssertEqual(job.stage, .submitted)
        // The only Whisper/extraction work is job 5, which genuinely has no transcript.
        XCTAssertEqual(env.extractor.calls.value, 1)
        XCTAssertEqual(env.transcriber.calls.value, 1)
        XCTAssertEqual(env.store.job(id: j5)?.stage, .submitted)
        // Job 1's saved transcript file is reused byte-for-byte (never re-transcribed or rewritten).
        let base = Bundle.module.url(forResource: "Fixtures", withExtension: nil)!.appendingPathComponent("v1_1/transcripts/\(j1.uuidString).json")
        XCTAssertEqual(try Data(contentsOf: env.dir.appendingPathComponent("transcripts/\(j1.uuidString).json")), try Data(contentsOf: base))
        XCTAssertEqual(env.notes.calls.value, 3, "OpenAI for jobs 1, 5 and 6")
        let sent = env.bodies().first { ($0["submission_id"] as? String) == job.submissionId }
        XCTAssertEqual(sent?["transcript"] as? String, env.store.transcript(jobId: j1)?.renderedText(timeZone: london))
        XCTAssertTrue(env.notes.lastInstructions.value.hasPrefix("DANIEL GCSE CUSTOM PROMPT"), "current student prompt used")
        XCTAssertEqual(job.completedStagesAt["transcribed"], transcribedAt, "job 1 never went through transcription again")
    }

    func testOtherV11JobsRecoverCorrectly() async throws {
        let env = try V11Env()
        let engine = env.engine()
        await engine.recoverAfterLaunch()
        await engine.runUntilIdle()
        // Without any retry: 5 (interrupted) is transcribed again, 6 is summarised from its saved transcript.
        XCTAssertEqual(env.transcriber.calls.value, 1, "only the interrupted job without a transcript")
        XCTAssertEqual(env.store.job(id: j5)?.stage, .submitted)
        XCTAssertEqual(env.store.job(id: j6)?.stage, .submitted)
        XCTAssertTrue((env.bodies().first { ($0["submission_id"] as? String) == env.store.job(id: j6)!.submissionId }?["transcript"] as? String)!
            .contains("Crash-window transcript text."))
        // Failed jobs wait for Fix & Retry; the submitted lesson is never sent again.
        XCTAssertEqual(env.store.job(id: j1)?.stage, .failed)
        XCTAssertEqual(env.store.job(id: j2)?.stage, .failed)
        XCTAssertEqual(env.store.job(id: j3)?.stage, .failed)
        let j4id = env.store.job(id: j4)!.submissionId
        XCTAssertFalse(env.bodies().contains { ($0["submission_id"] as? String) == j4id })

        // 3: submission retry reuses transcript + notes + identical payload.
        let payload = env.store.job(id: j3)!.submissionPayload
        let n = env.notes.calls.value, t = env.transcriber.calls.value
        let plan3 = await engine.retry(jobId: j3)
        XCTAssertEqual(plan3, .submit)
        await engine.runUntilIdle()
        XCTAssertEqual(env.store.job(id: j3)?.stage, .submitted)
        XCTAssertEqual(env.submitter.bodies.value.last, payload, "same submission id and body")
        XCTAssertEqual(env.notes.calls.value, n)
        XCTAssertEqual(env.transcriber.calls.value, t)

        // 2: no transcript → transcription is genuinely needed (no warning reason).
        let plan2 = await engine.retry(jobId: j2)
        XCTAssertEqual(plan2, .transcribe(reason: nil))
        await engine.runUntilIdle()
        XCTAssertEqual(env.store.job(id: j2)?.stage, .submitted)
        XCTAssertEqual(env.transcriber.calls.value, t + 1)
    }

    func testRestartThenFixAndRetry() async throws {
        let env = try V11Env()
        env.notes.failWith = OpenAIError.quotaExceeded("You exceeded your current quota")
        let e1 = env.engine()
        await e1.retry(jobId: j7)
        await e1.runUntilIdle()
        XCTAssertEqual(env.store.job(id: j7)?.error?.kind, .openAICredits, "still no credits")
        // Quit and relaunch the app (same version: no new backup), credits added, Fix & Retry.
        let env2 = try V11Env(dir: env.dir)
        let e2 = env2.engine()
        await e2.recoverAfterLaunch()
        let plan = await e2.retry(jobId: j7)
        XCTAssertEqual(plan, .summarise)
        await e2.runUntilIdle()
        XCTAssertEqual(env2.store.job(id: j7)?.stage, .submitted)
        XCTAssertEqual(env.transcriber.calls.value + env2.transcriber.calls.value, 1, "only job 5 (no transcript) was ever transcribed")
        XCTAssertEqual(env2.store.transcript(jobId: j7)?.parts.first?.segments.first?.text, "Mis-staged transcript text.")
    }
}

// MARK: - Data-safety guards

final class DataSafetyTests: XCTestCase {
    func testUnreadableHistoryIsNeverOverwritten() throws {
        let dir = try v11Folder()
        let lib = dir.appendingPathComponent("library.json")
        try Data("{ this is not json".utf8).write(to: lib)
        let before = try Data(contentsOf: lib)
        let store = try LibraryStore(directory: dir, appVersion: "1.2.0")
        XCTAssertTrue(store.health.readOnly)
        XCTAssertNotNil(store.health.migrationError)
        store.addLesson(Lesson(roomId: roomEE, studentId: nil, pupilName: "X", roomName: "", lessonDate: "2026-01-01", startedAt: nil, endedAt: nil,
                               dateSource: .manual, mode: .single, meetingTopic: "", sourceFolder: "", timeZoneIdentifier: "UTC", recordings: []))
        XCTAssertEqual(try Data(contentsOf: lib), before, "original file never replaced by an empty or partial history")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).contains { $0.hasPrefix("library.json.unreadable-") })
    }

    func testBackupFailureMeansNoChanges() throws {
        let dir = try v11Folder()
        try Data("blocker".utf8).write(to: dir.appendingPathComponent("Backups")) // a file where the folder should go
        let before = try Data(contentsOf: dir.appendingPathComponent("library.json"))
        let store = try LibraryStore(directory: dir, appVersion: "1.2.0")
        XCTAssertNotNil(store.health.backupError)
        XCTAssertTrue(store.health.readOnly)
        XCTAssertEqual(store.allLessons.count, 7, "history still readable")
        store.updateJob(id: j1) { $0.statusMessage = "x" }
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("library.json")), before, "nothing migrated or written")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("storage-info.json").path))
    }

    func testCorruptTranscriptIsExplainedKeptAndRegenerated() async throws {
        let env = try V11Env()
        let url = env.dir.appendingPathComponent("transcripts/\(j1.uuidString).json")
        try Data("garbage".utf8).write(to: url)
        XCTAssertEqual(env.store.transcriptState(jobId: j1), .corrupt("the file is damaged"))
        let engine = env.engine()
        let plan = await engine.retry(jobId: j1)
        guard case .transcribe(let reason?) = plan else { return XCTFail("\(String(describing: plan))") }
        XCTAssertTrue(reason.contains("could not be used"))
        XCTAssertEqual(env.store.job(id: j1)?.statusMessage, reason, "explained before transcribing")
        await engine.runUntilIdle()
        XCTAssertEqual(env.store.job(id: j1)?.stage, .submitted)
        XCTAssertEqual(env.store.transcriptState(jobId: j1), .valid)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: env.dir.appendingPathComponent("transcripts").path)
            .contains { $0.hasPrefix(j1.uuidString + ".damaged-") }, "damaged file kept, not deleted")
    }

    func testLaterFailuresNeverDiscardEarlierResults() async throws {
        let h = try Harness()
        let l = try h.addLesson(mode: .single, recordings: 1)
        h.submitter.results = [.failure(LetsMeetAPIError(httpStatus: 400, code: "invalid_json", message: "bad"))]
        await h.engine().runUntilIdle()
        let job = h.store.job(id: l.jobs[0].id)!
        XCTAssertEqual(job.stage, .failed)
        XCTAssertNotNil(job.notes, "notes kept after submission failure")
        XCTAssertEqual(h.store.transcriptState(jobId: job.id), .valid, "transcript kept")
        XCTAssertNotNil(job.submissionPayload, "submission id/body kept to prevent duplicates")
    }
}

// MARK: - OpenAI credit errors

final class CreditErrorTests: XCTestCase {
    func testInsufficientQuotaDetectedEverywhere() async throws {
        XCTAssertEqual(OpenAIClient.mapError(status: 429, data: Data(#"{"error":{"message":"You exceeded your current quota","type":"insufficient_quota","code":"insufficient_quota"}}"#.utf8), retryAfter: nil),
                       .quotaExceeded("You exceeded your current quota"))
        XCTAssertEqual(OpenAIClient.mapError(status: 400, data: Data(#"{"error":{"message":"You have no credits remaining. Add credits to continue using the API."}}"#.utf8), retryAfter: nil),
                       .quotaExceeded("You have no credits remaining. Add credits to continue using the API."))
        for sse in [#"data: {"type":"error","error":{"code":"insufficient_quota","message":"You have no credits remaining."}}"#,
                    #"data: {"type":"error","message":"You have no credits remaining. Add credits to continue using the API."}"#,
                    #"data: {"type":"response.failed","response":{"status":"failed","error":{"code":"insufficient_quota","message":"Quota"}}}"#] {
            let c = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, sse + "\n") })
            do { _ = try await c.streamResponse(ResponsesRequest(model: "m", instructions: "", userContent: "")); XCTFail() }
            catch let e as OpenAIError {
                guard case .quotaExceeded = e else { return XCTFail("\(e)") }
                XCTAssertFalse(e.isRetryable)
                XCTAssertEqual(e.localizedDescription, JobError.creditsMessage)
            }
        }
        XCTAssertFalse(JobError.looksLikeOpenAICredits("Incorrect API key provided"))
    }

    func testCreditFailureKeepsTranscriptAndIsNeverAutoRetried() async throws {
        let h = try Harness()
        h.notes.failWith = OpenAIError.quotaExceeded("insufficient_quota")
        let l = try h.addLesson(mode: .single, recordings: 1)
        let engine = h.engine()
        await engine.runUntilIdle()
        var job = h.store.job(id: l.jobs[0].id)!
        XCTAssertEqual(job.stage, .failed)
        XCTAssertEqual(job.resumeStage, .summarising)
        XCTAssertEqual(job.error?.kind, .openAICredits)
        XCTAssertEqual(job.error?.message, JobError.creditsMessage)
        XCTAssertEqual(job.displayStatus, "OpenAI credits needed")
        XCTAssertNil(job.nextAttemptAt)
        XCTAssertEqual(h.store.transcriptState(jobId: job.id), .valid)
        h.clock.value = h.clock.value.addingTimeInterval(3 * 86_400)
        await engine.runUntilIdle()
        XCTAssertEqual(h.notes.calls.value, 1, "not retried automatically")
        // Credits added → Fix & Retry → no Whisper.
        h.notes.failWith = nil
        await engine.retry(jobId: job.id)
        await engine.runUntilIdle()
        job = h.store.job(id: job.id)!
        XCTAssertEqual(job.stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1)
    }

    func testOtherPermanentOpenAIErrorsNeedSettingsFix() async throws {
        for err in [OpenAIError.invalidKey("bad key"), .modelUnavailable("gone"), .permissionDenied("no")] {
            let h = try Harness()
            h.notes.failWith = err
            let l = try h.addLesson(mode: .single, recordings: 1)
            await h.engine().runUntilIdle()
            XCTAssertEqual(h.store.job(id: l.jobs[0].id)?.error?.kind, .openAISettings)
            XCTAssertEqual(h.store.transcriptState(jobId: l.jobs[0].id), .valid)
        }
    }
}

// MARK: - Simultaneous transcriptions

/// Transcriber that tracks concurrency and can be held open until released.
final class GateTranscriber: Transcribing, @unchecked Sendable {
    let active = Box<Int>(0)
    let maxActive = Box<Int>(0)
    let calls = Box<Int>(0)
    let started = Box<[String]>([])
    var failNames: Set<String> = []
    var holdOpen = false
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func release() {
        lock.lock(); let w = waiters; waiters = []; holdOpen = false; lock.unlock()
        w.forEach { $0.resume() }
    }

    func transcribe(audioURL: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionOutput {
        calls.mutate { $0 += 1 }
        active.mutate { $0 += 1 }
        maxActive.mutate { [a = active.value] in $0 = max($0, a) }
        let name = String(audioURL.lastPathComponent.prefix(36))
        started.mutate { $0.append(name) }
        defer { active.mutate { $0 -= 1 } }
        lock.lock(); let hold = holdOpen; lock.unlock()
        if hold { await withCheckedContinuation { c in lock.lock(); waiters.append(c); lock.unlock() } }
        else { try await Task.sleep(nanoseconds: 30_000_000) }
        if failNames.contains(name) { throw NSError(domain: "whisper", code: 2, userInfo: [NSLocalizedDescriptionKey: "Whisper failed"]) }
        return TranscriptionOutput(segments: [TranscriptSegment(start: 0, end: 1, text: "Transcript for recording \(name)")], modelId: "w", language: "en")
    }
}

final class ConcurrencyTests: XCTestCase {
    func harness(limit: Int, jobs: Int, gate: GateTranscriber, pressure: Box<MemoryPressureLevel> = Box(.normal)) throws -> (Harness, JobEngine, [Lesson]) {
        let h = try Harness()
        h.store.updateSettings { $0.maxConcurrentTranscriptions = limit; $0.maxConcurrentJobs = 2 }
        let lessons = try (0..<jobs).map { _ in try h.addLesson(mode: .single, recordings: 1) }
        let deps = EngineDependencies(extractor: h.extractor, transcriber: gate, makeNotesProducer: { h.notes }, makeSubmitter: { h.submitter },
                                      isOnline: { true }, appVersion: "t", memoryPressure: { pressure.value })
        return (h, JobEngine(store: h.store, deps: deps, tempRoot: h.tempRoot, now: { h.clock.value }), lessons)
    }

    func testLimitRespectedAndQueueDrains() async throws {
        let gate = GateTranscriber()
        let (h, engine, lessons) = try harness(limit: 3, jobs: 10, gate: gate)
        await engine.runUntilIdle()
        XCTAssertEqual(gate.maxActive.value, 3, "never more than 3 at once, and 3 were used")
        let observed = await engine.maxObservedTranscriptions
        XCTAssertEqual(observed, 3)
        XCTAssertEqual(gate.calls.value, 10, "each recording transcribed exactly once")
        for l in lessons {
            let job = h.store.job(id: l.jobs[0].id)!
            XCTAssertEqual(job.stage, .submitted)
            // No cross-contamination: each transcript belongs to its own recording.
            XCTAssertEqual(h.store.transcript(jobId: job.id)?.parts.first?.segments.first?.text, "Transcript for recording \(l.recordings[0].id.uuidString)")
        }
    }

    func testDefaultIsOneAtATime() async throws {
        let gate = GateTranscriber()
        let (_, engine, _) = try harness(limit: AppSettings().maxConcurrentTranscriptions, jobs: 4, gate: gate)
        await engine.runUntilIdle()
        XCTAssertEqual(gate.maxActive.value, 1)
    }

    func testChangingLimitWhileRunning() async throws {
        let gate = GateTranscriber()
        gate.holdOpen = true
        let (h, engine, _) = try harness(limit: 1, jobs: 6, gate: gate)
        await engine.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        var active = await engine.activeTranscriptionCount
        XCTAssertEqual(active, 1)
        // Raise to 3: two more start straight away.
        h.store.updateSettings { $0.maxConcurrentTranscriptions = 3 }
        await engine.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        active = await engine.activeTranscriptionCount
        XCTAssertEqual(active, 3)
        XCTAssertEqual(gate.active.value, 3)
        // Lower to 1: running ones are NOT stopped, and nothing new starts.
        h.store.updateSettings { $0.maxConcurrentTranscriptions = 1 }
        await engine.tick()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(gate.active.value, 3)
        XCTAssertEqual(gate.calls.value, 3)
        gate.release()
        await engine.runUntilIdle()
        XCTAssertEqual(gate.calls.value, 6)
        XCTAssertEqual(h.store.allLessons.filter { $0.jobs[0].stage == .submitted }.count, 6)
    }

    func testFailuresReleaseSlots() async throws {
        let gate = GateTranscriber()
        let (h, engine, lessons) = try harness(limit: 2, jobs: 6, gate: gate)
        gate.failNames = Set(lessons.prefix(3).map { $0.recordings[0].id.uuidString })
        await engine.runUntilIdle()
        let states = lessons.map { h.store.job(id: $0.jobs[0].id)!.stage }
        XCTAssertEqual(states.filter { $0 == .failed }.count, 3)
        XCTAssertEqual(states.filter { $0 == .submitted }.count, 3, "failures did not block the queue")
        let active = await engine.activeTranscriptionCount
        XCTAssertEqual(active, 0)
    }

    func testSummarisingJobsDoNotUseTranscriptionSlots() async throws {
        let gate = GateTranscriber()
        gate.holdOpen = true
        let (h, engine, lessons) = try harness(limit: 1, jobs: 1, gate: gate)
        // A second lesson already has a transcript and only needs OpenAI.
        let ready = try h.addLesson(mode: .single, recordings: 1)
        try h.store.saveTranscript(StoredTranscript(jobId: ready.jobs[0].id, savedAt: Date(), model: "w", language: "en",
                                                    parts: [TranscriptPart(recordingId: ready.recordings[0].id, filename: "zoom_0.mp4", recordedAt: nil, durationSec: 60,
                                                                           segments: [TranscriptSegment(start: 0, end: 1, text: "Saved earlier.")])]))
        await engine.tick()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(h.store.job(id: ready.jobs[0].id)?.stage, .submitted, "summarised and submitted while Whisper is busy")
        XCTAssertEqual(gate.calls.value, 1, "only the job without a transcript uses Whisper")
        gate.release()
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.job(id: lessons[0].jobs[0].id)?.stage, .submitted)
    }

    func testMemoryPressureReducesNewTranscriptions() async throws {
        let gate = GateTranscriber()
        let pressure = Box<MemoryPressureLevel>(.critical)
        let (_, engine, _) = try harness(limit: 4, jobs: 6, gate: gate, pressure: pressure)
        await engine.runUntilIdle()
        XCTAssertEqual(gate.maxActive.value, 1, "critical pressure: one at a time")
        pressure.value = .warning
        let limit = await engine.transcriptionLimit()
        XCTAssertEqual(limit, 2)
    }

    func testSettingPersistsAndIsClamped() throws {
        let h = try Harness()
        h.store.updateSettings { $0.maxConcurrentTranscriptions = 5 }
        XCTAssertEqual(try LibraryStore(directory: h.store.directory).settings.maxConcurrentTranscriptions, 5)
        let hi = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"maxConcurrentTranscriptions":99}"#.utf8))
        XCTAssertEqual(hi.maxConcurrentTranscriptions, 8)
        let lo = try JSONCoding.decoder().decode(AppSettings.self, from: Data(#"{"maxConcurrentTranscriptions":0}"#.utf8))
        XCTAssertEqual(lo.maxConcurrentTranscriptions, 1)
    }
}
