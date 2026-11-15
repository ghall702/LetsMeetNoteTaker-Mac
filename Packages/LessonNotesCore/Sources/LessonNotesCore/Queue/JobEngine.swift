import Foundation

// MARK: Pipeline dependencies (real implementations live in the app; tests use mocks)

public protocol AudioExtracting: Sendable {
    /// Extracts 16 kHz mono audio into `directory` and returns the file URL.
    func extractAudio(for recording: RecordingRef, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL
}

public struct TranscriptionOutput: Sendable, Equatable {
    public var segments: [TranscriptSegment]
    public var modelId: String
    public var language: String
    public init(segments: [TranscriptSegment], modelId: String, language: String) {
        self.segments = segments
        self.modelId = modelId
        self.language = language
    }
}

public protocol Transcribing: Sendable {
    func transcribe(audioURL: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionOutput
}

public struct ProducedNotes: Sendable, Equatable {
    public var notes: GeneratedNotes
    public var model: String
    public var effort: ReasoningEffort
    public var adjustments: [String]
    public init(notes: GeneratedNotes, model: String, effort: ReasoningEffort, adjustments: [String] = []) {
        self.notes = notes
        self.model = model
        self.effort = effort
        self.adjustments = adjustments
    }
}

public protocol NotesProducing: Sendable {
    func produceNotes(transcript: String, context: NotesRequestContext, instructions: String,
                      progress: @escaping @Sendable (Double, String) -> Void) async throws -> ProducedNotes
}

public protocol NoteSubmitting: Sendable {
    func submit(body: Data) async throws -> NoteStatusResponse
    /// `multipart/form-data` submission with lesson files (`file_uploads`).
    func submit(body: Data, files: [UploadFile]) async throws -> NoteStatusResponse
}

extension NoteSubmitting {
    public func submit(body: Data, files: [UploadFile]) async throws -> NoteStatusResponse {
        precondition(files.isEmpty, "this submitter cannot upload files")
        return try await submit(body: body)
    }
}

extension LetsMeetClient: NoteSubmitting {}

/// `PATCH /notes/{id}` plus status lookup (for the current `version`).
public protocol NoteReplacing: Sendable {
    func replace(noteId: String, body: Data) async throws -> NoteReplaceResponse
    func status(of id: String) async throws -> NoteStatusResponse
}

extension LetsMeetClient: NoteReplacing {}

/// `PATCH /notes/{id}/lesson-length` (admin-only length; no content, version or status change).
public protocol LessonLengthSetting: Sendable {
    func setLessonLength(noteId: String, seconds: Int?) async throws -> LessonLengthResponse
}

extension LetsMeetClient: LessonLengthSetting {}

/// Real notes producer: OpenAI Responses API with the model chosen in Settings.
public struct OpenAINotesProducer: NotesProducing {
    public var generator: NotesGenerator
    public init(generator: NotesGenerator) { self.generator = generator }
    public func produceNotes(transcript: String, context: NotesRequestContext, instructions: String,
                             progress: @escaping @Sendable (Double, String) -> Void) async throws -> ProducedNotes {
        let r = try await generator.generateDetailed(transcript: transcript, context: context, instructions: instructions, progress: progress)
        return ProducedNotes(notes: r.notes, model: generator.model, effort: generator.effort, adjustments: r.adjustments)
    }
}

public struct EngineDependencies: Sendable {
    public var extractor: AudioExtracting
    public var transcriber: Transcribing
    public var makeNotesProducer: @Sendable () throws -> NotesProducing
    public var makeSubmitter: @Sendable () throws -> NoteSubmitting
    public var isOnline: @Sendable () -> Bool
    public var appVersion: String
    public var makeReplacer: (@Sendable () throws -> NoteReplacing)?
    /// macOS memory pressure (the app wires this to a DispatchSource); reduces new transcriptions.
    public var memoryPressure: @Sendable () -> MemoryPressureLevel
    public var makeLessonLengthSetter: (@Sendable () throws -> LessonLengthSetting)?
    /// Prepares lesson files as OpenAI context.
    public var materialLoader = MaterialLoader()

    public init(extractor: AudioExtracting, transcriber: Transcribing, makeNotesProducer: @escaping @Sendable () throws -> NotesProducing,
                makeSubmitter: @escaping @Sendable () throws -> NoteSubmitting, isOnline: @escaping @Sendable () -> Bool, appVersion: String,
                makeReplacer: (@Sendable () throws -> NoteReplacing)? = nil,
                memoryPressure: @escaping @Sendable () -> MemoryPressureLevel = { .normal },
                makeLessonLengthSetter: (@Sendable () throws -> LessonLengthSetting)? = nil) {
        self.makeLessonLengthSetter = makeLessonLengthSetter
        self.makeReplacer = makeReplacer
        self.memoryPressure = memoryPressure
        self.extractor = extractor
        self.transcriber = transcriber
        self.makeNotesProducer = makeNotesProducer
        self.makeSubmitter = makeSubmitter
        self.isOnline = isOnline
        self.appVersion = appVersion
    }
}

public enum MemoryPressureLevel: Sendable, Equatable { case normal, warning, critical }

public enum EngineEvent: Sendable, Equatable {
    case progress(jobId: UUID, fraction: Double, message: String)
    case submitted(jobId: UUID)
    case failed(jobId: UUID, message: String)
    case replaced(jobId: UUID)
    case replacementNeedsAttention(jobId: UUID, message: String)
    case idle
}

public enum PipelineError: Error, LocalizedError, Equatable {
    case recordingMissing(String)
    case noSpeech
    case transcriptMissing
    case lessonMissing
    case payloadTooLarge(String)
    case invalidSubmission(String)

