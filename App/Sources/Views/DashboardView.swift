import SwiftUI
import AppKit
import LessonNotesCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !model.setupIssues.isEmpty { setupCard }
                if let e = model.watchError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
                if model.settings.openAIPaused { openAIPausedCard }
                Card(title: "OpenAI usage today", systemImage: "chart.bar.xaxis") {
                    UsagePanel(compact: true)
                    Button("Usage history…") { model.sidebar = .usage }.buttonStyle(.link)
                }
                detectionsCard
                if !model.heldJobs.isEmpty { heldCard }
                activeCard
                if !model.attentionJobs.isEmpty { attentionCard }
                recentCard
            }
            .padding(20)
        }
        .navigationTitle("Dashboard")
    }

    var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LetsMeet Lesson Notes").font(.title2.weight(.semibold))
                Text(statusLine).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.setOpenAIPaused(!model.settings.openAIPaused) } label: {
                Label(model.settings.openAIPaused ? "Resume OpenAI" : "Pause OpenAI",
                      systemImage: model.settings.openAIPaused ? "play.circle" : "pause.circle")
            }
            .help("Pause OpenAI: keep transcribing, but don't use OpenAI to write notes until you resume")
            Button { model.startImport(files: true) } label: { Label("Import MP4s…", systemImage: "film.stack") }
            Button { model.startImport(files: false) } label: { Label("Import Folder…", systemImage: "folder.badge.plus") }
            Menu {
                Button("Scan Zoom folder now") { model.startWatching() }
                    .disabled(model.settings.zoomFolderBookmark == nil)
                Button("Check website statuses now") { Task { await model.syncStatuses(force: true) } }
                Button(model.isPaused ? "Resume processing" : "Pause processing") { model.setPaused(!model.isPaused) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("More actions")
        }
    }

    var statusLine: String {
        var parts: [String] = []
        if model.settings.watchFolder, model.zoomFolderURL != nil { parts.append("Watching \((model.settings.zoomFolderPath as NSString).abbreviatingWithTildeInPath)") }
        else { parts.append("Folder watching is off") }
        if let s = model.lastSync { parts.append("statuses checked \(s.formatted(date: .omitted, time: .shortened))") }
        return parts.joined(separator: " · ")
    }

    var openAIPausedCard: some View {
        let waiting = model.activeJobs.filter { model.isHeldForOpenAI($0.job) }.count
        return Card(title: "OpenAI activity is paused", systemImage: "pause.circle") {
            Text("Recordings are still transcribed on this Mac, but notes are not written until you resume, so your OpenAI allowance is kept"
                 + (model.settings.openAIPauseAllowsToday ? " for today's lessons." : ".")
                 + (waiting > 0 ? " \(waiting) transcribed lesson\(waiting == 1 ? " is" : "s are") waiting." : ""))
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Toggle("Still write notes for lessons dated today", isOn: Binding(
                    get: { model.settings.openAIPauseAllowsToday },
                    set: { v in model.updateSettings { $0.openAIPauseAllowsToday = v }; model.setOpenAIPaused(true) }))
                Spacer()
                Button("Resume OpenAI") { model.setOpenAIPaused(false) }.buttonStyle(.borderedProminent)
            }
        }
    }

    var setupCard: some View {
        Card(title: "Finish setting up", systemImage: "checklist") {
            ForEach(model.setupIssues, id: \.self) { Label($0, systemImage: "circle").foregroundStyle(.secondary) }
            HStack {
                Button("Open Setup Assistant") { model.showOnboarding = true }.buttonStyle(.borderedProminent)
                Button("Settings") { model.sidebar = .settings }
            }
        }
    }

    var detectionsCard: some View {
        Card(title: "New recordings to review", systemImage: "bell.badge") {
            if model.detections.isEmpty {
                Text("No new recordings. Finished Zoom recordings appear here automatically.").foregroundStyle(.secondary)
            }
            ForEach(model.detections) { d in
                let session = SessionGrouper.group(d.recordings, timeZone: model.settings.timeZone).first
                HStack {
                    Image(systemName: "video.fill").foregroundStyle(.tint)
                    VStack(alignment: .leading) {
                        Text(session?.topic ?? (d.folderPath as NSString).lastPathComponent).font(.body.weight(.medium))
                        Text("\(session.map { CoreFormat.longUKDate($0.inferredDate.lessonDate) } ?? "") · \(d.recordings.count) recording\(d.recordings.count == 1 ? "" : "s") · found \(d.detectedAt.shortDateTime)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Dismiss") { model.dismissDetection(d) }
                    Button("Review…") { model.openDetection(folderPath: d.folderPath) }.buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 2)
            }
        }
    }

    var heldCard: some View {
        Card(title: "Ready to start", systemImage: "pause.circle") {
            Text("Automatic processing is off, so these lessons wait for you.").font(.caption).foregroundStyle(.secondary)
            ForEach(model.heldJobs) { item in
                let l = item.lesson, j = item.job
                HStack {
                    Text("\(l.pupilName) — \(CoreFormat.longUKDate(l.lessonDate))")
                    Spacer()
                    Button("Cancel") { model.cancel(j) }
                    Button("Start") { model.start(j) }.buttonStyle(.borderedProminent)
                }
            }
        }
    }

    var activeCard: some View {
        Card(title: "Processing", systemImage: "gearshape.2") {
            if model.activeJobs.isEmpty {
                Text(model.isPaused ? "Processing is paused." : "Nothing is processing right now.").foregroundStyle(.secondary)
            }
            ForEach(model.activeJobs) { item in
                let l = item.lesson, j = item.job
                HStack(alignment: .top) {
                    JobProgressRow(lesson: l, job: j)
                    if model.isHeldForOpenAI(j) {
                        Button("Write Notes Now") { model.writeNotesNow(j) }
                            .help("Use OpenAI for this lesson now, even though OpenAI is paused")
                    }
                    Button { model.cancel(j) } label: { Image(systemName: "xmark.circle") }
                        .buttonStyle(.borderless).help("Cancel").accessibilityLabel("Cancel \(l.pupilName)")
                }
                Divider()
            }
        }
    }

    var attentionCard: some View {
        Card(title: "Needs attention", systemImage: "exclamationmark.triangle") {
            if model.creditFailures.count > 1 {
                HStack {
                    Label("\(model.creditFailures.count) lessons are waiting for OpenAI credit. Their transcripts are saved.", systemImage: "creditcard")
                        .font(.callout)
                    Spacer()
                    Link("Add Credits…", destination: JobError.openAIBillingURL)
                    Button("Retry All \(model.creditFailures.count)") { model.retryAllCreditFailures() }.buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            ForEach(model.attentionJobs) { item in
                let l = item.lesson, j = item.job
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(l.pupilName) — \(CoreFormat.longUKDate(l.lessonDate))").font(.body.weight(.medium))
                        Spacer()
                        StatusChip(job: j)
                    }
                    Text(j.error?.message ?? j.replacement?.message ?? "Needs attention").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    HStack {
                        Button("Open") { model.openLesson(l.id) }
                        if j.error?.kind == .openAICredits { Link("Add Credits…", destination: JobError.openAIBillingURL) }
                        if j.stage == .failed && j.error?.kind != .payloadTooLarge {
                            Button("Fix & Retry") { model.retry(j) }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                Divider()
            }
        }
    }

    var recentCard: some View {
        Card(title: "Recent submissions", systemImage: "paperplane") {
            let recent = model.allJobs.filter { $0.job.stage == .submitted }.sorted { ($0.job.submittedAt ?? .distantPast) > ($1.job.submittedAt ?? .distantPast) }.prefix(8)
            if recent.isEmpty { Text("No lesson notes submitted yet.").foregroundStyle(.secondary) }
            ForEach(Array(recent)) { item in
                let l = item.lesson, j = item.job
                Button { model.openLesson(l.id) } label: {
                    HStack {
                        Text(l.pupilName).frame(width: 120, alignment: .leading)
                        Text(j.notes?.title ?? l.meetingTopic).lineLimit(1)
                        Spacer()
                        Text(CoreFormat.longUKDate(l.lessonDate)).foregroundStyle(.secondary)
                        StatusChip(job: j)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
