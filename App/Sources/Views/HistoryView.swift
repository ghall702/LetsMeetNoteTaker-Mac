import SwiftUI
import AppKit
import LessonNotesCore

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all = "All", processing = "Processing", pending = "Waiting for approval", published = "Published",
         rejected = "Rejected", deleted = "Deleted", failed = "Failed / needs attention"
    var id: String { rawValue }

    func matches(_ l: Lesson) -> Bool {
        switch self {
        case .all: return true
        case .processing: return l.jobs.contains { $0.stage.isActive || $0.stage == .held }
        case .pending: return l.jobs.contains { $0.stage == .submitted && ($0.remoteStatus ?? .pending) == .pending }
        case .published: return l.jobs.contains { $0.remoteStatus == .published }
        case .rejected: return l.jobs.contains { $0.remoteStatus == .rejected }
        case .deleted: return l.jobs.contains { $0.remoteStatus == .deleted }
        case .failed: return l.jobs.contains { $0.stage == .failed }
        }
    }
}

struct HistoryView: View {
    @EnvironmentObject var model: AppModel
    @State private var query = ""
    @State private var filter: HistoryFilter = .all
    @State private var transcriptMatches: Set<UUID> = []
    @State private var searchTask: Task<Void, Never>?

    var filtered: [Lesson] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.lessons.filter { l in
            guard filter.matches(l) else { return false }
            guard !q.isEmpty else { return true }
            let hay = [l.pupilName, l.roomName, l.lessonDate, CoreFormat.longUKDate(l.lessonDate), l.meetingTopic, l.title]
                + l.recordings.map(\.filename) + l.jobs.compactMap { $0.notes?.overview }
            return hay.contains { $0.lowercased().contains(q) } || transcriptMatches.contains(l.id)
        }
    }

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                Picker("Show", selection: $filter) {
                    ForEach(HistoryFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .padding(8)
                List(selection: $model.selectedLessonId) {
                    ForEach(filtered) { l in
                        HistoryRow(lesson: l).tag(l.id)
                            .contextMenu {
                                Button("Reprocess Anyway") { model.reprocess(l) }
                                Button("Delete Local Data", role: .destructive) { model.deleteLocal(l) }
                            }
                    }
                }
                .overlay {
                    if filtered.isEmpty {
                        Text(model.lessons.isEmpty ? "No lessons yet" : "No matching lessons").foregroundStyle(.secondary)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
            Group {
                if let l = model.lesson(model.selectedLessonId) {
                    LessonDetailView(lesson: l)
                } else {
                    Text("Select a lesson").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .searchable(text: $query, placement: .toolbar, prompt: "Search pupil, date, title or transcript")
        .navigationTitle("History")
        .onChange(of: query) { _, q in searchTranscripts(q) }
    }

    func searchTranscripts(_ q: String) {
        searchTask?.cancel()
        let needle = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard needle.count >= 3 else { transcriptMatches = []; return }
        let store = model.store
        let lessons = model.lessons
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if Task.isCancelled { return }
            let ids = await Task.detached(priority: .userInitiated) { () -> Set<UUID> in
                var out = Set<UUID>()
                for l in lessons where l.jobs.contains(where: { store.searchableTranscript(jobId: $0.id).contains(needle) }) { out.insert(l.id) }
                return out
            }.value
            if !Task.isCancelled { transcriptMatches = ids }
        }
    }
}

struct HistoryRow: View {
    var lesson: Lesson
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(lesson.pupilName).font(.body.weight(.semibold))
                Spacer()
                Text(CoreFormat.longUKDate(lesson.lessonDate)).font(.caption).foregroundStyle(.secondary)
            }
            Text(lesson.title).lineLimit(1).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(lesson.jobs) { StatusChip(job: $0) }
                if lesson.mode != .single { Text(lesson.mode.rawValue).font(.caption2).foregroundStyle(.tertiary) }
            }
        }
        .padding(.vertical, 3)
    }
}

/// Status of a queued website replacement, with the documented conflict choices.
struct ReplacementCard: View {
    @EnvironmentObject var model: AppModel
    let rep: PendingReplacement
    let job: Job

