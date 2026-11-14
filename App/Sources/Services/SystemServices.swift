import Foundation
import Network
import ServiceManagement
import UserNotifications
import AppKit
import UniformTypeIdentifiers
import os
import LessonNotesCore

let appLog = Logger(subsystem: "com.georgehalltuition.lessonnotes", category: "app")

enum AppInfo {
    static var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0.0" }
    static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1" }
    static let adminToolsURL = URL(string: "https://georgehalltuition.com/admin-tools")!

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("LessonNotes", isDirectory: true)
    }

    static var tempAudioDirectory: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("LessonNotesAudio", isDirectory: true)
    }
}

/// Launch at login via SMAppService.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var requiresApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled {
            if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
        } else {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
        }
    }
}

/// Connectivity via NWPathMonitor.
final class NetworkMonitor: @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var online = true
    var onChange: ((Bool) -> Void)?

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let isOnline = path.status == .satisfied
            self.lock.lock(); let changed = self.online != isOnline; self.online = isOnline; self.lock.unlock()
            if changed { DispatchQueue.main.async { self.onChange?(isOnline) } }
        }
        monitor.start(queue: DispatchQueue(label: "lessonnotes.network"))
    }

    var isOnline: Bool { lock.lock(); defer { lock.unlock() }; return online }
}

/// macOS memory pressure (normal / warning / critical) for throttling new transcriptions.
final class MemoryPressureMonitor: @unchecked Sendable {
    private let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: DispatchQueue(label: "lessonnotes.memory"))
    private let lock = NSLock()
    private var current: MemoryPressureLevel = .normal
    var onChange: ((MemoryPressureLevel) -> Void)?

    init() {
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let e = self.source.data
            let level: MemoryPressureLevel = e.contains(.critical) ? .critical : (e.contains(.warning) ? .warning : .normal)
            self.lock.lock(); self.current = level; self.lock.unlock()
            self.onChange?(level)
        }
        source.resume()
    }

    var level: MemoryPressureLevel { lock.lock(); defer { lock.unlock() }; return current }
}

/// Native notifications with a "Review" action.
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    static let reviewCategory = "NEW_RECORDING"
    static let reviewAction = "REVIEW"

    /// Called with the folder path when George clicks a new-recording notification.
    var onReview: ((String) -> Void)?
    var onOpenLesson: ((UUID) -> Void)?

    func configure() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        let review = UNNotificationAction(identifier: Self.reviewAction, title: "Review", options: [.foreground])
        let category = UNNotificationCategory(identifier: Self.reviewCategory, actions: [review], intentIdentifiers: [], options: [])
        center.setNotificationCategories([category])
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func notifyNewRecording(folderPath: String, title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        c.categoryIdentifier = Self.reviewCategory
        c.userInfo = ["folderPath": folderPath]
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "rec-" + folderPath, content: c, trigger: nil))
    }

    func notify(title: String, body: String, lessonId: UUID? = nil) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        if let lessonId { c.userInfo = ["lessonId": lessonId.uuidString] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        DispatchQueue.main.async {
            if let path = info["folderPath"] as? String { self.onReview?(path) }
            else if let s = info["lessonId"] as? String, let id = UUID(uuidString: s) { self.onOpenLesson?(id) }
        }
        completionHandler()
    }
}

/// Security-scoped bookmarks (sandbox access that survives relaunch).
enum FolderAccess {
    static func bookmark(for url: URL) throws -> Data {
        try url.bookmarkData(options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolves a bookmark and starts accessing it. Caller must call `stopAccessingSecurityScopedResource`.
    static func resolve(_ data: Data) -> (url: URL, stale: Bool)? {
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        _ = url.startAccessingSecurityScopedResource()
        return (url, stale)
    }

    /// Runs `body` with access to a recording (bookmark first, then path fallback).
    static func withAccess<T>(bookmark: Data?, path: String, _ body: (URL) async throws -> T) async throws -> T {
        if let bookmark, let r = resolve(bookmark) {
            defer { r.url.stopAccessingSecurityScopedResource() }
            return try await body(r.url)
        }
        return try await body(URL(fileURLWithPath: path))
    }

    @MainActor
    static func chooseFolder(title: String, startingAt path: String?) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if let path { panel.directoryURL = URL(fileURLWithPath: (path as NSString).expandingTildeInPath) }
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseRecordings() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Import Zoom recordings"
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.mpeg4Movie, .mpeg4Audio, .movie]
        panel.prompt = "Import"
        NSApp.activate(ignoringOtherApps: true)
        return panel.runModal() == .OK ? panel.urls : []
    }
}

/// Recursive FSEvents watcher for the Zoom folder.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let path: String
    private let onChange: ([String]) -> Void

    init(path: String, onChange: @escaping ([String]) -> Void) {
        self.path = path
        self.onChange = onChange
    }

    deinit { stop() }

    func start() {
        guard stream == nil else { return }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let array = unsafeBitCast(paths, to: NSArray.self)
            var list: [String] = []
            for i in 0..<count { if let s = array[i] as? String { list.append(s) } }
            watcher.onChange(list)
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault, callback, &context, [path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2.0, flags) else { return }
        FSEventStreamSetDispatchQueue(s, DispatchQueue.main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }
}
