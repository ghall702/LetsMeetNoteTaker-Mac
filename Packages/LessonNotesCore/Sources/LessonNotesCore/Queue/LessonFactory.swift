import Foundation

/// What George confirmed in the confirmation sheet.
public struct LessonConfirmation: Sendable {
    public var roomId: String
    public var roomName: String
    public var studentId: UUID?
    public var pupilName: String
    public var lessonDate: String
    public var startedAt: Date?
    public var dateSource: DateSource
    public var mode: ProcessingMode
    public var meetingTopic: String
    public var sourceFolder: String
    /// Selected recordings in the order to process (chronological / as reordered).
    public var recordings: [RecordingRef]

    public init(roomId: String, roomName: String, studentId: UUID?, pupilName: String, lessonDate: String, startedAt: Date?,
                dateSource: DateSource, mode: ProcessingMode, meetingTopic: String, sourceFolder: String, recordings: [RecordingRef]) {
        self.roomId = roomId
        self.roomName = roomName
        self.studentId = studentId
        self.pupilName = pupilName
        self.lessonDate = lessonDate
        self.startedAt = startedAt
        self.dateSource = dateSource
        self.mode = mode
        self.meetingTopic = meetingTopic
        self.sourceFolder = sourceFolder
        self.recordings = recordings
    }
}

public enum LessonFactoryError: Error, LocalizedError, Equatable {
    case noRecordings
    case singleNeedsOneRecording
    case invalidRoom
    case invalidDate
    case tooManyRecordings

    public var errorDescription: String? {
        switch self {
        case .noRecordings: return "Select at least one recording."
        case .singleNeedsOneRecording: return "Single mode processes exactly one recording. Choose Combine or Separate for several."
        case .invalidRoom: return "Choose a pupil whose Let's Meet room still exists."
        case .invalidDate: return "Enter a valid lesson date."
        case .tooManyRecordings: return "A single note can list at most 20 recordings."
        }
    }
}

public enum LessonFactory {
    public static func make(_ c: LessonConfirmation, settings: AppSettings, held: Bool, now: Date = Date(),
                            reprocessOf: UUID? = nil) throws -> Lesson {
        guard !c.recordings.isEmpty else { throw LessonFactoryError.noRecordings }
        if c.mode == .single && c.recordings.count != 1 { throw LessonFactoryError.singleNeedsOneRecording }
        if c.mode == .combined && c.recordings.count > 20 { throw LessonFactoryError.tooManyRecordings }
        guard Room.isValidRoomId(c.roomId) else { throw LessonFactoryError.invalidRoom }
        let tz = settings.timeZone
        guard CoreFormat.parseLessonDate(c.lessonDate, timeZone: tz) != nil else { throw LessonFactoryError.invalidDate }

        var recs = c.recordings
        for i in recs.indices { recs[i].order = i }

        let stage: JobStage = held ? .held : .queued
        var jobs: [Job] = []
        switch c.mode {
        case .single, .combined:
            let id = SubmissionID.make(installId: settings.installId, lessonDate: c.lessonDate, startedAt: c.startedAt, timeZone: tz, partLetter: "a")
            jobs.append(Job(submissionId: id, partLetter: "a", recordingIds: recs.map(\.id), stage: stage, createdAt: now))
        case .separate:
            for (i, r) in recs.enumerated() {
                let letter = SubmissionID.partLetter(i)
                let start = r.recordedAt ?? (i == 0 ? c.startedAt : nil)
                let id = SubmissionID.make(installId: settings.installId, lessonDate: c.lessonDate, startedAt: start, timeZone: tz, partLetter: letter)
                jobs.append(Job(submissionId: id, partLetter: letter, recordingIds: [r.id], stage: stage, createdAt: now))
            }
        }

        let endedAt: Date? = {
            guard let last = recs.last, let at = last.recordedAt, last.durationSec > 0 else { return nil }
            return at.addingTimeInterval(TimeInterval(last.durationSec))
        }()

        return Lesson(roomId: c.roomId, studentId: c.studentId, pupilName: c.pupilName, roomName: c.roomName, lessonDate: c.lessonDate,
                      startedAt: c.startedAt, endedAt: endedAt, dateSource: c.dateSource, mode: c.mode, meetingTopic: c.meetingTopic,
                      sourceFolder: c.sourceFolder, timeZoneIdentifier: tz.identifier, recordings: recs, jobs: jobs,
                      createdAt: now, reprocessOf: reprocessOf)
    }

    /// "Reprocess anyway": a brand-new lesson with brand-new submission ids.
    public static func reprocess(_ lesson: Lesson, settings: AppSettings, held: Bool, now: Date = Date()) throws -> Lesson {
        let recs = lesson.recordings.map { r -> RecordingRef in var c = r; c.id = UUID(); return c }
        let c = LessonConfirmation(roomId: lesson.roomId, roomName: lesson.roomName, studentId: lesson.studentId, pupilName: lesson.pupilName,
                                   lessonDate: lesson.lessonDate, startedAt: lesson.startedAt, dateSource: lesson.dateSource, mode: lesson.mode,
                                   meetingTopic: lesson.meetingTopic, sourceFolder: lesson.sourceFolder, recordings: recs)
        return try make(c, settings: settings, held: held, now: now, reprocessOf: lesson.id)
    }
}

/// Builds the `POST /notes` body. The full transcript is always included.
public enum SubmissionBuilder {
    public static func build(lesson: Lesson, job: Job, notes: GeneratedNotes, transcriptText: String,
                             appVersion: String, transcriptionModel: String, summaryModel: String) -> NoteSubmission {
        let tz = lesson.timeZone
        let recs = lesson.recordings(for: job)
        let isFirstJob = lesson.jobs.first?.id == job.id
        let started: Date? = lesson.mode == .separate ? (recs.first?.recordedAt ?? (isFirstJob ? lesson.startedAt : nil)) : lesson.startedAt
        let ended: Date? = {
            if lesson.mode == .separate {
                guard let r = recs.first, let at = r.recordedAt, r.durationSec > 0 else { return nil }
                return at.addingTimeInterval(TimeInterval(r.durationSec))
            }
            return lesson.endedAt
        }()
        let recordings = recs.enumerated().map { i, r in
            SubmissionRecording(filename: CoreFormat.truncate(r.filename, maxCharacters: 260), durationSec: r.durationSec,
                                recordedAt: r.recordedAt.map { CoreFormat.iso8601($0, timeZone: tz) },
                                order: i, sha256: r.sha256)
        }
        let clean = NotesSchema.sanitise(notes)
        var submission = NoteSubmission(
            submissionId: job.submissionId, roomId: lesson.roomId, lessonDate: lesson.lessonDate,
            startedAt: started.map { CoreFormat.iso8601($0, timeZone: tz) },
            endedAt: ended.map { CoreFormat.iso8601($0, timeZone: tz) },
            title: clean.title, summary: NotesSchema.summary(from: clean),
            transcript: transcriptText,
            privateNotes: clean.privateNotes.isEmpty ? nil : clean.privateNotes,
            recordings: recordings, mode: lesson.mode,
            generator: SubmissionGenerator(appVersion: String(appVersion.prefix(100)),
                                           transcriptionModel: String(transcriptionModel.prefix(100)),
                                           summaryModel: String(summaryModel.prefix(100))))
        submission.lessonLength = LessonLength.seconds(for: lesson, job: job)
        return submission
    }
}
