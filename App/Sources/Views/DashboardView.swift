import SwiftUI
import AppKit
import LessonNotesCore

struct DashboardView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.appearIn(0)
                    if !model.setupIssues.isEmpty { setupCard.appearIn(1) }
                    if let e = model.watchError {
                        Label(e, systemImage: "exclamationmark.triangle").font(.system(size: 12.5)).foregroundStyle(Theme.clayInk)
                    }
                    if geo.size.width >= 900 {
                        HStack(alignment: .top, spacing: 18) {
                            mainColumn.frame(maxWidth: .infinity)
                            sideColumn.frame(width: min(340, geo.size.width * 0.34))
                        }
                    } else {
                        VStack(spacing: 18) { mainColumn; sideColumn }
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 20)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("Dashboard")
    }

    // MARK: Header

    var greeting: String {
        let h = Calendar.current.component(.hour, from: Date())
        return h < 12 ? "Good morning," : (h < 18 ? "Good afternoon," : "Good evening,")
    }

    var firstName: String {
        if model.isDemo { return "George" }
        return NSFullUserName().split(separator: " ").first.map(String.init) ?? "there"
    }

    var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 2) {
                Text(greeting).font(.system(size: 14)).foregroundStyle(Theme.ink2)
                HStack(alignment: .center, spacing: 10) {
                    Text(firstName).font(Theme.serif(40)).foregroundStyle(Theme.ink)
                    Sprig(color: Theme.sage).frame(width: 34, height: 34).offset(y: -2)
                }
            }
            Spacer()
            Menu {
                Button("Import MP4s…") { model.startImport(files: true) }
                Button("Import Folder…") { model.startImport(files: false) }
            } label: {
                Label("Import recordings", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .padding(.horizontal, 15).padding(.vertical, 8)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(Theme.line))
            Button { model.setOpenAIPaused(!model.settings.openAIPaused) } label: {
                Label(model.settings.openAIPaused ? "Resume OpenAI" : "Pause OpenAI",
                      systemImage: model.settings.openAIPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.soft)
            .help("Pause OpenAI: keep transcribing, but don't use OpenAI to write notes until you resume")
            Menu {
                Button("Scan Zoom folder now") { model.startWatching() }
                    .disabled(model.settings.zoomFolderBookmark == nil)
                Button("Check website statuses now") { Task { await model.syncStatuses(force: true) } }
                Button(model.isPaused ? "Resume processing" : "Pause processing") { model.setPaused(!model.isPaused) }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .frame(width: 34, height: 34)
            .background(RoundedRectangle(cornerRadius: 11, style: .continuous).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(Theme.line2))
            .accessibilityLabel("More actions")
        }
    }

    // MARK: Main column

    var mainColumn: some View {
        VStack(alignment: .leading, spacing: 18) {
            if model.settings.openAIPaused { openAIPausedCard.appearIn(1) }
            hero.appearIn(1)
            tiles.appearIn(2)
            if !model.heldJobs.isEmpty { heldCard.appearIn(3) }
            inProgressCard.appearIn(3)
            recentCard.appearIn(4)
        }
    }

    var hero: some View {
        let count = model.detections.count
        return ZStack(alignment: .leading) {
            Theme.hero
            HillsArt(dark: true)
                .frame(width: 440)
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
                .frame(maxWidth: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 12) {
                Text(count > 0 ? "Ready for you" : "All caught up")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.6).textCase(.uppercase)
                    .foregroundStyle(Color.white.opacity(0.6))
                Text(count > 0 ? "\(count) new lesson\(count == 1 ? "" : "s") to confirm" : "No new lessons to confirm")
                    .font(Theme.serif(32)).foregroundStyle(Color(nsColor: NSColor(hex: 0xF7F4EC)))
                    .frame(maxWidth: 380, alignment: .leading)
                    .contentTransition(.numericText())
                if count > 0 {
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(model.detections.prefix(3)) { d in
                            Button { model.openDetection(folderPath: d.folderPath) } label: {
                                Text(detectionLine(d))
                                    .font(.system(size: 12.5)).foregroundStyle(Color.white.opacity(0.92))
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(Capsule().fill(Color.white.opacity(0.1)))
                            }
                            .buttonStyle(.plain)
                            .contextMenu { Button("Dismiss") { withAnimation(Theme.spring) { model.dismissDetection(d) } } }
                            .help("Review this lesson")
                        }
                    }
                    Button {
                        if let d = model.detections.first { model.openDetection(folderPath: d.folderPath) }
                    } label: {
                        Label("Review & confirm", systemImage: "checkmark")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Color(nsColor: NSColor(hex: 0x2F4135)))
                            .padding(.horizontal, 18).padding(.vertical, 10)
                            .background(Capsule().fill(Color(nsColor: NSColor(hex: 0xF7F3EA))))
                    }
                    .buttonStyle(.plain)
                    .hoverLift()
                    .padding(.top, 2)
                } else {
                    Text("Finished Zoom recordings appear here automatically.")
                        .font(.system(size: 13)).foregroundStyle(Color.white.opacity(0.7))
                }
            }
            .padding(24)
        }
        .frame(minHeight: count > 0 ? 230 : 170)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 8)
        .animation(Theme.spring, value: count)
    }

    func detectionLine(_ d: PendingDetection) -> String {
        let session = SessionGrouper.group(d.recordings, timeZone: model.settings.timeZone).first
        let suggestion = session.flatMap { MappingMatcher.rank(MatchContext(session: $0), mappings: model.mappings, rooms: model.rooms).first }
        var parts: [String] = [suggestion?.displayName ?? session?.topic ?? (d.folderPath as NSString).lastPathComponent]
        if let s = session, let date = CoreFormat.parseLessonDate(s.inferredDate.lessonDate, timeZone: model.settings.timeZone) {
            parts.append(date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        }
        parts.append("\(d.recordings.count) recording\(d.recordings.count == 1 ? "" : "s")")
        return parts.joined(separator: " · ")
    }

    var tiles: some View {
        let active = model.activeJobs
        let transcribing = active.filter { [.queued, .extracting, .transcribing].contains($0.job.stage) && !model.isHeldForOpenAI($0.job) }.count
        let writing = active.filter { [.summarising, .submitting].contains($0.job.stage) || model.isHeldForOpenAI($0.job) }.count
        let cal = Calendar.current
        let sentToday = model.allJobs.filter { $0.job.stage == .submitted && ($0.job.submittedAt.map { cal.isDateInToday($0) } ?? false) }.count
        return HStack(spacing: 14) {
            StatTile(icon: "waveform", title: "Transcribing", detail: "On this Mac", value: transcribing, tone: .sage)
            StatTile(icon: "pencil", title: "Writing notes", detail: model.settings.openAIPaused ? "OpenAI paused" : (model.settings.openAIModel.isEmpty ? "OpenAI" : model.settings.openAIModel), value: writing, tone: .sand)
            StatTile(icon: "paperplane", title: "Sent today", detail: "To approve", value: sentToday, tone: .lavender)
                .onTapGesture { model.sidebar = .history }
        }
    }

    var inProgressCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                IconBadge(systemName: "waveform", tone: .sage, size: 30)
                Text("In progress").font(Theme.serif(22)).foregroundStyle(Theme.ink)
                Spacer()
                Button("View all") { model.sidebar = .history }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            .padding(.bottom, 6)
            if model.activeJobs.isEmpty {
                HStack(spacing: 12) {
                    Sprig(color: Theme.sage).frame(width: 30, height: 30)
                    Text(model.isPaused ? "Processing is paused." : "Nothing is processing right now.")
                        .font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
                .padding(.vertical, 10)
            }
            ForEach(Array(model.activeJobs.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider().overlay(Theme.line2) }
                QueueRow(item: item)
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
        .animation(Theme.spring, value: model.activeJobs.map(\.id))
    }

    var heldCard: some View {
        Card(title: "Ready to start", systemImage: "pause", tone: .lavender) {
            Text("Automatic processing is off, so these lessons wait for you.").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            ForEach(model.heldJobs) { item in
                let l = item.lesson, j = item.job
                HStack(spacing: 10) {
                    Avatar(name: l.pupilName, size: 30)
                    Text("\(l.pupilName) — \(CoreFormat.longUKDate(l.lessonDate))").font(.system(size: 13)).foregroundStyle(Theme.ink)
                    Spacer()
                    Button("Cancel") { model.cancel(j) }.buttonStyle(.softCompact)
                    Button("Start") { model.start(j) }.buttonStyle(.primary)
                }
            }
        }
    }

    var recentCard: some View {
        let recent = model.allJobs.filter { $0.job.stage == .submitted }
            .sorted { ($0.job.submittedAt ?? .distantPast) > ($1.job.submittedAt ?? .distantPast) }.prefix(6)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                IconBadge(systemName: "paperplane", tone: .lavender, size: 30)
                Text("Recently sent").font(Theme.serif(22)).foregroundStyle(Theme.ink)
            }
            .padding(.bottom, 4)
            if recent.isEmpty { Text("No lesson notes sent yet.").font(.system(size: 13)).foregroundStyle(Theme.ink2) }
            ForEach(Array(recent)) { item in
                let l = item.lesson, j = item.job
                Button { model.openLesson(l.id) } label: {
                    HStack(spacing: 11) {
                        Avatar(name: l.pupilName, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(j.notes?.title ?? l.meetingTopic).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                            Text("\(l.pupilName) · \(CoreFormat.longUKDate(l.lessonDate))").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        }
                        Spacer()
                        StatusChip(job: j)
                    }
                    .padding(.vertical, 5).padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 20)
    }

    var setupCard: some View {
        Card(title: "Finish setting up", systemImage: "checklist", tone: .sand) {
            ForEach(model.setupIssues, id: \.self) {
                Label($0, systemImage: "circle").font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
            HStack {
                Button("Open Setup Assistant") { model.showOnboarding = true }.buttonStyle(.primary)
                Button("Settings") { model.sidebar = .settings }.buttonStyle(.soft)
            }
        }
    }

    var openAIPausedCard: some View {
        let waiting = model.activeJobs.filter { model.isHeldForOpenAI($0.job) }.count
        return Card(title: "OpenAI activity is paused", systemImage: "pause", tone: .lavender) {
            Text("Recordings are still transcribed on this Mac, but notes are not written until you resume, so your OpenAI allowance is kept"
                 + (model.settings.openAIPauseAllowsToday ? " for today's lessons." : ".")
                 + (waiting > 0 ? " \(waiting) transcribed lesson\(waiting == 1 ? " is" : "s are") waiting." : ""))
                .font(.system(size: 13)).foregroundStyle(Theme.ink2)
            HStack {
                Toggle("Still write notes for lessons dated today", isOn: Binding(
                    get: { model.settings.openAIPauseAllowsToday },
                    set: { v in model.updateSettings { $0.openAIPauseAllowsToday = v }; model.setOpenAIPaused(true) }))
                    .toggleStyle(.checkbox).font(.system(size: 12.5))
                Spacer()
                Button("Resume OpenAI") { model.setOpenAIPaused(false) }.buttonStyle(.primary)
            }
        }
    }

    // MARK: Side column

    var sideColumn: some View {
        VStack(spacing: 18) {
            OpenAIRingCard().appearIn(2)
            needsYouCard.appearIn(3)
            videosCard.appearIn(4)
        }
    }

    var needsYouCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconBadge(systemName: "hand.raised", tone: .clay, size: 30)
                Text("Needs you").font(Theme.serif(20)).foregroundStyle(Theme.ink)
                Spacer()
                if !model.attentionJobs.isEmpty {
                    Text("\(model.attentionJobs.count)").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.clayInk)
                        .frame(width: 22, height: 22).background(Circle().fill(Theme.clay))
                }
            }
            if model.attentionJobs.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.sageInk)
                        .frame(width: 26, height: 26).background(Circle().fill(Theme.sageTint))
                    Text("Nothing needs you. Lovely.").font(.system(size: 13)).foregroundStyle(Theme.ink2)
                }
            }
            if model.creditFailures.count > 1 {
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(model.creditFailures.count) lessons are waiting for OpenAI credit. Their transcripts are saved.")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.clayInk)
                    HStack {
                        Button("Retry all \(model.creditFailures.count)") { model.retryAllCreditFailures() }.buttonStyle(.primary)
                        Link("Add credit", destination: JobError.openAIBillingURL).font(.system(size: 12.5, weight: .medium))
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.clay))
            }
            ForEach(model.attentionJobs.prefix(4)) { item in AttentionItem(item: item) }
            if model.attentionJobs.count > 4 {
                Button("\(model.attentionJobs.count - 4) more in History") { model.sidebar = .history }
                    .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
    }

    var videosCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                IconBadge(systemName: "play.rectangle", tone: .sand, size: 30)
                Text("Lesson videos").font(Theme.serif(20)).foregroundStyle(Theme.ink)
                Spacer()
                Button("Open Videos") { model.sidebar = .videos }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            if let item = model.activeVideoJobs.first {
                let p = model.videoProgress[item.job.id]
                HStack(spacing: 12) {
                    HillsArt()
                        .frame(width: 70, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Uploading \(item.lesson.pupilName) · \(shortDate(item.lesson.lessonDate))")
                            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                        SoftBar(value: p?.fraction ?? 0)
                        Text(p?.message ?? item.job.video?.displayPhase(paused: model.settings.video.paused).rawValue ?? "Waiting")
                            .font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(2)
                    }
                }
            } else {
                HStack(spacing: 12) {
                    HillsArt(sun: true)
                        .frame(width: 70, height: 52)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    Text(model.settings.video.autoUpload ? "No uploads right now. Videos follow their notes to LetsMeet automatically."
                                                      : "Video uploads are off (Settings → Videos).")
                        .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                }
            }
            Divider().overlay(Theme.line2)
            HStack {
                Text("\(model.activeVideoJobs.count) in the queue").font(.system(size: 12)).foregroundStyle(Theme.ink2)
                Spacer()
                if !model.failedVideoJobs.isEmpty {
                    Pill(text: "\(model.failedVideoJobs.count) need attention", tone: .clay)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
    }

    func shortDate(_ lessonDate: String) -> String {
        CoreFormat.parseLessonDate(lessonDate, timeZone: model.settings.timeZone)?
            .formatted(.dateTime.day().month(.abbreviated)) ?? lessonDate
    }
}

