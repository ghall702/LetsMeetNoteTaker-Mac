import SwiftUI
import AppKit
import LessonNotesCore

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

/// Video uploads: live progress, historical backfill and per-video management.
struct VideosView: View {
    @EnvironmentObject var model: AppModel
    @State private var filter: Filter = .all
    @State private var confirmBackfill = false
    @State private var showBackfillList = false

    enum Filter: String, CaseIterable, Identifiable { case all = "All", active = "Active", failed = "Needs attention", done = "Uploaded"; var id: String { rawValue } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !model.activeVideoJobs.isEmpty { activeCard }
                backfillCard
                listCard
            }
            .padding(20)
        }
        .navigationTitle("Videos")
        .onAppear { if model.backfillReport == nil { model.scanBackfill() } }
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Lesson videos").font(.title2.weight(.semibold))
                Text(statusLine).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.setVideoUploadsPaused(!model.settings.video.paused) } label: {
                Label(model.settings.video.paused ? "Resume Uploads" : "Pause Uploads",
                      systemImage: model.settings.video.paused ? "play.circle" : "pause.circle")
            }
            Button { model.settingsTab = 7; model.sidebar = .settings } label: { Label("Video Settings", systemImage: "gearshape") }
        }
    }

    var statusLine: String {
        var parts: [String] = []
        parts.append(model.settings.video.paused ? "Uploads paused" : (model.settings.video.autoUpload ? "New lessons upload automatically" : "Automatic uploads off"))
        let active = model.activeVideoJobs.count
        if active > 0 { parts.append("\(active) in the queue") }
        let failed = model.failedVideoJobs.count
        if failed > 0 { parts.append("\(failed) need attention") }
        return parts.joined(separator: " · ")
    }

    var activeCard: some View {
        Card(title: "Uploading", systemImage: "icloud.and.arrow.up") {
            ForEach(model.activeVideoJobs) { item in
                VideoProgressRow(item: item)
                Divider()
            }
        }
    }

    // MARK: Backfill

    var backfillCard: some View {
        Card(title: "Historical backfill", systemImage: "clock.arrow.2.circlepath") {
            Text("Lessons whose notes were uploaded before video uploads were turned on. Their notes are never resubmitted or changed — only the video is added to the existing note.")
                .font(.callout).foregroundStyle(.secondary)
            if let r = model.backfillReport {
                Grid(alignment: .leading, horizontalSpacing: 28, verticalSpacing: 8) {
                    GridRow {
                        stat("\(r.total)", "Historical lessons")
                        stat("\(r.count(.eligible))", "Eligible to upload", .accentColor)
                        stat("\(r.count(.alreadyUploaded))", "Already have a video")
                        stat("\(r.needingMerge)", "Need joining")
                    }
                    GridRow {
                        stat("\(r.count(.missingRecordings))", "Recordings not found", r.count(.missingRecordings) > 0 ? .orange : .secondary)
                        stat("\(r.unresolvedNotes)", "Note id to look up")
                        stat("\(r.count(.noteDeleted))", "Note deleted on LetsMeet")
                        stat(r.estimatedBytes.fileSize, "To upload")
                    }
                    GridRow {
                        stat("\(r.count(.inProgress))", "In progress")
                        stat("\(r.count(.succeeded))", "Uploaded", .green)
                        stat("\(r.count(.failed))", "Failed", r.count(.failed) > 0 ? .red : .secondary)
                        Color.clear.frame(width: 1, height: 1)
                    }
                }
                if model.probeTotal > 0 && model.probeDone < model.probeTotal {
                    ProgressView(value: Double(model.probeDone), total: Double(max(1, model.probeTotal))) {
                        Text("Checking LetsMeet… \(model.probeDone) of \(model.probeTotal)").font(.caption)
                    }
                }
                HStack {
                    Button("Scan Again") { model.scanBackfill() }.disabled(model.isScanningBackfill)
                    Button("Check LetsMeet for Existing Videos") { model.checkBackfillOnWebsite() }
                        .help("Read-only: looks up each note on LetsMeet and whether it already has a video (about one lesson per second)")
                        .disabled(model.probeTotal > 0 && model.probeDone < model.probeTotal)
                    Spacer()
                    if r.count(.failed) > 0 { Button("Retry Failed") { model.retryAllFailedVideos() } }
                    Button("Start Backfill (\(r.count(.eligible)))") { confirmBackfill = true }
                        .buttonStyle(.borderedProminent)
                        .disabled(r.count(.eligible) == 0)
                }
                DisclosureGroup("Lessons (\(r.total))", isExpanded: $showBackfillList) {
                    ForEach(r.items) { item in
                        HStack {
                            Text(item.pupilName).frame(width: 120, alignment: .leading)
                            Text(CoreFormat.longUKDate(item.lessonDate)).foregroundStyle(.secondary).frame(width: 150, alignment: .leading)
                            Text(item.recordingCount > 1 ? "\(item.recordingCount) recordings → joined" : "1 recording").font(.caption).foregroundStyle(.secondary)
                            Spacer()
                            if let d = item.detail { Text(d).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                            StatusChip(label(item.status), color: color(item.status))
                        }
                        .padding(.vertical, 1)
                    }
                }
            } else {
                HStack { ProgressView().controlSize(.small); Text("Scanning your lessons…").foregroundStyle(.secondary) }
            }
        }
        .alert("Start the backfill?", isPresented: $confirmBackfill) {
            Button("Start Backfill") { model.startBackfill() }
            Button("Cancel", role: .cancel) {}
        } message: {
            let r = model.backfillReport
            Text("\(r?.count(.eligible) ?? 0) lesson videos (about \((r?.estimatedBytes ?? 0).fileSize)) will be uploaded one after another to the existing notes. Make sure the media server has room for them. You can pause at any time; progress is kept if the app quits.")
        }
    }

    func stat(_ value: String, _ label: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    func label(_ s: VideoBackfillReport.Item.Status) -> String {
        switch s {
        case .eligible: return "Ready to upload"
        case .alreadyUploaded: return "Has a video"
        case .missingRecordings: return "Recording not found"
        case .noteDeleted: return "Note deleted"
        case .inProgress: return "In progress"
        case .succeeded: return "Uploaded"
        case .failed: return "Failed"
        }
    }

    func color(_ s: VideoBackfillReport.Item.Status) -> Color {
        switch s {
        case .eligible, .inProgress: return .accentColor
        case .alreadyUploaded, .succeeded: return .green
        case .missingRecordings: return .orange
        case .noteDeleted: return .gray
        case .failed: return .red
        }
    }

    // MARK: List

    var listCard: some View {
        Card(title: "All lesson videos", systemImage: "play.rectangle") {
            Picker("Show", selection: $filter) { ForEach(Filter.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 420)
            let items = filtered
            if items.isEmpty { Text("No videos here yet.").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VideoRow(item: item)
                Divider()
            }
        }
    }

    var filtered: [LessonJob] {
        switch filter {
        case .all: return model.videoJobs
        case .active: return model.activeVideoJobs
        case .failed: return model.failedVideoJobs
        case .done: return model.videoJobs.filter { $0.job.video?.stage == .ready }
        }
    }
}

struct VideoProgressRow: View {
    @EnvironmentObject var model: AppModel
    var item: LessonJob

    var body: some View {
        let v = item.job.video
        let p = model.videoProgress[item.job.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(item.lesson.pupilName).font(.callout.weight(.semibold))
                Text(CoreFormat.longUKDate(item.lesson.lessonDate)).font(.caption).foregroundStyle(.secondary)
                if (v?.sourceRecordingIds.count ?? 0) > 1 { Text("\(v!.sourceRecordingIds.count) recordings joined").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                VideoStatusChip(video: v)
                Button { model.stopVideo(item.job) } label: { Image(systemName: "xmark.circle") }.buttonStyle(.borderless).help("Stop")
            }
            ProgressView(value: p?.fraction ?? 0)
            HStack {
                Text(p?.message ?? waitingText(v)).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let p, p.totalBytes > 0 {
                    Text("\(Int((p.fraction * 100).rounded()))% · \(p.sentBytes.fileSize) of \(p.totalBytes.fileSize)"
                         + (p.bytesPerSecond.map { " · \(Int64($0).fileSize)/s" } ?? ""))
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } else if let size = v?.fileSize {
                    Text(size.fileSize).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    func waitingText(_ v: VideoUploadState?) -> String {
        guard let v else { return "" }
        if let next = v.nextAttemptAt, next > Date() { return (v.lastError.map { $0 + " — " } ?? "") + "next try \(next.formatted(date: .omitted, time: .shortened))" }
        if model.settings.video.paused { return "Paused" }
        return "Waiting"
    }
}

struct VideoStatusChip: View {
    var video: VideoUploadState?
    var body: some View {
        if let v = video {
            switch v.stage {
            case .queued: StatusChip("Queued", color: .secondary, icon: "tray")
            case .merging: StatusChip("Joining", color: .accentColor, icon: "film.stack")
            case .registering, .uploading: StatusChip("Uploading", color: .accentColor, icon: "icloud.and.arrow.up")
            case .completing: StatusChip("Confirming", color: .accentColor, icon: "checkmark.icloud")
            case .ready:
                if v.replacement != nil { StatusChip(v.replacement?.stage == .failed ? "Replace failed" : "Replacing", color: v.replacement?.stage == .failed ? .red : .accentColor, icon: "arrow.triangle.2.circlepath") }
                else { StatusChip(v.adoptedExisting ? "Already on LetsMeet" : "Uploaded", color: .green, icon: "checkmark.seal.fill") }
            case .failed: StatusChip("Needs attention", color: .red, icon: "exclamationmark.triangle.fill")
            case .skipped: StatusChip("Skipped", color: .gray, icon: "minus.circle")
            case .deleted: StatusChip(v.deletePending ? "Delete pending" : "Deleted", color: .gray, icon: "trash")
            }
        } else {
            StatusChip("No video", color: .secondary, icon: "video.slash")
        }
    }
}

/// One lesson's video with its actions (used in Videos and History).
struct VideoRow: View {
    @EnvironmentObject var model: AppModel
    var item: LessonJob
    var showsLesson = true
    @State private var confirmDelete = false
    init(item: LessonJob, showsLesson: Bool = true) { self.item = item; self.showsLesson = showsLesson }

    var body: some View {
        let j = item.job
        let v = j.video
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if showsLesson {
                    Button { model.openLesson(item.lesson.id) } label: {
                        Text("\(item.lesson.pupilName) — \(CoreFormat.longUKDate(item.lesson.lessonDate))").font(.body.weight(.medium))
                    }.buttonStyle(.plain)
                }
                if let v { Text(v.originalFilename).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
                Spacer()
                VideoStatusChip(video: v)
                actions
            }
            if let v {
                Text(details(v)).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if let e = v.lastError, v.stage == .failed || v.stage == .skipped || v.nextAttemptAt != nil {
                    Text(e).font(.caption).foregroundStyle(v.stage == .failed ? .red : .secondary).textSelection(.enabled)
                }
                if let r = v.replacement, let e = r.lastError { Text(e).font(.caption).foregroundStyle(r.stage == .failed ? .red : .secondary) }
            }
        }
        .alert("Delete this video from LetsMeet?", isPresented: $confirmDelete) {
            Button("Delete Video", role: .destructive) { model.deleteVideo(j) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Pupils will no longer be able to watch it. Your original Zoom recordings on this Mac are not touched.")
        }
    }

    func details(_ v: VideoUploadState) -> String {
        var p: [String] = []
        if v.sourceRecordingIds.count > 1 { p.append("\(v.sourceRecordingIds.count) recordings joined into one MP4") }
        if let s = v.fileSize { p.append(s.fileSize) }
        if let d = v.durationSec { p.append(CoreFormat.duration(d)) }
        p.append(v.origin == .backfill ? "backfill" : (v.origin == .manual ? "uploaded by you" : "automatic"))
        if let c = v.completedAt, v.stage == .ready { p.append("done \(c.shortDateTime)") }
        if let r = v.remoteStatus, v.stage == .ready, r != "ready" { p.append("LetsMeet status: \(r)") }
        return p.joined(separator: " · ")
    }

    @ViewBuilder var actions: some View {
        let j = item.job
        if let v = j.video {
            switch v.stage {
            case .failed:
                Button("Retry") { model.retryVideo(j) }.buttonStyle(.borderedProminent)
            case .ready:
                Menu {
                    Button("Watch on LetsMeet") { model.openVideo(j) }
                    Button("Download Original") { model.openVideo(j, download: true) }
                    Button("Check Availability") { model.checkVideoAvailability(j) }
                    Divider()
                    if v.replacement == nil { Button("Replace Video…") { model.replaceVideo(j) } }
                    else {
                        if v.replacement?.stage == .failed { Button("Retry Replacement") { model.retryVideo(j) } }
                        Button("Cancel Replacement") { model.cancelVideoReplacement(j) }
                    }
                    Divider()
                    Button("Delete from LetsMeet…", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
            case .deleted:
                if v.deletePending { Button("Retry Delete") { model.deleteVideo(j) } }
                else { Button("Upload Again") { model.uploadVideoAgain(j) } }
            case .skipped:
                EmptyView()
            default:
                Button("Stop") { model.stopVideo(j) }
            }
        } else if j.stage == .submitted && j.remoteStatus != .deleted {
            Button("Upload Video") { model.uploadVideoNow(j) }
        }
    }
}

/// The video block in a lesson's History page.
struct JobVideoSection: View {
    @EnvironmentObject var model: AppModel
    var lesson: Lesson
    var job: Job
    init(lesson: Lesson, job: Job) { self.lesson = lesson; self.job = job }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Lesson video", systemImage: "play.rectangle").font(.headline)
            if job.video == nil {
                Text(job.stage == .submitted
                     ? (VideoBackfill.isHistorical(job, settings: model.settings.video) ? "Not uploaded yet. Upload it here, or with the historical backfill on the Videos page." : "Not uploaded.")
                     : "The video is uploaded after the notes are submitted" + (model.settings.video.autoUpload ? " (automatic)." : " — automatic uploads are off."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if job.video?.stage.isActive == true { VideoProgressRow(item: LessonJob(lesson: lesson, job: job)) }
            else { VideoRow(item: LessonJob(lesson: lesson, job: job), showsLesson: false) }
        }
    }
}
