import Foundation

/// Historical backfill: lessons whose notes were uploaded before automatic video uploads were
/// turned on. Scanning only reads local data (and, after "Check LetsMeet", the stored probe
/// results); nothing is uploaded until George presses Start Backfill.
public struct VideoBackfillReport: Sendable, Equatable {
    public struct Item: Sendable, Equatable, Identifiable {
        public enum Status: String, Sendable { case eligible, alreadyUploaded, missingRecordings, noteDeleted, inProgress, succeeded, failed }
        public var id: UUID { jobId }
        public var jobId: UUID
        public var lessonId: UUID
        public var pupilName: String
        public var lessonDate: String
        public var mode: ProcessingMode
        public var recordingCount: Int
        public var needsMerge: Bool
        public var noteResolved: Bool
        public var bytes: Int64
        public var status: Status
        public var detail: String?
    }

    public var items: [Item] = []

    public var total: Int { items.count }
    public func count(_ s: Item.Status) -> Int { items.filter { $0.status == s }.count }
    public var eligible: [Item] { items.filter { $0.status == .eligible } }
    public var needingMerge: Int { items.filter { $0.needsMerge && $0.status == .eligible }.count }
    public var unresolvedNotes: Int { items.filter { !$0.noteResolved && ($0.status == .eligible || $0.status == .missingRecordings) }.count }
    public var estimatedBytes: Int64 { eligible.reduce(0) { $0 + $1.bytes } }
}

public enum VideoBackfill {
    /// Submitted before automatic uploads started (or before this version was installed).
    public static func isHistorical(_ j: Job, settings: VideoSettings) -> Bool {
        guard j.stage == .submitted else { return false }
        guard let since = settings.automaticSince, let at = j.submittedAt else { return true }
        return at < since
    }

    /// `sourceSize` returns a recording's size, or nil when it can't be found.
    public static func scan(store: LibraryStore, sourceSize: (RecordingRef) -> Int64?) -> VideoBackfillReport {
        let settings = store.settings.video
        var report = VideoBackfillReport()
        for l in store.allLessons.sorted(by: { ($0.lessonDate, $0.createdAt) < ($1.lessonDate, $1.createdAt) }) {
            for j in l.jobs where isHistorical(j, settings: settings) {
                let recs = l.recordings(for: j)
                let needsMerge = recs.count > 1 || recs.contains { !VideoQueue.videoExtensions.contains(($0.filename as NSString).pathExtension.lowercased()) }
                var item = VideoBackfillReport.Item(jobId: j.id, lessonId: l.id, pupilName: l.pupilName, lessonDate: l.lessonDate, mode: l.mode,
                                                    recordingCount: recs.count, needsMerge: needsMerge,
                                                    noteResolved: j.noteId != nil || j.videoProbe?.noteId != nil || j.video?.noteId != nil,
                                                    bytes: 0, status: .eligible)
                if let v = j.video {
                    switch v.stage {
                    case .ready: item.status = v.adoptedExisting ? .alreadyUploaded : .succeeded
                    case .failed: item.status = .failed; item.detail = v.lastError
                    case .skipped: item.status = .noteDeleted; item.detail = v.lastError
                    case .deleted: item.status = .alreadyUploaded; item.detail = "Video deleted on LetsMeet"
                    default: item.status = .inProgress
                    }
                } else if j.remoteStatus == .deleted || j.videoProbe?.noteDeleted == true {
                    item.status = .noteDeleted
                } else if j.videoProbe?.existingStatus == "ready" {
                    item.status = .alreadyUploaded
                } else {
                    var missing: [String] = []
                    var bytes: Int64 = 0
                    for r in recs {
                        if let s = sourceSize(r) { bytes += s } else { missing.append(r.filename) }
                    }
                    item.bytes = bytes
                    if recs.isEmpty || !missing.isEmpty {
                        item.status = .missingRecordings
                        item.detail = recs.isEmpty ? "No recordings saved for this lesson" : "Not found: " + missing.joined(separator: ", ")
                    }
                }
                report.items.append(item)
            }
        }
        return report
    }
}