/// Count tile under the hero.
struct StatTile: View {
    var icon: String
    var title: String
    var detail: String
    var value: Int
    var tone: Theme.Tone
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 15, weight: .medium)).foregroundStyle(tone.ink)
                .frame(width: 38, height: 38)
                .background(Circle().fill(Theme.raised.opacity(0.75)))
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(tone.ink)
                Text(detail).font(.system(size: 11.5)).foregroundStyle(tone.ink.opacity(0.8)).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text("\(value)").font(Theme.serif(30)).foregroundStyle(tone.ink)
                .contentTransition(.numericText())
                .animation(Theme.spring, value: value)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(tone.fill))
        .hoverLift()
    }
}

/// One lesson in the "In progress" list: who, what, which step, how far.
struct QueueRow: View {
    @EnvironmentObject var model: AppModel
    var item: LessonJob

    var steps: [(String, Int)] {
        // 0 = to do, 1 = current, 2 = done
        let order: [JobStage] = [.extracting, .transcribing, .summarising, .submitting]
        let current = item.job.stage == .queued ? -1 : (order.firstIndex(of: item.job.stage) ?? 0)
        let pct = model.progress[item.job.id].map { " \(Int(($0.fraction * 100).rounded()))%" } ?? ""
        let names = ["Audio", "Transcribing", "Notes", "Upload"]
        return names.enumerated().map { i, n in
            (i == current ? n + (i == 1 ? pct : "") : n, i < current ? 2 : (i == current ? 1 : 0))
        }
    }

