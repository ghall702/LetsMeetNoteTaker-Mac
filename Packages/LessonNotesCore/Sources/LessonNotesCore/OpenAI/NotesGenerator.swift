import Foundation

public enum TranscriptChunker {
    /// Rough token estimate (≈ 4 characters per token for English).
    public static func estimateTokens(_ s: String) -> Int { (s.utf8.count + 3) / 4 }

    /// Splits on line boundaries into chunks of at most `maxTokens` (estimated).
    public static func chunk(_ text: String, maxTokens: Int) -> [String] {
        let maxChars = max(1000, maxTokens * 4)
        if text.utf8.count <= maxChars { return [text] }
        var chunks: [String] = []
        var current = ""
        func push() { if !current.isEmpty { chunks.append(current); current = "" } }
        for lineSub in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(lineSub)
            while line.utf8.count > maxChars {
                push()
                let idx = line.index(line.startIndex, offsetBy: min(line.count, maxChars / 2))
                chunks.append(String(line[..<idx]))
                line = String(line[idx...])
            }
            if current.utf8.count + line.utf8.count + 1 > maxChars { push() }
            current += current.isEmpty ? line : "\n" + line
        }
        push()
        return chunks
    }
}

public struct NotesRequestContext: Sendable, Equatable {
    public var pupilName: String
    public var pupilContext: String
    public var lessonDate: String
    public var recordingSummary: String
    /// Lesson files attached by the tutor (sent after the transcript).
    public var materials: [ContextMaterial]

    public init(pupilName: String, pupilContext: String = "", lessonDate: String, recordingSummary: String = "", materials: [ContextMaterial] = []) {
        self.pupilName = pupilName
        self.pupilContext = pupilContext
        self.lessonDate = lessonDate
        self.recordingSummary = recordingSummary
        self.materials = materials
    }

    /// Explains the attached files to the model.
    func materialsIntro() -> String {
        guard !materials.isEmpty else { return "" }
        var s = "Lesson files (included after the transcript; the pupil will also be able to download them with these notes):\n"
        for m in materials { s += "- \(m.label)\n" }
        s += """
        Use these files as context alongside the transcript. Base the notes on what was actually taught in the lesson, and use the files to         get details right (exact questions, wording, examples) and to refer the pupil to them where helpful. Slides show what was presented.         Student work is the pupil's own attempt: do not present its mistakes as correct, and use it to inform praise, next steps and private notes.         Exemplar material is the tutor's model of good work: use it to explain what a strong answer looks like. Do not invent content from the files         that was not part of the lesson.

        """
        return s
    }

    func header() -> String {
        var s = "Pupil: \(pupilName)\n"
        if !pupilContext.trimmingCharacters(in: .whitespaces).isEmpty { s += "Pupil context: \(pupilContext)\n" }
        s += "Lesson date: \(CoreFormat.longUKDate(lessonDate))\n"
        if !recordingSummary.isEmpty { s += "Recordings: \(recordingSummary)\n" }
        s += materialsIntro()
        return s
    }
}

public protocol ResponsesPerforming: Sendable {
    func perform(_ request: ResponsesRequest, onProgress: (@Sendable (Int) -> Void)?) async throws -> ResponsesResult
}

extension OpenAIClient: ResponsesPerforming {
    public func perform(_ request: ResponsesRequest, onProgress: (@Sendable (Int) -> Void)?) async throws -> ResponsesResult {
        try await streamResponse(request, onProgress: onProgress)
    }
}

public struct GenerationResult: Sendable, Equatable {
    public var notes: GeneratedNotes
    public var adjustments: [String]
    /// True if the output limit forced the notes to be written in two parts.
    public var usedSplitGeneration: Bool
}

/// Generates lesson notes, chunking very long transcripts (map → reduce).
/// Output is only accepted when OpenAI reports the response as completed and the
/// whole JSON validates. If the model hits its output limit, the notes are written
/// in two parts (teaching content, then everything else) and merged; if that is still
/// incomplete the job fails — truncated notes are never saved or submitted.
public struct NotesGenerator: Sendable {
    public var performer: ResponsesPerforming
    public var model: String
    public var effort: ReasoningEffort
    /// Transcripts estimated above this many tokens are chunked.
    public var chunkThresholdTokens: Int
    /// `max_output_tokens`; nil lets OpenAI use the model's own maximum.
    public var maxOutputTokens: Int?

    public init(performer: ResponsesPerforming, model: String, effort: ReasoningEffort, chunkThresholdTokens: Int = 100_000,
                maxOutputTokens: Int? = nil) {
        self.performer = performer
        self.model = model
        self.effort = effort
        self.chunkThresholdTokens = max(4_000, chunkThresholdTokens)
        self.maxOutputTokens = maxOutputTokens
    }

    public static func userContent(context: NotesRequestContext, transcript: String) -> String {
        context.header() + "Transcript:\n" + transcript
    }

    static let teachingOnly = """


    OUTPUT SPLIT (part 1 of 2): In this response write ONLY `title`, `learning_content` and `worked_examples`, in full. \
    Return "" or [] for every other field; they are written separately.
    """
    static let everythingElse = """


    OUTPUT SPLIT (part 2 of 2): In this response write every field EXCEPT `learning_content` and `worked_examples`, which must be "" and []. \
    They are written separately, so do not summarise them elsewhere.
    """

