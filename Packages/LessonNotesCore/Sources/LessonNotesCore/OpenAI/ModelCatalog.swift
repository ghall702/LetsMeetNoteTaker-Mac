import Foundation

/// Result of a live "Test Model" run — the only capability information the app
/// shows as verified (it never invents prices or capabilities).
public struct ModelVerification: Codable, Equatable, Sendable {
    public var modelId: String
    public var testedAt: Date
    public var structuredOutputWorks: Bool
    /// The reasoning effort sent during the test, if any.
    public var reasoningEffortTested: ReasoningEffort
    /// true = accepted, false = rejected, nil = not tested (effort was "Model default").
    public var reasoningEffortAccepted: Bool?
    public var message: String
    public var elapsedSeconds: Double

    public init(modelId: String, testedAt: Date, structuredOutputWorks: Bool, reasoningEffortTested: ReasoningEffort,
                reasoningEffortAccepted: Bool?, message: String, elapsedSeconds: Double) {
        self.modelId = modelId
        self.testedAt = testedAt
        self.structuredOutputWorks = structuredOutputWorks
        self.reasoningEffortTested = reasoningEffortTested
        self.reasoningEffortAccepted = reasoningEffortAccepted
        self.message = message
        self.elapsedSeconds = elapsedSeconds
    }
}

public struct CachedModelList: Codable, Equatable, Sendable {
    public var models: [OpenAIModelInfo]
    public var fetchedAt: Date?
    public var verifications: [String: ModelVerification]
    public init(models: [OpenAIModelInfo] = [], fetchedAt: Date? = nil, verifications: [String: ModelVerification] = [:]) {
        self.models = models
        self.fetchedAt = fetchedAt
        self.verifications = verifications
    }
}

public enum ModelCatalog {
    /// Substrings identifying models that cannot produce text lesson notes
    /// (embeddings, images, audio, speech, realtime, moderation, legacy completions…).
    public static let excludedFragments: [String] = [
        "embedding", "embed", "whisper", "tts", "transcribe", "audio", "realtime", "dall-e", "dalle", "image",
        "moderation", "sora", "video", "davinci", "babbage", "ada-", "curie", "instruct", "search", "computer-use",
        "speech", "voice", "diariz",
    ]

    /// Whether a model id plausibly supports text generation. This is a filter, not a
    /// capability claim — the Test Model button verifies actual support.
    public static func isLikelyTextModel(_ id: String) -> Bool {
        let lower = id.lowercased()
        if excludedFragments.contains(where: { lower.contains($0) }) { return false }
        // Text-generation families use these prefixes; fine-tunes are "ft:<base>…".
        let base = lower.hasPrefix("ft:") ? String(lower.dropFirst(3)) : lower
        let prefixes = ["gpt-", "o1", "o3", "o4", "o5", "o6", "o7", "chatgpt-", "codex-"]
        return prefixes.contains(where: { base.hasPrefix($0) })
    }

    /// Filter + sort: newest first, then alphabetical.
    public static func filterForNotes(_ models: [OpenAIModelInfo]) -> [OpenAIModelInfo] {
        models.filter { isLikelyTextModel($0.id) }.sorted {
            let a = $0.created ?? 0, b = $1.created ?? 0
            return a != b ? a > b : $0.id < $1.id
        }
    }

    public static func search(_ models: [OpenAIModelInfo], query: String) -> [OpenAIModelInfo] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return models }
        let parts = q.split(separator: " ").map(String.init)
        return models.filter { m in parts.allSatisfy { m.id.lowercased().contains($0) } }
    }

    public enum Availability: Equatable, Sendable {
        case available
        case notInList
        case unknown // no list fetched yet
    }

    /// Whether the selected model is in the account's model list (never auto-replaced).
    public static func availability(of modelId: String, in list: CachedModelList) -> Availability {
        guard list.fetchedAt != nil, !list.models.isEmpty else { return .unknown }
        return list.models.contains { $0.id == modelId } ? .available : .notInList
    }
}

/// Runs a small structured-output request with harmless sample data (never a pupil transcript).
public enum ModelTester {
    public static let sampleTranscript = """
    [00:00] Tutor: Good afternoon! Today we're going to look at the water cycle.
    [00:12] Pupil: Is that when water goes up into the clouds?
    [00:18] Tutor: Exactly. When the sun warms the sea, water evaporates and becomes water vapour.
    [00:35] Pupil: And then it cools down and makes clouds — condensation!
    [00:41] Tutor: Brilliant. Then it falls as rain, which we call precipitation.
    [01:02] Tutor: For homework, please draw and label the water cycle in your book.
    """

    public static func run(client: OpenAIClient, model: String, effort: ReasoningEffort, now: () -> Date = Date.init) async -> ModelVerification {
        let started = now()
        let req = ResponsesRequest(
            model: model,
            instructions: PromptLibrary.effectiveInstructions(basePrompt: PromptLibrary.starterGlobalPrompt),
            userContent: "This is a TEST with invented sample data, not a real lesson.\nPupil: Sample Pupil\nLesson date: 1 January 2026\nTranscript:\n" + sampleTranscript,
            reasoningEffort: effort)
        func done(_ ok: Bool, _ accepted: Bool?, _ msg: String) -> ModelVerification {
            ModelVerification(modelId: model, testedAt: now(), structuredOutputWorks: ok, reasoningEffortTested: effort,
                              reasoningEffortAccepted: accepted, message: msg, elapsedSeconds: now().timeIntervalSince(started))
        }
        do {
            let result = try await client.createResponse(req)
            let notes = try NotesSchema.parse(result.outputText)
            return done(true, effort.apiValue == nil ? nil : true,
                        "Success — the model returned valid lesson-notes JSON (title: “\(notes.title)”).")
        } catch let e as OpenAIError {
            if case .reasoningUnsupported = e { return done(false, false, e.localizedDescription) }
            return done(false, nil, e.localizedDescription)
        } catch let e as NotesSchema.ParseError {
            return done(false, nil, e.localizedDescription)
        } catch {
            return done(false, nil, error.localizedDescription)
        }
    }
}