    var body: some View {
        let l = item.lesson, j = item.job
        let p = model.progress[j.id]
        HStack(alignment: .top, spacing: 13) {
            Avatar(name: l.pupilName, size: 38)
            VStack(alignment: .leading, spacing: 5) {
                Text("\(l.pupilName) — \(j.notes?.title ?? shortTopic(l))")
                    .font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(meta(l, j)).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
                HStack(spacing: 12) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
                        HStack(spacing: 5) {
                            Circle()
                                .fill(s.1 == 0 ? Theme.line : (s.1 == 1 ? Theme.forest : Theme.sage))
                                .frame(width: 7, height: 7)
                            Text(s.0).font(.system(size: 11.5)).foregroundStyle(s.1 == 1 ? Theme.ink2 : Theme.ink3)
                        }
                    }
                }
                if j.stage != .queued {
                    SoftBar(value: p?.fraction ?? 0).frame(maxWidth: 560)
                } else if let m = p?.message ?? j.statusMessage {
                    Text(m).font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 8) {
                StatusChip(job: j)
                HStack(spacing: 6) {
                    if model.isHeldForOpenAI(j) {
                        Button("Write notes now") { model.writeNotesNow(j) }.buttonStyle(.softCompact)
                            .help("Use OpenAI for this lesson now, even though OpenAI is paused")
                    }
                    Button { model.cancel(j) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.ink3)
                        .help("Cancel").accessibilityLabel("Cancel \(l.pupilName)")
                }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .contain)
    }

