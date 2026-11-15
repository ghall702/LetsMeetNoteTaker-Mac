import Foundation

public struct RegenerationOptions: Sendable, Equatable {
    public enum PromptChoice: Sendable, Equatable {
        /// The current global prompt, or the student's custom prompt if they have one.
        case current
        /// A one-off prompt used only for this regeneration (never saved).
        case temporary(String)
    }
    public var prompt: PromptChoice
    public var additionalInstructions: String

    public init(prompt: PromptChoice = .current, additionalInstructions: String = "") {
        self.prompt = prompt
        self.additionalInstructions = additionalInstructions
    }
}

public enum RegenerationError: Error, LocalizedError, Equatable {
    case jobNotFound
    case transcriptMissing
    case versionNotFound
    case notADraft
    case replacementInProgress

    public var errorDescription: String? {
        switch self {
        case .jobNotFound: return "That lesson could not be found."
        case .transcriptMissing: return "The local transcript for this lesson is no longer available (deleted by the retention setting or manually), so the notes cannot be regenerated. Use Reprocess Anyway to transcribe the recordings again."
        case .versionNotFound: return "That version of the notes could not be found."
        case .notADraft: return "Only a regenerated draft can be used to replace the notes."
        case .replacementInProgress: return "A replacement for this lesson is already waiting to be sent to the website."
        }
    }
}

/// Regenerating notes from the saved local transcript (no re-transcription), local version
/// history, and queuing replacements of website notes.
public enum NotesRegeneration {
    static func context(for lesson: Lesson, job: Job, mapping: StudentMapping?, materials: [ContextMaterial] = []) -> NotesRequestContext {
        let recs = lesson.recordings(for: job)
        let summary = recs.count > 1
            ? "\(recs.count) recordings combined in order (\(recs.map(\.filename).joined(separator: ", ")))"
            : (recs.first.map { "\($0.filename), \(CoreFormat.duration($0.durationSec))" } ?? "")
        return NotesRequestContext(pupilName: lesson.pupilName, pupilContext: mapping?.context ?? "",
                                   lessonDate: lesson.lessonDate, recordingSummary: summary, materials: materials)
    }

    /// Generates a complete new version of every field and stores it as a draft for review.
    /// The saved prompts and default model are not changed.
    @discardableResult
    public static func regenerate(store: LibraryStore, jobId: UUID, options: RegenerationOptions, producer: NotesProducing,
                                  materialLoader: MaterialLoader = MaterialLoader(),
                                  now: Date = Date(), progress: @escaping @Sendable (Double, String) -> Void = { _, _ in }) async throws -> NoteVersion {
        guard let lesson = store.lesson(containingJob: jobId), let job = lesson.jobs.first(where: { $0.id == jobId }) else { throw RegenerationError.jobNotFound }
        guard job.hasTranscript, let transcript = store.transcript(jobId: jobId) else { throw RegenerationError.transcriptMissing }
        let mapping = store.mapping(id: lesson.studentId)
        // The lesson's files (as uploaded, if already uploaded) are used as context again.
        let files = job.attachments ?? job.submittedAttachments ?? []
        let materials = files.filter(\.includeInContext).map { materialLoader.load($0, at: store.attachmentURL(jobId: jobId, $0)) }
        let prompt: ResolvedPrompt
        switch options.prompt {
        case .current:
            prompt = PromptResolver.adding(options.additionalInstructions,
                                           to: PromptResolver.resolve(globalPrompt: store.settings.globalPrompt, mapping: mapping))
        case .temporary(let text):
            prompt = PromptResolver.temporary(text, additionalInstructions: options.additionalInstructions)
        }
        let produced = try await UsageContext.$current.withValue(UsageContext(lessonId: lesson.id, jobId: jobId, purpose: .regenerate)) {
            try await producer.produceNotes(transcript: transcript.renderedText(timeZone: lesson.timeZone),
                                            context: context(for: lesson, job: job, mapping: mapping, materials: materials),
                                            instructions: prompt.effectiveInstructions, progress: progress)
        }
        let extra = options.additionalInstructions.trimmingCharacters(in: .whitespacesAndNewlines)
        let version = NoteVersion(createdAt: now, kind: .regenerated, state: .draft, notes: produced.notes, model: produced.model,
                                  effort: produced.effort, promptSource: prompt.source, promptSnapshot: prompt.effectiveInstructions,
                                  additionalInstructions: extra.isEmpty ? nil : extra, adjustments: produced.adjustments,
                                  baseVersion: store.job(id: jobId)?.remoteVersion)
        store.updateJob(id: jobId, now: now) { j in
            j.materialiseVersions()
            j.noteVersions?.append(version)
        }
        return version
    }

    public static func discard(store: LibraryStore, jobId: UUID, versionId: UUID, now: Date = Date()) {
        store.updateJob(id: jobId, now: now) { j in
            j.materialiseVersions()
            if let i = j.noteVersions?.firstIndex(where: { $0.id == versionId && $0.state == .draft }) { j.noteVersions?[i].state = .discarded }
        }
    }

