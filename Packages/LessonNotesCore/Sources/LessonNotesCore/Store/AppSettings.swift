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

    public init() {}

    public var timeZone: TimeZone {
        if let id = timeZoneIdentifier, let tz = TimeZone(identifier: id) { return tz }
        return .current
    }

    enum CodingKeys: String, CodingKey {
        case websiteBaseURL, openAIModel, reasoningEffort, globalPrompt, transcriptionModel, transcriptionLanguage, zoomFolderPath,
             zoomFolderBookmark, watchFolder, autoProcessAfterConfirm, retention, timeZoneIdentifier,
             chunkThresholdTokens, maxConcurrentJobs, onboardingCompleted, installId, notifyOnSubmitted
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
    }
}