    func shortTopic(_ l: Lesson) -> String {
        CoreFormat.parseLessonDate(l.lessonDate, timeZone: model.settings.timeZone)
            .map { $0.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)) + " lesson" } ?? l.meetingTopic
    }

    func meta(_ l: Lesson, _ j: Job) -> String {
        var parts = [CoreFormat.longUKDate(l.lessonDate)]
        let recs = l.mode == .combined ? l.recordings.count : 1
        parts.append(recs > 1 ? "\(recs) recordings combined" : "1 recording")
        if l.jobs.count > 1 { parts.append("part \(j.partLetter)") }
        return parts.joined(separator: " · ")
    }
}

/// A lesson that needs George: what went wrong and the way out.
struct AttentionItem: View {
    @EnvironmentObject var model: AppModel
    var item: LessonJob
    var body: some View {
        let l = item.lesson, j = item.job
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: j.error?.kind == .openAICredits ? "creditcard" : "exclamationmark")
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.clayInk)
                .frame(width: 28, height: 28)
                .background(Circle().fill(Theme.raised.opacity(0.7)))
            VStack(alignment: .leading, spacing: 4) {
                Text(title(j)).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.clayInk)
                Text(detail(l, j))
                    .font(.system(size: 12)).foregroundStyle(Theme.clayInk.opacity(0.85)).lineLimit(3).textSelection(.enabled)
                HStack(spacing: 8) {
                    if j.stage == .failed && j.error?.kind != .payloadTooLarge {
                        Button("Retry") { model.retry(j) }.buttonStyle(.primary)
                    }
                    if j.error?.kind == .openAICredits {
                        Link("Add credit", destination: JobError.openAIBillingURL).font(.system(size: 12.5, weight: .medium))
                    }
                    Button("Open") { model.openLesson(l.id) }.buttonStyle(.softCompact)
                }
                .padding(.top, 2)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.clay))
    }

    func detail(_ l: Lesson, _ j: Job) -> String {
        let who: String = l.pupilName + " · " + CoreFormat.longUKDate(l.lessonDate) + ". "
        let message: String = j.error?.message ?? j.replacement?.message ?? j.fileUpdate?.message ?? ""
        return who + message
    }

    func title(_ j: Job) -> String {
        if j.error?.kind == .openAICredits { return "OpenAI credits ran out" }
        if j.replacement != nil { return "Replacing the notes needs you" }
        if j.fileUpdate != nil { return "Updating the files needs you" }
        return j.stage == .failed ? "Something went wrong" : "Needs attention"
    }
}

