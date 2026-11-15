import Foundation

/// File-based persistence in Application Support (`~/Library/Application Support/LessonNotes`
/// inside the sandbox container). Lessons and jobs live in `library.json`; transcripts are
/// stored one file per job so the index stays small. All writes are atomic.
public final class LibraryStore: @unchecked Sendable {
    public let directory: URL
    private let lock = NSRecursiveLock()
    private var lessons: [Lesson] = []
    private var mappingsStorage: [StudentMapping] = []
    private var roomsStorage = CachedRooms()
    private var modelsStorage = CachedModelList()
    private var settingsStorage = AppSettings()
    private var detectionsStorage: [PendingDetection] = []
    private var transcriptTextCache: [UUID: String] = [:]

    /// Called (on an arbitrary thread) after any change.
    public var onChange: (@Sendable () -> Void)?

    /// Current on-disk schema. 1 = versions 1.0/1.1, 2 = 1.2 (adds storage-info.json and stage recovery).
    public static let schemaVersion = 2

    /// What happened while opening the data folder (shown to George if anything went wrong).
    public struct StorageHealth: Equatable, Sendable {
        public var unreadableFiles: [String] = []
        public var backupPath: String?
        public var backupError: String?
        public var migrationError: String?
        public var migratedFromSchema: Int?
        public var recoveredJobs: Int = 0
        /// True when nothing may be written (data is protected after a problem).
        public var readOnly: Bool { !unreadableFiles.isEmpty || backupError != nil || migrationError != nil }
    }

    public private(set) var health = StorageHealth()
    /// Files that must never be overwritten in this session (unreadable or unverified).
    private var protectedFiles: Set<String> = []

