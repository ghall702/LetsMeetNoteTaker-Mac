import Foundation

/// A media file found on disk (from the watcher, a file import or a folder scan).
public struct ScannedRecording: Identifiable, Hashable, Sendable, Codable {
    public var id: String { path }
    public var path: String
    public var fileSize: Int64
    public var fileCreationDate: Date?
    public var fileModificationDate: Date?
    /// Filled in by media inspection (AVFoundation) when available.
    public var embeddedCreationDate: Date?
    public var durationSeconds: Double?

    public init(path: String, fileSize: Int64 = 0, fileCreationDate: Date? = nil, fileModificationDate: Date? = nil,
                embeddedCreationDate: Date? = nil, durationSeconds: Double? = nil) {
        self.path = path
        self.fileSize = fileSize
        self.fileCreationDate = fileCreationDate
        self.fileModificationDate = fileModificationDate
        self.embeddedCreationDate = embeddedCreationDate
        self.durationSeconds = durationSeconds
    }

    public var filename: String { (path as NSString).lastPathComponent }
    public var folderPath: String { (path as NSString).deletingLastPathComponent }
    public var folderName: String { (folderPath as NSString).lastPathComponent }
    public var kind: RecordingFileKind { RecordingFileKind.classify(filename) }
    public var zoomFolder: ZoomFolderInfo? { ZoomFolderParser.parse(folderName) }

    public var evidence: DateEvidence {
        DateEvidence(folderInfo: zoomFolder,
                     cloudFilenameTimestamp: ZoomFolderParser.parseCloudFileTimestamp(filename),
                     embeddedCreationDate: embeddedCreationDate,
                     fileCreationDate: fileCreationDate,
                     fileModificationDate: fileModificationDate)
    }

    public var recordingTimestamp: Date? { LessonDateInference.recordingTimestamp(evidence) }
}

/// A proposed lesson made from one or more recordings.
public struct ProposedSession: Identifiable, Hashable, Sendable {
    public var id: String
    public var folderPath: String
    public var folderName: String
    public var zoomInfo: ZoomFolderInfo?
    /// Meeting topic (Zoom) or a readable fallback (folder / file name).
    public var topic: String
    /// Recordings in suggested chronological order.
    public var recordings: [ScannedRecording]
    /// Audio-only duplicates Zoom writes next to an MP4; kept out of the default list.
    public var excludedAudioOnly: [ScannedRecording]
    public var inferredDate: InferredLessonDate

    public static func == (a: ProposedSession, b: ProposedSession) -> Bool { a.id == b.id && a.recordings == b.recordings }
    public func hash(into h: inout Hasher) { h.combine(id) }
}

public enum SessionGrouper {
    /// Order recordings: reliable recording timestamp first, then natural filename order.
    public static func chronological(_ recs: [ScannedRecording]) -> [ScannedRecording] {
        recs.sorted { a, b in
            switch (a.recordingTimestamp, b.recordingTimestamp) {
            case let (x?, y?) where x != y: return x < y
            default: return naturalLess(a.filename, b.filename)
            }
        }
    }

