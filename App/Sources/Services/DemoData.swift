import Foundation
import LessonNotesCore

/// Sample data used only when the app is launched with the `LESSONNOTES_DEMO` environment
/// variable (CI screenshots). It lives in a throwaway temporary folder and never touches
/// real data, keys or the website.
enum DemoData {
    static var mode: String? { ProcessInfo.processInfo.environment["LESSONNOTES_DEMO"] }

    static func seed(_ store: LibraryStore) {
        let ellieRoom = "3ae368a1b979e5f6e0aba39d3103b7e1", danielRoom = "fb01c9b1eef909f27d1d49a6b1a1c9e3"
        store.setRooms([Room(roomId: ellieRoom, name: "LetsMeet - EE"), Room(roomId: danielRoom, name: "LetsMeet - DT"),
                        Room(roomId: "c9dfb0a8d59e2f7812880c6f9564009c", name: "LetsMeet SD")])
        let ellie = StudentMapping(roomId: ellieRoom, roomName: "LetsMeet - EE", displayName: "Ellie", code: "EE", context: "Year 5")
        var daniel = StudentMapping(roomId: danielRoom, roomName: "LetsMeet - DT", displayName: "Daniel", code: "DT",
                                    context: "GCSE English Language", promptMode: .custom,
                                    customPrompt: "You write revision-focused notes for a GCSE English Language pupil. Refer to assessment objectives AO1–AO6 where relevant.")
        daniel.rules = [MatchRule(kind: .meetingNameContains, value: "Daniel")]
        store.upsertMapping(ellie)
        store.upsertMapping(daniel)
        store.updateSettings {
            $0.onboardingCompleted = mode != "onboarding"
            $0.openAIModel = "example-model"
            $0.transcriptionModel = ""
        }
        var s = store.settings
        s.timeZoneIdentifier = "Europe/London"
        let now = Date()
        func recs(_ n: Int, _ start: Date) -> [RecordingRef] {
            (0..<n).map { RecordingRef(filename: "zoom_\($0).mp4", path: "/Users/Shared/Zoom/demo/zoom_\($0).mp4", durationSec: 1700 + $0 * 300,
                                       recordedAt: start.addingTimeInterval(Double($0) * 1900), sha256: String(repeating: "\($0)", count: 64),
                                       fileSize: 420_000_000, order: $0) }
        }
        func lesson(_ name: String, _ room: String, _ mapping: StudentMapping, daysAgo: Double, mode: ProcessingMode, n: Int) -> Lesson? {
            let start = now.addingTimeInterval(-daysAgo * 86_400)
            let c = LessonConfirmation(roomId: room, roomName: mapping.roomName, studentId: mapping.id, pupilName: name,
                                       lessonDate: CoreFormat.lessonDateString(start, timeZone: s.timeZone), startedAt: start,
                                       dateSource: .zoomFolder, mode: mode, meetingTopic: mapping.roomName, sourceFolder: "/Users/Shared/Zoom/demo",
                                       recordings: recs(n, start))
            return try? LessonFactory.make(c, settings: s, held: false, now: start)
        }
        let notes = GeneratedNotes(title: "Adding fractions with different denominators",
                                   overview: "Today we practised adding fractions with **different denominators**. I modelled the method first, then you completed four questions with less support each time.",
                                   keyPoints: ["Find the lowest common multiple of the denominators", "Change both fractions before adding", "Simplify the answer at the end"],
                                   nextSteps: ["Practise subtracting fractions the same way"],
                                   homework: "White Rose worksheet page 4, questions 1–6.",
                                   vocabulary: ["denominator", "numerator", "common multiple"],
                                   praise: "Brilliant persistence on the tricky last question!",
                                   keyQuotes: [],
                                   learningContent: "## Finding a common denominator\nTo add fractions, the denominators must match. Find the **lowest common multiple** (LCM) of the denominators.\n\n1. List multiples of each denominator.\n2. Choose the smallest shared multiple.\n3. Convert both fractions.\n\n| Fraction | Converted |\n|---|---|\n| 1/3 | 4/12 |\n| 1/4 | 3/12 |",
                                   workedExamples: ["**1/3 + 1/4**\n1. LCM of 3 and 4 is 12\n2. 1/3 = 4/12 and 1/4 = 3/12\n3. 4/12 + 3/12 = **7/12**"],
                                   privateNotes: "Still muddles numerator and denominator under pressure.")
        if var l = lesson("Ellie", ellieRoom, ellie, daysAgo: 1, mode: .single, n: 1) {
            l.jobs[0].stage = .submitted; l.jobs[0].remoteStatus = .published; l.jobs[0].notes = notes; l.jobs[0].noteId = "7487e543-demo"
            l.jobs[0].submittedAt = now.addingTimeInterval(-80_000); l.jobs[0].remoteCheckedAt = now; l.jobs[0].summaryModel = "example-model"
            l.jobs[0].transcriptionModel = "whisperkit/openai_whisper-large-v3-v20240930_turbo"
            l.jobs[0].promptSnapshot = PromptResolver.resolve(globalPrompt: s.globalPrompt, mapping: ellie)
            var draftNotes = notes
            draftNotes.title = "Adding and simplifying fractions"
            draftNotes.keyQuotes = []
            draftNotes.learningContent += "\n\n## Simplifying\nDivide the numerator and denominator by their highest common factor."
            l.jobs[0].remoteVersion = 2
            l.jobs[0].noteVersions = [
                NoteVersion(createdAt: now.addingTimeInterval(-80_000), kind: .original, state: .current, notes: notes, model: "example-model", websiteVersion: 2),
                NoteVersion(createdAt: now, kind: .regenerated, state: .draft, notes: draftNotes, model: "example-model", effort: .high, promptSource: .global,
                            additionalInstructions: "Add a section on simplifying.", baseVersion: 2)]
            store.addLesson(l)
            try? store.saveTranscript(StoredTranscript(jobId: l.jobs[0].id, savedAt: now, model: "whisperkit/openai_whisper-large-v3-v20240930_turbo", language: "en",
                parts: [TranscriptPart(recordingId: l.recordings[0].id, filename: "zoom_0.mp4", recordedAt: l.recordings[0].recordedAt, durationSec: 1700, segments: [
                    TranscriptSegment(start: 0, end: 6, text: "Right, let's look at adding fractions today."),
                    TranscriptSegment(start: 6, end: 14, text: "What do we need to do when the denominators are different?"),
                    TranscriptSegment(start: 14, end: 20, text: "Find a common multiple?")])]))
        }
        if var l = lesson("Daniel", danielRoom, daniel, daysAgo: 0.2, mode: .combined, n: 2) {
            var n2 = notes; n2.title = "Language Paper 1, Question 4: evaluating a text"
            l.jobs[0].stage = .submitted; l.jobs[0].remoteStatus = .pending; l.jobs[0].notes = n2; l.jobs[0].submittedAt = now; l.jobs[0].summaryModel = "example-model"
            store.addLesson(l)
        }
        if var l = lesson("Ellie", ellieRoom, ellie, daysAgo: 3, mode: .single, n: 1) {
            l.jobs[0].stage = .failed; l.jobs[0].resumeStage = .submitting; l.jobs[0].notes = notes
            l.jobs[0].error = JobError(message: APILimits.SizeProblem.transcriptTooLarge(bytes: 5_214_880).message, kind: .payloadTooLarge)
            store.addLesson(l)
        }
        if var l = lesson("Daniel", danielRoom, daniel, daysAgo: 0, mode: .separate, n: 2) {
            l.jobs[0].stage = .transcribing; l.jobs[1].stage = .queued
            store.addLesson(l)
        }
        let folder = "/Users/Shared/Zoom/2026-11-14 16.00.12 LetsMeet - EE"
        store.upsertDetection(PendingDetection(folderPath: folder, recordings: [
            ScannedRecording(path: folder + "/zoom_0.mp4", fileSize: 512_000_000, durationSeconds: 1810),
            ScannedRecording(path: folder + "/zoom_1.mp4", fileSize: 301_000_000, durationSeconds: 1190)]))
    }
}
