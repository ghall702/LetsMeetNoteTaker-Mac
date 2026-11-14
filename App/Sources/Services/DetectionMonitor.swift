import Foundation
import LessonNotesCore

/// Watches the Zoom folder for new recordings and applies the readiness rules:
/// .mp4 (or .m4a), no `.zoom` placeholder in the folder, size unchanged for 20 s twice,
/// playable and longer than 30 s.
@MainActor
final class DetectionMonitor {
    private weak var model: AppModel?
    private var root: URL?
    private var timer: Timer?
    private var observations: [String: [RecordingReadiness.SizeObservation]] = [:]
    private var candidateFolders: Set<String> = []
    private var scanning = false
    private let handledKey = "handledZoomFolders"
    private let baselineKey = "zoomWatchBaselineDone"

    init(model: AppModel) { self.model = model }

    private var handled: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: handledKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: handledKey) }
    }

    func markHandled(_ folder: String) {
        var h = handled
        h.insert(folder)
        handled = h
        candidateFolders.remove(folder)
    }

    func start(root: URL) {
        self.root = root
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: RecordingReadiness.stableInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        rescan()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        root = nil
        candidateFolders = []
        observations = [:]
    }

    func filesChanged(_ paths: [String]) {
        for p in paths {
            let kind = RecordingFileKind.classify((p as NSString).lastPathComponent)
            if kind != .other { candidateFolders.insert((p as NSString).deletingLastPathComponent) }
        }
    }

    /// Finds folders that contain media not yet processed. On the very first watch, existing
    /// recordings older than a day are treated as history (use Import for those).
    func rescan() {
        guard let root, !scanning, let model else { return }
        scanning = true
        let processed = Set(model.store.allLessons.flatMap { $0.recordings.map(\.path) })
        let detected = Set(model.store.detections.map(\.folderPath))
        let firstRun = !UserDefaults.standard.bool(forKey: baselineKey)
        Task.detached(priority: .utility) {
            let result = try? FolderScanner.scan(roots: [root])
            await MainActor.run {
                self.scanning = false
                guard let result else { return }
                let cutoff = Date().addingTimeInterval(-86_400)
                var h = self.handled
                for rec in result.recordings where !processed.contains(rec.path) && !detected.contains(rec.folderPath) && !h.contains(rec.folderPath) {
                    if firstRun, (rec.fileModificationDate ?? .distantPast) < cutoff { h.insert(rec.folderPath); continue }
                    self.candidateFolders.insert(rec.folderPath)
                }
                for f in result.foldersStillConverting where !h.contains(f) { self.candidateFolders.insert(f) }
                if firstRun {
                    self.handled = h
                    UserDefaults.standard.set(true, forKey: self.baselineKey)
                }
                self.poll()
            }
        }
    }

    private func poll() {
        guard let model, root != nil else { return }
        let fm = FileManager.default
        let now = Date()
        let handled = self.handled
        let processed = Set(model.store.allLessons.flatMap { $0.recordings.map(\.path) })
        for folder in candidateFolders {
            if handled.contains(folder) || model.store.detections.contains(where: { $0.folderPath == folder }) {
                candidateFolders.remove(folder); continue
            }
            guard let names = try? fm.contentsOfDirectory(atPath: folder) else { candidateFolders.remove(folder); continue }
            let media = names.filter { RecordingFileKind.classify($0).isMedia }
            if media.isEmpty { continue }
            var allStable = true
            for name in media {
                let path = (folder as NSString).appendingPathComponent(name)
                let size = ((try? fm.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.int64Value ?? 0
                var obs = observations[path] ?? []
                obs.append(.init(size: size, at: now))
                if obs.count > 5 { obs.removeFirst(obs.count - 5) }
                observations[path] = obs
                if !RecordingReadiness.isSizeStable(obs) { allStable = false }
            }
            let converting = names.contains { RecordingFileKind.classify($0) == .conversionPlaceholder }
            guard allStable, !converting else { continue }
            candidateFolders.remove(folder)
            let paths = media.map { (folder as NSString).appendingPathComponent($0) }.filter { !processed.contains($0) }
            Task { await self.finalise(folder: folder, paths: paths, names: names) }
        }
    }

    private func finalise(folder: String, paths: [String], names: [String]) async {
        guard let model else { return }
        var ready: [ScannedRecording] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let info = await MediaInspector.inspect(url)
            let verdict = RecordingReadiness.evaluate(filename: url.lastPathComponent, siblings: names,
                                                      observations: observations[path] ?? [], playable: info.playable,
                                                      durationSeconds: info.durationSeconds)
            guard verdict == .ready else { continue }
            let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey])
            ready.append(ScannedRecording(path: path, fileSize: Int64(v?.fileSize ?? 0), fileCreationDate: v?.creationDate,
                                          fileModificationDate: v?.contentModificationDate, embeddedCreationDate: info.creationDate,
                                          durationSeconds: info.durationSeconds))
        }
        for p in paths { observations[p] = nil }
        guard !ready.isEmpty else { markHandled(folder); return }
        model.store.upsertDetection(PendingDetection(folderPath: folder, recordings: ready, notified: true))
        let session = SessionGrouper.group(ready, timeZone: model.settings.timeZone).first
        let topic = session?.topic ?? (folder as NSString).lastPathComponent
        let dateText = session.map { CoreFormat.longUKDate($0.inferredDate.lessonDate) } ?? ""
        NotificationService.shared.notifyNewRecording(folderPath: folder, title: "New lesson recording found",
                                                      body: "\(topic), \(dateText)" + (ready.count > 1 ? " — \(ready.count) recordings" : ""))
    }
}
