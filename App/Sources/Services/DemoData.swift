import Foundation
import AppKit
import LessonNotesCore

/// Sample data used only when the app is launched with the `LESSONNOTES_DEMO` environment
/// variable (CI screenshots). It lives in a throwaway temporary folder and never touches
/// real data, keys or the website.
enum DemoData {
    static var mode: String? { ProcessInfo.processInfo.environment["LESSONNOTES_DEMO"] }

    private static var sized = false

    /// Sizes the main window once and writes its on-screen frame (top-left origin, points)
    /// to the app's temporary folder for the screenshot workflow to crop to.
    @MainActor static func layoutAndPublishWindowFrame() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil && !($0 is NSPanel) && $0.frame.width > 500 && $0.styleMask.contains(.titled) }),
              let screen = w.screen ?? NSScreen.main else { return }
        if !sized {
            sized = true
            let size = NSSize(width: min(1280, screen.visibleFrame.width - 40), height: min(820, screen.visibleFrame.height - 40))
            let origin = NSPoint(x: screen.visibleFrame.midX - size.width / 2, y: screen.visibleFrame.midY - size.height / 2)
            w.setFrame(NSRect(origin: origin, size: size), display: true)
        }
        let f = w.frame
        let info: [String: Double] = ["x": f.minX - screen.frame.minX, "y": screen.frame.maxY - f.maxY, "w": f.width, "h": f.height,
                                      "sw": screen.frame.width, "sh": screen.frame.height]
        if let data = try? JSONSerialization.data(withJSONObject: info) {
            try? data.write(to: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lessonnotes-window.json"))
        }
    }

    static func seed(_ store: LibraryStore) {
        let ellieRoom = "3ae368a1b979e5f6e0aba39d3103b7e1", danielRoom = "fb01c9b1eef909f27d1d49a6b1a1c9e3"
        store.setRooms([Room(roomId: ellieRoom, name: "LetsMeet - EE"), Room(roomId: danielRoom, name: "LetsMeet - DT"),
                        Room(roomId: "c9dfb0a8d59e2f7812880c6f9564009c", name: "LetsMeet SD")])
        let ellie = StudentMapping(roomId: ellieRoom, roomName: "LetsMeet - EE", displayName: "Ellie", code: "EE", context: "Year 5")
        var daniel = StudentMapping(roomId: danielRoom, roomName: "LetsMeet - DT", displayName: "Daniel", code: "DT",
                                    context: "GCSE English Language", promptMode: .custom,
                                    customPrompt: "You write revision-focused notes for a GCSE English Language pupil. Refer to assessment objectives AO1–AO6 where relevant.")
        daniel.rules = [MatchRule(kind: .meetingNameContains, value: "Daniel")]
        store.updateModelList {
            $0.models = [OpenAIModelInfo(id: "gpt-5", created: 1_754_000_000), OpenAIModelInfo(id: "gpt-5-mini", created: 1_754_000_000),
                         OpenAIModelInfo(id: "gpt-4.1", created: 1_744_000_000), OpenAIModelInfo(id: "o4-mini", created: 1_744_000_000),
                         OpenAIModelInfo(id: "text-embedding-3-large", created: 1_705_000_000)]
            $0.fetchedAt = Date()
            $0.verifications["gpt-5-mini"] = ModelVerification(modelId: "gpt-5-mini", testedAt: Date(), structuredOutputWorks: true,
                                                                  reasoningEffortTested: .modelDefault, reasoningEffortAccepted: nil,
                                                                  message: "Success — the model returned valid lesson-notes JSON (title: “The water cycle”).", elapsedSeconds: 4.2)
        }
        store.upsertMapping(ellie)
        store.upsertMapping(daniel)
        store.updateSettings {
            $0.onboardingCompleted = mode != "onboarding"
            $0.openAIModel = "gpt-5-mini"
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
            l.jobs[0].submittedAt = now.addingTimeInterval(-80_000); l.jobs[0].remoteCheckedAt = now; l.jobs[0].summaryModel = "gpt-5-mini"
            l.jobs[0].transcriptionModel = "whisperkit/openai_whisper-large-v3-v20240930_turbo"
            l.jobs[0].promptSnapshot = PromptResolver.resolve(globalPrompt: s.globalPrompt, mapping: ellie)
            var draftNotes = notes
            draftNotes.title = "Adding and simplifying fractions"
            draftNotes.keyQuotes = []
            draftNotes.learningContent += "\n\n## Simplifying\nDivide the numerator and denominator by their highest common factor."
            l.jobs[0].remoteVersion = 2
            l.jobs[0].noteVersions = [
                NoteVersion(createdAt: now.addingTimeInterval(-80_000), kind: .original, state: .current, notes: notes, model: "gpt-5-mini", websiteVersion: 2),
                NoteVersion(createdAt: now, kind: .regenerated, state: .draft, notes: draftNotes, model: "gpt-5-mini", effort: .high, promptSource: .global,
                            additionalInstructions: "Add a section on simplifying.", baseVersion: 2)]
            store.addLesson(l)
            // Sample lesson files: two uploaded with the note, one added later as context only.
            var files: [LessonAttachment] = []
            for (name, role, include, ctxOnly) in [("macOS Preview Fractions slides.pdf", AttachmentRole.slides, true, false),
                                                   ("Ellie's worksheet.jpg", AttachmentRole.studentWork, true, false),
                                                   ("Model answers.docx", AttachmentRole.exemplar, true, true), ("New worksheet.png", AttachmentRole.studentWork, true, false)] {
                let a = LessonAttachment(filename: name, byteCount: 180_000 + name.count * 1000, sha256: "demo", role: role,
                                         includeInContext: include, shareWithPupil: !ctxOnly, addedAt: now)
                let u = store.attachmentURL(jobId: l.jobs[0].id, a)
                try? FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data("demo".utf8).write(to: u)
                files.append(a)
            }
            store.updateJob(id: l.jobs[0].id) {
                $0.attachments = files
                let onWebsite = files.filter { $0.shareWithPupil && $0.filename != "New worksheet.png" }
                $0.submittedAttachments = onWebsite
                $0.remoteFiles = onWebsite.map { RemoteFile(filename: $0.filename, size: $0.byteCount) }
                $0.filesChangedSinceNotes = true
            }
            try? store.saveTranscript(StoredTranscript(jobId: l.jobs[0].id, savedAt: now, model: "whisperkit/openai_whisper-large-v3-v20240930_turbo", language: "en",
                parts: [TranscriptPart(recordingId: l.recordings[0].id, filename: "zoom_0.mp4", recordedAt: l.recordings[0].recordedAt, durationSec: 1700, segments: [
                    TranscriptSegment(start: 0, end: 6, text: "Right, let's look at adding fractions today."),
                    TranscriptSegment(start: 6, end: 14, text: "What do we need to do when the denominators are different?"),
                    TranscriptSegment(start: 14, end: 20, text: "Find a common multiple?")])]))
        }
        if var l = lesson("Daniel", danielRoom, daniel, daysAgo: 0.2, mode: .combined, n: 2) {
            var n2 = notes; n2.title = "Language Paper 1, Question 4: evaluating a text"
            l.jobs[0].stage = .submitted; l.jobs[0].remoteStatus = .pending; l.jobs[0].notes = n2; l.jobs[0].submittedAt = now; l.jobs[0].summaryModel = "gpt-5-mini"
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
        // Sample usage records (screenshots only).
        let ledger = UsageLedger(directory: store.directory)
        for (i, l) in store.allLessons.enumerated() {
            let input = [15_200, 48_900, 21_300, 9_800][i % 4], output = [2_400, 5_100, 3_200, 1_900][i % 4]
            ledger.append(UsageRecord(responseId: "resp_demo_\(i)", date: now.addingTimeInterval(-Double(i) * 3_000), model: "gpt-6.1-sol",
                                      lessonId: l.id, jobId: l.jobs.first?.id, purpose: .lessonNotes, outcome: .succeeded,
                                      usage: TokenUsage(inputTokens: input, cachedInputTokens: i == 1 ? 12_000 : 0, outputTokens: output, totalTokens: input + output),
                                      estimatedCostUSD: nil, complimentaryEligible: true, source: "demo"))
        }
        ledger.append(UsageRecord(responseId: "resp_demo_y", date: now.addingTimeInterval(-86_400), model: "gpt-6.1-sol", lessonId: nil, jobId: nil,
                                  purpose: .lessonNotes, outcome: .succeeded,
                                  usage: TokenUsage(inputTokens: 210_000, cachedInputTokens: 0, outputTokens: 62_000, totalTokens: 272_000),
                                  estimatedCostUSD: nil, complimentaryEligible: true, source: "demo"))
        // Sample video uploads (screenshots only): one uploaded, one uploading, one waiting for its recording,
        // plus older lessons for the historical backfill.
        store.updateSettings { $0.video.automaticSince = now.addingTimeInterval(-3_600) }
        let submitted = store.allLessons.flatMap { l in l.jobs.filter { $0.stage == .submitted }.map { (l, $0) } }
        for (i, pair) in submitted.enumerated() {
            var v = VideoQueue.makeState(lesson: pair.0, job: pair.1, origin: i == 0 ? .automatic : .backfill, now: now)
            v.noteId = pair.1.noteId ?? "demo-note-\(i)"
            switch i {
            case 0: v.stage = .ready; v.recordingId = "demo-rec-0"; v.fileSize = 734_003_200; v.durationSec = 1700; v.completedAt = now
            case 1: v.stage = .uploading; v.recordingId = "demo-rec-1"; v.fileSize = 2_000_000_000
            default:
                v.stage = .failed; v.errorKind = .recordingsMissing
                v.lastError = "Original recording not found: zoom_0.mp4. Reconnect the drive or folder, then Retry."
            }
            store.updateJob(id: pair.1.id) { $0.video = v }
        }
        for (d, mode, n) in [(20.0, ProcessingMode.combined, 3), (27.0, .single, 1), (34.0, .combined, 2), (41.0, .single, 1)] {
            if var l = lesson("Daniel", danielRoom, daniel, daysAgo: d, mode: mode, n: n) {
                l.jobs[0].stage = .submitted; l.jobs[0].noteId = "demo-\(Int(d))"; l.jobs[0].remoteStatus = .published
                l.jobs[0].submittedAt = now.addingTimeInterval(-d * 86_400); l.jobs[0].notes = notes
                store.addLesson(l)
            }
        }
        let folder = "/Users/Shared/Zoom/2026-11-14 16.00.12 LetsMeet - EE"
        store.upsertDetection(PendingDetection(folderPath: folder, recordings: [
            ScannedRecording(path: folder + "/zoom_0.mp4", fileSize: 512_000_000, durationSeconds: 1810),
            ScannedRecording(path: folder + "/zoom_1.mp4", fileSize: 301_000_000, durationSeconds: 1190)]))
    }

    /// Screenshot sample for the Videos dashboard (LESSONNOTES_DEMO=videos only).
    @MainActor static func seedVideoDashboard(_ model: AppModel) {
        let now = Date()
        let tz = TimeZone(identifier: "Europe/London")!
        var days: [TrafficDay] = []
        var server: [ServerTrafficDay] = []
        for back in stride(from: 13, through: 0, by: -1) {
            let d = Bandwidth.day(now.addingTimeInterval(-Double(back) * 86_400), tz)
            let up = Int64([0, 3, 7, 12, 5, 0, 9, 14, 6, 11, 4, 8, 13, 2][13 - back]) * 1_000_000_000 / 2
            let play = Int64([1, 2, 4, 3, 6, 2, 5, 7, 4, 8, 3, 6, 9, 3][13 - back]) * 1_000_000_000 / 3
            days.append(TrafficDay(date: d, uploadBytes: up, playbackBytes: play))
            server.append(ServerTrafficDay(date: d, rxBytes: up + 90_000_000, txBytes: play + 40_000_000))
        }
        let gateway = GatewayStats(timezone: "Europe/London",
                                   volume: VolumeStats(path: "/srv/sftpgo/data/recordings", realPath: "/mnt/storage/sftpgo/data/recordings",
                                                       totalBytes: 3_170_000_000_000, usedBytes: 476_000_000_000, availableBytes: 2_535_000_000_000),
                                   recordings: GatewayRecordingIndex(count: 118, bytes: 451_000_000_000),
                                   traffic: TrafficHistory(since: CoreFormat.iso8601(now.addingTimeInterval(-20 * 86_400)), days: days),
                                   serverTraffic: ServerTrafficHistory(available: true, since: CoreFormat.iso8601(now.addingTimeInterval(-20 * 86_400)), days: server))
        let snap = MediaStatsSnapshot(stats: MediaStatsResponse(gateway: gateway,
                                                                recordings: WebsiteRecordingCounts(ready: 117, uploading: 1, failed: 0, deletePending: 0, readyBytes: 449_800_000_000)),
                                      fetchedAt: now, lastAttemptAt: now)
        model.mediaStatsCache.store(snap)
        model.statsSnapshot = snap
        for item in model.allJobs where item.job.video?.stage == .uploading {
            var p = VideoProgress(message: "Uploading video", fraction: 0.62, sentBytes: 1_240_000_000, totalBytes: 2_000_000_000, updatedAt: now)
            p.rate.update(sent: 1_231_500_000, at: now.addingTimeInterval(-1))
            p.rate.update(sent: 1_240_000_000, at: now)
            model.videoProgress[item.job.id] = p
        }
    }
}