    public var errorDescription: String? {
        switch self {
        case .recordingMissing(let f): return "The recording “\(f)” can no longer be found or opened. Check it still exists, then retry."
        case .noSpeech: return "No speech was recognised in the selected recordings."
        case .transcriptMissing: return "The local transcript for this lesson is missing (it may have been deleted by the retention setting). Use Reprocess to transcribe again."
        case .lessonMissing: return "The lesson record is missing."
        case .payloadTooLarge(let m): return m
        case .invalidSubmission(let m): return "The notes could not be validated before upload: \(m)"
        }
    }
}

// MARK: Engine

/// Persistent processing queue. Jobs survive restarts because every stage change is
/// written to the store; a relaunch resumes each job at its saved stage.
public actor JobEngine {
    let store: LibraryStore
    let deps: EngineDependencies
    let tempRoot: URL
    let retryPolicy: RetryPolicy
    let now: @Sendable () -> Date

    private var running: [UUID: Task<Void, Never>] = [:]
    private var transcribingJobs: Set<UUID> = []
    private var networkJobs: Set<UUID> = []
    private var userCancelled: Set<UUID> = []
    private var loopTask: Task<Void, Never>?
    private var eventHandler: (@Sendable (EngineEvent) -> Void)?
    public private(set) var isPaused = false

    /// Seconds between lesson-length requests (keeps well under the 60 requests/minute limit).
    let lessonLengthPacing: TimeInterval
    private var lessonLengthTask: Task<Void, Never>?

    public init(store: LibraryStore, deps: EngineDependencies, tempRoot: URL, retryPolicy: RetryPolicy = RetryPolicy(),
                now: @escaping @Sendable () -> Date = { Date() }, lessonLengthPacing: TimeInterval = 1.5) {
        self.lessonLengthPacing = lessonLengthPacing
        self.store = store
        self.deps = deps
        self.tempRoot = tempRoot
        self.retryPolicy = retryPolicy
        self.now = now
    }

    public func setEventHandler(_ h: @escaping @Sendable (EngineEvent) -> Void) { eventHandler = h }

    private func emit(_ e: EngineEvent) { eventHandler?(e) }

    // MARK: Lifecycle

    /// Call once at launch: removes leftover temporary audio and restarts any
    /// transcription that was interrupted when the app quit (from the beginning).
    public func recoverAfterLaunch() {
        try? FileManager.default.removeItem(at: tempRoot)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        for l in store.allLessons {
            for j in l.jobs where j.stage == .extracting || j.stage == .transcribing {
                let saved = store.transcriptState(jobId: j.id) == .valid
                store.updateJob(id: j.id, now: now()) {
                    if saved {
                        $0.hasTranscript = true
                        $0.stage = $0.notes != nil ? .submitting : .summarising
                        $0.statusMessage = "Reusing the transcript saved before the app was closed"
                    } else {
                        $0.stage = .queued
                        $0.statusMessage = "Restarting transcription after the app was closed"
                    }
                }
            }
        }
    }

    public func start(interval: TimeInterval = 15) {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        for (_, t) in running { t.cancel() }
    }

    public func setPaused(_ paused: Bool) {
        isPaused = paused
        if !paused { tick() }
    }

    public var activeJobIds: [UUID] { Array(running.keys) }

    // MARK: Scheduling

    /// A job needs Whisper only if no valid transcript is saved (the flag alone is not trusted).
    func needsTranscription(_ j: Job) -> Bool {
        [.queued, .extracting, .transcribing].contains(j.stage) && store.transcriptState(jobId: j.id) != .valid
    }

    /// Transcription slots in use and the effective limit (setting, reduced under memory pressure).
    public var activeTranscriptionCount: Int { transcribingJobs.count }
    public var activeNetworkCount: Int { networkJobs.count }
    public private(set) var maxObservedTranscriptions = 0

    public func transcriptionLimit() -> Int {
        let configured = max(1, min(8, store.settings.maxConcurrentTranscriptions))
        switch deps.memoryPressure() {
        case .normal: return configured
        case .warning: return max(1, configured / 2)
        case .critical: return 1
        }
    }

    /// Starts every job that is due. Whisper transcriptions and OpenAI/website work use separate
    /// pools: at most `maxConcurrentTranscriptions` transcriptions (reduced under memory pressure;
    /// running ones are never stopped) and `maxConcurrentJobs` network jobs.
    public static let openAIPausedMessage = "Transcribed — waiting while OpenAI is paused"

    public func tick() {
        guard !isPaused else { return }
        let t = now()
        let networkLimit = max(1, min(4, store.settings.maxConcurrentJobs))
        let transcriptionLimit = transcriptionLimit()
        let online = deps.isOnline()
        let settings = store.settings
        var lessonDates: [UUID: String] = [:]
        for l in store.allLessons { for j in l.jobs { lessonDates[j.id] = l.lessonDate } }
        let candidates = store.allLessons.flatMap { l in l.jobs }
            .filter { $0.stage.isActive && running[$0.id] == nil }
            .filter { ($0.nextAttemptAt ?? .distantPast) <= t }
            .sorted { $0.createdAt < $1.createdAt }
        for job in candidates {
            let id = job.id
            if needsTranscription(job) {
                guard transcribingJobs.count < transcriptionLimit else { continue }
                transcribingJobs.insert(id)
                maxObservedTranscriptions = max(maxObservedTranscriptions, transcribingJobs.count)
                running[id] = Task { [weak self] in
                    await self?.process(jobId: id, phase: .transcription)
                    await self?.finished(jobId: id)
                }
            } else {
                if job.notes == nil, settings.openAIHeld(lessonDate: lessonDates[id] ?? "", job: job, now: t) {
                    if job.statusMessage != Self.openAIPausedMessage {
                        store.updateJob(id: id, now: t) { $0.statusMessage = Self.openAIPausedMessage }
                    }
                    continue
                }
                guard online else {
                    if job.statusMessage != "Waiting for internet" {
                        store.updateJob(id: job.id, now: t) { $0.statusMessage = "Waiting for internet" }
                    }
                    continue
                }
                guard networkJobs.count < networkLimit else { continue }
                networkJobs.insert(id)
                running[id] = Task { [weak self] in
                    await self?.process(jobId: id, phase: .network)
                    await self?.finished(jobId: id)
                }
            }
        }
        // Queued website replacements (PATCH), for submitted notes.
        if online {
            let due = store.allLessons.flatMap(\.jobs).filter { j in
                guard let r = j.replacement, r.state == .queued, running[j.id] == nil else { return false }
                return (r.nextAttemptAt ?? .distantPast) <= t
            }
            for job in due where networkJobs.count < networkLimit + 2 {
                let id = job.id
                networkJobs.insert(id)
                running[id] = Task { [weak self] in
                    await self?.processReplacement(jobId: id)
                    await self?.finished(jobId: id)
                }
            }
        }
        if online && lessonLengthTask == nil && deps.makeLessonLengthSetter != nil && !dueLessonLengths(now: t).isEmpty {
            lessonLengthTask = Task { [weak self] in
                await self?.syncLessonLengths()
                await self?.lessonLengthFinished()
            }
        }
        if running.isEmpty { emit(.idle) }
    }

    private func finished(jobId: UUID) {
        running[jobId] = nil
        transcribingJobs.remove(jobId)
        networkJobs.remove(jobId)
        tick()
    }

    /// Test helper: keeps ticking until no job is running or due now.
    public func runUntilIdle(maxRounds: Int = 200) async {
        for _ in 0..<maxRounds {
            tick()
            let tasks = Array(running.values) + (lessonLengthTask.map { [$0] } ?? [])
            if tasks.isEmpty { return }
            for t in tasks { await t.value }
        }
    }

    /// Test helper: wait for currently running work only.
    public func waitForRunning() async {
        for t in Array(running.values) { await t.value }
    }

    // MARK: User actions

    public func cancel(jobId: UUID) {
        guard let job = store.job(id: jobId), job.stage.isActive || job.stage == .held else { return }
        userCancelled.insert(jobId)
        running[jobId]?.cancel()
        store.updateJob(id: jobId, now: now()) {
            $0.resumeStage = $0.stage == .held ? .queued : $0.stage
            $0.stage = .cancelled
            $0.statusMessage = "Cancelled"
            $0.nextAttemptAt = nil
        }
    }

    /// Manual retry ("Fix & Retry"/"Resume"). Resumes from the last completed stage using what is
    /// actually saved: a valid transcript goes straight to OpenAI (no audio extraction or Whisper);
    /// saved notes go straight to website submission with the same submission id. The current
    /// model and prompt settings are used for a new summarisation.
    @discardableResult
    public func retry(jobId: UUID) -> JobRecovery.RetryPlan? {
        guard let job = store.job(id: jobId) else { return nil }
        let state = store.transcriptState(jobId: jobId)
        let plan = JobRecovery.retryPlan(for: job, transcriptState: state)
        if case .corrupt = state { store.quarantineTranscript(jobId: jobId, now: now()) }
        store.updateJob(id: jobId, now: now()) { j in
            switch plan {
            case .submit:
                j.stage = .submitting
            case .summarise:
                j.stage = .summarising
                j.hasTranscript = true
                j.summaryModel = nil
                j.reasoningEffort = nil
                j.promptSnapshot = nil // use the prompt configured now
            case .transcribe:
                j.stage = .queued
                j.hasTranscript = false
            case .resume(let s):
                j.stage = s
            }
            j.error = nil
            j.attempts = 0
            j.firstRetryAt = nil
            j.nextAttemptAt = nil
            switch plan {
            case .transcribe(let reason?): j.statusMessage = reason
            case .summarise: j.statusMessage = "Reusing the saved transcript"
            default: j.statusMessage = "Queued for retry"
            }
        }
        userCancelled.remove(jobId)
        tick()
        return plan
    }

    public func startHeld(jobId: UUID) {
        store.updateJob(id: jobId, now: now()) { j in
            guard j.stage == .held else { return }
            j.stage = .queued
            j.statusMessage = nil
        }
        tick()
    }

    // MARK: Processing

    private func update(_ id: UUID, _ body: (inout Job) -> Void) { store.updateJob(id: id, now: now(), body) }

    enum Phase { case transcription, network }

    /// Runs one phase: `.transcription` holds a Whisper slot and stops once the transcript is
    /// saved (the next tick schedules summarising in the network pool); `.network` runs
    /// summarising and submission.
    private func process(jobId: UUID, phase: Phase) async {
        var stageAtFailure: JobStage = .queued
        do {
            while true {
                try Task.checkCancellation()
                guard let lesson = store.lesson(containingJob: jobId), let job = lesson.jobs.first(where: { $0.id == jobId }) else { return }
                stageAtFailure = job.stage
                switch job.stage {
                case .queued, .extracting, .transcribing:
                    if store.transcriptState(jobId: jobId) == .valid {
                        update(jobId) { $0.hasTranscript = true; $0.stage = $0.notes != nil ? .submitting : .summarising }
                        if phase == .transcription { return }
                        continue
                    }
                    guard phase == .transcription else { return }
                    if case .corrupt = store.transcriptState(jobId: jobId) { store.quarantineTranscript(jobId: jobId, now: now()) }
                    try await transcribeStage(lesson: lesson, job: job)
                    return // release the transcription slot; summarising is scheduled separately
                case .summarising:
                    guard phase == .network else { return }
                    if job.notes != nil { update(jobId) { $0.stage = .submitting }; continue }
                    if store.settings.openAIHeld(lessonDate: lesson.lessonDate, job: job, now: now()) {
                        update(jobId) { $0.statusMessage = Self.openAIPausedMessage }
                        return
                    }
                    guard deps.isOnline() else { update(jobId) { $0.statusMessage = "Waiting for internet" }; return }
                    try await summariseStage(lesson: lesson, job: job)
                case .submitting:
                    guard phase == .network else { return }
                    guard deps.isOnline() else { update(jobId) { $0.statusMessage = "Waiting for internet" }; return }
                    try await submitStage(lesson: lesson, job: job)
                default:
                    return
                }
            }
        } catch {
            handleFailure(jobId: jobId, stage: stageAtFailure, error: error)
        }
    }

    private func handleFailure(jobId: UUID, stage: JobStage, error: Error) {
        let t = now()
        if userCancelled.contains(jobId) { userCancelled.remove(jobId); return }
        // Local pipeline errors are never retried automatically.
        if let p = error as? PipelineError {
            let kind: JobError.Kind
            switch p {
            case .payloadTooLarge: kind = .payloadTooLarge
            case .recordingMissing: kind = .recordingMissing
            case .invalidSubmission: kind = .validation
            default: kind = .general
            }
            fail(jobId, stage: stage, JobError(message: p.localizedDescription, kind: kind, occurredAt: t))
            return
        }
        switch FailureClass.classify(error, now: t) {
        case .cancelled:
            // App shutting down: leave the job at its stage so it resumes next launch.
            return
        case .deferred(let message, let until):
            update(jobId) { $0.statusMessage = message; $0.nextAttemptAt = until }
        case .offline:
            update(jobId) { $0.statusMessage = "Waiting for internet"; $0.nextAttemptAt = t.addingTimeInterval(30) }
        case .retryable(let message, let retryAfter):
            guard stage.needsNetwork else {
                fail(jobId, stage: stage, JobError(message: message, occurredAt: t)); return
            }
            var gaveUp = false
            update(jobId) { j in
                j.attempts += 1
                let first = j.firstRetryAt ?? t
                j.firstRetryAt = first
                if let next = retryPolicy.nextAttempt(attempt: j.attempts, firstRetryAt: first, now: t, retryAfter: retryAfter) {
                    j.nextAttemptAt = next
                    let f = DateFormatter()
                    f.dateFormat = "HH:mm:ss"
                    j.statusMessage = "Will retry at \(f.string(from: next)) — \(message)"
                } else {
                    gaveUp = true
                }
            }
            if gaveUp {
                fail(jobId, stage: stage, JobError(message: "Gave up after retrying for 24 hours: \(message)", occurredAt: t))
            }
        case .fatal(var e):
            if e.kind == .submissionConflict, let le = error as? LetsMeetAPIError, let nid = le.noteId {
                update(jobId) { $0.noteId = nid }
                e.message += " (A different note already uses this submission id. Use Reprocess to submit as a new note.)"
            }
            fail(jobId, stage: stage, e)
        }
    }

    private func fail(_ jobId: UUID, stage: JobStage, _ e: JobError) {
        update(jobId) { j in
            j.stage = .failed
            j.resumeStage = stage
            j.error = e
            j.nextAttemptAt = nil
            j.statusMessage = e.kind == .payloadTooLarge ? "Needs attention" : "Failed"
        }
        emit(.failed(jobId: jobId, message: e.message))
    }

    private func transcribeStage(lesson: Lesson, job: Job) async throws {
        let recs = lesson.recordings(for: job)
        guard !recs.isEmpty else { throw PipelineError.lessonMissing }
        let dir = tempRoot.appendingPathComponent(job.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Temporary audio is always deleted, on success or failure.
        defer { try? FileManager.default.removeItem(at: dir) }

        let language = store.settings.transcriptionLanguage
        var parts: [TranscriptPart] = []
        var modelId = ""
        var lang = language ?? "auto"
        let n = Double(recs.count)
        for (i, rec) in recs.enumerated() {
            try Task.checkCancellation()
            let base = Double(i) / n
            let label = recs.count > 1 ? " (part \(i + 1) of \(recs.count))" : ""
            update(job.id) { $0.stage = .extracting; $0.statusMessage = "Extracting audio\(label)" }
            emit(.progress(jobId: job.id, fraction: base, message: "Extracting audio\(label)"))
            let jobId = job.id
            let handler = eventHandler
            let audio = try await deps.extractor.extractAudio(for: rec, into: dir) { p in
                handler?(.progress(jobId: jobId, fraction: base + p * 0.1 / n, message: "Extracting audio\(label)"))
            }
            defer { try? FileManager.default.removeItem(at: audio) }
            update(job.id) { $0.stage = .transcribing; $0.statusMessage = "Transcribing\(label)" }
            let out = try await deps.transcriber.transcribe(audioURL: audio, language: language) { p in
                handler?(.progress(jobId: jobId, fraction: base + (0.1 + p * 0.9) / n, message: "Transcribing\(label)"))
            }
            try? FileManager.default.removeItem(at: audio)
            modelId = out.modelId
            lang = out.language
            parts.append(TranscriptPart(recordingId: rec.id, filename: rec.filename, recordedAt: rec.recordedAt,
                                        durationSec: rec.durationSec, segments: out.segments))
        }
        let stored = StoredTranscript(jobId: job.id, savedAt: now(), model: modelId, language: lang, parts: parts)
        if stored.renderedText(timeZone: lesson.timeZone).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw PipelineError.noSpeech
        }
        try store.saveTranscript(stored)
        update(job.id) {
            $0.stage = .summarising
            $0.statusMessage = nil
            $0.completedStagesAt["transcribed"] = now()
        }
    }

    private func summariseStage(lesson: Lesson, job: Job) async throws {
        guard let transcript = store.transcript(jobId: job.id) else { throw PipelineError.transcriptMissing }
        let settings = store.settings
        let mapping = store.mapping(id: lesson.studentId)
        // Snapshot the effective prompt when summarisation first begins.
        var prompt = job.promptSnapshot
        if prompt == nil {
            let resolved = PromptResolver.resolve(globalPrompt: settings.globalPrompt, mapping: mapping)
            prompt = resolved
            update(job.id) { $0.promptSnapshot = resolved }
        }
        update(job.id) { $0.statusMessage = "Writing lesson notes" }
        let producer = try deps.makeNotesProducer()
        let recs = lesson.recordings(for: job)
        let summary = recs.count > 1
            ? "\(recs.count) recordings combined in order (\(recs.map(\.filename).joined(separator: ", ")))"
            : (recs.first.map { "\($0.filename), \(CoreFormat.duration($0.durationSec))" } ?? "")
        let materials = (job.attachments ?? []).filter(\.includeInContext).map { deps.materialLoader.load($0, at: store.attachmentURL(jobId: job.id, $0)) }
        let context = NotesRequestContext(pupilName: lesson.pupilName, pupilContext: mapping?.context ?? "",
                                          lessonDate: lesson.lessonDate, recordingSummary: summary, materials: materials)
        let jobId = job.id
        let handler = eventHandler
        let produced = try await UsageContext.$current.withValue(UsageContext(lessonId: lesson.id, jobId: jobId, purpose: .lessonNotes)) {
            try await producer.produceNotes(transcript: transcript.renderedText(timeZone: lesson.timeZone),
                                            context: context, instructions: prompt!.effectiveInstructions) { p, msg in
                handler?(.progress(jobId: jobId, fraction: p, message: msg))
            }
        }
        update(job.id) {
            $0.notes = produced.notes
            $0.notesAdjustments = produced.adjustments.isEmpty ? nil : produced.adjustments
            $0.summaryModel = produced.model
            $0.reasoningEffort = produced.effort
            $0.stage = .submitting
            $0.statusMessage = nil
            $0.attempts = 0
            $0.firstRetryAt = nil
            $0.completedStagesAt["summarised"] = now()
        }
    }

    private func submitStage(lesson: Lesson, job: Job) async throws {
        var payload = job.submissionPayload
        if payload == nil {
            guard let notes = job.notes else { update(job.id) { $0.stage = .summarising }; return }
            guard let transcript = store.transcript(jobId: job.id) else { throw PipelineError.transcriptMissing }
            let text = transcript.renderedText(timeZone: lesson.timeZone)
            let submission = SubmissionBuilder.build(lesson: lesson, job: job, notes: notes, transcriptText: text,
                                                     appVersion: deps.appVersion,
                                                     transcriptionModel: transcript.model.isEmpty ? (job.transcriptionModel ?? "unknown") : transcript.model,
                                                     summaryModel: job.summaryModel ?? "unknown")
            let body = try submission.jsonData()
            // Size limits are checked on the exact UTF-8 bytes; oversized uploads are never sent or retried.
            if let problem = APILimits.check(transcript: submission.transcript, encodedBody: body) {
                throw PipelineError.payloadTooLarge(problem.message)
            }
            let issues = SubmissionValidator.validate(submission)
            if !issues.isEmpty { throw PipelineError.invalidSubmission(issues.map(\.description).joined(separator: "; ")) }
            let files = job.attachments ?? []
            if let problem = AttachmentRules.check(files, noteJSONBytes: body.count) {
                throw PipelineError.invalidSubmission(problem.localizedDescription)
            }
            payload = body
            // The note JSON and its files are frozen together, so retries send identical content.
            update(job.id) { $0.submissionPayload = body; $0.submittedAttachments = files }
        }
        let frozenFiles = store.job(id: job.id)?.submittedAttachments ?? []
        var uploads: [UploadFile] = []
        for a in frozenFiles {
            do { uploads.append(UploadFile(filename: a.filename, contentType: a.contentType, data: try store.attachmentData(jobId: job.id, a))) }
            catch { throw PipelineError.invalidSubmission(error.localizedDescription) }
        }
        let what = uploads.isEmpty ? "Uploading notes and full transcript"
            : "Uploading notes, full transcript and \(uploads.count) file\(uploads.count == 1 ? "" : "s")"
        update(job.id) { $0.statusMessage = what }
        emit(.progress(jobId: job.id, fraction: 0.5, message: what))
        let submitter = try deps.makeSubmitter()
        store.flush() // the frozen payload must be on disk before it is sent (idempotent retries)
        let response = uploads.isEmpty ? try await submitter.submit(body: payload!) : try await submitter.submit(body: payload!, files: uploads)
        update(job.id) {
            $0.noteId = response.noteId
            $0.remoteStatus = response.status
            $0.remoteVersion = response.version ?? $0.remoteVersion
            if let len = response.lessonLength { $0.lessonLengthSynced = len }
            $0.replayed = response.replayed
            $0.remoteUpdatedAt = response.updatedAt
            $0.submittedAt = now()
            $0.remoteCheckedAt = now()
            if response.status == .published { $0.publishedAt = response.publishedAt.flatMap(CoreFormat.parseISO8601) ?? now() }
            $0.stage = .submitted
            $0.error = nil
            $0.nextAttemptAt = nil
            $0.attempts = 0
            $0.statusMessage = nil
            $0.completedStagesAt["submitted"] = now()
        }
        emit(.submitted(jobId: job.id))
    }
}

// MARK: Lesson length sync (admin-only `lesson_length`)

extension JobEngine {
    struct LessonLengthItem { let jobId: UUID; let ref: String; let seconds: Int }

