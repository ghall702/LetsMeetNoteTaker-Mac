import Foundation

/// Token usage exactly as reported by OpenAI (`usage` on a Responses API response).
/// Fields are nil when OpenAI did not report them — never estimated.
public struct TokenUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int?
    public var cachedInputTokens: Int?
    public var outputTokens: Int?
    public var reasoningTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int?, cachedInputTokens: Int?, outputTokens: Int?, reasoningTokens: Int? = nil, totalTokens: Int?) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
    }

    /// Parses the Responses API `usage` object.
    public static func parse(_ obj: Any?) -> TokenUsage? {
        guard let u = obj as? [String: Any] else { return nil }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        let input = int(u["input_tokens"])
        let output = int(u["output_tokens"])
        let cached = int((u["input_tokens_details"] as? [String: Any])?["cached_tokens"])
        let reasoning = int((u["output_tokens_details"] as? [String: Any])?["reasoning_tokens"])
        let total = int(u["total_tokens"]) ?? { if let i = input, let o = output { return i + o } else { return nil } }()
        if input == nil && output == nil && total == nil { return nil }
        return TokenUsage(inputTokens: input, cachedInputTokens: cached, outputTokens: output, reasoningTokens: reasoning, totalTokens: total)
    }
}

/// What an OpenAI request was for (no transcript or pupil data).
public enum UsagePurpose: String, Codable, Sendable, CaseIterable {
    case lessonNotes, notesPart, notesCombine, regenerate, modelTest, other
    public var label: String {
        switch self {
        case .lessonNotes: return "Lesson notes"
        case .notesPart: return "Lesson notes (part)"
        case .notesCombine: return "Lesson notes (combining parts)"
        case .regenerate: return "Regenerate notes"
        case .modelTest: return "Test Model"
        case .other: return "Other"
        }
    }
}

/// Context for the OpenAI request currently being made, carried as a task-local value so the
/// central client can attribute usage without changing the lesson-processing code paths.
public struct UsageContext: Sendable, Equatable {
    public var lessonId: UUID?
    public var jobId: UUID?
    public var purpose: UsagePurpose
    public init(lessonId: UUID?, jobId: UUID?, purpose: UsagePurpose) {
        self.lessonId = lessonId
        self.jobId = jobId
        self.purpose = purpose
    }
    @TaskLocal public static var current: UsageContext?
}

/// One OpenAI request. Contains no API keys, transcripts or pupil names.
public struct UsageRecord: Codable, Equatable, Sendable, Identifiable {
    public enum Outcome: String, Codable, Sendable { case succeeded, incomplete, failed }

    public var id: UUID
    /// OpenAI response id (`resp_…`), used to avoid recording the same response twice.
    public var responseId: String?
    public var date: Date
    public var model: String
    public var lessonId: UUID?
    public var jobId: UUID?
    public var purpose: UsagePurpose
    public var outcome: Outcome
    public var errorSummary: String?
    /// nil = OpenAI did not report usage for this request (unknown, not zero).
    public var usage: TokenUsage?
    /// Estimated full-price cost in USD at the configured price (nil if no price set or usage unknown).
    public var estimatedCostUSD: Double?
    /// Whether the model was in the complimentary-eligible list when the request was made.
    public var complimentaryEligible: Bool
    /// Source of the record: this app, or an imported export.
    public var source: String

    public init(id: UUID = UUID(), responseId: String?, date: Date, model: String, lessonId: UUID?, jobId: UUID?, purpose: UsagePurpose,
                outcome: Outcome, errorSummary: String? = nil, usage: TokenUsage?, estimatedCostUSD: Double?, complimentaryEligible: Bool,
                source: String = "app") {
        self.id = id
        self.responseId = responseId
        self.date = date
        self.model = model
        self.lessonId = lessonId
        self.jobId = jobId
        self.purpose = purpose
        self.outcome = outcome
        self.errorSummary = errorSummary
        self.usage = usage
        self.estimatedCostUSD = estimatedCostUSD
        self.complimentaryEligible = complimentaryEligible
        self.source = source
    }

    public var totalTokens: Int? { usage?.totalTokens }
    public var utcDay: String { UsageCalendar.utcDay(date) }
}