    public enum AcceptOutcome: Equatable, Sendable {
        /// The note is on the website: a PATCH replacement was queued.
        case replacementQueued
        /// Not on the website yet: the local notes were replaced and will be submitted.
        case replacedLocally
    }

    /// "Replace Existing Notes" for a reviewed draft. Never overwrites before George accepts.
    @discardableResult
    public static func accept(store: LibraryStore, jobId: UUID, versionId: UUID, now: Date = Date()) throws -> AcceptOutcome {
        guard let job = store.job(id: jobId) else { throw RegenerationError.jobNotFound }
        guard let draft = job.allNoteVersions.first(where: { $0.id == versionId }) else { throw RegenerationError.versionNotFound }
        guard draft.state == .draft else { throw RegenerationError.notADraft }
        if let r = job.replacement, r.state == .queued { throw RegenerationError.replacementInProgress }

        if job.stage == .submitted && job.remoteStatus != .deleted {
            store.updateJob(id: jobId, now: now) { j in
                j.materialiseVersions()
                for i in j.noteVersions!.indices where j.noteVersions![i].state == .uploading { j.noteVersions![i].state = .discarded }
                if let i = j.noteVersions!.firstIndex(where: { $0.id == versionId }) { j.noteVersions![i].state = .uploading }
                j.filesChangedSinceNotes = nil
                j.replacement = PendingReplacement(versionId: versionId, updateId: PendingReplacement.makeUpdateId(now: now),
                                                   baseVersion: draft.baseVersion ?? j.remoteVersion, createdAt: now)
            }
            return .replacementQueued
        }
        // Not yet on the website: swap the notes in. Content changed, so any frozen payload
        // is discarded and a new submission id is used (avoids 409 submission_conflict).
        let settings = store.settings
        let lesson = store.lesson(containingJob: jobId)
        store.updateJob(id: jobId, now: now) { j in
            j.materialiseVersions()
            for i in j.noteVersions!.indices {
                if j.noteVersions![i].state == .current { j.noteVersions![i].state = .superseded }
                if j.noteVersions![i].id == versionId { j.noteVersions![i].state = .current }
            }
            j.notes = draft.notes
            j.summaryModel = draft.model
            j.reasoningEffort = draft.effort
            j.notesAdjustments = draft.adjustments
            j.filesChangedSinceNotes = nil
            if j.submissionPayload != nil {
                j.submissionPayload = nil
                j.submittedAttachments = nil
                if let lesson {
                    let start = lesson.recordings(for: j).first?.recordedAt ?? lesson.startedAt
                    j.submissionId = SubmissionID.make(installId: settings.installId, lessonDate: lesson.lessonDate, startedAt: start,
                                                       timeZone: lesson.timeZone, partLetter: j.partLetter)
                }
            }
        }
        return .replacedLocally
    }

    /// Version conflict → "Replace anyway": resend against the website's current version with a NEW update_id.
    public static func replaceAnyway(store: LibraryStore, jobId: UUID, now: Date = Date()) {
        store.updateJob(id: jobId, now: now) { j in
            guard var r = j.replacement, r.state == .conflict else { return }
            r.baseVersion = r.conflictCurrentVersion
            r.updateId = PendingReplacement.makeUpdateId(now: now)
            r.body = nil
            r.state = .queued
            r.attempts = 0
            r.nextAttemptAt = nil
            r.firstRetryAt = nil
            r.message = nil
            j.replacement = r
        }
    }

    /// Version conflict → "Keep website version": drop the queued replacement.
    public static func keepWebsiteVersion(store: LibraryStore, jobId: UUID, now: Date = Date()) {
        store.updateJob(id: jobId, now: now) { j in
            guard let r = j.replacement else { return }
            j.materialiseVersions()
            if let i = j.noteVersions?.firstIndex(where: { $0.id == r.versionId }) { j.noteVersions?[i].state = .discarded }
            j.replacement = nil
        }
    }

    /// Retry a failed replacement with the same update_id (same body).
    public static func retryReplacement(store: LibraryStore, jobId: UUID, now: Date = Date()) {
        store.updateJob(id: jobId, now: now) { j in
            guard var r = j.replacement, r.state == .failed else { return }
            r.state = .queued
            r.attempts = 0
            r.nextAttemptAt = nil
            r.firstRetryAt = nil
            r.message = nil
            j.replacement = r
        }
    }