/// OpenAI allowance as a ring with today's figures.
struct OpenAIRingCard: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let s = model.settings.usage
            let today = UsageAccounting.today(model.usageRecords, now: now, settings: s)
            let allowance = s.dailyComplimentaryTokens
            let used = today.eligibleTokens
            let fraction = allowance > 0 ? Double(used) / Double(allowance) : 1
            let tone: Theme.Tone = fraction >= 0.9 ? .clay : (fraction >= 0.7 ? .sand : .sage)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    IconBadge(systemName: "sparkles", tone: .lavender, size: 30)
                    Text("OpenAI today").font(Theme.serif(20)).foregroundStyle(Theme.ink)
                    Spacer()
                    Pill(text: fraction >= 1 ? "Over allowance" : (fraction >= 0.7 ? "Approaching limit" : "Within allowance"), tone: tone)
                }
                HStack(spacing: 18) {
                    ZStack {
                        Ring(value: fraction, tint: tone == .sage ? Theme.sage : tone.ink, lineWidth: 10)
                        VStack(spacing: 0) {
                            Text("\(Int((min(fraction, 9.99) * 100).rounded()))%").font(Theme.serif(24)).foregroundStyle(Theme.ink)
                            Text("of free tokens").font(.system(size: 9.5)).foregroundStyle(Theme.ink3)
                        }
                    }
                    .frame(width: 104, height: 104)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(UsageFormat.tokens(today.totalTokens)).font(Theme.serif(24)).foregroundStyle(Theme.ink)
                        Text("tokens used").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                        Text("\(UsageFormat.tokens(max(0, allowance - used))) left · resets in \(UsageFormat.countdown(to: UsageCalendar.nextReset(after: now), from: now))")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                        Text("\(today.lessonCount) lesson\(today.lessonCount == 1 ? "" : "s") · est. \(UsageFormat.usd(today.estimatedSpendUSD)) today")
                            .font(.system(size: 12)).foregroundStyle(Theme.ink2)
                    }
                }
                Button("Usage history") { model.sidebar = .usage }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .cardSurface(padding: 18)
        }
    }
}

/// Plain list-row button with a soft hover highlight.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        RowButtonBody(configuration: configuration)
    }
}

private struct RowButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false
    var body: some View {
        configuration.label
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(hovering || configuration.isPressed ? Theme.line2.opacity(0.7) : Color.clear))
            .onHover { hovering = $0 }
            .animation(.easeOut(duration: 0.15), value: hovering)
    }
}