/// Configurable model pricing (USD per 1M tokens).
public struct ModelPrice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { modelPrefix }
    /// Matches the model id exactly or as a prefix (e.g. dated snapshots).
    public var modelPrefix: String
    public var inputPerMillion: Double
    public var cachedInputPerMillion: Double
    public var outputPerMillion: Double
    /// Optional higher tier for prompts with more input tokens than this threshold.
    public var longContextThreshold: Int?
    public var longInputPerMillion: Double?
    public var longCachedInputPerMillion: Double?
    public var longOutputPerMillion: Double?
    public var note: String

    public init(modelPrefix: String, inputPerMillion: Double, cachedInputPerMillion: Double, outputPerMillion: Double,
                longContextThreshold: Int? = nil, longInputPerMillion: Double? = nil, longCachedInputPerMillion: Double? = nil,
                longOutputPerMillion: Double? = nil, note: String = "") {
        self.modelPrefix = modelPrefix
        self.inputPerMillion = inputPerMillion
        self.cachedInputPerMillion = cachedInputPerMillion
        self.outputPerMillion = outputPerMillion
        self.longContextThreshold = longContextThreshold
        self.longInputPerMillion = longInputPerMillion
        self.longCachedInputPerMillion = longCachedInputPerMillion
        self.longOutputPerMillion = longOutputPerMillion
        self.note = note
    }

    /// Defaults from third-party price listings (Nov 2026); OpenAI's own pricing page could not be
    /// reached when this was written, so George should confirm them in Settings.
    public static let defaults: [ModelPrice] = [
        ModelPrice(modelPrefix: "gpt-6.1-sol", inputPerMillion: 2.00, cachedInputPerMillion: 0.10, outputPerMillion: 10.00,
                   longContextThreshold: 272_000, longInputPerMillion: 4.00, longCachedInputPerMillion: 0.20, longOutputPerMillion: 15.00,
                   note: "From published third-party listings, November 2026 — please confirm at openai.com/api/pricing"),
    ]

    public static func match(_ model: String, in prices: [ModelPrice]) -> ModelPrice? {
        let m = model.lowercased()
        return prices.filter { m == $0.modelPrefix.lowercased() || m.hasPrefix($0.modelPrefix.lowercased() + "-") }
            .max { $0.modelPrefix.count < $1.modelPrefix.count }
    }

    /// Full-price cost of a request (no complimentary allowance applied).
    public func cost(of u: TokenUsage) -> Double? {
        guard let input = u.inputTokens, let output = u.outputTokens else { return nil }
        let cached = min(u.cachedInputTokens ?? 0, input)
        let long = longContextThreshold.map { input > $0 } ?? false
        let inRate = long ? (longInputPerMillion ?? inputPerMillion) : inputPerMillion
        let cachedRate = long ? (longCachedInputPerMillion ?? cachedInputPerMillion) : cachedInputPerMillion
        let outRate = long ? (longOutputPerMillion ?? outputPerMillion) : outputPerMillion
        return (Double(input - cached) * inRate + Double(cached) * cachedRate + Double(output) * outRate) / 1_000_000
    }
}

/// Settings for usage monitoring and the free-allowance safeguard.
public struct UsageSettings: Codable, Equatable, Sendable {
    public var dailyComplimentaryTokens: Int = 250_000
    /// Model ids (or prefixes) that share the complimentary daily allowance.
    public var complimentaryModels: [String] = ["gpt-6.1-sol"]
    public var protectionEnabled: Bool = false
    /// Extra tokens kept in reserve on top of the estimate.
    public var safetyMarginTokens: Int = 10_000
    /// Output tokens assumed when no maximum output is configured.
    public var assumedOutputTokens: Int = 16_000
    public var prices: [ModelPrice] = ModelPrice.defaults

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = UsageSettings()
        dailyComplimentaryTokens = try c.decodeIfPresent(Int.self, forKey: .dailyComplimentaryTokens) ?? d.dailyComplimentaryTokens
        complimentaryModels = try c.decodeIfPresent([String].self, forKey: .complimentaryModels) ?? d.complimentaryModels
        protectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .protectionEnabled) ?? d.protectionEnabled
        safetyMarginTokens = try c.decodeIfPresent(Int.self, forKey: .safetyMarginTokens) ?? d.safetyMarginTokens
        assumedOutputTokens = try c.decodeIfPresent(Int.self, forKey: .assumedOutputTokens) ?? d.assumedOutputTokens
        prices = try c.decodeIfPresent([ModelPrice].self, forKey: .prices) ?? d.prices
    }

    public func isComplimentary(_ model: String) -> Bool {
        let m = model.lowercased()
        return complimentaryModels.contains { let p = $0.lowercased().trimmingCharacters(in: .whitespaces); return !p.isEmpty && (m == p || m.hasPrefix(p + "-")) }
    }

    public func price(for model: String) -> ModelPrice? { ModelPrice.match(model, in: prices) }
}

public enum UsageCalendar {
    static let utc = TimeZone(identifier: "UTC")!

    public static func utcDay(_ d: Date) -> String { CoreFormat.lessonDateString(d, timeZone: utc) }
    public static func utcMonth(_ d: Date) -> String { String(utcDay(d).prefix(7)) }

    /// Next 00:00 UTC after `now`.
    public static func nextReset(after now: Date) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let start = cal.startOfDay(for: now)
        return cal.date(byAdding: .day, value: 1, to: start)!
    }

    public static func days(endingAt now: Date, count: Int) -> [String] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        return (0..<count).compactMap { cal.date(byAdding: .day, value: -$0, to: now).map(utcDay) }
    }
}
