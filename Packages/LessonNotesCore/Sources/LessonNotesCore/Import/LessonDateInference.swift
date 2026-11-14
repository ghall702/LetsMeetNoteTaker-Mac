import Foundation

public enum DateSource: String, Codable, Sendable, CaseIterable {
    case zoomFolder
    case zoomCloudFilename
    case embeddedMetadata
    case fileCreation
    case fileModification
    case manual
    case unknown

    public var label: String {
        switch self {
        case .zoomFolder: return "Zoom folder name"
        case .zoomCloudFilename: return "Zoom cloud file name"
        case .embeddedMetadata: return "Recording metadata"
        case .fileCreation: return "File creation date"
        case .fileModification: return "File modification date"
        case .manual: return "Entered manually"
        case .unknown: return "Unknown"
        }
    }
}

public enum DateConfidence: String, Codable, Sendable, Comparable {
    case low, medium, high
    private var rank: Int { switch self { case .low: return 0; case .medium: return 1; case .high: return 2 } }
    public static func < (a: DateConfidence, b: DateConfidence) -> Bool { a.rank < b.rank }
}

/// Everything known about when a recording was made.
public struct DateEvidence: Sendable, Equatable {
    public var folderInfo: ZoomFolderInfo?
    public var cloudFilenameTimestamp: Date?
    public var embeddedCreationDate: Date?
    public var fileCreationDate: Date?
    public var fileModificationDate: Date?

    public init(folderInfo: ZoomFolderInfo? = nil, cloudFilenameTimestamp: Date? = nil, embeddedCreationDate: Date? = nil,
                fileCreationDate: Date? = nil, fileModificationDate: Date? = nil) {
        self.folderInfo = folderInfo
        self.cloudFilenameTimestamp = cloudFilenameTimestamp
        self.embeddedCreationDate = embeddedCreationDate
        self.fileCreationDate = fileCreationDate
        self.fileModificationDate = fileModificationDate
    }
}

public struct InferredLessonDate: Equatable, Sendable, Codable {
    /// `YYYY-MM-DD` local lesson date. Empty when nothing usable is known.
    public var lessonDate: String
    /// Exact start time, only when a reliable source establishes it.
    public var startedAt: Date?
    public var source: DateSource
    public var confidence: DateConfidence
    public var needsReview: Bool
    public var notes: [String]

    public init(lessonDate: String, startedAt: Date?, source: DateSource, confidence: DateConfidence, needsReview: Bool, notes: [String] = []) {
        self.lessonDate = lessonDate
        self.startedAt = startedAt
        self.source = source
        self.confidence = confidence
        self.needsReview = needsReview
        self.notes = notes
    }
}

public enum LessonDateInference {
    /// Embedded MP4 dates of 1904/1970 or in the future are placeholders, not facts.
    public static func isPlausible(_ date: Date?, now: Date = Date()) -> Bool {
        guard let date else { return false }
        let earliest = Date(timeIntervalSince1970: 1_104_537_600) // 2005-01-01
        return date >= earliest && date <= now.addingTimeInterval(86_400)
    }

    /// Priority (spec): 1. Zoom folder name  2. reliable embedded metadata  3. file creation  4. modification.
    /// A Zoom cloud filename (explicit UTC) is treated as equivalent to the folder name.
    public static func infer(_ e: DateEvidence, timeZone: TimeZone, now: Date = Date()) -> InferredLessonDate {
        var notes: [String] = []
        let metadata = isPlausible(e.embeddedCreationDate, now: now) ? e.embeddedCreationDate : nil
        if e.embeddedCreationDate != nil && metadata == nil {
            notes.append("Embedded recording date looks like a placeholder and was ignored.")
        }

        if let info = e.folderInfo {
            let start = info.startDate(in: timeZone)
            var review = false
            if start == nil {
                review = true
                notes.append("The folder time does not exist in \(timeZone.identifier) (clock change); check the start time.")
            }
            if let start, let metadata, abs(metadata.timeIntervalSince(start)) > 36 * 3600 {
                review = true
                notes.append("Recording metadata (\(CoreFormat.lessonDateString(metadata, timeZone: timeZone))) disagrees with the folder date.")
            }
            if let start, start > now.addingTimeInterval(86_400) {
                review = true
                notes.append("Folder date is in the future.")
            }
            return InferredLessonDate(lessonDate: info.lessonDate, startedAt: start, source: .zoomFolder,
                                      confidence: review ? .medium : .high, needsReview: review, notes: notes)
        }
        if let cloud = e.cloudFilenameTimestamp, isPlausible(cloud, now: now) {
            return InferredLessonDate(lessonDate: CoreFormat.lessonDateString(cloud, timeZone: timeZone), startedAt: cloud,
                                      source: .zoomCloudFilename, confidence: .high, needsReview: false, notes: notes)
        }
        if let metadata {
            return InferredLessonDate(lessonDate: CoreFormat.lessonDateString(metadata, timeZone: timeZone), startedAt: metadata,
                                      source: .embeddedMetadata, confidence: .medium, needsReview: false, notes: notes)
        }
        if let created = e.fileCreationDate, isPlausible(created, now: now) {
            notes.append("Only the file creation date is available; it changes when files are copied.")
            return InferredLessonDate(lessonDate: CoreFormat.lessonDateString(created, timeZone: timeZone), startedAt: nil,
                                      source: .fileCreation, confidence: .low, needsReview: true, notes: notes)
        }
        if let modified = e.fileModificationDate, isPlausible(modified, now: now) {
            notes.append("Only the file modification date is available; please confirm the lesson date.")
            return InferredLessonDate(lessonDate: CoreFormat.lessonDateString(modified, timeZone: timeZone), startedAt: nil,
                                      source: .fileModification, confidence: .low, needsReview: true, notes: notes)
        }
        notes.append("No date information found.")
        return InferredLessonDate(lessonDate: "", startedAt: nil, source: .unknown, confidence: .low, needsReview: true, notes: notes)
    }

    /// Best timestamp for ordering an individual recording inside a session.
    public static func recordingTimestamp(_ e: DateEvidence, now: Date = Date()) -> Date? {
        if let c = e.cloudFilenameTimestamp, isPlausible(c, now: now) { return c }
        if let m = e.embeddedCreationDate, isPlausible(m, now: now) { return m }
        return nil
    }
}
