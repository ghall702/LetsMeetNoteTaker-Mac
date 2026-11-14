import Foundation
import SwiftUI
import AppKit
import LessonNotesCore

enum SidebarItem: String, CaseIterable, Identifiable, Hashable {
    case dashboard, history, students, usage, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .history: return "History"
        case .students: return "Students"
        case .usage: return "API Usage"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "rectangle.grid.2x2"
        case .history: return "clock.arrow.circlepath"
        case .students: return "person.2"
        case .usage: return "chart.bar.xaxis"
        case .settings: return "gearshape"
        }
    }
}

/// Request to show the confirmation sheet for one proposed lesson.
struct ReviewRequest: Identifiable {
    let id = UUID()
    var session: ProposedSession
    var fromDetection: Bool
}

struct JobProgress: Equatable {
    var fraction: Double
    var message: String
}

struct LessonJob: Identifiable {
    let lesson: Lesson
    let job: Job
    var id: UUID { job.id }
}

struct RetryConfirmation: Identifiable {
    let id = UUID()
    let job: Job
    let pupil: String
    let reason: String
}

struct ConnectionResult: Equatable {
    var ok: Bool
    var message: String
}

/// Central app state shared by the menu bar, main window and settings.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let store: LibraryStore
    let whisper: WhisperModelManager
    let network = NetworkMonitor()
    let memoryMonitor = MemoryPressureMonitor()
    /// Local OpenAI usage records (token counts from API responses; no keys or transcripts).
    private(set) var usageMonitor: UsageMonitor!
    @Published var usageVersion = 0
    private(set) var engine: JobEngine!
    private var transcriber: WhisperTranscriber!
    private var watcher: FolderWatcher?
    private var watchedFolderURL: URL?
    private var detection: DetectionMonitor!
    private var timers: [Timer] = []
    private var reloadScheduled = false

    // Published state
    @Published var lessons: [Lesson] = []
    @Published var mappings: [StudentMapping] = []
    @Published var rooms = CachedRooms()
    @Published var settings = AppSettings()
    @Published var detections: [PendingDetection] = []
    @Published var modelList = CachedModelList()
    @Published var progress: [UUID: JobProgress] = [:]
    @Published var isOnline = true
    @Published var isPaused = false
    @Published var memoryPressure: MemoryPressureLevel = .normal
    @Published var retryConfirmation: RetryConfirmation?

    @Published var sidebar: SidebarItem? = .dashboard
    @Published var selectedLessonId: UUID?
    @Published var reviewRequest: ReviewRequest?
    @Published var showImport = false
    @Published var importRoots: [URL] = []
    @Published var showOnboarding = false
    @Published var banner: String?
    /// Screenshot mode only: open the draft review sheet automatically.
    @Published var demoReviewDraft = false
    @Published var demoSelectFirstStudent = false
    @Published var settingsTab = 0

    @Published var hasWebsiteKey = false
    @Published var hasOpenAIKey = false
    @Published var websiteTest: ConnectionResult?
    @Published var openAITest: ConnectionResult?
    @Published var isRefreshingRooms = false
    @Published var isRefreshingModels = false
    @Published var modelsError: String?
    @Published var isTestingModel = false
    @Published var lastSync: Date?
    @Published var isSyncing = false
    @Published var watchError: String?

    private init() {
        let demoMode = DemoData.mode
        let dir = demoMode != nil ? FileManager.default.temporaryDirectory.appendingPathComponent("LessonNotesDemo-\(UUID().uuidString)") : AppInfo.supportDirectory
        var startupError: String?
        do {
            // Real data folder: backed up and migrated recoverably on upgrade (demo uses a temp folder).
            store = try LibraryStore(directory: dir, appVersion: demoMode == nil ? AppInfo.version : nil)
        } catch {
            // Fall back to a temporary location so the app can still report the problem.
            store = try! LibraryStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent("LessonNotes-fallback"))
            startupError = "Could not open the data folder: \(error.localizedDescription)"
        }
        whisper = WhisperModelManager()
        banner = startupError
        let health = store.health
        if let e = health.backupError ?? health.migrationError {
            banner = e + " Your data has been left exactly as it was and processing is paused. Backups are in Settings → General → Data safety."
        } else if !health.unreadableFiles.isEmpty {
            banner = "Some data files could not be read (\(health.unreadableFiles.joined(separator: ", "))). They have been left untouched; processing is paused."
        }
        if demoMode != nil { DemoData.seed(store) }
        let storeForUsage = store
        let ledger = UsageLedger(directory: store.directory)
        usageMonitor = UsageMonitor(ledger: ledger, settings: { @Sendable in storeForUsage.settings.usage })
        reload()
        usageMonitor.ledger.onChange = { [weak self] in
            DispatchQueue.main.async { self?.usageVersion += 1 }
        }
        store.onChange = { [weak self] in
            DispatchQueue.main.async { self?.scheduleReload() }
        }
        hasWebsiteKey = KeychainStore.get(.website) != nil
        hasOpenAIKey = KeychainStore.get(.openAI) != nil
        isOnline = network.isOnline

        let store = self.store
        let whisper = self.whisper
        transcriber = WhisperTranscriber(resolveModel: { @Sendable in
            await MainActor.run { () -> (name: String, folder: URL, tokenizerBase: URL)? in
                let s = store.settings
                let name = s.transcriptionModel.isEmpty ? (whisper.downloaded.keys.sorted().first ?? "") : s.transcriptionModel
                guard let folder = whisper.folder(for: name) else { return nil }
                return (name, folder, whisper.modelsBase)
            }
        }, poolLimit: { @Sendable in store.settings.maxConcurrentTranscriptions })
        let net = network
        let memory = memoryMonitor
        let usage = usageMonitor
        let deps = EngineDependencies(
            extractor: AVAudioExtractor(),
            transcriber: transcriber,
            makeNotesProducer: { @Sendable in
                guard let key = KeychainStore.get(.openAI) else { throw OpenAIError.missingKey }
                let s = store.settings
                guard !s.openAIModel.isEmpty else { throw OpenAIError.modelUnavailable("No OpenAI model selected in Settings.") }
                var client = try OpenAIClient(apiKey: key, transport: URLSessionTransport(timeout: 900))
                client.usageMonitor = usage
                return OpenAINotesProducer(generator: NotesGenerator(performer: client, model: s.openAIModel, effort: s.reasoningEffort,
                                                                     chunkThresholdTokens: s.chunkThresholdTokens, maxOutputTokens: s.maxOutputTokens))
            },
            makeSubmitter: { @Sendable in
                let s = store.settings
                return try LetsMeetClient(baseURLString: s.websiteBaseURL, apiKey: KeychainStore.get(.website) ?? "",
                                          transport: URLSessionTransport(timeout: 300))
            },
            isOnline: { net.isOnline },
            appVersion: AppInfo.version,
            makeReplacer: { @Sendable in
                let s = store.settings
                return try LetsMeetClient(baseURLString: s.websiteBaseURL, apiKey: KeychainStore.get(.website) ?? "",
                                          transport: URLSessionTransport(timeout: 300))
            },
            memoryPressure: { memory.level })
        engine = JobEngine(store: store, deps: deps, tempRoot: AppInfo.tempAudioDirectory)
        detection = DetectionMonitor(model: self)
    }

    // MARK: Startup

    func start() {
        if let demo = DemoData.mode {
            startDemo(demo)
            return
        }
        NotificationService.shared.configure()
        NotificationService.shared.onReview = { [weak self] path in self?.openDetection(folderPath: path) }
        NotificationService.shared.onOpenLesson = { [weak self] id in self?.openLesson(id) }
        network.onChange = { [weak self] online in
            guard let self else { return }
            self.isOnline = online
            if online { Task { await self.engine.tick(); await self.syncStatuses(force: false) } }
        }
        let handler: @Sendable (EngineEvent) -> Void = { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        Task {
            await engine.setEventHandler(handler)
            await engine.recoverAfterLaunch()
            await engine.start()
        }
        startWatching()
        store.applyRetention(settings.retention)
        Task { await refreshRooms(silent: true) }
        Task { await syncStatuses(force: true) }

        timers.append(Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.syncStatuses(force: false) }
        })
        timers.append(Timer.scheduledTimer(withTimeInterval: 86_400, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.refreshRooms(silent: true)
                self.store.applyRetention(self.settings.retention)
            }
        })
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                await self.engine.tick()
                await self.syncStatuses(force: false)
                self.detection.rescan()
            }
        }
        memoryMonitor.onChange = { [weak self] level in
            Task { @MainActor in
                self?.memoryPressure = level
                if level == .normal { await self?.engine.tick() }
            }
        }
        if store.health.readOnly { setPaused(true) }
        if !settings.onboardingCompleted {
            showOnboarding = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showMainWindow() }
        }
    }

    /// Screenshot/demo mode: processing paused, no network, no folder watching.
    private func startDemo(_ demo: String) {
        isPaused = true
        Task { await engine.setPaused(true) }
        progress = Dictionary(uniqueKeysWithValues: activeJobs.map { ($0.job.id, JobProgress(fraction: 0.42, message: "Transcribing (part 1 of 2)")) })
        switch demo {
        case "history", "regenerate": sidebar = .history; demoReviewDraft = demo == "regenerate"; selectedLessonId = lessons.first { $0.jobs.first?.remoteStatus == .published }?.id
        case "students": sidebar = .students; demoSelectFirstStudent = true
        case "settings": sidebar = .settings; settingsTab = 1
        case "usage": sidebar = .usage
        case "onboarding": showOnboarding = true
        default: sidebar = .dashboard
        }
        if let look = ProcessInfo.processInfo.environment["LESSONNOTES_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: look == "dark" ? .darkAqua : .aqua)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.showMainWindow()
            if demo == "review", let d = self.detections.first { self.openDetection(folderPath: d.folderPath) }
        }
        // Screenshot helper: size the main window and publish its frame so CI can crop to it.
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in DemoData.layoutAndPublishWindowFrame() }
        }
    }

    private func scheduleReload() {
        guard !reloadScheduled else { return }
        reloadScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.reloadScheduled = false
            self?.reload()
        }
    }

    func reload() {
        lessons = store.allLessons.sorted { ($0.lessonDate, $0.createdAt) > ($1.lessonDate, $1.createdAt) }
        mappings = store.mappings.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        rooms = store.rooms
        let newSettings = store.settings
        if newSettings != settings { settings = newSettings }
        detections = store.detections.sorted { $0.detectedAt > $1.detectedAt }
        modelList = store.modelList
    }

    private func handle(_ event: EngineEvent) {
        switch event {
        case .progress(let id, let f, let m):
            progress[id] = JobProgress(fraction: f, message: m)
        case .submitted(let id):
            progress[id] = nil
            if settings.notifyOnSubmitted, let l = store.lesson(containingJob: id) {
                NotificationService.shared.notify(title: "Lesson notes submitted",
                                                  body: "\(l.pupilName), \(CoreFormat.longUKDate(l.lessonDate)) — waiting for approval on the website.",
                                                  lessonId: l.id)
            }
        case .failed(let id, let message):
            progress[id] = nil
            if let l = store.lesson(containingJob: id) {
                NotificationService.shared.notify(title: "Lesson notes need attention", body: "\(l.pupilName): \(message)", lessonId: l.id)
            }
        case .replaced(let id):
            progress[id] = nil
            if let l = store.lesson(containingJob: id) {
                NotificationService.shared.notify(title: "Lesson notes replaced",
                                                  body: "\(l.pupilName), \(CoreFormat.longUKDate(l.lessonDate)) — the new version is waiting for approval on the website.",
                                                  lessonId: l.id)
            }
        case .replacementNeedsAttention(let id, let message):
            progress[id] = nil
            if let l = store.lesson(containingJob: id) {
                NotificationService.shared.notify(title: "Replacing notes needs attention", body: "\(l.pupilName): \(message)", lessonId: l.id)
            }
        case .idle:
            break
        }
    }

    // MARK: Derived state

    var allJobs: [LessonJob] { lessons.flatMap { l in l.jobs.map { LessonJob(lesson: l, job: $0) } } }
    var activeJobs: [LessonJob] { allJobs.filter { $0.job.stage.isActive }.sorted { $0.job.createdAt < $1.job.createdAt } }
    var attentionJobs: [LessonJob] {
        allJobs.filter { $0.job.stage == .failed || ($0.job.replacement.map { $0.state != .queued } ?? false) }
    }
    var heldJobs: [LessonJob] { allJobs.filter { $0.job.stage == .held } }
    var isBusy: Bool { !activeJobs.isEmpty }

    var transcriptionModelName: String? {
        if !settings.transcriptionModel.isEmpty, whisper.downloaded[settings.transcriptionModel] != nil { return settings.transcriptionModel }
        return whisper.downloaded.keys.sorted().first
    }

    var isDemo: Bool { DemoData.mode != nil }

    var setupIssues: [String] {
        if isDemo { return [] }
        var issues: [String] = []
        if !hasWebsiteKey { issues.append("Add your Let's Meet website API key") }
        if !hasOpenAIKey { issues.append("Add your OpenAI API key") }
        if settings.openAIModel.isEmpty { issues.append("Choose an OpenAI model") }
        if transcriptionModelName == nil { issues.append("Download a transcription model") }
        if settings.zoomFolderBookmark == nil { issues.append("Choose your Zoom recordings folder") }
        if mappings.isEmpty { issues.append("Add your students") }
        return issues
    }

    func lesson(_ id: UUID?) -> Lesson? { guard let id else { return nil }; return lessons.first { $0.id == id } }

    // MARK: Settings & keys

    func updateSettings(_ body: (inout AppSettings) -> Void) {
        store.updateSettings(body)
        settings = store.settings
    }

    func saveKey(_ value: String, account: KeychainStore.Account) -> String? {
        do {
            try KeychainStore.set(value, for: account)
            hasWebsiteKey = KeychainStore.get(.website) != nil
            hasOpenAIKey = KeychainStore.get(.openAI) != nil
            if account == .website { websiteTest = nil } else { openAITest = nil }
            Task { await engine.tick() }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func removeKey(_ account: KeychainStore.Account) {
        KeychainStore.delete(account)
        hasWebsiteKey = KeychainStore.get(.website) != nil
        hasOpenAIKey = KeychainStore.get(.openAI) != nil
    }

    func websiteClient() throws -> LetsMeetClient {
        try LetsMeetClient(baseURLString: settings.websiteBaseURL, apiKey: KeychainStore.get(.website) ?? "", transport: URLSessionTransport(timeout: 60))
    }

    func openAIClient() throws -> OpenAIClient {
        guard let key = KeychainStore.get(.openAI) else { throw OpenAIError.missingKey }
        var client = try OpenAIClient(apiKey: key, transport: URLSessionTransport(timeout: 120))
        client.usageMonitor = usageMonitor
        return client
    }

    func testWebsite() async {
        websiteTest = nil
        do {
            let ping = try await websiteClient().ping()
            websiteTest = ConnectionResult(ok: ping.ok, message: ping.ok ? "Connected (API version \(ping.apiVersion ?? 1))." : "The website did not confirm the connection.")
            if ping.ok { await refreshRooms(silent: true) }
        } catch {
            websiteTest = ConnectionResult(ok: false, message: error.localizedDescription)
        }
    }

    func refreshRooms(silent: Bool = false) async {
        guard hasWebsiteKey else { return }
        isRefreshingRooms = true
        defer { isRefreshingRooms = false }
        do {
            let rooms = try await websiteClient().rooms()
            store.setRooms(rooms)
            reload()
        } catch {
            if !silent { websiteTest = ConnectionResult(ok: false, message: "Could not load rooms: \(error.localizedDescription)") }
        }
    }

    func testOpenAIKey() async {
        openAITest = nil
        do {
            let models = try await openAIClient().listModels()
            store.updateModelList { $0.models = models; $0.fetchedAt = Date() }
            reload()
            openAITest = ConnectionResult(ok: true, message: "Key works — \(ModelCatalog.filterForNotes(models).count) text models available to your account.")
        } catch {
            openAITest = ConnectionResult(ok: false, message: error.localizedDescription)
        }
    }

    func refreshModels() async {
        isRefreshingModels = true
        modelsError = nil
        defer { isRefreshingModels = false }
        do {
            let models = try await openAIClient().listModels()
            store.updateModelList { $0.models = models; $0.fetchedAt = Date() }
            reload()
        } catch {
            modelsError = error.localizedDescription
        }
    }

    func testSelectedModel() async {
        let model = settings.openAIModel
        guard !model.isEmpty else { return }
        isTestingModel = true
        defer { isTestingModel = false }
        do {
            let client = try openAIClient()
            let effort = settings.reasoningEffort
            let v = await UsageContext.$current.withValue(UsageContext(lessonId: nil, jobId: nil, purpose: .modelTest)) {
                await ModelTester.run(client: client, model: model, effort: effort)
            }
            store.updateModelList { $0.verifications[model] = v }
        } catch {
            store.updateModelList {
                $0.verifications[model] = ModelVerification(modelId: model, testedAt: Date(), structuredOutputWorks: false,
                                                            reasoningEffortTested: settings.reasoningEffort, reasoningEffortAccepted: nil,
                                                            message: error.localizedDescription, elapsedSeconds: 0)
            }
        }
        reload()
    }

    // MARK: Zoom folder watching

    func chooseZoomFolder() {
        guard let url = FolderAccess.chooseFolder(title: "Choose your Zoom recordings folder", startingAt: settings.zoomFolderPath) else { return }
        do {
            let bm = try FolderAccess.bookmark(for: url)
            updateSettings { $0.zoomFolderBookmark = bm; $0.zoomFolderPath = url.path }
            startWatching()
        } catch {
            watchError = "Could not save access to that folder: \(error.localizedDescription)"
        }
    }

    func startWatching() {
        watcher?.stop()
        watcher = nil
        watchedFolderURL?.stopAccessingSecurityScopedResource()
        watchedFolderURL = nil
        watchError = nil
        guard let bm = settings.zoomFolderBookmark else { return }
        guard let resolved = FolderAccess.resolve(bm) else {
            watchError = "Lesson Notes lost access to the Zoom folder. Choose it again in Settings."
            return
        }
        watchedFolderURL = resolved.url
        if resolved.stale, let fresh = try? FolderAccess.bookmark(for: resolved.url) {
            updateSettings { $0.zoomFolderBookmark = fresh }
        }
        guard settings.watchFolder else { detection.stop(); return }
        let w = FolderWatcher(path: resolved.url.path) { [weak self] paths in self?.detection.filesChanged(paths) }
        w.start()
        watcher = w
        detection.start(root: resolved.url)
    }

    var zoomFolderURL: URL? { watchedFolderURL }

    // MARK: Detections & review

    func openDetection(folderPath: String) {
        guard let d = store.detections.first(where: { $0.folderPath == folderPath }) else { showMainWindow(); return }
        let sessions = SessionGrouper.group(d.recordings, timeZone: settings.timeZone)
        guard let s = sessions.first else { return }
        showMainWindow()
        reviewRequest = ReviewRequest(session: s, fromDetection: true)
    }

    func dismissDetection(_ d: PendingDetection) {
        store.removeDetection(folderPath: d.folderPath)
        detection.markHandled(d.folderPath)
    }

    func review(_ session: ProposedSession) {
        reviewRequest = ReviewRequest(session: session, fromDetection: false)
    }

    /// Creates the lesson and queues it. Called by the confirmation sheet.
    func confirm(_ c: LessonConfirmation, remember: MatchContext?, createMappingName: String?) throws {
        if let remember {
            if let id = c.studentId, var m = store.mapping(id: id) {
                if MappingMatcher.applyRemember(remember, to: &m) { store.upsertMapping(m) }
            } else if let name = createMappingName {
                var m = StudentMapping(roomId: c.roomId, roomName: c.roomName, displayName: name)
                _ = MappingMatcher.applyRemember(remember, to: &m)
                store.upsertMapping(m)
            }
        }
        let lesson = try LessonFactory.make(c, settings: store.settings, held: !settings.autoProcessAfterConfirm)
        store.addLesson(lesson)
        store.removeDetection(folderPath: c.sourceFolder)
        detection.markHandled(c.sourceFolder)
        reload()
        Task { await engine.tick() }
    }

    // MARK: Jobs

    /// Fix & Retry: resumes from the last completed stage. If transcription would have to be
    /// repeated although a transcript was expected, George is told why and asked first.
    func retry(_ job: Job) {
        let plan = JobRecovery.retryPlan(for: job, transcriptState: store.transcriptState(jobId: job.id))
        if case .transcribe(let reason?) = plan {
            retryConfirmation = RetryConfirmation(job: job, pupil: store.lesson(containingJob: job.id)?.pupilName ?? "", reason: reason)
            return
        }
        Task { await engine.retry(jobId: job.id) }
    }

    func confirmRetry(_ c: RetryConfirmation) {
        retryConfirmation = nil
        Task { await engine.retry(jobId: c.job.id) }
    }

    var creditFailures: [LessonJob] { attentionJobs.filter { $0.job.error?.kind == .openAICredits } }

    /// Retries every job that failed because OpenAI credits ran out (each reuses its saved transcript).
    func retryAllCreditFailures() {
        for item in creditFailures { retry(item.job) }
    }
    func cancel(_ job: Job) { Task { await engine.cancel(jobId: job.id) } }
    func start(_ job: Job) { Task { await engine.startHeld(jobId: job.id) } }

    func reprocess(_ lesson: Lesson) {
        do {
            let copy = try LessonFactory.reprocess(lesson, settings: store.settings, held: !settings.autoProcessAfterConfirm)
            store.addLesson(copy)
            selectedLessonId = copy.id
            Task { await engine.tick() }
        } catch {
            banner = error.localizedDescription
        }
    }

    func deleteLocal(_ lesson: Lesson) {
        for j in lesson.jobs where j.stage.isActive { Task { await engine.cancel(jobId: j.id) } }
        store.deleteLesson(id: lesson.id)
        if selectedLessonId == lesson.id { selectedLessonId = nil }
        reload()
    }

    func deleteTranscript(_ job: Job) {
        store.deleteTranscript(jobId: job.id)
    }

    // MARK: Regeneration & replacement

    /// Generates a new draft from the saved transcript with the chosen prompt/model.
    /// Saved defaults are not changed.
    func regenerate(_ job: Job, options: RegenerationOptions, model: String, effort: ReasoningEffort,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> NoteVersion {
        guard let key = KeychainStore.get(.openAI) else { throw OpenAIError.missingKey }
        let m = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !m.isEmpty else { throw OpenAIError.modelUnavailable("Choose a model.") }
        let s = store.settings
        var client = try OpenAIClient(apiKey: key, transport: URLSessionTransport(timeout: 900))
        client.usageMonitor = usageMonitor
        let producer = OpenAINotesProducer(generator: NotesGenerator(performer: client, model: m, effort: effort,
                                                                     chunkThresholdTokens: s.chunkThresholdTokens, maxOutputTokens: s.maxOutputTokens))
        let v = try await NotesRegeneration.regenerate(store: store, jobId: job.id, options: options, producer: producer, progress: progress)
        reload()
        return v
    }

    func discardDraft(_ job: Job, _ version: NoteVersion) {
        NotesRegeneration.discard(store: store, jobId: job.id, versionId: version.id)
        reload()
    }

    @discardableResult
    func acceptDraft(_ job: Job, _ version: NoteVersion) throws -> NotesRegeneration.AcceptOutcome {
        let outcome = try NotesRegeneration.accept(store: store, jobId: job.id, versionId: version.id)
        reload()
        Task { await engine.tick() }
        return outcome
    }

    func replaceAnyway(_ job: Job) {
        NotesRegeneration.replaceAnyway(store: store, jobId: job.id)
        Task { await engine.tick() }
    }

    func keepWebsiteVersion(_ job: Job) {
        NotesRegeneration.keepWebsiteVersion(store: store, jobId: job.id)
    }

    func retryReplacement(_ job: Job) {
        NotesRegeneration.retryReplacement(store: store, jobId: job.id)
        Task { await engine.tick() }
    }

    func submitAsNewNote(_ job: Job) {
        do {
            let l = try NotesRegeneration.submitAsNewNote(store: store, jobId: job.id, held: !settings.autoProcessAfterConfirm)
            selectedLessonId = l.id
            reload()
            Task { await engine.tick() }
        } catch {
            banner = error.localizedDescription
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        Task { await engine.setPaused(paused) }
    }

    func syncStatuses(force: Bool) async {
        guard hasWebsiteKey, isOnline, !isSyncing else { return }
        let ids = StatusSync.dueSubmissionIds(lessons: store.allLessons, now: Date(), force: force)
        guard !ids.isEmpty else { lastSync = Date(); return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let results = try await websiteClient().statuses(of: ids)
            let changes = StatusSync.apply(results, store: store, now: Date())
            for c in changes where c.from != nil {
                NotificationService.shared.notify(title: "Lesson notes \(c.to.label.lowercased())", body: "\(c.pupilName)'s notes are now: \(c.to.label).")
            }
            lastSync = Date()
        } catch {
            appLog.error("Status sync failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Import

    func startImport(files: Bool) {
        let urls: [URL]
        if files { urls = FolderAccess.chooseRecordings() }
        else { urls = FolderAccess.chooseFolder(title: "Import a folder of Zoom recordings", startingAt: settings.zoomFolderPath).map { [$0] } ?? [] }
        guard !urls.isEmpty else { return }
        importRoots = urls
        showMainWindow()
        showImport = true
    }

    // MARK: Windows

    var openWindowAction: (() -> Void)?

    func showMainWindow() {
        NSApp.setActivationPolicy(.regular)
        openWindowAction?()
        NSApp.activate(ignoringOtherApps: true)
    }

    func openLesson(_ id: UUID) {
        sidebar = .history
        selectedLessonId = id
        showMainWindow()
    }
}
