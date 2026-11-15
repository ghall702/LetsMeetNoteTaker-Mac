import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Dependencies (the app provides AVFoundation merging and URLSession uploads)

public struct SourceFile: Sendable, Equatable {
    public var exists: Bool
    public var size: Int64
    public init(exists: Bool, size: Int64) { self.exists = exists; self.size = size }
}

public struct MergedVideo: Sendable, Equatable {
    public var size: Int64
    public var durationSec: Int
    public init(size: Int64, durationSec: Int) { self.size = size; self.durationSec = durationSec }
}

public protocol VideoMediaProviding: Sendable {
    /// Whether a recording can be read, and its size (without reading it).
    func sourceInfo(_ rec: RecordingRef) async -> SourceFile
    /// Joins the recordings, in this order, into one MP4 at `output` (lossless where possible),
    /// validates it and returns its size and duration. The originals are only read.
    func merge(_ recs: [RecordingRef], to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MergedVideo
    /// Re-checks a merged MP4 left by an earlier run (nil = missing or not valid).
    func validateMerged(_ url: URL) async -> MergedVideo?
    /// Runs `body` with read access to a recording (security-scoped bookmark or path).
    func withAccess(bookmark: Data?, path: String, _ body: @Sendable (URL) async throws -> Void) async throws
}

public enum SignedUploadError: Error, Equatable, LocalizedError {
    case expired          // 403: the signed URL expired
    case incomplete       // 400 upload_incomplete: connection dropped
    case tooLarge         // 413: larger than the declared size
    case http(Int)
    case network(String)
    public var errorDescription: String? {
        switch self {
        case .expired: return "The upload link expired."
        case .incomplete: return "The upload was interrupted."
        case .tooLarge: return "The media server rejected the file as larger than declared."
        case .http(let c): return "The media server returned HTTP \(c)."
        case .network(let m): return m
        }
    }
}

/// Streams a file to a signed URL (PUT, raw body, Content-Length) without loading it into memory.
public protocol SignedUploading: Sendable {
    func upload(file: URL, size: Int64, to target: SignedUpload, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws
}

public struct VideoDependencies: Sendable {
    public var makeAPI: @Sendable () throws -> RecordingsAPI
    public var media: VideoMediaProviding
    public var uploader: SignedUploading
    public var isOnline: @Sendable () -> Bool
    /// Folder for merged MP4s.
    public var videosDirectory: @Sendable () -> URL
    public init(makeAPI: @escaping @Sendable () throws -> RecordingsAPI, media: VideoMediaProviding, uploader: SignedUploading,
                isOnline: @escaping @Sendable () -> Bool, videosDirectory: @escaping @Sendable () -> URL) {
        self.makeAPI = makeAPI; self.media = media; self.uploader = uploader; self.isOnline = isOnline; self.videosDirectory = videosDirectory
    }
}

public enum VideoEvent: Sendable, Equatable {
    case progress(jobId: UUID, message: String, fraction: Double, sentBytes: Int64, totalBytes: Int64)
    case finished(jobId: UUID)
    case needsAttention(jobId: UUID, message: String)
    case probeProgress(done: Int, total: Int)
    case idle
}

// MARK: - Queue helpers

public enum VideoQueue {
    public static let videoExtensions: Set<String> = ["mp4"]

    /// Builds the upload state for a submitted job (single, combined or one part of separate).
    public static func makeState(lesson: Lesson, job: Job, origin: VideoUploadState.Origin, now: Date, generation: Int = 1) -> VideoUploadState {
        let recs = lesson.recordings(for: job)
        let partSuffix = lesson.jobs.count > 1 ? " (part \(job.partLetter))" : ""
        let filename: String
        if recs.count == 1 {
            let f = recs[0].filename
            filename = videoExtensions.contains((f as NSString).pathExtension.lowercased()) ? f : ((f as NSString).deletingPathExtension + ".mp4")
        } else {
            filename = AttachmentRules.sanitisedFilename("\(lesson.lessonDate) \(lesson.roomName)\(partSuffix) combined.mp4")
        }
        var s = VideoUploadState(origin: origin, uploadId: VideoUploadState.uploadId(for: job.id, generation: generation),
                                 noteId: job.noteId ?? job.videoProbe?.noteId, sourceRecordingIds: recs.map(\.id),
                                 originalFilename: filename, title: "Lesson recording" + partSuffix, now: now)
        // Anything other than one .mp4 is processed into a single MP4 first.
        s.needsMerge = recs.count > 1 || !videoExtensions.contains((recs.first?.filename as NSString?)?.pathExtension.lowercased() ?? "")
        return s
    }