    var conflictDetail: String {
        var s = "Website version " + (rep.conflictCurrentVersion.map { String($0) } ?? "?")
        if let who = rep.conflictChangedBy { s += ", changed by " + who }
        if let raw = rep.conflictUpdatedAt, let d = CoreFormat.parseISO8601(raw) { s += " on " + d.shortDateTime }
        return s + ". Replacing would overwrite those changes."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder var content: some View {
        switch rep.state {
        case .queued: queued
        case .conflict: conflict
        case .noteDeleted: deleted
        case .failed: failed
        }
    }

    var queued: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView().controlSize(.small)
                Text("Replacing the notes on the website…").font(.callout.weight(.medium))
            }
            Text(rep.message ?? "").font(.caption).foregroundStyle(.secondary)
        }
    }

    var conflict: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This note was changed on the website since you generated this version", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.callout.weight(.medium))
            Text(conflictDetail).font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Keep Website Version") { model.keepWebsiteVersion(job) }
                Button("Replace Anyway") { model.replaceAnyway(job) }.buttonStyle(.borderedProminent)
            }
        }
    }

    var deleted: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This note has been deleted on the website", systemImage: "trash").foregroundStyle(.red).font(.callout.weight(.medium))
            HStack {
                Button("Discard Replacement") { model.keepWebsiteVersion(job) }
                Button("Submit as New Note") { model.submitAsNewNote(job) }.buttonStyle(.borderedProminent)
            }
        }
    }

    var failed: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("The replacement could not be sent", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red).font(.callout.weight(.medium))
            Text(rep.message ?? "").font(.caption).textSelection(.enabled)
            HStack {
                Button("Discard Replacement") { model.keepWebsiteVersion(job) }
                Button("Retry") { model.retryReplacement(job) }.buttonStyle(.borderedProminent)
            }
        }
    }
}

struct RegenerateRequest: Identifiable {
    let id = UUID()
    var draftId: UUID?
}

/// Fast read-only text for long transcripts.
struct ReadOnlyText: NSViewRepresentable {
    var text: String
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.isSelectable = true
        tv.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.textContainerInset = NSSize(width: 6, height: 6)
        tv.string = text
        return scroll
    }
    func updateNSView(_ v: NSScrollView, context: Context) {
        if let tv = v.documentView as? NSTextView, tv.string != text { tv.string = text }
    }
}