    /// One complete structured response; on an output-limit stop, splits the output in two.
    func completeNotes(instructions: String, content: String, materials: [ContextMaterial] = [],
                       onProgress: (@Sendable (Int) -> Void)?) async throws -> (GeneratedNotes, Bool) {
        do {
            let r = try await performer.perform(ResponsesRequest(model: model, instructions: instructions, userContent: content,
                                                                  reasoningEffort: effort, maxOutputTokens: maxOutputTokens, materials: materials), onProgress: onProgress)
            return (try parse(r.outputText), false)
        } catch OpenAIError.incomplete(let reason) where reason == "max_output_tokens" {
            let a = try await performer.perform(ResponsesRequest(model: model, instructions: instructions + Self.teachingOnly, userContent: content,
                                                                  reasoningEffort: effort, maxOutputTokens: maxOutputTokens, materials: materials), onProgress: onProgress)
            let b = try await performer.perform(ResponsesRequest(model: model, instructions: instructions + Self.everythingElse, userContent: content,
                                                                  reasoningEffort: effort, maxOutputTokens: maxOutputTokens, materials: materials), onProgress: onProgress)
            let teaching = try parse(a.outputText)
            var merged = try parse(b.outputText)
            merged.learningContent = teaching.learningContent
            merged.workedExamples = teaching.workedExamples
            if merged.title.trimmingCharacters(in: .whitespaces).isEmpty { merged.title = teaching.title }
            return (merged, true)
        }
    }

    /// `progress` is called with a 0...1 fraction (approximate, by request).
    public func generateDetailed(transcript: String, context: NotesRequestContext, instructions: String,
                                 progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> GenerationResult {
        let chunks = TranscriptChunker.estimateTokens(transcript) > chunkThresholdTokens
            ? TranscriptChunker.chunk(transcript, maxTokens: chunkThresholdTokens * 3 / 4)
            : [transcript]

        if chunks.count == 1 {
            progress?(0.05, "Writing lesson notes…")
            let (raw, split) = try await completeNotes(instructions: instructions, content: Self.userContent(context: context, transcript: transcript),
                                                       materials: context.materials) { chars in
                progress?(min(0.95, 0.1 + Double(chars) / 12000.0), "Writing lesson notes…")
            }
            let n = NotesSchema.normalise(raw)
            return GenerationResult(notes: n.notes, adjustments: n.adjustments, usedSplitGeneration: split)
        }

        var partials: [GeneratedNotes] = []
        var split = false
        let total = Double(chunks.count + 1)
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress?(Double(i) / total, "Summarising part \(i + 1) of \(chunks.count)…")
            var partContext = context
            partContext.materials = [] // files are given once, when the parts are combined
            let content = partContext.header()
                + "This is part \(i + 1) of \(chunks.count) of the transcript of ONE lesson. Write notes for this part only; they will be merged later.\n"
                + "Transcript (part \(i + 1)):\n" + chunk
            let (notes, s) = try await withPurpose(.notesPart) { try await completeNotes(instructions: instructions, content: content, onProgress: nil) }
            split = split || s
            partials.append(NotesSchema.sanitise(notes))
        }
        progress?(Double(chunks.count) / total, "Combining notes…")
        let encoded = (try? JSONCoding.encoder(pretty: true).encode(partials)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let reduceInstructions = instructions + """


        You are now combining partial notes written for consecutive parts of ONE lesson into a single final set of notes. \
        Merge and de-duplicate them into one coherent version of every field (keep the full teaching detail in `learning_content` and every distinct worked example), \
        write one overall title and overview, and keep private observations in `private_notes`. Do not add anything that is not in the partial notes (lesson files, if included, may only be used to get details right). \
        Fields that are empty in every part stay empty.
        """
        let (raw, s) = try await withPurpose(.notesCombine) {
            try await completeNotes(instructions: reduceInstructions, content: context.header() + "Partial notes (JSON):\n" + encoded,
                                    materials: context.materials, onProgress: nil)
        }
        let n = NotesSchema.normalise(raw)
        return GenerationResult(notes: n.notes, adjustments: n.adjustments, usedSplitGeneration: split || s)
    }

    public func generate(transcript: String, context: NotesRequestContext, instructions: String,
                         progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> GeneratedNotes {
        try await generateDetailed(transcript: transcript, context: context, instructions: instructions, progress: progress).notes
    }

    /// Labels usage records for chunked notes (only when a lesson context is set).
    func withPurpose<T>(_ p: UsagePurpose, _ body: () async throws -> T) async throws -> T {
        guard var ctx = UsageContext.current, ctx.purpose == .lessonNotes else { return try await body() }
        ctx.purpose = p
        return try await UsageContext.$current.withValue(ctx) { try await body() }
    }

    func parse(_ text: String) throws -> GeneratedNotes {
        do { return try NotesSchema.parse(text) }
        catch { throw OpenAIError.invalidOutput(error.localizedDescription) }
    }
}