    public static func mergedFilename(for jobId: UUID) -> String { "merged-\(jobId.uuidString.lowercased()).mp4" }

    /// Merged MP4s in the folder that no queued or failed video still needs.
    public static func leftoverMergedFiles(store: LibraryStore, directory: URL) -> [URL] {
        let needed = Set(store.allLessons.flatMap(\.jobs).compactMap { j -> String? in
            guard let v = j.video, v.stage != .ready, v.stage != .skipped, v.stage != .deleted else { return nil }
            return v.mergedFilename
        })
        let items = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return items.filter { $0.hasPrefix("merged-") && !needed.contains($0) }.map { directory.appendingPathComponent($0) }
    }
}

// MARK: - Engine

/// Persistent video upload queue: note id → existing-video check → merge (combined) → register →
/// streaming PUT → complete. Every step is recorded so a restart resumes where it stopped; the
/// stable `upload_id` makes registering safe to repeat. Separate from `JobEngine`.
public actor VideoUploadEngine {
    let store: LibraryStore
    let deps: VideoDependencies
    let now: @Sendable () -> Date
    var running: [UUID: Task<Void, Never>] = [:]
    var signed: [UUID: SignedUpload] = [:]
    var replaceSigned: [UUID: SignedUpload] = [:]
    var eventHandler: (@Sendable (VideoEvent) -> Void)?
    var probeTask: Task<Void, Never>?
    let probePacing: TimeInterval

    /// Retry delays from the API guidance: 30 s, 1 min, 5 min, 15 min, 30 min, then hourly.
    public static let retryDelays: [TimeInterval] = [30, 60, 300, 900, 1800, 3600]

    public init(store: LibraryStore, deps: VideoDependencies, now: @escaping @Sendable () -> Date = { Date() }, probePacing: TimeInterval = 1.1) {
        self.store = store
        self.deps = deps
        self.now = now
        self.probePacing = probePacing
    }

    public func setEventHandler(_ h: (@Sendable (VideoEvent) -> Void)?) { eventHandler = h }
    func emit(_ e: VideoEvent) { eventHandler?(e) }

    var settings: VideoSettings { store.settings.video }

    // MARK: Scheduling

    public func tick() {
        let s = settings
        let t = now()
        if s.autoUpload, let since = s.automaticSince { autoQueue(since: since, now: t) }
        guard !s.paused, deps.isOnline() else { return }
        let limit = max(1, min(3, s.maxConcurrentUploads))
        let due = store.allLessons.flatMap(\.jobs).filter { j in
            guard running[j.id] == nil, let v = j.video else { return false }
            if v.stage.isActive { return (v.nextAttemptAt ?? .distantPast) <= t }
            if v.stage == .ready, let r = v.replacement, r.stage != .failed { return (r.nextAttemptAt ?? .distantPast) <= t }
            return false
        }.sorted { ($0.video?.createdAt ?? .distantPast) < ($1.video?.createdAt ?? .distantPast) }
        for j in due where running.count < limit {
            let id = j.id
            running[id] = Task { [weak self] in
                await self?.process(jobId: id)
                await self?.finished(id)
            }
        }
    }

    func finished(_ id: UUID) {
        running[id] = nil
        tick()
        if running.isEmpty { emit(.idle) }
    }

    public func runUntilIdle() async {
        tick()
        while let (_, task) = running.first {
            await task.value
            tick()
        }
        await probeTask?.value
    }

    /// New lessons submitted after video uploads were turned on are queued automatically.
    func autoQueue(since: Date, now t: Date) {
        for l in store.allLessons {
            for j in l.jobs where j.stage == .submitted && j.video == nil && j.remoteStatus != .deleted {
                guard let at = j.submittedAt, at >= since else { continue }
                let state = VideoQueue.makeState(lesson: l, job: j, origin: .automatic, now: t)
                store.updateJob(id: j.id, now: t) { if $0.video == nil { $0.video = state } }
            }
        }
    }

    // MARK: Public actions

    /// Queues one job (manual upload or a backfill item). Existing states are kept.
    public func enqueue(jobIds: [UUID], origin: VideoUploadState.Origin) {
        let t = now()
        for id in jobIds {
            guard let l = store.lesson(containingJob: id), let j = l.jobs.first(where: { $0.id == id }), j.stage == .submitted, j.video == nil else { continue }
            let state = VideoQueue.makeState(lesson: l, job: j, origin: origin, now: t)
            store.updateJob(id: id, now: t) { if $0.video == nil { $0.video = state } }
        }
        tick()
    }

    /// Retry after a failure: resumes from the step that failed (nothing completed is redone).
    public func retry(jobId: UUID) {
        store.updateJob(id: jobId, now: now()) { j in
            guard var v = j.video else { return }
            if v.stage == .failed { v.stage = v.resumeStage ?? .queued }
            if v.replacement?.stage == .failed { v.replacement?.stage = .registering; v.replacement?.lastError = nil; v.replacement?.attempts = 0; v.replacement?.nextAttemptAt = nil }
            v.attempts = 0; v.firstRetryAt = nil; v.nextAttemptAt = nil; v.lastError = nil; v.errorKind = nil
            j.video = v
        }
        tick()
    }

    /// Upload again after the remote recording was deleted (new upload id).
    public func uploadAgain(jobId: UUID) {
        guard let l = store.lesson(containingJob: jobId), let j = l.jobs.first(where: { $0.id == jobId }) else { return }
        let gen = (j.video?.generation ?? 1) + 1
        var s = VideoQueue.makeState(lesson: l, job: j, origin: .manual, now: now(), generation: gen)
        s.generation = gen
        store.updateJob(id: jobId, now: now()) { $0.video = s }
        tick()
    }

    public func cancel(jobId: UUID) {
        running[jobId]?.cancel()
        store.updateJob(id: jobId, now: now()) { j in
            guard var v = j.video, v.stage.isActive else { return }
            v.resumeStage = v.stage
            v.stage = .failed
            v.lastError = "Stopped by you."
            v.errorKind = .other
            j.video = v
        }
    }

    /// Deletes the remote recording (DELETE /recordings/{id}). Local recordings are never touched.
    @discardableResult
    public func deleteRemote(jobId: UUID) async throws -> Bool {
        guard let v = store.job(id: jobId)?.video, let rid = v.recordingId else { return false }
        running[jobId]?.cancel()
        let api = try deps.makeAPI()
        let (rec, done) = try await api.deleteRecording(id: rid)
        store.updateJob(id: jobId, now: now()) { j in
            j.video?.stage = .deleted
            j.video?.deletePending = !done
            j.video?.remoteStatus = rec?.status ?? (done ? "deleted" : "delete_pending")
            j.video?.replacement = nil
        }
        return done
    }

    /// Queues replacing the uploaded video with another MP4.
    public func replace(jobId: UUID, filename: String, path: String, bookmark: Data?, size: Int64, durationSec: Int?) throws {
        guard let v = store.job(id: jobId)?.video, v.stage == .ready, v.recordingId != nil else { throw VideoActionError.notUploaded }
        guard size > 0, size <= VideoLimits.maxBytes else { throw VideoActionError.tooLarge }
        let r = VideoReplacement(filename: AttachmentRules.sanitisedFilename(filename), path: path, bookmark: bookmark, fileSize: size, durationSec: durationSec, now: now())
        store.updateJob(id: jobId, now: now()) { $0.video?.replacement = r }
        tick()
    }

    public func cancelReplacement(jobId: UUID) {
        running[jobId]?.cancel()
        store.updateJob(id: jobId, now: now()) { $0.video?.replacement = nil }
    }

    // MARK: Website check for historical notes (read-only, paced for the rate limit)

    public func probe(jobIds: [UUID]) {
        guard probeTask == nil else { return }
        probeTask = Task { [weak self] in
            await self?.runProbe(jobIds)
            await self?.probeFinished()
        }
    }
    func probeFinished() { probeTask = nil }
    public var isProbing: Bool { probeTask != nil }

    func runProbe(_ ids: [UUID]) async {
        guard let api = try? deps.makeAPI() else { return }
        for (i, id) in ids.enumerated() {
            if Task.isCancelled { return }
            guard let j = store.job(id: id) else { continue }
            var p = VideoProbe(checkedAt: now(), noteId: j.noteId)
            do {
                if p.noteId == nil {
                    let st = try await api.noteStatus(j.submissionId)
                    if st.status == .deleted { p.noteDeleted = true } else { p.noteId = st.noteId }
                    try await pace()
                }
                if let nid = p.noteId, !p.noteDeleted {
                    let recs = try await api.recordings(noteId: nid).filter { !$0.isGone }
                    let best = recs.first(where: \.isReady) ?? recs.first
                    p.existingRecordingId = best?.recordingId
                    p.existingStatus = best?.status
                }
            } catch let e as LetsMeetAPIError where e.httpStatus == 404 {
                p.noteDeleted = true
            } catch let e as LetsMeetAPIError where e.httpStatus == 429 {
                try? await Task.sleep(nanoseconds: UInt64((e.retryAfter ?? 30) * 1_000_000_000))
                p.error = e.message
            } catch {
                p.error = error.localizedDescription
            }
            let probe = p
            store.updateJob(id: id, now: now()) { $0.videoProbe = probe }
            emit(.probeProgress(done: i + 1, total: ids.count))
            try? await pace()
        }
    }

    func pace() async throws {
        if probePacing > 0 { try await Task.sleep(nanoseconds: UInt64(probePacing * 1_000_000_000)) }
    }

    // MARK: Pipeline

    func state(_ id: UUID) -> (Lesson, Job, VideoUploadState)? {
        guard let l = store.lesson(containingJob: id), let j = l.jobs.first(where: { $0.id == id }), let v = j.video else { return nil }
        return (l, j, v)
    }

    func update(_ id: UUID, _ body: (inout VideoUploadState) -> Void) {
        let t = now()
        store.updateJob(id: id, now: t) { j in
            guard var v = j.video else { return }
            body(&v)
            v.updatedAt = t
            j.video = v
        }
    }

    func process(jobId: UUID) async {
        var expiredRenewals = 0
        while !Task.isCancelled {
            guard !settings.paused, let (lesson, job, v) = state(jobId) else { return }
            if v.stage == .ready {
                if v.replacement != nil { await processReplacement(jobId: jobId) }
                return
            }
            guard v.stage.isActive else { return }
            do {
                let api = try deps.makeAPI()
                switch v.stage {
                case .queued:
                    if try await prepare(jobId, lesson: lesson, job: job, v: v, api: api) == false { return }
                case .merging:
                    try await mergeStage(jobId, lesson: lesson, job: job, v: v)
                case .registering:
                    try await registerStage(jobId, v: v, api: api)
                case .uploading:
                    guard let target = signed[jobId] else { update(jobId) { $0.stage = .registering }; continue }
                    do {
                        try await uploadStage(jobId, lesson: lesson, job: job, v: v, target: target)
                    } catch SignedUploadError.expired where expiredRenewals < 2 {
                        // Expired link: register again with the same upload_id for a fresh one.
                        expiredRenewals += 1
                        signed[jobId] = nil
                        update(jobId) { $0.stage = .registering }
                    }
                case .completing:
                    try await completeStage(jobId, v: v, api: api)
                default:
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                handle(jobId, error: error)
                return
            }
        }
    }

    /// Note id, existing remote video and source files. Returns false when finished here.
    func prepare(_ id: UUID, lesson: Lesson, job: Job, v: VideoUploadState, api: RecordingsAPI) async throws -> Bool {
        var noteId = v.noteId ?? job.noteId
        if noteId == nil {
            emit(.progress(jobId: id, message: "Finding the note on LetsMeet", fraction: 0, sentBytes: 0, totalBytes: 0))
            let st = try await api.noteStatus(job.submissionId)
            if st.status == .deleted { finish(id, skipped: "This note has been deleted on LetsMeet.", kind: .noteDeleted); return false }
            guard let n = st.noteId else {
                fail(id, "LetsMeet did not return a note id for this lesson, so the video can't be attached.", kind: .noteMissing, resume: .queued)
                return false
            }
            noteId = n
        }
        let resolved = noteId!
        update(id) { $0.noteId = resolved; $0.lastCompletedStage = $0.lastCompletedStage ?? "resolved" }
        if !v.checkedExisting {
            let recs = try await api.recordings(noteId: resolved).filter { !$0.isGone }
            if let mine = recs.first(where: { $0.uploadId == v.uploadId }) {
                update(id) { $0.recordingId = mine.recordingId; $0.remoteStatus = mine.status }
                if mine.isReady { markReady(id, adopted: false); return false }
            } else if let existing = recs.first(where: \.isReady) {
                // Already has a video on LetsMeet: nothing to upload.
                update(id) { $0.recordingId = existing.recordingId; $0.remoteStatus = existing.status }
                markReady(id, adopted: true)
                return false
            }
            update(id) { $0.checkedExisting = true; $0.lastCompletedStage = "checked" }
        }
        let recs = lesson.recordings(for: job).filter { v.sourceRecordingIds.contains($0.id) }
        var missing: [String] = []
        var total: Int64 = 0
        for r in recs {
            let info = await deps.media.sourceInfo(r)
            if !info.exists { missing.append(r.filename) }
            total += info.size
        }
        if recs.count != v.sourceRecordingIds.count || !missing.isEmpty {
            fail(id, "Original recording\(missing.count == 1 ? "" : "s") not found: \(missing.joined(separator: ", ")). Reconnect the drive or folder, then Retry.",
                 kind: .recordingsMissing, resume: .queued)
            return false
        }
        if v.needsMerge {
            if total > VideoLimits.maxBytes + VideoLimits.maxBytes / 20 {
                fail(id, "The recordings add up to \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)), above the 8 GiB limit.", kind: .tooLarge, resume: nil)
                return false
            }
            update(id) { $0.stage = .merging }
        } else {
            if total > VideoLimits.maxBytes {
                fail(id, "This recording is \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file)), above the 8 GiB limit.", kind: .tooLarge, resume: nil)
                return false
            }
            let dur = recs.first.map(\.durationSec)
            update(id) { $0.fileSize = total; $0.durationSec = dur.flatMap { $0 > 0 ? $0 : nil }; $0.stage = .registering }
        }
        return true
    }

    func mergedURL(_ v: VideoUploadState, _ id: UUID) -> URL {
        deps.videosDirectory().appendingPathComponent(v.mergedFilename ?? VideoQueue.mergedFilename(for: id))
    }

    func mergeStage(_ id: UUID, lesson: Lesson, job: Job, v: VideoUploadState) async throws {
        let url = mergedURL(v, id)
        // Reuse a merged file from an earlier run if it is still valid.
        if v.mergedFilename != nil, let ok = await deps.media.validateMerged(url), ok.size == v.fileSize || v.fileSize == nil {
            update(id) { $0.fileSize = ok.size; $0.durationSec = ok.durationSec; $0.stage = .registering }
            return
        }
        let recs = v.sourceRecordingIds.compactMap { rid in lesson.recordings.first { $0.id == rid } }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let handler = eventHandler
        let label = recs.count > 1 ? "Joining \(recs.count) recordings" : "Preparing the MP4"
        emit(.progress(jobId: id, message: label, fraction: 0, sentBytes: 0, totalBytes: 0))
        let merged: MergedVideo
        do {
            merged = try await deps.media.merge(recs, to: url) { f in
                handler?(.progress(jobId: id, message: label, fraction: f, sentBytes: 0, totalBytes: 0))
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            fail(id, "Joining the recordings failed: \(error.localizedDescription)", kind: .mergeFailed, resume: .merging)
            throw CancellationError()
        }
        let name = url.lastPathComponent
        update(id) { $0.mergedFilename = name; $0.fileSize = merged.size; $0.durationSec = merged.durationSec; $0.lastCompletedStage = "merged" }
        if merged.size > VideoLimits.maxBytes {
            fail(id, "The joined video is \(ByteCountFormatter.string(fromByteCount: merged.size, countStyle: .file)), above the 8 GiB limit. It has been kept at \(url.path) for you to deal with.",
                 kind: .tooLarge, resume: nil)
            throw CancellationError()
        }
        update(id) { $0.stage = .registering }
    }

    func registerStage(_ id: UUID, v: VideoUploadState, api: RecordingsAPI) async throws {
        guard let noteId = v.noteId, let size = v.fileSize else { update(id) { $0.stage = .queued }; return }
        emit(.progress(jobId: id, message: "Registering the upload", fraction: 0, sentBytes: 0, totalBytes: size))
        let r = try await api.registerUpload(RegisterUploadRequest(uploadId: v.uploadId, noteId: noteId, title: v.title,
                                                                   originalFilename: v.originalFilename, sizeBytes: size))
        update(id) { $0.recordingId = r.recording.recordingId; $0.remoteStatus = r.recording.status }
        if r.recording.isReady { markReady(id, adopted: false); return }
        guard let up = r.upload else { update(id) { $0.stage = .completing }; return }
        signed[id] = up
        update(id) { $0.stage = .uploading; $0.lastCompletedStage = "registered" }
    }

    func uploadStage(_ id: UUID, lesson: Lesson, job: Job, v: VideoUploadState, target: SignedUpload) async throws {
        guard let size = v.fileSize else { update(id) { $0.stage = .queued }; return }
        let handler = eventHandler
        let progress: @Sendable (Int64, Int64) -> Void = { sent, total in
            handler?(.progress(jobId: id, message: "Uploading video", fraction: total > 0 ? Double(sent) / Double(total) : 0, sentBytes: sent, totalBytes: total))
        }
        progress(0, size)
        let uploader = deps.uploader
        if v.needsMerge {
            let url = mergedURL(v, id)
            guard FileManager.default.fileExists(atPath: url.path) else { update(id) { $0.stage = .merging; $0.mergedFilename = nil }; return }
            try await uploader.upload(file: url, size: size, to: target, progress: progress)
        } else {
            guard let rec = lesson.recordings.first(where: { $0.id == v.sourceRecordingIds.first }) else { update(id) { $0.stage = .queued }; return }
            try await deps.media.withAccess(bookmark: rec.bookmark, path: rec.path) { url in
                try await uploader.upload(file: url, size: size, to: target, progress: progress)
            }
        }
        signed[id] = nil
        update(id) { $0.stage = .completing; $0.lastCompletedStage = "uploaded" }
    }

    func completeStage(_ id: UUID, v: VideoUploadState, api: RecordingsAPI) async throws {
        guard let rid = v.recordingId, let size = v.fileSize else { update(id) { $0.stage = .registering }; return }
        emit(.progress(jobId: id, message: "Confirming with LetsMeet", fraction: 1, sentBytes: size, totalBytes: size))
        do {
            let r = try await api.completeUpload(recordingId: rid, CompleteUploadRequest(sizeBytes: size, durationSec: v.durationSec))
            update(id) { $0.remoteStatus = r.recording.status }
            if r.recording.isReady { markReady(id, adopted: false) }
            else { scheduleRetry(id, message: "LetsMeet has not confirmed the video yet (status \(r.recording.status)).", kind: .server, retryAfter: nil) }
        } catch let e as LetsMeetAPIError where e.httpStatus == 422 && (e.code == "file_missing" || e.code == "size_mismatch") {
            // The media server doesn't have the expected file: upload again (same upload_id).
            let n = v.reuploads + 1
            if n > 3 { fail(id, "The media server still reports \(e.code.replacingOccurrences(of: "_", with: " ")) after uploading again 3 times.", kind: .server, resume: .registering); throw CancellationError() }
            update(id) { $0.reuploads = n; $0.stage = .registering; $0.lastError = "Uploading again: \(e.message)" }
        } catch let e as LetsMeetAPIError where e.httpStatus == 409 && e.code == "already_ready" {
            markReady(id, adopted: false)
        }
    }

    func markReady(_ id: UUID, adopted: Bool) {
        let t = now()
        var merged: URL?
        update(id) { v in
            if v.needsMerge, self.settings.deleteMergedAfterUpload, v.mergedFilename != nil {
                merged = self.mergedURL(v, id)
                v.mergedFilename = nil
            }
            v.stage = .ready
            v.adoptedExisting = adopted
            v.remoteStatus = "ready"
            v.completedAt = t
            v.lastError = nil
            v.errorKind = nil
            v.nextAttemptAt = nil
            v.lastCompletedStage = "ready"
        }
        if let merged { try? FileManager.default.removeItem(at: merged) }
        signed[id] = nil
        emit(.finished(jobId: id))
    }

    func finish(_ id: UUID, skipped message: String, kind: VideoUploadState.ErrorKind) {
        update(id) { $0.stage = .skipped; $0.lastError = message; $0.errorKind = kind; $0.nextAttemptAt = nil }
        emit(.needsAttention(jobId: id, message: message))
    }

    func fail(_ id: UUID, _ message: String, kind: VideoUploadState.ErrorKind, resume: VideoUploadState.Stage?) {
        update(id) { v in
            v.resumeStage = resume ?? (v.stage.isActive ? v.stage : .queued)
            v.stage = .failed
            v.lastError = message
            v.errorKind = kind
            v.nextAttemptAt = nil
        }
        signed[id] = nil
        emit(.needsAttention(jobId: id, message: message))
    }

    func scheduleRetry(_ id: UUID, message: String, kind: VideoUploadState.ErrorKind, retryAfter: TimeInterval?) {
        let s = settings
        guard s.autoRetry else { fail(id, message, kind: kind, resume: nil); return }
        let t = now()
        var gaveUp = false
        update(id) { v in
            v.attempts += 1
            let first = v.firstRetryAt ?? t
            v.firstRetryAt = first
            let base = Self.retryDelays[min(v.attempts - 1, Self.retryDelays.count - 1)]
            let delay = max(base, retryAfter ?? 0)
            let next = t.addingTimeInterval(delay)
            if next.timeIntervalSince(first) > TimeInterval(s.retryWindowHours) * 3600 { gaveUp = true; return }
            v.nextAttemptAt = next
            v.lastError = message
            v.errorKind = kind
        }
        if gaveUp { fail(id, "Gave up after retrying for \(s.retryWindowHours) hours: \(message)", kind: kind, resume: nil) }
    }

    func handle(_ id: UUID, error: Error) {
        signed[id] = nil
        switch error {
        case let e as LetsMeetAPIError:
            switch (e.httpStatus, e.code) {
            case (401, _), (403, _):
                fail(id, "LetsMeet rejected the API key (\(e.code)). Check the key in Settings, then Retry.", kind: .authentication, resume: nil)
            case (404, "recording_not_found"):
                update(id) { $0.recordingId = nil; $0.checkedExisting = false; $0.stage = .queued; $0.generation += 1
                             $0.uploadId = VideoUploadState.uploadId(for: id, generation: $0.generation) }
                scheduleRetry(id, message: "The recording was removed on LetsMeet; registering a new upload.", kind: .server, retryAfter: 1)
            case (404, _):
                finish(id, skipped: "This note no longer exists on LetsMeet.", kind: .noteDeleted)
            case (409, "upload_conflict"):
                update(id) { $0.generation += 1; $0.uploadId = VideoUploadState.uploadId(for: id, generation: $0.generation); $0.stage = .registering }
                scheduleRetry(id, message: "Upload id already used elsewhere; using a new one.", kind: .server, retryAfter: 1)
            case (409, "recording_deleted"):
                fail(id, "This video was deleted on LetsMeet. Use Upload Again to send it as a new recording.", kind: .remoteDeleted, resume: nil)
            case (429, _):
                scheduleRetry(id, message: "LetsMeet asked the app to slow down.", kind: .rateLimited, retryAfter: e.retryAfter)
            case (500...599, _):
                scheduleRetry(id, message: e.message, kind: .server, retryAfter: e.retryAfter)
            default:
                fail(id, e.localizedDescription, kind: .rejected, resume: nil)
            }
        case let e as SignedUploadError:
            switch e {
            case .tooLarge: fail(id, e.localizedDescription, kind: .rejected, resume: .queued)
            case .expired: update(id) { $0.stage = .registering }; scheduleRetry(id, message: "The upload link expired.", kind: .network, retryAfter: nil)
            case .http(let c) where c < 500: fail(id, e.localizedDescription, kind: .rejected, resume: .registering)
            default:
                // Interrupted: start the PUT again with a fresh link (same upload_id).
                update(id) { if $0.stage == .uploading { $0.stage = .registering } }
                scheduleRetry(id, message: e.localizedDescription, kind: .network, retryAfter: nil)
            }
        case let e as TransportError:
            if case .offline = e { update(id) { $0.nextAttemptAt = self.now().addingTimeInterval(30); $0.lastError = "Waiting for internet" } }
            else { update(id) { if $0.stage == .uploading { $0.stage = .registering } }; scheduleRetry(id, message: e.localizedDescription, kind: .network, retryAfter: nil) }
        case let e as LetsMeetClientError:
            fail(id, e.localizedDescription, kind: .authentication, resume: nil)
        default:
            update(id) { if $0.stage == .uploading { $0.stage = .registering } }
            scheduleRetry(id, message: error.localizedDescription, kind: .network, retryAfter: nil)
        }
    }

    // MARK: Replacement

    func processReplacement(jobId: UUID) async {
        var renewals = 0
        while !Task.isCancelled {
            guard let (_, _, v) = state(jobId), let r = v.replacement, r.stage != .failed, let rid = v.recordingId else { return }
            do {
                let api = try deps.makeAPI()
                switch r.stage {
                case .registering:
                    let resp = try await api.replaceUpload(recordingId: rid, ReplaceUploadRequest(uploadId: r.uploadId, originalFilename: r.filename, sizeBytes: r.fileSize))
                    guard let up = resp.upload else { setReplacement(jobId) { $0.stage = .completing }; continue }
                    replaceSigned[jobId] = up
                    setReplacement(jobId) { $0.stage = .uploading }
                case .uploading:
                    guard let target = replaceSigned[jobId] else { setReplacement(jobId) { $0.stage = .registering }; continue }
                    let handler = eventHandler
                    let size = r.fileSize
                    do {
                        try await deps.media.withAccess(bookmark: r.bookmark, path: r.path) { [uploader = deps.uploader] url in
                            try await uploader.upload(file: url, size: size, to: target) { sent, total in
                                handler?(.progress(jobId: jobId, message: "Uploading replacement video", fraction: total > 0 ? Double(sent) / Double(total) : 0, sentBytes: sent, totalBytes: total))
                            }
                        }
                    } catch SignedUploadError.expired where renewals < 2 {
                        renewals += 1
                        replaceSigned[jobId] = nil
                        setReplacement(jobId) { $0.stage = .registering }
                        continue
                    }
                    replaceSigned[jobId] = nil
                    setReplacement(jobId) { $0.stage = .completing }
                case .completing:
                    let resp = try await api.completeUpload(recordingId: rid, CompleteUploadRequest(sizeBytes: r.fileSize, durationSec: r.durationSec))
                    if resp.recording.isReady && resp.recording.replacementPending != true {
                        update(jobId) { v in
                            v.fileSize = r.fileSize; v.durationSec = r.durationSec ?? v.durationSec; v.originalFilename = r.filename
                            v.remoteStatus = "ready"; v.replacement = nil; v.completedAt = self.now()
                        }
                        emit(.finished(jobId: jobId))
                        return
                    }
                    setReplacement(jobId) { $0.nextAttemptAt = self.now().addingTimeInterval(30); $0.lastError = "Waiting for LetsMeet to confirm the replacement." }
                    return
                case .failed:
                    return
                }
            } catch is CancellationError {
                return
            } catch {
                replaceSigned[jobId] = nil
                let retryable: Bool
                var after: TimeInterval?
                if let e = error as? LetsMeetAPIError { retryable = e.isRetryable; after = e.retryAfter }
                else if let e = error as? SignedUploadError { retryable = e != .tooLarge && { if case .http(let c) = e { return c >= 500 } else { return true } }() }
                else { retryable = true }
                let t = now()
                setReplacement(jobId) { rep in
                    rep.lastError = error.localizedDescription + " The current video keeps playing."
                    if retryable && self.settings.autoRetry && rep.attempts < 8 {
                        rep.attempts += 1
                        rep.firstRetryAt = rep.firstRetryAt ?? t
                        if rep.stage == .uploading { rep.stage = .registering }
                        rep.nextAttemptAt = t.addingTimeInterval(max(Self.retryDelays[min(rep.attempts - 1, Self.retryDelays.count - 1)], after ?? 0))
                    } else {
                        rep.stage = .failed
                    }
                }
                return
            }
        }
    }

    func setReplacement(_ id: UUID, _ body: (inout VideoReplacement) -> Void) {
        update(id) { v in
            guard var r = v.replacement else { return }
            body(&r)
            v.replacement = r
        }
    }
}

public enum VideoActionError: Error, LocalizedError, Equatable {
    case notUploaded, tooLarge
    public var errorDescription: String? {
        switch self {
        case .notUploaded: return "There is no uploaded video to replace."
        case .tooLarge: return "Videos must be 8 GiB or smaller."
        }
    }
}