    /// Group scanned media into proposed lessons.
    /// - Files inside a Zoom session folder (`YYYY-MM-DD HH.MM.SS Topic`) form one session.
    /// - Other files are grouped by folder and clustered when they were recorded close together.
    public static func group(_ input: [ScannedRecording], timeZone: TimeZone, looseGap: TimeInterval = 2 * 3600,
                             now: Date = Date()) -> [ProposedSession] {
        let media = input.filter { $0.kind.isMedia }
        var byFolder: [String: [ScannedRecording]] = [:]
        for r in media { byFolder[r.folderPath, default: []].append(r) }

        var sessions: [ProposedSession] = []
        for (folder, recs) in byFolder {
            let folderName = (folder as NSString).lastPathComponent
            if let info = ZoomFolderParser.parse(folderName) {
                sessions.append(makeSession(id: folder, folderPath: folder, recs: recs, zoomInfo: info, timeZone: timeZone, now: now))
                continue
            }
            // Loose files: cluster by best available timestamp.
            let dated = recs.map { r -> (ScannedRecording, Date?) in
                let inferred = LessonDateInference.infer(r.evidence, timeZone: timeZone, now: now)
                return (r, inferred.startedAt ?? r.recordingTimestamp)
            }
            let withDate = dated.filter { $0.1 != nil }.sorted { $0.1! < $1.1! }
            let withoutDate = dated.filter { $0.1 == nil }.map { $0.0 }
            var cluster: [ScannedRecording] = []
            var clusterEnd: Date?
            func flush() {
                guard !cluster.isEmpty else { return }
                let id = folder + "#" + cluster.map(\.filename).sorted().joined(separator: "|")
                sessions.append(makeSession(id: id, folderPath: folder, recs: cluster, zoomInfo: nil, timeZone: timeZone, now: now))
                cluster = []
                clusterEnd = nil
            }
            for (r, d) in withDate {
                let start = d!
                if let end = clusterEnd, start.timeIntervalSince(end) > looseGap { flush() }
                cluster.append(r)
                let end = start.addingTimeInterval(r.durationSeconds ?? 0)
                clusterEnd = max(clusterEnd ?? end, end)
            }
            flush()
            for r in withoutDate.sorted(by: { naturalLess($0.filename, $1.filename) }) {
                sessions.append(makeSession(id: r.path, folderPath: folder, recs: [r], zoomInfo: nil, timeZone: timeZone, now: now))
            }
        }
        return sessions.sorted { a, b in
            if a.inferredDate.lessonDate != b.inferredDate.lessonDate { return a.inferredDate.lessonDate < b.inferredDate.lessonDate }
            switch (a.inferredDate.startedAt, b.inferredDate.startedAt) {
            case let (x?, y?) where x != y: return x < y
            default: return naturalLess(a.id, b.id)
            }
        }
    }

    static func makeSession(id: String, folderPath: String, recs: [ScannedRecording], zoomInfo: ZoomFolderInfo?,
                            timeZone: TimeZone, now: Date) -> ProposedSession {
        let hasVideo = recs.contains { $0.kind == .video }
        let primary = hasVideo ? recs.filter { $0.kind == .video } : recs
        let excluded = hasVideo ? recs.filter { $0.kind == .audioOnly } : []
        let ordered = chronological(primary)
        let folderName = (folderPath as NSString).lastPathComponent

        let inferred: InferredLessonDate
        if let first = ordered.first {
            // Use the earliest evidence in the session; flag review if recordings disagree on the day.
            var base = LessonDateInference.infer(first.evidence, timeZone: timeZone, now: now)
            if zoomInfo == nil {
                let candidates = ordered.map { LessonDateInference.infer($0.evidence, timeZone: timeZone, now: now) }
                if let best = candidates.max(by: { $0.confidence < $1.confidence }) { base = best }
                let days = Set(candidates.map(\.lessonDate).filter { !$0.isEmpty })
                if days.count > 1 {
                    base.needsReview = true
                    base.notes.append("Recordings in this group have different dates.")
                }
                if let earliest = candidates.compactMap(\.startedAt).min(), base.startedAt != nil { base.startedAt = earliest }
            }
            inferred = base
        } else {
            inferred = InferredLessonDate(lessonDate: "", startedAt: nil, source: .unknown, confidence: .low, needsReview: true)
        }

        let topic: String
        if let zoomInfo, !zoomInfo.topic.isEmpty { topic = zoomInfo.topic }
        else if zoomInfo == nil, let f = ordered.first, looksGeneric(folderName) {
            topic = (f.filename as NSString).deletingPathExtension
        } else { topic = folderName }

        return ProposedSession(id: id, folderPath: folderPath, folderName: folderName, zoomInfo: zoomInfo, topic: topic,
                               recordings: ordered, excludedAudioOnly: excluded, inferredDate: inferred)
    }

    static func looksGeneric(_ folderName: String) -> Bool {
        let generic: Set<String> = ["downloads", "desktop", "documents", "zoom", "movies", "recordings", "videos", "imports"]
        return generic.contains(folderName.lowercased())
    }
}