    /// - Parameter appVersion: when set (the real app), the data folder is backed up before an
    ///   upgrade and migrated recoverably. Tests that only need a store pass nil.
    public init(directory: URL, appVersion: String? = nil, now: Date = Date()) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        load(appVersion: appVersion, now: now)
    }

    var transcriptsDir: URL { directory.appendingPathComponent("transcripts", isDirectory: true) }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: Load / save

    struct LibraryFile: Codable { var version: Int; var lessons: [Lesson] }

    struct StorageInfo: Codable {
        var schemaVersion: Int
        var lastAppVersion: String?
        var updatedAt: Date?
    }

    enum ReadResult<T> { case ok(T), missing, unreadable(String) }

    private func readStrict<T: Decodable>(_ type: T.Type, _ name: String) -> ReadResult<T> {
        guard FileManager.default.fileExists(atPath: file(name).path) else { return .missing }
        guard let data = try? Data(contentsOf: file(name)) else { return .unreadable("could not open the file") }
        do { return .ok(try JSONCoding.decoder().decode(T.self, from: data)) }
        catch { return .unreadable(String(describing: error)) }
    }

    /// Reads a file; if it exists but cannot be decoded, it is copied aside and protected from
    /// being overwritten, so a later save can never replace real data with empty data.
    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        switch readStrict(type, name) {
        case .ok(let v): return v
        case .missing: return nil
        case .unreadable:
            let copy = file(name + ".unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: file(name), to: copy)
            protectedFiles.insert(name)
            health.unreadableFiles.append(name)
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        if protectedFiles.contains(name) || protectedFiles.contains("*") {
            setWriteError("\(name) was not saved because the data folder is protected after a problem opening it.")
            return
        }
        let url = file(name)
        let job: () -> Void = { [weak self] in
            do {
                let data = try JSONCoding.encoder(pretty: false).encode(value)
                try data.write(to: url, options: [.atomic])
            } catch {
                // Disk errors are surfaced through `lastWriteError`.
                self?.setWriteError(error.localizedDescription)
            }
        }
        guard deferredWrites else { job(); return }
        // Saving is done off the caller's thread so the window never waits for a large library
        // to be encoded. Changes are coalesced: only the newest snapshot of each file is written.
        writeLock.lock()
        pendingWrites[name] = job
        let schedule = !writeScheduled
        writeScheduled = true
        writeLock.unlock()
        if schedule { writeQueue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.drainWrites() } }
    }

    private func drainWrites() {
        writeLock.lock()
        let jobs = pendingWrites
        pendingWrites = [:]
        writeScheduled = false
        writeLock.unlock()
        for (_, job) in jobs.sorted(by: { $0.key < $1.key }) { job() }
    }

    /// Writes any changes still waiting to be saved, and waits until they are on disk.
    public func flush() {
        guard deferredWrites else { return }
        writeQueue.sync { drainWrites() }
    }

    private func setWriteError(_ m: String) { writeLock.lock(); writeErrorStorage = m; writeLock.unlock() }
    public var lastWriteError: String? { writeLock.lock(); defer { writeLock.unlock() }; return writeErrorStorage }
    private var writeErrorStorage: String?

    /// When true (the app), files are saved on a background queue a moment after each change.
    /// Tests keep synchronous saving so every change is on disk immediately.
    public var deferredWrites = false
    private let writeQueue = DispatchQueue(label: "LessonNotes.LibraryStore.write", qos: .utility)
    private let writeLock = NSLock()
    private var pendingWrites: [String: () -> Void] = [:]
    private var writeScheduled = false

    public var backupsDirectory: URL { directory.appendingPathComponent("Backups", isDirectory: true) }

    private func load(appVersion: String?, now: Date) {
        let fm = FileManager.default
        let info: StorageInfo? = { if case .ok(let i) = readStrict(StorageInfo.self, "storage-info.json") { return i } else { return nil } }()
        let hasExistingData = fm.fileExists(atPath: file("library.json").path) || fm.fileExists(atPath: file("settings.json").path)
        let fromSchema = info?.schemaVersion ?? 1
        let upgrading = appVersion != nil && hasExistingData && (fromSchema < Self.schemaVersion || info?.lastAppVersion != appVersion)

        // 1–4. Back up everything (including transcripts of failed jobs) and verify the copy.
        if upgrading, let appVersion {
            do {
                let url = try StorageBackup.create(from: directory, label: "before-\(appVersion)", now: now)
                health.backupPath = url.path
            } catch {
                // Without a verified backup nothing is changed or written this session.
                health.backupError = error.localizedDescription
                protectedFiles.insert("*")
            }
        }

        switch readStrict(LibraryFile.self, "library.json") {
        case .ok(let lib): lessons = lib.lessons
        case .missing: lessons = []
        case .unreadable(let why):
            let copy = file("library.json.unreadable-\(Int(now.timeIntervalSince1970))")
            try? fm.copyItem(at: file("library.json"), to: copy)
            protectedFiles.insert("library.json")
            health.unreadableFiles.append("library.json")
            health.migrationError = "Your lesson history could not be read, so it has been left untouched (\(why.prefix(200)))."
            lessons = []
        }
        mappingsStorage = read([StudentMapping].self, "mappings.json") ?? []
        roomsStorage = read(CachedRooms.self, "rooms.json") ?? CachedRooms()
        modelsStorage = read(CachedModelList.self, "models.json") ?? CachedModelList()
        detectionsStorage = read([PendingDetection].self, "detections.json") ?? []
        if let s = read(AppSettings.self, "settings.json") { settingsStorage = s } else { write(settingsStorage, "settings.json") }
        // Upgrade: a global prompt that is exactly an earlier factory default was never
        // customised, so it moves to the new default. Customised prompts are left alone.
        if PromptLibrary.isLegacyDefault(settingsStorage.globalPrompt) {
            settingsStorage.globalPrompt = PromptLibrary.starterGlobalPrompt
            write(settingsStorage, "settings.json")
        }

        // 5–6. Recover job stages from the data actually on disk, write atomically, then verify.
        guard !protectedFiles.contains("library.json"), !protectedFiles.contains("*") else { return }
        let before = lessons
        var migrated = lessons
        let changes = JobRecovery.normalise(&migrated) { [self] id in transcriptStateUnlocked(id) }
        health.recoveredJobs = changes
        if changes > 0 || upgrading {
            lessons = migrated
            saveLibrary()
            let ok: Bool = {
                guard case .ok(let reread) = readStrict(LibraryFile.self, "library.json") else { return false }
                let ids = { (ls: [Lesson]) in Set(ls.flatMap { l in [l.id] + l.jobs.map(\.id) + l.recordings.map(\.id) }) }
                return reread.lessons.count == before.count && ids(reread.lessons) == ids(before)
            }()
            if !ok {
                // Put the original back (from memory, then the verified backup) and stop writing.
                lessons = before
                if let data = try? JSONCoding.encoder().encode(LibraryFile(version: 1, lessons: before)) { try? data.write(to: file("library.json"), options: [.atomic]) }
                if let b = health.backupPath, let data = try? Data(contentsOf: URL(fileURLWithPath: b).appendingPathComponent("library.json")) {
                    try? data.write(to: file("library.json"), options: [.atomic])
                }
                health.migrationError = "Updating the lesson history could not be verified, so the original was kept."
                protectedFiles.insert("library.json")
                return
            }
        }
        if upgrading { health.migratedFromSchema = fromSchema }
        if let appVersion, health.backupError == nil {
            write(StorageInfo(schemaVersion: Self.schemaVersion, lastAppVersion: appVersion, updatedAt: now), "storage-info.json")
        }
    }

    func transcriptStateUnlocked(_ jobId: UUID) -> TranscriptState {
        let url = transcriptURL(jobId)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else { return .corrupt("the file could not be opened") }
        guard let t = try? JSONCoding.decoder().decode(StoredTranscript.self, from: data) else { return .corrupt("the file is damaged") }
        if t.parts.flatMap(\.segments).allSatisfy({ TranscriptCleaner.clean($0.text).isEmpty }) { return .corrupt("the transcript is empty") }
        return .valid
    }

    /// Whether a usable transcript is saved for a job.
    public func transcriptState(jobId: UUID) -> TranscriptState { transcriptStateUnlocked(jobId) }

    /// Moves a damaged transcript aside (never deleted) before it is regenerated.
    public func quarantineTranscript(jobId: UUID, now: Date = Date()) {
        let url = transcriptURL(jobId)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let dest = transcriptsDir.appendingPathComponent(jobId.uuidString + ".damaged-\(Int(now.timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: url, to: dest)
    }

    private func changed() { onChange?() }

    private func saveLibrary() { write(LibraryFile(version: 1, lessons: lessons), "library.json") }

    // MARK: Settings

    public var settings: AppSettings {
        lock.lock(); defer { lock.unlock() }
        return settingsStorage
    }

    public func updateSettings(_ body: (inout AppSettings) -> Void) {
        lock.lock()
        body(&settingsStorage)
        write(settingsStorage, "settings.json")
        lock.unlock()
        changed()
    }

    // MARK: Rooms / mappings / models

    public var rooms: CachedRooms { lock.lock(); defer { lock.unlock() }; return roomsStorage }

    public func setRooms(_ rooms: [Room], at date: Date = Date()) {
        lock.lock()
        roomsStorage = CachedRooms(rooms: rooms, fetchedAt: date)
        write(roomsStorage, "rooms.json")
        // Keep the latest room names on mappings for offline display.
        for i in mappingsStorage.indices {
            if let n = rooms.first(where: { $0.roomId == mappingsStorage[i].roomId })?.name { mappingsStorage[i].roomName = n }
        }
        write(mappingsStorage, "mappings.json")
        lock.unlock()
        changed()
    }

    public var mappings: [StudentMapping] { lock.lock(); defer { lock.unlock() }; return mappingsStorage }

    public func mapping(id: UUID?) -> StudentMapping? {
        guard let id else { return nil }
        return mappings.first { $0.id == id }
    }

    public func upsertMapping(_ m: StudentMapping) {
        lock.lock()
        if let i = mappingsStorage.firstIndex(where: { $0.id == m.id }) { mappingsStorage[i] = m } else { mappingsStorage.append(m) }
        write(mappingsStorage, "mappings.json")
        lock.unlock()
        changed()
    }

    public func deleteMapping(id: UUID) {
        lock.lock()
        mappingsStorage.removeAll { $0.id == id }
        write(mappingsStorage, "mappings.json")
        lock.unlock()
        changed()
    }

    public var modelList: CachedModelList { lock.lock(); defer { lock.unlock() }; return modelsStorage }

    public func updateModelList(_ body: (inout CachedModelList) -> Void) {
        lock.lock()
        body(&modelsStorage)
        write(modelsStorage, "models.json")
        lock.unlock()
        changed()
    }

    // MARK: Detections

    public var detections: [PendingDetection] { lock.lock(); defer { lock.unlock() }; return detectionsStorage }

    public func upsertDetection(_ d: PendingDetection) {
        lock.lock()
        if let i = detectionsStorage.firstIndex(where: { $0.folderPath == d.folderPath }) { detectionsStorage[i] = d } else { detectionsStorage.append(d) }
        write(detectionsStorage, "detections.json")
        lock.unlock()
        changed()
    }

    public func removeDetection(folderPath: String) {
        lock.lock()
        detectionsStorage.removeAll { $0.folderPath == folderPath }
        write(detectionsStorage, "detections.json")
        lock.unlock()
        changed()
    }

    // MARK: Lessons & jobs

    public var allLessons: [Lesson] { lock.lock(); defer { lock.unlock() }; return lessons }

    public func lesson(id: UUID) -> Lesson? { allLessons.first { $0.id == id } }

    public func lesson(containingJob jobId: UUID) -> Lesson? { allLessons.first { $0.jobs.contains { $0.id == jobId } } }

    public func job(id: UUID) -> Job? {
        for l in allLessons { if let j = l.jobs.first(where: { $0.id == id }) { return j } }
        return nil
    }

    public func addLesson(_ l: Lesson) {
        lock.lock()
        lessons.append(l)
        saveLibrary()
        lock.unlock()
        changed()
    }

    public func updateLesson(id: UUID, _ body: (inout Lesson) -> Void) {
        lock.lock()
        if let i = lessons.firstIndex(where: { $0.id == id }) {
            body(&lessons[i])
            saveLibrary()
        }
        lock.unlock()
        changed()
    }

    @discardableResult
    public func updateJob(id: UUID, now: Date = Date(), _ body: (inout Job) -> Void) -> Job? {
        lock.lock()
        var result: Job?
        outer: for li in lessons.indices {
            for ji in lessons[li].jobs.indices where lessons[li].jobs[ji].id == id {
                body(&lessons[li].jobs[ji])
                lessons[li].jobs[ji].updatedAt = now
                result = lessons[li].jobs[ji]
                break outer
            }
        }
        if result != nil { saveLibrary() }
        lock.unlock()
        if result != nil { changed() }
        return result
    }

    /// Deletes local data only (lesson, notes, transcripts). Website records are untouched.
    public func deleteLesson(id: UUID) {
        lock.lock()
        if let l = lessons.first(where: { $0.id == id }) {
            for j in l.jobs {
                deleteTranscriptFile(jobId: j.id)
                try? FileManager.default.removeItem(at: attachmentsDir.appendingPathComponent(j.id.uuidString, isDirectory: true))
            }
        }
        lessons.removeAll { $0.id == id }
        saveLibrary()
        lock.unlock()
        changed()
    }

    // MARK: Lesson files

    var attachmentsDir: URL { directory.appendingPathComponent("attachments", isDirectory: true) }

    public enum AttachmentError: Error, LocalizedError, Equatable {
        case notEditable
        case missing(String)
        case changed(String)
        public var errorDescription: String? {
            switch self {
            case .notEditable: return "Files can't be changed once the notes have been written or uploaded."
            case .missing(let n): return "The lesson file “\(n)” is missing from the app's storage. Remove it or add it again."
            case .changed(let n): return "The stored copy of “\(n)” has changed since it was added. Remove it and add it again."
            }
        }
    }

    public func attachmentURL(jobId: UUID, _ a: LessonAttachment) -> URL {
        attachmentsDir.appendingPathComponent(jobId.uuidString, isDirectory: true)
            .appendingPathComponent(a.id.uuidString, isDirectory: true)
            .appendingPathComponent(a.filename)
    }

    /// Copies a file into the app's storage and adds it to the job (call off the main thread).
    /// The original file is never changed.
    @discardableResult
    public func addAttachment(from source: URL, toJob jobId: UUID, role: AttachmentRole = .other, contextOnly: Bool = false,
                              now: Date = Date()) throws -> LessonAttachment {
        guard let job = job(id: jobId) else { throw AttachmentError.notEditable }
        if !contextOnly && !job.attachmentsEditable { throw AttachmentError.notEditable }
        if countFor(job, contextOnly) >= AttachmentRules.maxFiles { throw AttachmentRules.Problem.tooMany }
        let name = AttachmentRules.sanitisedFilename(source.lastPathComponent)
        let size = (try? FileManager.default.attributesOfItem(atPath: source.path)[.size] as? NSNumber)?.intValue ?? 0
        if let p = AttachmentRules.check(filename: name, byteCount: size) { throw p }
        let data = try Data(contentsOf: source)
        if let p = AttachmentRules.check(filename: name, byteCount: data.count) { throw p }
        let a = LessonAttachment(filename: name, byteCount: data.count, sha256: SHA256Hasher.hex(of: data), role: role,
                                 contextOnly: contextOnly, addedAt: now)
        let url = attachmentURL(jobId: jobId, a)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
        var added = false
        var problem: Error?
        let newId = contextOnly ? nil : freshSubmissionId(jobId)
        updateJob(id: jobId, now: now) { j in
            guard contextOnly || j.attachmentsEditable else { problem = AttachmentError.notEditable; return }
            guard countFor(j, contextOnly) < AttachmentRules.maxFiles else { problem = AttachmentRules.Problem.tooMany; return }
            j.attachments = (j.attachments ?? []) + [a]
            Self.filesChanged(&j, uploadsChanged: !contextOnly, newSubmissionId: newId)
            added = true
        }
        if !added {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            throw problem ?? AttachmentError.notEditable
        }
        return a
    }

    public func removeAttachment(jobId: UUID, id: UUID) throws {
        guard let job = job(id: jobId), let a = job.attachments?.first(where: { $0.id == id }) else { return }
        guard a.contextOnly || job.attachmentsEditable else { throw AttachmentError.notEditable }
        let newId = a.contextOnly ? nil : freshSubmissionId(jobId)
        updateJob(id: jobId) { j in
            j.attachments?.removeAll { $0.id == id }
            Self.filesChanged(&j, uploadsChanged: !a.contextOnly, newSubmissionId: newId)
        }
        try? FileManager.default.removeItem(at: attachmentURL(jobId: jobId, a).deletingLastPathComponent())
    }

    /// The file's type only affects what OpenAI is told, so it can be changed at any time.
    public func setAttachmentRole(jobId: UUID, id: UUID, role: AttachmentRole) {
        updateJob(id: jobId) { j in
            if let i = j.attachments?.firstIndex(where: { $0.id == id }), j.attachments?[i].role != role {
                j.attachments?[i].role = role
                Self.filesChanged(&j, uploadsChanged: false, newSubmissionId: nil)
            }
            if let i = j.submittedAttachments?.firstIndex(where: { $0.id == id }) { j.submittedAttachments?[i].role = role }
        }
    }

    /// Whether OpenAI sees the file; it is uploaded for the pupil either way. Can change at any time.
    public func setAttachmentIncluded(jobId: UUID, id: UUID, included: Bool) {
        updateJob(id: jobId) { j in
            if let i = j.attachments?.firstIndex(where: { $0.id == id }), j.attachments?[i].includeInContext != included {
                j.attachments?[i].includeInContext = included
                Self.filesChanged(&j, uploadsChanged: false, newSubmissionId: nil)
            }
            if let i = j.submittedAttachments?.firstIndex(where: { $0.id == id }) { j.submittedAttachments?[i].includeInContext = included }
        }
    }

    private func countFor(_ j: Job, _ contextOnly: Bool) -> Int {
        (j.attachments ?? []).filter { $0.contextOnly == contextOnly }.count
    }

    /// A new submission id for a job whose prepared upload is discarded.
    func freshSubmissionId(_ jobId: UUID) -> String? {
        guard let l = lesson(containingJob: jobId), let j = l.jobs.first(where: { $0.id == jobId }), j.submissionPayload != nil else { return nil }
        let start = l.recordings(for: j).first?.recordedAt ?? l.startedAt
        return SubmissionID.make(installId: settings.installId, lessonDate: l.lessonDate, startedAt: start, timeZone: l.timeZone, partLetter: j.partLetter)
    }

    /// After a file change: a prepared (frozen) upload is discarded and a new submission id is
    /// used, because the website treats the same id with different files as a conflict.
    static func filesChanged(_ j: inout Job, uploadsChanged: Bool, newSubmissionId: String?) {
        if uploadsChanged, j.stage != .submitted, j.submissionPayload != nil {
            j.submissionPayload = nil
            j.submittedAttachments = nil
            if let id = newSubmissionId { j.submissionId = id }
        }
        if j.notes != nil { j.filesChangedSinceNotes = true }
    }

    /// The stored bytes, checked against the SHA-256 recorded when the file was added.
    public func attachmentData(jobId: UUID, _ a: LessonAttachment) throws -> Data {
        guard let d = try? Data(contentsOf: attachmentURL(jobId: jobId, a)) else { throw AttachmentError.missing(a.filename) }
        guard SHA256Hasher.hex(of: d) == a.sha256 else { throw AttachmentError.changed(a.filename) }
        return d
    }

    // MARK: Transcripts

    func transcriptURL(_ jobId: UUID) -> URL { transcriptsDir.appendingPathComponent(jobId.uuidString + ".json") }

    public func saveTranscript(_ t: StoredTranscript) throws {
        let data = try JSONCoding.encoder().encode(t)
        try data.write(to: transcriptURL(t.jobId), options: [.atomic])
        lock.lock(); transcriptTextCache[t.jobId] = nil; lock.unlock()
        updateJob(id: t.jobId) { $0.hasTranscript = true; $0.transcriptPurgedAt = nil; $0.transcriptionModel = t.model }
    }

    public func transcript(jobId: UUID) -> StoredTranscript? {
        guard let data = try? Data(contentsOf: transcriptURL(jobId)) else { return nil }
        return try? JSONCoding.decoder().decode(StoredTranscript.self, from: data)
    }

    public func transcriptExists(jobId: UUID) -> Bool { FileManager.default.fileExists(atPath: transcriptURL(jobId).path) }

    /// True when a valid, readable transcript is saved (the flag alone is not trusted).
    public func hasUsableTranscript(jobId: UUID) -> Bool { transcriptStateUnlocked(jobId) == .valid }

    private func deleteTranscriptFile(jobId: UUID) {
        try? FileManager.default.removeItem(at: transcriptURL(jobId))
        transcriptTextCache[jobId] = nil
    }

    public func deleteTranscript(jobId: UUID, now: Date = Date()) {
        lock.lock(); deleteTranscriptFile(jobId: jobId); lock.unlock()
        updateJob(id: jobId, now: now) { $0.hasTranscript = false; $0.transcriptPurgedAt = now }
    }

    /// Lower-cased transcript text for searching (cached, loaded lazily).
    public func searchableTranscript(jobId: UUID) -> String {
        lock.lock()
        if let c = transcriptTextCache[jobId] { lock.unlock(); return c }
        lock.unlock()
        let text = transcript(jobId: jobId).map { $0.parts.flatMap { $0.segments.map(\.text) }.joined(separator: " ").lowercased() } ?? ""
        lock.lock(); transcriptTextCache[jobId] = text; lock.unlock()
        return text
    }

    // MARK: Duplicates

    public struct PreviousProcessing: Equatable, Sendable {
        public var lessonId: UUID
        public var pupilName: String
        public var processedAt: Date
        public var status: String
        public var filename: String
    }

    /// Earlier lessons that used a recording with this SHA-256.
    public func previousProcessing(sha256: String) -> [PreviousProcessing] {
        allLessons.compactMap { l in
            guard let rec = l.recordings.first(where: { $0.sha256 == sha256 }) else { return nil }
            let jobs = l.jobs.filter { $0.recordingIds.contains(rec.id) }
            let status = jobs.map(\.displayStatus).first ?? "Unknown"
            return PreviousProcessing(lessonId: l.id, pupilName: l.pupilName, processedAt: l.createdAt, status: status, filename: rec.filename)
        }
    }

    // MARK: Retention

    /// Deletes local transcripts older than the retention period. Returns the number purged.
    @discardableResult
    public func applyRetention(_ period: RetentionPeriod, now: Date = Date()) -> Int {
        guard let interval = period.interval else { return 0 }
        var purged = 0
        for l in allLessons {
            for j in l.jobs where j.hasTranscript {
                // Never purge a transcript that still has to be uploaded (failed / needs attention / in progress).
                guard j.stage == .submitted || j.stage == .cancelled else { continue }
                let saved = transcript(jobId: j.id)?.savedAt ?? j.createdAt
                if now.timeIntervalSince(saved) > interval {
                    deleteTranscript(jobId: j.id, now: now)
                    purged += 1
                }
            }
        }
        return purged
    }
}
