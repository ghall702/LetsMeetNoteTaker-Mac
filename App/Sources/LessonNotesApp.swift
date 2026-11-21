import SwiftUI
import AppKit
import LessonNotesCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if SelfTest.runIfRequested() { return }
        FontLoader.register()
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in AppModel.shared.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.store.flush() }
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
        Window("LetsMeet Lesson Notes", id: "main") {
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
                Button(model.settings.openAIPaused ? "Resume OpenAI Activity" : "Pause OpenAI Activity") { model.setOpenAIPaused(!model.settings.openAIPaused) }
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
        HStack(spacing: 3) {
            Image(nsImage: MenuBarGlyph.image(attention: !model.attentionJobs.isEmpty, busy: model.isBusy))
            if pending > 0 { Text("\(pending)") }
        }
        .accessibilityLabel(model.isBusy ? "Lesson Notes, processing" : "Lesson Notes")
        .onAppear {
            model.openWindowAction = { openWindow(id: "main") }
        }
    }
}

/// The menu-bar icon: a wide page with a sprig growing out of its side, drawn as a template
/// image so macOS tints it for light and dark menu bars. A small dot shows work in progress;
/// an exclamation mark replaces the top leaf when a lesson needs attention.
enum MenuBarGlyph {
    private static var cache: [String: NSImage] = [:]

    static func image(attention: Bool, busy: Bool) -> NSImage {
        let key = "\(attention)-\(busy)"
        if let img = cache[key] { return img }
        let img = NSImage(size: NSSize(width: 30, height: 18), flipped: true) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let page = NSBezierPath(roundedRect: NSRect(x: 1.2, y: 2.2, width: 14.6, height: 13.6), xRadius: 2.6, yRadius: 2.6)
            page.lineWidth = 1.5
            page.stroke()
            let lines = NSBezierPath()
            lines.lineWidth = 1.35
            lines.lineCapStyle = .round
            for (y, w) in [(6.6, 7.6), (9.4, 6.4), (12.2, 4.6)] {
                lines.move(to: NSPoint(x: 4.6, y: y))
                lines.line(to: NSPoint(x: 4.6 + w, y: y))
            }
            lines.stroke()
            let stem = NSBezierPath()
            stem.lineWidth = 1.45
            stem.lineCapStyle = .round
            stem.move(to: NSPoint(x: 12.9, y: 15.3))
            stem.curve(to: NSPoint(x: 28.3, y: 3.2), controlPoint1: NSPoint(x: 18, y: 12.8), controlPoint2: NSPoint(x: 22.6, y: 8.9))
            stem.stroke()
            var leaves: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                (17.1, 10.9, 3.1, 1.25, -58), (20.2, 13.2, 3.1, 1.25, 8), (21.7, 7.2, 3.0, 1.2, -62), (24.6, 9.4, 3.0, 1.2, 4)]
            if !attention { leaves.append((27.4, 3.6, 2.6, 1.1, -42)) }
            for (cx, cy, rx, ry, angle) in leaves {
                let leaf = NSBezierPath(ovalIn: NSRect(x: -rx, y: -ry, width: rx * 2, height: ry * 2))
                var t = AffineTransform(translationByX: cx, byY: cy)
                t.rotate(byDegrees: angle)
                leaf.transform(using: t)
                leaf.fill()
            }
            if attention {
                let bang = NSBezierPath()
                bang.lineWidth = 1.6
                bang.lineCapStyle = .round
                bang.move(to: NSPoint(x: 27.6, y: 0.9))
                bang.line(to: NSPoint(x: 27.6, y: 4.6))
                bang.stroke()
                NSBezierPath(ovalIn: NSRect(x: 26.8, y: 6.0, width: 1.6, height: 1.6)).fill()
            }
            if busy {
                NSBezierPath(ovalIn: NSRect(x: 24.2, y: 12.0, width: 5, height: 5)).fill()
            }
            return true
        }
        img.isTemplate = true
        img.accessibilityDescription = "Lesson Notes"
        cache[key] = img
        return img
    }
}