    /// The website note was deleted: submit the reviewed version as a NEW note (new submission id),
    /// reusing the local transcript — no re-transcription or re-summarising.
    @discardableResult
    public static func submitAsNewNote(store: LibraryStore, jobId: UUID, held: Bool = false, now: Date = Date()) throws -> Lesson {
        guard let lesson = store.lesson(containingJob: jobId), let job = lesson.jobs.first(where: { $0.id == jobId }) else { throw RegenerationError.jobNotFound }
        guard let transcript = store.transcript(jobId: jobId) else { throw RegenerationError.transcriptMissing }
        let versionId = job.replacement?.versionId
        let version = job.allNoteVersions.first { $0.id == versionId } ?? job.currentVersion
        guard let notes = version?.notes ?? job.notes else { throw RegenerationError.versionNotFound }
        let recs = lesson.recordings(for: job).enumerated().map { i, r -> RecordingRef in var c = r; c.id = UUID(); c.order = i; return c }
        let c = LessonConfirmation(roomId: lesson.roomId, roomName: lesson.roomName, studentId: lesson.studentId, pupilName: lesson.pupilName,
                                   lessonDate: lesson.lessonDate, startedAt: recs.first?.recordedAt ?? lesson.startedAt, dateSource: lesson.dateSource,
                                   mode: recs.count == 1 && lesson.mode == .combined ? .single : (lesson.mode == .separate ? .separate : lesson.mode),
                                   meetingTopic: lesson.meetingTopic, sourceFolder: lesson.sourceFolder, recordings: recs)
        var settings = store.settings
        settings.timeZoneIdentifier = lesson.timeZoneIdentifier
        var newLesson = try LessonFactory.make(c, settings: settings, held: false, now: now, reprocessOf: lesson.id)
        newLesson.jobs[0].stage = held ? .held : .submitting
        newLesson.jobs[0].notes = notes
        newLesson.jobs[0].summaryModel = version?.model ?? job.summaryModel
        newLesson.jobs[0].reasoningEffort = version?.effort ?? job.reasoningEffort
        newLesson.jobs[0].promptSnapshot = job.promptSnapshot
        newLesson.jobs[0].transcriptionModel = job.transcriptionModel
        store.addLesson(newLesson)
        var copy = transcript
        copy.jobId = newLesson.jobs[0].id
        copy.parts = zip(transcript.parts, recs).map { p, r in var q = p; q.recordingId = r.id; return q }
        try store.saveTranscript(copy)
        store.updateJob(id: jobId, now: now) { j in
            j.replacement = nil
            j.remoteStatus = .deleted
        }
        return store.lesson(id: newLesson.id) ?? newLesson
    }
}

/// "Redo with Different Files": a new note for the same recording, made from the saved
/// transcript (no re-transcription), with its own copy of the files so they can be swapped.
/// It is created held, so files can be changed before it runs, and it is submitted as a NEW
/// note (new submission id) — the website cannot change the files of an uploaded note.
public enum RedoFromTranscript {
    public enum RedoError: Error, LocalizedError, Equatable {
        case notFound, transcriptMissing
        public var errorDescription: String? {
            switch self {
            case .notFound: return "This lesson could not be found."
            case .transcriptMissing: return "The saved transcript for this lesson is no longer on this Mac, so it can't be redone without transcribing again."
            }
        }
    }

    @discardableResult
    public static func make(store: LibraryStore, jobId: UUID, now: Date = Date()) throws -> Lesson {
        guard let lesson = store.lesson(containingJob: jobId), let job = lesson.jobs.first(where: { $0.id == jobId }) else { throw RedoError.notFound }
        guard store.transcriptState(jobId: jobId) == .valid, let transcript = store.transcript(jobId: jobId) else { throw RedoError.transcriptMissing }
        let old = lesson.recordings(for: job)
        var idMap: [UUID: UUID] = [:]
        let recs = old.enumerated().map { i, r -> RecordingRef in
            var c = r; c.id = UUID(); c.order = i; idMap[r.id] = c.id; return c
        }
        let c = LessonConfirmation(roomId: lesson.roomId, roomName: lesson.roomName, studentId: lesson.studentId, pupilName: lesson.pupilName,
                                   lessonDate: lesson.lessonDate, startedAt: recs.first?.recordedAt ?? lesson.startedAt,
                                   dateSource: lesson.dateSource, mode: recs.count == 1 ? .single : .combined,
                                   meetingTopic: lesson.meetingTopic, sourceFolder: lesson.sourceFolder, recordings: recs)
        var new = try LessonFactory.make(c, settings: store.settings, held: true, now: now, reprocessOf: lesson.id)
        let newJobId = new.jobs[0].id
        var t = transcript
        t.jobId = newJobId
        for i in t.parts.indices { if let n = idMap[t.parts[i].recordingId] { t.parts[i].recordingId = n } }
        new.jobs[0].hasTranscript = true
        new.jobs[0].transcriptionModel = job.transcriptionModel
        new.jobs[0].completedStagesAt["transcribed"] = now
        new.jobs[0].statusMessage = "Transcript reused. Change the files if needed, then press Start."
        try store.saveTranscript(t)
        store.addLesson(new)
        // Copy the files (uploaded ones and context-only ones become normal files here, up to the limit).
        var copied: [LessonAttachment] = []
        for a in job.attachments ?? job.submittedAttachments ?? [] {
            guard let data = try? store.attachmentData(jobId: jobId, a) else { continue }
            var b = a
            b.id = UUID()
            b.addedAt = now
            b.contextOnly = copied.filter { !$0.contextOnly }.count >= AttachmentRules.maxFiles
            let url = store.attachmentURL(jobId: newJobId, b)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? data.write(to: url, options: [.atomic])) != nil { copied.append(b) }
        }
        if !copied.isEmpty { store.updateJob(id: newJobId, now: now) { $0.attachments = copied } }
        return store.lesson(containingJob: newJobId) ?? new
    }
}
