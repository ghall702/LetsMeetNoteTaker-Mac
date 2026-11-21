import SwiftUI
import AppKit
import LessonNotesCore

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                AppLogo(size: 22)
                Text("Lesson Notes").font(Theme.serif(18)).foregroundStyle(Theme.ink)
                Spacer()
                if !model.isOnline { Label("Offline", systemImage: "wifi.slash").font(.caption).foregroundStyle(.orange) }
            }
            MenuUsageLine()
            if model.settings.openAIPaused {
                Label("OpenAI paused — transcribing only" + (model.settings.openAIPauseAllowsToday ? " (today's lessons still get notes)" : ""),
                      systemImage: "pause.circle").font(.caption).foregroundStyle(.purple)
            }
            if !model.detections.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("New recordings").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    ForEach(model.detections.prefix(4)) { d in
                        Button {
                            open()
                            model.openDetection(folderPath: d.folderPath)
                        } label: {
                            Label((d.folderPath as NSString).lastPathComponent, systemImage: "video.badge.checkmark").lineLimit(1)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if model.activeJobs.isEmpty {
                Text(model.isPaused ? "Processing paused" : "No lessons processing").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(Array(model.activeJobs.prefix(5))) { item in JobProgressRow(lesson: item.lesson, job: item.job) }
            }
            if !model.attentionJobs.isEmpty {
                Button { open(); model.sidebar = .dashboard } label: {
                    Label("\(model.attentionJobs.count) lesson(s) need attention", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                }
                .buttonStyle(.plain)
            }
            Divider()
            Button("Open Lesson Notes") { open() }.keyboardShortcut("l")
            Button("Import MP4s…") { model.startImport(files: true) }
            Button("Import Folder…") { model.startImport(files: false) }
            Button("Check Website Statuses") { Task { await model.syncStatuses(force: true) } }
            Button(model.isPaused ? "Resume Processing" : "Pause Processing") { model.setPaused(!model.isPaused) }
            Button(model.settings.openAIPaused ? "Resume OpenAI Activity" : "Pause OpenAI Activity") { model.setOpenAIPaused(!model.settings.openAIPaused) }
            Button("Settings…") { NSApp.activate(ignoringOtherApps: true); openSettings() }.keyboardShortcut(",")
            Divider()
            Button("Quit Lesson Notes") { NSApp.terminate(nil) }.keyboardShortcut("q")
        }
        .buttonStyle(.plain)
        .padding(14)
        .frame(width: 340)
        .tint(Theme.forest)
    }

    func open() {
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuUsageLine: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        let s = model.settings.usage
        let today = UsageAccounting.today(model.usageRecords, now: Date(), settings: s)
        let color = allowanceColor(used: today.eligibleTokens, allowance: s.dailyComplimentaryTokens)
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Circle().fill(color).frame(width: 8, height: 8)
                Text("OpenAI today: \(UsageFormat.tokens(today.eligibleTokens)) of \(UsageFormat.tokens(s.dailyComplimentaryTokens)) free tokens")
                    .font(.caption.monospacedDigit())
            }
            ProgressView(value: Double(min(today.eligibleTokens, s.dailyComplimentaryTokens)), total: Double(max(1, s.dailyComplimentaryTokens))).tint(color)
        }
    }
}