struct LessonDetailView: View {
    @EnvironmentObject var model: AppModel
    var lesson: Lesson
    init(lesson: Lesson) { self.lesson = lesson }
    @State private var confirmDelete = false
    @State private var confirmReprocess = false
    @State private var preview: (URL, String)?
    @State private var previewShown = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ForEach(lesson.jobs) { job in JobSection(lesson: lesson, job: job) }
                recordings
            }
            .padding(20)
        }
        .alert("Delete local data?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { model.deleteLocal(lesson) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the lesson, notes and transcripts from this Mac. It does not delete anything on the website or your Zoom recordings.")
        }
        .alert("Reprocess this lesson?", isPresented: $confirmReprocess) {
            Button("Reprocess Anyway") { model.reprocess(lesson) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The recordings will be transcribed and summarised again and submitted as a NEW note (new submission ID). The existing website note is not changed.")
        }
        .sheet(isPresented: $previewShown) {
            if let p = preview { PreviewSheet(url: p.0, title: p.1) }
        }
    }

    var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lesson.title).font(.title2.weight(.semibold)).textSelection(.enabled)
            HStack(spacing: 12) {
                Label(lesson.pupilName, systemImage: "person")
                Label(CoreFormat.longUKDate(lesson.lessonDate), systemImage: "calendar")
                if let s = lesson.startedAt { Label(s.formatted(date: .omitted, time: .shortened), systemImage: "clock") }
                Label(lesson.mode.label, systemImage: "square.stack")
            }
            .font(.callout).foregroundStyle(.secondary)
            Text("Room: \(model.rooms.name(for: lesson.roomId) ?? lesson.roomName) · date from \(lesson.dateSource.label)").font(.caption).foregroundStyle(.secondary)
            if let orig = lesson.reprocessOf, model.lesson(orig) != nil {
                Button("Reprocessed from an earlier lesson — show original") { model.selectedLessonId = orig }.buttonStyle(.link)
            }
            ViewThatFits(in: .horizontal) {
                HStack { headerButtons }
                VStack(alignment: .leading, spacing: 6) { headerButtons }
            }
            .padding(.top, 4)
        }
    }

    @ViewBuilder var headerButtons: some View {
        Link(destination: AppInfo.adminToolsURL) { Label("Open Admin Tools", systemImage: "safari") }.fixedSize()
        Button { confirmReprocess = true } label: { Label("Reprocess Anyway", systemImage: "arrow.triangle.2.circlepath") }.fixedSize()
        Button(role: .destructive) { confirmDelete = true } label: { Label("Delete Local Data", systemImage: "trash") }.fixedSize()
    }

    var recordings: some View {
        Card(title: "Recordings", systemImage: "film") {
            ForEach(lesson.recordings) { r in
                HStack {
                    VStack(alignment: .leading) {
                        Text(r.filename).font(.body.weight(.medium))
                        Text([r.recordedAt?.shortDateTime, CoreFormat.duration(r.durationSec), r.fileSize.byteString,
                              r.sha256.map { "SHA-256 " + String($0.prefix(12)) + "…" }].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Spacer()
                    Button("Preview") { openPreview(r) }
                    Button("Show in Finder") { reveal(r) }
                }
            }
        }
    }

    func access(_ r: RecordingRef) -> URL {
        if let bm = r.bookmark, let res = FolderAccess.resolve(bm) { return res.url }
        return URL(fileURLWithPath: r.path)
    }

    func openPreview(_ r: RecordingRef) {
        let url = access(r)
        guard FileManager.default.fileExists(atPath: url.path) else { model.banner = "“\(r.filename)” can no longer be found."; return }
        preview = (url, r.filename)
        previewShown = true
    }

    func reveal(_ r: RecordingRef) {
        NSWorkspace.shared.activateFileViewerSelecting([access(r)])
    }
}

struct JobSection: View {
    @EnvironmentObject var model: AppModel
    var lesson: Lesson
    var job: Job
    init(lesson: Lesson, job: Job) { self.lesson = lesson; self.job = job }
    @State private var showTranscript = false
    @State private var confirmDeleteTranscript = false
    @State private var regenerate: RegenerateRequest?
    @State private var showVersions = false

    var body: some View {
        Card(title: lesson.jobs.count > 1 ? "Note \(job.partLetter.uppercased())" : "Lesson note", systemImage: "doc.text") {
            HStack {
                StatusChip(job: job)
                if job.stage.isActive, let p = model.progress[job.id] {
                    ProgressView(value: p.fraction).frame(width: 140)
                    Text(p.message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                actions
            }
            if let e = job.error {
                VStack(alignment: .leading, spacing: 4) {
                    Label(e.kind == .payloadTooLarge ? "Needs attention" : (e.kind == .openAICredits ? "OpenAI credits needed" : "Error"),
                          systemImage: e.kind == .openAICredits ? "creditcard" : "exclamationmark.triangle.fill").foregroundStyle(e.kind == .openAICredits ? .orange : .red)
                    Text(e.message).textSelection(.enabled)
                    Text("Occurred \(e.occurredAt.shortDateTime)" + (e.httpStatus.map { " · HTTP \($0)" } ?? "") + (e.code.map { " · \($0)" } ?? ""))
                        .font(.caption).foregroundStyle(.secondary)
                    if e.kind == .openAICredits {
                        HStack {
                            Label("Transcript saved — Fix & Retry will not transcribe again", systemImage: "checkmark.shield").font(.caption).foregroundStyle(.green)
                            Spacer()
                            Link("Open OpenAI Billing", destination: JobError.openAIBillingURL)
                        }
                    }
                    if let d = e.detail { Text("OpenAI said: \(d)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                }
                .padding(8)
                .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if job.attempts > 0, let next = job.nextAttemptAt {
                Text("Retry \(job.attempts) scheduled for \(next.shortDateTime)").font(.caption).foregroundStyle(.secondary)
            }
            if let m = job.statusMessage, job.error == nil, job.stage != .submitted { Text(m).font(.caption).foregroundStyle(.secondary) }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                row("Submission ID", job.submissionId)
                if let n = job.noteId { row("Website note ID", n) }
                if job.stage == .submitted {
                    row("Website status", (job.remoteStatus ?? .pending).label + (job.remoteCheckedAt.map { " (checked \($0.shortDateTime))" } ?? ""))
                }
                if let s = job.submittedAt { row("Submitted", s.shortDateTime + (job.replayed == true ? " (already received)" : "")) }
                row("Transcription model", job.transcriptionModel ?? "—")
                row("OpenAI model", (job.summaryModel ?? "—") + (job.reasoningEffort.flatMap { $0 == .modelDefault ? nil : " · effort \($0.label)" } ?? ""))
                if let p = job.promptSnapshot { row("Prompt", p.source == .custom ? "Student's custom prompt" : "Global default prompt") }
            }
            .font(.callout)

            LessonUsageSummary(jobId: job.id)

            if let rep = job.replacement { replacementCard(rep) }

            if let n = job.notes {
                Divider()
                Text("Notes for pupil and parent").font(.subheadline.weight(.semibold))
                NotesView(notes: n, adjustments: job.notesAdjustments ?? [])
            }

            if job.notes != nil || job.hasTranscript {
                HStack {
                    Button { regenerate = RegenerateRequest(draftId: nil) } label: { Label("Regenerate Notes…", systemImage: "wand.and.stars") }
                        .disabled(!job.hasTranscript || job.stage.isActive || job.replacement?.state == .queued)
                        .help(job.hasTranscript ? "Write a new version from the saved transcript" : "The local transcript is no longer available")
                    let drafts = job.draftVersions
                    if let d = drafts.last {
                        Button("Review Draft (\(drafts.count))") { regenerate = RegenerateRequest(draftId: d.id) }
                    }
                }
            }

            let versions = job.allNoteVersions
            if versions.count > 1 {
                DisclosureGroup("Version history (\(versions.count))", isExpanded: $showVersions) {
                    ForEach(versions.reversed()) { v in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(v.notes.title).lineLimit(1)
                                Text(versionSubtitle(v)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            StatusChip(versionLabel(v.state), color: versionColor(v.state))
                            Button(v.state == .draft ? "Review" : "Compare") { regenerate = RegenerateRequest(draftId: v.id) }
                        }
                    }
                }
            }

            if job.hasTranscript, let t = model.store.transcript(jobId: job.id) {
                let text = t.renderedText(timeZone: lesson.timeZone)
                DisclosureGroup(isExpanded: $showTranscript) {
                    ReadOnlyText(text: text).frame(height: 320)
                    HStack {
                        Button("Copy Transcript") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        Button("Delete Local Transcript", role: .destructive) { confirmDeleteTranscript = true }
                            .disabled(job.stage != .submitted && job.stage != .cancelled)
                            .help("Transcripts can only be deleted after the note has been uploaded.")
                    }
                } label: {
                    Text("Transcript · \(t.wordCount) words · \(APILimits.utf8Bytes(text).byteStringDecimal)")
                }
            } else if let purged = job.transcriptPurgedAt {
                Text("Local transcript deleted \(purged.shortDateTime) (retention setting or manual deletion).").font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if model.demoReviewDraft, let d = job.draftVersions.last {
                model.demoReviewDraft = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { regenerate = RegenerateRequest(draftId: d.id) }
            }
        }
        .sheet(item: $regenerate) { req in
            RegenerateSheet(lessonId: lesson.id, jobId: job.id, initialDraftId: req.draftId).environmentObject(model)
        }
        .alert("Delete the local transcript?", isPresented: $confirmDeleteTranscript) {
            Button("Delete", role: .destructive) { model.deleteTranscript(job) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The copy on the website (if uploaded) is not affected.")
        }
    }

    func versionSubtitle(_ v: NoteVersion) -> String {
        var s = v.createdAt.shortDateTime + " · " + (v.kind == .original ? "original" : "regenerated") + " · " + v.model
        if let w = v.websiteVersion { s += " · website v" + String(w) }
        return s
    }

    func versionLabel(_ s: NoteVersion.State) -> String {
        switch s {
        case .current: return "Current"
        case .draft: return "Draft"
        case .uploading: return "Replacing…"
        case .superseded: return "Previous"
        case .discarded: return "Discarded"
        }
    }

    func versionColor(_ s: NoteVersion.State) -> Color {
        switch s {
        case .current: return .green
        case .draft: return .blue
        case .uploading: return .orange
        case .superseded, .discarded: return .gray
        }
    }

    func replacementCard(_ rep: PendingReplacement) -> some View {
        ReplacementCard(rep: rep, job: job)
    }

    @ViewBuilder var actions: some View {
        switch job.stage {
        case .held:
            Button("Start") { model.start(job) }.buttonStyle(.borderedProminent)
            Button("Cancel") { model.cancel(job) }
        case .queued, .extracting, .transcribing, .summarising, .submitting:
            if job.nextAttemptAt != nil { Button("Retry Now") { model.retry(job) } }
            Button("Cancel") { model.cancel(job) }
        case .failed:
            if job.error?.kind != .payloadTooLarge {
                Button("Fix & Retry") { model.retry(job) }.buttonStyle(.borderedProminent)
            }
        case .cancelled:
            Button("Resume") { model.retry(job) }
        case .submitted:
            Button("Check Status") { Task { await model.syncStatuses(force: true) } }
        }
    }

    func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

extension Int {
    var byteStringDecimal: String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_GB")
        return (f.string(from: NSNumber(value: self)) ?? String(self)) + " bytes"
    }
}