    /// Submitted notes (including those from before 1.3) whose website lesson length is not yet
    /// known to match the recordings' total duration.
    func dueLessonLengths(now t: Date) -> [LessonLengthItem] {
        store.allLessons.flatMap { l in
            l.jobs.compactMap { j -> LessonLengthItem? in
                guard j.stage == .submitted, j.remoteStatus != .deleted, j.lessonLengthError == nil,
                      (j.lessonLengthNextAttemptAt ?? .distantPast) <= t,
                      let secs = LessonLength.seconds(for: l, job: j), j.lessonLengthSynced != secs else { return nil }
                return LessonLengthItem(jobId: j.id, ref: j.submissionId, seconds: secs)
            }
        }
    }

    func lessonLengthFinished() { lessonLengthTask = nil }

    /// Sends lesson lengths one at a time with the dedicated endpoint — the notes themselves are
    /// never resent, and status/version are unchanged on the website.
    func syncLessonLengths() async {
        guard let make = deps.makeLessonLengthSetter, let setter = try? make() else { return }
        for item in dueLessonLengths(now: now()) {
            guard deps.isOnline(), !Task.isCancelled else { return }
            do {
                let r = try await setter.setLessonLength(noteId: item.ref, seconds: item.seconds)
                store.updateJob(id: item.jobId, now: now()) { j in
                    j.lessonLengthSynced = r.lessonLength ?? item.seconds
                    j.lessonLengthAttempts = nil
                    j.lessonLengthNextAttemptAt = nil
                    if let s = r.status { j.remoteStatus = s }
                }
            } catch let e as LetsMeetAPIError {
                switch e.httpStatus {
                case 404:
                    store.updateJob(id: item.jobId, now: now()) { $0.remoteStatus = .deleted }
                case 422, 400:
                    store.updateJob(id: item.jobId, now: now()) { $0.lessonLengthError = e.localizedDescription }
                case 429:
                    lessonLengthBackoff(item.jobId, retryAfter: e.retryAfter)
                    return // rate limited: stop this pass
                case 401, 403:
                    lessonLengthBackoff(item.jobId, retryAfter: 3600)
                    return // key problem: try again later
                default:
                    lessonLengthBackoff(item.jobId, retryAfter: e.retryAfter)
                }
            } catch {
                lessonLengthBackoff(item.jobId, retryAfter: nil)
                return
            }
            if lessonLengthPacing > 0 { try? await Task.sleep(nanoseconds: UInt64(lessonLengthPacing * 1_000_000_000)) }
        }
    }

