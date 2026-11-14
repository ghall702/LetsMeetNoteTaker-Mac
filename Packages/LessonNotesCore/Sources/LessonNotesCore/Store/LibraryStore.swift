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

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)
        load()
    }

    var transcriptsDir: URL { directory.appendingPathComponent("transcripts", isDirectory: true) }
    func file(_ name: String) -> URL { directory.appendingPathComponent(name) }

    // MARK: Load / save

    private struct LibraryFile: Codable { var version: Int; var lessons: [Lesson] }

    private func read<T: Decodable>(_ type: T.Type, _ name: String) -> T? {
        guard let data = try? Data(contentsOf: file(name)) else { return nil }
        do { return try JSONCoding.decoder().decode(T.self, from: data) }
        catch {
            // Keep a copy of an unreadable file rather than silently overwriting it.
            let backup = file(name + ".unreadable-\(Int(Date().timeIntervalSince1970))")
            try? FileManager.default.copyItem(at: file(name), to: backup)
            return nil
        }
    }

    private func write<T: Encodable>(_ value: T, _ name: String) {
        do {
            let data = try JSONCoding.encoder(pretty: false).encode(value)
            try data.write(to: file(name), options: [.atomic])
        } catch {
            // Disk errors are surfaced through `lastWriteError`.
            lastWriteError = error.localizedDescription
        }
    }

    public private(set) var lastWriteError: String?

    private func load() {
        lessons = read(LibraryFile.self, "library.json")?.lessons ?? []
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
            for j in l.jobs { deleteTranscriptFile(jobId: j.id) }
        }
        lessons.removeAll { $0.id == id }
        saveLibrary()
        lock.unlock()
        changed()
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
