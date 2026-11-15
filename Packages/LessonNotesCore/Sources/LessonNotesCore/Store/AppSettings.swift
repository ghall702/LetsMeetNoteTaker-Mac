import Foundation

public enum RetentionPeriod: String, Codable, CaseIterable, Sendable, Identifiable {
    case forever, oneYear, days90, days30
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .forever: return "Forever"
        case .oneYear: return "1 year"
        case .days90: return "90 days"
        case .days30: return "30 days"
        }
    }
    public var interval: TimeInterval? {
        switch self {
        case .forever: return nil
        case .oneYear: return 365 * 86_400
        case .days90: return 90 * 86_400
        case .days30: return 30 * 86_400
        }
    }
}

/// Non-secret settings, persisted as JSON in Application Support.
/// API keys are never stored here — they live in the Keychain.
public struct AppSettings: Codable, Equatable, Sendable {
    public var websiteBaseURL: String = LetsMeetClient.defaultBaseURL
    public var openAIModel: String = ""
    public var reasoningEffort: ReasoningEffort = .modelDefault
    public var globalPrompt: String = PromptLibrary.starterGlobalPrompt
    public var transcriptionModel: String = ""
    /// Whisper language code; nil = auto-detect.
    public var transcriptionLanguage: String? = "en"
    public var zoomFolderPath: String = "~/Documents/Zoom"
    public var zoomFolderBookmark: Data?
    public var watchFolder: Bool = true
    public var autoProcessAfterConfirm: Bool = true
    public var retention: RetentionPeriod = .forever
    /// nil = the Mac's current time zone.
    public var timeZoneIdentifier: String?
    public var chunkThresholdTokens: Int = 100_000
    public var maxConcurrentJobs: Int = 2
    public var onboardingCompleted: Bool = false
    public var installId: UUID = UUID()
    public var notifyOnSubmitted: Bool = true
    /// `max_output_tokens` for OpenAI; nil = the model's own maximum (recommended).
    public var maxOutputTokens: Int?
    /// Whisper transcriptions that may run at the same time (1–8). Default 1 for stability.
    public var maxConcurrentTranscriptions: Int = 1
    /// OpenAI usage counter, pricing and free-allowance protection.
    public var usage = UsageSettings()
    /// Pause OpenAI: transcription carries on, but no notes are written (except as allowed below).
    public var openAIPaused: Bool = false
    /// While paused, still write notes for lessons dated today (in the app's time zone).
    public var openAIPauseAllowsToday: Bool = true
    /// Name new PDF files "macOS Preview <name>.pdf".
    public var pdfPreviewPrefix: Bool = true

    public init() {}

    /// Whether automatic note-writing for this lesson/job is held by "Pause OpenAI".
    public func openAIHeld(lessonDate: String, job: Job, now: Date) -> Bool {
        guard openAIPaused, job.openAIOverride != true else { return false }
        if openAIPauseAllowsToday && lessonDate == CoreFormat.lessonDateString(now, timeZone: timeZone) { return false }
        return true
    }

    public var timeZone: TimeZone {
        if let id = timeZoneIdentifier, let tz = TimeZone(identifier: id) { return tz }
        return .current
    }

    enum CodingKeys: String, CodingKey {
        case websiteBaseURL, openAIModel, reasoningEffort, globalPrompt, transcriptionModel, transcriptionLanguage, zoomFolderPath,
             zoomFolderBookmark, watchFolder, autoProcessAfterConfirm, retention, timeZoneIdentifier,
             chunkThresholdTokens, maxConcurrentJobs, onboardingCompleted, installId, notifyOnSubmitted, maxOutputTokens, maxConcurrentTranscriptions, usage,
             openAIPaused, openAIPauseAllowsToday, pdfPreviewPrefix
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        websiteBaseURL = try c.decodeIfPresent(String.self, forKey: .websiteBaseURL) ?? d.websiteBaseURL
        openAIModel = try c.decodeIfPresent(String.self, forKey: .openAIModel) ?? d.openAIModel
        reasoningEffort = (try? c.decodeIfPresent(ReasoningEffort.self, forKey: .reasoningEffort)) ?? d.reasoningEffort
        globalPrompt = try c.decodeIfPresent(String.self, forKey: .globalPrompt) ?? d.globalPrompt
        transcriptionModel = try c.decodeIfPresent(String.self, forKey: .transcriptionModel) ?? d.transcriptionModel
        transcriptionLanguage = c.contains(.transcriptionLanguage) ? try c.decodeIfPresent(String.self, forKey: .transcriptionLanguage) : d.transcriptionLanguage
        zoomFolderPath = try c.decodeIfPresent(String.self, forKey: .zoomFolderPath) ?? d.zoomFolderPath
        zoomFolderBookmark = try c.decodeIfPresent(Data.self, forKey: .zoomFolderBookmark)
        watchFolder = try c.decodeIfPresent(Bool.self, forKey: .watchFolder) ?? d.watchFolder
        autoProcessAfterConfirm = try c.decodeIfPresent(Bool.self, forKey: .autoProcessAfterConfirm) ?? d.autoProcessAfterConfirm
        retention = (try? c.decodeIfPresent(RetentionPeriod.self, forKey: .retention)) ?? d.retention
        timeZoneIdentifier = try c.decodeIfPresent(String.self, forKey: .timeZoneIdentifier)
        chunkThresholdTokens = try c.decodeIfPresent(Int.self, forKey: .chunkThresholdTokens) ?? d.chunkThresholdTokens
        maxConcurrentJobs = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentJobs) ?? d.maxConcurrentJobs
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
        installId = try c.decodeIfPresent(UUID.self, forKey: .installId) ?? d.installId
        notifyOnSubmitted = try c.decodeIfPresent(Bool.self, forKey: .notifyOnSubmitted) ?? d.notifyOnSubmitted
        maxOutputTokens = try c.decodeIfPresent(Int.self, forKey: .maxOutputTokens)
        maxConcurrentTranscriptions = min(8, max(1, try c.decodeIfPresent(Int.self, forKey: .maxConcurrentTranscriptions) ?? 1))
        usage = (try? c.decodeIfPresent(UsageSettings.self, forKey: .usage)) ?? d.usage
        openAIPaused = try c.decodeIfPresent(Bool.self, forKey: .openAIPaused) ?? d.openAIPaused
        openAIPauseAllowsToday = try c.decodeIfPresent(Bool.self, forKey: .openAIPauseAllowsToday) ?? d.openAIPauseAllowsToday
        pdfPreviewPrefix = try c.decodeIfPresent(Bool.self, forKey: .pdfPreviewPrefix) ?? d.pdfPreviewPrefix
    }
}
