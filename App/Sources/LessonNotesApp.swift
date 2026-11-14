import SwiftUI
import AppKit
import LessonNotesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in AppModel.shared.showMainWindow() }
        return true
    }
}

@main
struct LessonNotesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        Window("Let's Meet Lesson Notes", id: "main") {
            MainWindow()
                .environmentObject(model)
                .environmentObject(model.whisper)
                .frame(minWidth: 960, minHeight: 620)
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import MP4s…") { model.startImport(files: true) }.keyboardShortcut("o", modifiers: [.command])
                Button("Import Folder…") { model.startImport(files: false) }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandMenu("Lessons") {
                Button("Dashboard") { model.sidebar = .dashboard }.keyboardShortcut("1", modifiers: .command)
                Button("History") { model.sidebar = .history }.keyboardShortcut("2", modifiers: .command)
                Button("Students") { model.sidebar = .students }.keyboardShortcut("3", modifiers: .command)
                Divider()
                Button("Check Website Statuses Now") { Task { await model.syncStatuses(force: true) } }.keyboardShortcut("r", modifiers: [.command, .shift])
                Button(model.isPaused ? "Resume Processing" : "Pause Processing") { model.setPaused(!model.isPaused) }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.whisper)
                .frame(width: 760, height: 640)
        }

        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        let pending = model.detections.count
        HStack(spacing: 2) {
            Image(systemName: model.isBusy ? "waveform.circle.fill" : (model.attentionJobs.isEmpty ? "note.text" : "exclamationmark.circle"))
            if pending > 0 { Text("\(pending)") }
        }
        .accessibilityLabel(model.isBusy ? "Lesson Notes, processing" : "Lesson Notes")
        .onAppear {
            model.openWindowAction = { openWindow(id: "main") }
        }
    }
}
