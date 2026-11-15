import Foundation
import AppKit
import UniformTypeIdentifiers
import LessonNotesCore

/// Where merged MP4s are written: the app's data folder, or a folder George chose
/// (security-scoped access is held for as long as the app runs).
final class VideoFolder: @unchecked Sendable {
    private let lock = NSLock()
    private var current: URL = AppInfo.supportDirectory.appendingPathComponent("Videos", isDirectory: true)
    private var scoped: URL?

    var url: URL { lock.lock(); defer { lock.unlock() }; return current }
    static var defaultURL: URL { AppInfo.supportDirectory.appendingPathComponent("Videos", isDirectory: true) }

    func configure(settings: VideoSettings) {
        lock.lock(); defer { lock.unlock() }
        scoped?.stopAccessingSecurityScopedResource()
        scoped = nil
        current = Self.defaultURL
        if let b = settings.mergedFolderBookmark {
            var stale = false
            if let u = try? URL(resolvingBookmarkData: b, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale),
               u.startAccessingSecurityScopedResource() {
                scoped = u
                current = u
            }
        }
        try? FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
    }
}

extension AppModel {
    // MARK: Startup

    func startVideoUploads() {
        // First run with video uploads: lessons already uploaded go to the backfill, not the automatic queue.
        if settings.video.automaticSince == nil { updateSettings { $0.video.automaticSince = Date() } }
        let handler: @Sendable (VideoEvent) -> Void = { [weak self] e in Task { @MainActor in self?.handleVideo(e) } }
        Task {
            await videoEngine.setEventHandler(handler)
            await videoEngine.tick()
        }
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.videoEngine.tick() }
        }
    }

    func handleVideo(_ e: VideoEvent) {
        switch e {
        case .progress(let id, let message, let fraction, let sent, let total):
            let now = Date()
            var speed: Double?
            if let old = videoProgress[id], old.message == message, sent > old.sentBytes {
                let dt = now.timeIntervalSince(old.updatedAt)
                if dt >= 0.5 {
                    let instant = Double(sent - old.sentBytes) / dt
                    speed = old.bytesPerSecond.map { $0 * 0.7 + instant * 0.3 } ?? instant
                } else {
                    return // throttle UI updates
                }
            }
            videoProgress[id] = VideoProgress(message: message, fraction: fraction, sentBytes: sent, totalBytes: total, bytesPerSecond: speed, updatedAt: now)
        case .finished(let id):
            videoProgress[id] = nil
        case .needsAttention(let id, _):
            videoProgress[id] = nil
        case .probeProgress(let done, let total):
            probeDone = done; probeTotal = total
            if done == total { scanBackfill() }
        case .idle:
            videoProgress = videoProgress.filter { id, _ in store.job(id: id)?.video?.stage.isActive == true }
        }
    }

    var videoJobs: [LessonJob] { allJobs.filter { $0.job.video != nil }.sorted { ($0.job.video?.updatedAt ?? .distantPast) > ($1.job.video?.updatedAt ?? .distantPast) } }
    var activeVideoJobs: [LessonJob] { videoJobs.filter { $0.job.video?.stage.isActive == true } }
    var failedVideoJobs: [LessonJob] { videoJobs.filter { $0.job.video?.stage == .failed || $0.job.video?.replacement?.stage == .failed } }

    // MARK: Controls

    func setVideoUploadsPaused(_ paused: Bool) {
        updateSettings { $0.video.paused = paused }
        Task { await videoEngine.tick() }
    }

    func uploadVideoNow(_ job: Job) { Task { await videoEngine.enqueue(jobIds: [job.id], origin: .manual) } }
    func retryVideo(_ job: Job) { Task { await videoEngine.retry(jobId: job.id) } }
    func stopVideo(_ job: Job) { Task { await videoEngine.cancel(jobId: job.id) }; videoProgress[job.id] = nil }
    func uploadVideoAgain(_ job: Job) { Task { await videoEngine.uploadAgain(jobId: job.id) } }
    func retryAllFailedVideos() { for item in failedVideoJobs { retryVideo(item.job) } }

    func deleteVideo(_ job: Job) {
        Task {
            do {
                let done = try await videoEngine.deleteRemote(jobId: job.id)
                banner = done ? "The video was deleted from LetsMeet. Your original recordings are untouched."
                              : "The video is hidden from pupils, but the media server didn't confirm the deletion yet. Use Retry Delete later."
            } catch { banner = "Deleting the video failed: \(error.localizedDescription)" }
        }
    }

    func replaceVideo(_ job: Job) {
        let panel = NSOpenPanel()
        panel.title = "Choose the replacement video"
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let bookmark = try? FolderAccess.bookmark(for: url)
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        Task {
            let duration = await AVVideoMedia.duration(of: url)
            do { try await videoEngine.replace(jobId: job.id, filename: url.lastPathComponent, path: url.path, bookmark: bookmark, size: size, durationSec: duration) }
            catch { banner = error.localizedDescription }
        }
    }

    func cancelVideoReplacement(_ job: Job) { Task { await videoEngine.cancelReplacement(jobId: job.id) } }

    private func recordingsAPI() throws -> LetsMeetClient {
        guard let key = KeychainStore.get(.website), !key.isEmpty else { throw LetsMeetClientError.missingKey }
        return try LetsMeetClient(baseURLString: settings.websiteBaseURL, apiKey: key, transport: URLSessionTransport(timeout: 60))
    }

    /// Opens a 15-minute staff playback link (or a download link) in the browser.
    func openVideo(_ job: Job, download: Bool = false) {
        guard let rid = job.video?.recordingId else { return }
        Task {
            do {
                let p = try await recordingsAPI().playback(recordingId: rid, download: download)
                NSWorkspace.shared.open(p.url)
            } catch { banner = "Couldn't open the video: \(error.localizedDescription)" }
        }
    }

    func checkVideoAvailability(_ job: Job) {
        guard let rid = job.video?.recordingId else { return }
        Task {
            do {
                let api = try recordingsAPI()
                let a = try await api.availability(recordingId: rid)
                let rec = try? await api.recording(id: rid)
                if let status = rec?.status ?? a.status { store.updateJob(id: job.id) { $0.video?.remoteStatus = status } }
                banner = a.available ? "The video is available on LetsMeet." : "The video is not available: \(a.reason ?? a.status ?? "unknown reason")."
            } catch { banner = "Checking the video failed: \(error.localizedDescription)" }
        }
    }

    // MARK: Backfill

    /// Reads the library and checks the original recordings exist (no network).
    func scanBackfill() {
        guard !isScanningBackfill else { return }
        isScanningBackfill = true
        let store = self.store
        Task {
            let report = await Task.detached(priority: .userInitiated) { () -> VideoBackfillReport in
                VideoBackfill.scan(store: store) { rec in
                    var size: Int64?
                    let probe = { (url: URL) in
                        if FileManager.default.isReadableFile(atPath: url.path) {
                            size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
                        }
                    }
                    if let b = rec.bookmark, let r = FolderAccess.resolve(b) { probe(r.url); r.url.stopAccessingSecurityScopedResource() }
                    else { probe(URL(fileURLWithPath: rec.path)) }
                    return size
                }
            }.value
            backfillReport = report
            isScanningBackfill = false
        }
    }

    /// Read-only: finds note ids and existing videos on LetsMeet for the historical lessons.
    func checkBackfillOnWebsite() {
        guard let r = backfillReport else { return }
        let ids = r.items.filter { $0.status == .eligible || $0.status == .missingRecordings }.map(\.jobId)
        probeDone = 0; probeTotal = ids.count
        Task { await videoEngine.probe(jobIds: ids) }
    }

    func startBackfill() {
        guard let r = backfillReport else { return }
        let ids = r.eligible.map(\.jobId)
        Task {
            await videoEngine.enqueue(jobIds: ids, origin: .backfill)
            scanBackfill()
        }
    }

    // MARK: Merged files

    func chooseMergedFolder() {
        guard let url = FolderAccess.chooseFolder(title: "Choose a folder for joined videos", startingAt: settings.video.mergedFolderPath) else { return }
        do {
            let b = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            updateSettings { $0.video.mergedFolderBookmark = b; $0.video.mergedFolderPath = url.path }
            videoFolder.configure(settings: settings.video)
        } catch { banner = "Couldn't use that folder: \(error.localizedDescription)" }
    }

    func useDefaultMergedFolder() {
        updateSettings { $0.video.mergedFolderBookmark = nil; $0.video.mergedFolderPath = nil }
        videoFolder.configure(settings: settings.video)
    }

    var leftoverMergedFiles: [URL] { VideoQueue.leftoverMergedFiles(store: store, directory: videoFolder.url) }

    func deleteLeftoverMergedFiles() {
        for u in leftoverMergedFiles { try? FileManager.default.removeItem(at: u) }
        objectWillChange.send()
    }

    var mergedFilesBytes: Int64 {
        let dir = videoFolder.url
        let items = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return items.filter { $0.hasPrefix("merged-") }.reduce(0) { sum, n in
            sum + ((try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }
}