    private func lessonLengthBackoff(_ jobId: UUID, retryAfter: TimeInterval?) {
        let t = now()
        store.updateJob(id: jobId, now: t) { j in
            let n = (j.lessonLengthAttempts ?? 0) + 1
            j.lessonLengthAttempts = n
            j.lessonLengthNextAttemptAt = t.addingTimeInterval(max(retryAfter ?? 0, RetryPolicy.baseDelay(forAttempt: n)))
        }
    }
}

// MARK: Website replacements (PATCH)

extension JobEngine {
    func processReplacement(jobId: UUID) async {
        guard let lesson = store.lesson(containingJob: jobId), let job = lesson.jobs.first(where: { $0.id == jobId }),
              var rep = job.replacement, rep.state == .queued else { return }
        guard let version = job.allNoteVersions.first(where: { $0.id == rep.versionId }) else {
            store.updateJob(id: jobId, now: now()) { $0.replacement = nil }
            return
        }
        let noteRef = job.noteId ?? job.submissionId
        do {
            guard let makeReplacer = deps.makeReplacer else { throw LetsMeetClientError.missingKey }
            let replacer = try makeReplacer()
            if rep.body == nil {
                if rep.baseVersion == nil {
                    let st = try await replacer.status(of: noteRef)
                    if st.status == .deleted {
                        markReplacement(jobId, state: .noteDeleted, message: "This note has been deleted on the website.")
                        store.updateJob(id: jobId, now: now()) { $0.remoteStatus = .deleted }
                        return
                    }
                    guard let v = st.version else {
                        markReplacement(jobId, state: .failed, message: "The website did not report the note's version, so it cannot be replaced safely.")
                        return
                    }
                    rep.baseVersion = v
                }
                let n = NotesSchema.sanitise(version.notes)
                let body = NoteReplacement(updateId: rep.updateId, baseVersion: rep.baseVersion!, title: n.title, summary: NotesSchema.summary(from: n),
                                           privateNotes: n.privateNotes.isEmpty ? nil : n.privateNotes,
                                           generator: ReplacementGenerator(appVersion: String(deps.appVersion.prefix(100)), summaryModel: String(version.model.prefix(100))))
                let issues = SubmissionValidator.validate(body)
                if !issues.isEmpty {
                    markReplacement(jobId, state: .failed, message: "The new notes could not be validated: " + issues.map(\.description).joined(separator: "; "))
                    return
                }
                rep.body = try body.jsonData()
                let frozen = rep
                store.updateJob(id: jobId, now: now()) { $0.replacement = frozen }
            }
            emit(.progress(jobId: jobId, fraction: 0.5, message: "Replacing notes on the website"))
            store.flush()
            let resp = try await replacer.replace(noteId: noteRef, body: rep.body!)
            completeReplacement(jobId, version: version, response: resp)
        } catch let e as LetsMeetAPIError {
            switch (e.httpStatus, e.code) {
            case (409, "version_conflict"):
                store.updateJob(id: jobId, now: now()) { j in
                    j.replacement?.state = .conflict
                    j.replacement?.conflictCurrentVersion = e.currentVersion
                    j.replacement?.conflictChangedBy = e.lastChangedBy
                    j.replacement?.conflictUpdatedAt = e.remoteUpdatedAt
                    j.replacement?.message = "This note was changed on the website since you generated this version."
                    j.replacement?.nextAttemptAt = nil
                }
                emit(.replacementNeedsAttention(jobId: jobId, message: "This note was changed on the website since you generated this version."))
            case (409, "update_id_conflict"):
                // A reused update_id with a different body: generate a fresh id and resend.
                store.updateJob(id: jobId, now: now()) { j in
                    j.replacement?.updateId = PendingReplacement.makeUpdateId(now: now())
                    j.replacement?.body = nil
                    j.replacement?.attempts += 1
                    if (j.replacement?.attempts ?? 0) > 3 { j.replacement?.state = .failed; j.replacement?.message = e.message }
                }
            case (404, _):
                store.updateJob(id: jobId, now: now()) { $0.remoteStatus = .deleted }
                markReplacement(jobId, state: .noteDeleted, message: "This note has been deleted on the website. You can submit these notes as a new note.")
            case (422, "no_changes"):
                completeReplacement(jobId, version: version, response: nil)
            default:
                if e.isRetryable { scheduleReplacementRetry(jobId, message: e.message, retryAfter: e.retryAfter) }
                else { markReplacement(jobId, state: .failed, message: e.localizedDescription) }
            }
        } catch {
            switch FailureClass.classify(error, now: now()) {
            case .offline:
                store.updateJob(id: jobId, now: now()) { $0.replacement?.message = "Waiting for internet"; $0.replacement?.nextAttemptAt = now().addingTimeInterval(30) }
            case .retryable(let m, let ra):
                scheduleReplacementRetry(jobId, message: m, retryAfter: ra)
            case .cancelled, .deferred:
                return
            case .fatal(let je):
                markReplacement(jobId, state: .failed, message: je.message)
            }
        }
    }

    private func markReplacement(_ jobId: UUID, state: PendingReplacement.State, message: String) {
        store.updateJob(id: jobId, now: now()) { j in
            j.replacement?.state = state
            j.replacement?.message = message
            j.replacement?.nextAttemptAt = nil
        }
        emit(.replacementNeedsAttention(jobId: jobId, message: message))
    }

    private func scheduleReplacementRetry(_ jobId: UUID, message: String, retryAfter: TimeInterval?) {
        let t = now()
        var gaveUp = false
        store.updateJob(id: jobId, now: t) { j in
            guard var r = j.replacement else { return }
            r.attempts += 1
            let first = r.firstRetryAt ?? t
            r.firstRetryAt = first
            if let next = retryPolicy.nextAttempt(attempt: r.attempts, firstRetryAt: first, now: t, retryAfter: retryAfter) {
                r.nextAttemptAt = next
                r.message = "Will retry — \(message)"
            } else {
                gaveUp = true
            }
            j.replacement = r
        }
        if gaveUp { markReplacement(jobId, state: .failed, message: "Gave up after retrying for 24 hours: \(message)") }
    }

    private func completeReplacement(_ jobId: UUID, version: NoteVersion, response: NoteReplaceResponse?) {
        let t = now()
        store.updateJob(id: jobId, now: t) { j in
            j.materialiseVersions()
            for i in j.noteVersions!.indices {
                if j.noteVersions![i].state == .current { j.noteVersions![i].state = .superseded }
                if j.noteVersions![i].id == version.id {
                    j.noteVersions![i].state = .current
                    j.noteVersions![i].websiteVersion = response?.version ?? j.remoteVersion
                }
            }
            j.notes = version.notes
            j.summaryModel = version.model
            j.reasoningEffort = version.effort
            j.notesAdjustments = version.adjustments.isEmpty ? nil : version.adjustments
            if let r = response {
                j.remoteStatus = r.status
                if let v = r.version { j.remoteVersion = v }
                if let len = r.lessonLength { j.lessonLengthSynced = len }
                if let n = r.noteId { j.noteId = n }
                j.remoteUpdatedAt = r.updatedAt ?? j.remoteUpdatedAt
                if r.status != .published { j.publishedAt = nil }
            }
            j.remoteCheckedAt = t
            j.replacement = nil
        }
        emit(.replaced(jobId: jobId))
    }
}

// MARK: Status synchronisation

public enum StatusSync {
    public static let pendingInterval: TimeInterval = 600
    public static let publishedInterval: TimeInterval = 86_400
    public static let publishedWindow: TimeInterval = 30 * 86_400

    /// Submission ids due for a status check. Pending notes: every 10 min. Published notes:
    /// daily for 30 days (they can be unpublished). Rejected/deleted: never again.
    public static func dueSubmissionIds(lessons: [Lesson], now: Date, force: Bool = false) -> [String] {
        var ids: [String] = []
        for l in lessons {
            for j in l.jobs where j.stage == .submitted {
                let status = j.remoteStatus ?? .pending
                if status.isFinal { continue }
                let last = j.remoteCheckedAt ?? .distantPast
                let elapsed = now.timeIntervalSince(last)
                switch status {
                case .pending:
                    if force || elapsed >= pendingInterval - 30 { ids.append(j.submissionId) }
                case .published:
                    let since = j.publishedAt ?? j.submittedAt ?? j.createdAt
                    guard now.timeIntervalSince(since) <= publishedWindow else { continue }
                    if force || elapsed >= publishedInterval - 60 { ids.append(j.submissionId) }
                default: break
                }
            }
        }
        return ids
    }

    public struct Change: Equatable, Sendable {
        public var jobId: UUID
        public var pupilName: String
        public var from: NoteStatus?
        public var to: NoteStatus
    }

    /// Applies results to the store and returns status changes (for notifications).
    @discardableResult
    public static func apply(_ results: [NoteStatusResponse], store: LibraryStore, now: Date) -> [Change] {
        var changes: [Change] = []
        for r in results {
            guard let lesson = store.allLessons.first(where: { $0.jobs.contains { $0.submissionId == r.submissionId } }),
                  let job = lesson.jobs.first(where: { $0.submissionId == r.submissionId }) else { continue }
            let old = job.remoteStatus
            store.updateJob(id: job.id, now: now) { j in
                j.remoteStatus = r.status
                j.remoteCheckedAt = now
                if let nid = r.noteId { j.noteId = nid }
                if let v = r.version { j.remoteVersion = v }
                if let len = r.lessonLength { j.lessonLengthSynced = len }
                j.remoteUpdatedAt = r.updatedAt ?? j.remoteUpdatedAt
                if r.status == .published {
                    j.publishedAt = r.publishedAt.flatMap(CoreFormat.parseISO8601) ?? j.publishedAt ?? now
                }
            }
            if old != r.status { changes.append(Change(jobId: job.id, pupilName: lesson.pupilName, from: old, to: r.status)) }
        }
        return changes
    }
}
