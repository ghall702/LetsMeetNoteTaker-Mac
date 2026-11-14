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

    public init(pupilName: String, pupilContext: String = "", lessonDate: String, recordingSummary: String = "") {
        self.pupilName = pupilName
        self.pupilContext = pupilContext
        self.lessonDate = lessonDate
        self.recordingSummary = recordingSummary
    }

    func header() -> String {
        var s = "Pupil: \(pupilName)\n"
        if !pupilContext.trimmingCharacters(in: .whitespaces).isEmpty { s += "Pupil context: \(pupilContext)\n" }
        s += "Lesson date: \(CoreFormat.longUKDate(lessonDate))\n"
        if !recordingSummary.isEmpty { s += "Recordings: \(recordingSummary)\n" }
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

/// Generates lesson notes, chunking very long transcripts (map → reduce).
public struct NotesGenerator: Sendable {
    public var performer: ResponsesPerforming
    public var model: String
    public var effort: ReasoningEffort
    /// Transcripts estimated above this many tokens are chunked.
    public var chunkThresholdTokens: Int

    public init(performer: ResponsesPerforming, model: String, effort: ReasoningEffort, chunkThresholdTokens: Int = 100_000) {
        self.performer = performer
        self.model = model
        self.effort = effort
        self.chunkThresholdTokens = max(4_000, chunkThresholdTokens)
    }

    public static func userContent(context: NotesRequestContext, transcript: String) -> String {
        context.header() + "Transcript:\n" + transcript
    }

    /// `progress` is called with a 0...1 fraction (approximate, by request).
    public func generate(transcript: String, context: NotesRequestContext, instructions: String,
                         progress: (@Sendable (Double, String) -> Void)? = nil) async throws -> GeneratedNotes {
        let chunks = TranscriptChunker.estimateTokens(transcript) > chunkThresholdTokens
            ? TranscriptChunker.chunk(transcript, maxTokens: chunkThresholdTokens * 3 / 4)
            : [transcript]

        if chunks.count == 1 {
            progress?(0.05, "Writing lesson notes…")
            let r = try await performer.perform(ResponsesRequest(model: model, instructions: instructions,
                                                                  userContent: Self.userContent(context: context, transcript: transcript),
                                                                  reasoningEffort: effort)) { chars in
                progress?(min(0.95, 0.1 + Double(chars) / 4000.0), "Writing lesson notes…")
            }
            return try parse(r.outputText)
        }

        var partials: [GeneratedNotes] = []
        let total = Double(chunks.count + 1)
        for (i, chunk) in chunks.enumerated() {
            try Task.checkCancellation()
            progress?(Double(i) / total, "Summarising part \(i + 1) of \(chunks.count)…")
            let content = context.header()
                + "This is part \(i + 1) of \(chunks.count) of the transcript of ONE lesson. Write notes for this part only; they will be merged later.\n"
                + "Transcript (part \(i + 1)):\n" + chunk
            let r = try await performer.perform(ResponsesRequest(model: model, instructions: instructions, userContent: content,
                                                                  reasoningEffort: effort), onProgress: nil)
            partials.append(try parse(r.outputText))
        }
        progress?(Double(chunks.count) / total, "Combining notes…")
        let encoded = (try? JSONCoding.encoder(pretty: true).encode(partials)).map { String(decoding: $0, as: UTF8.self) } ?? "[]"
        let reduceInstructions = instructions + """


        You are now combining partial notes written for consecutive parts of ONE lesson into a single final set of notes. \
        Merge and de-duplicate them, keep the most important points within the item limits, write one overall title and overview, \
        and keep private observations in `private_notes`. Do not add anything that is not in the partial notes.
        """
        let r = try await performer.perform(ResponsesRequest(model: model, instructions: reduceInstructions,
                                                              userContent: context.header() + "Partial notes (JSON):\n" + encoded,
                                                              reasoningEffort: effort), onProgress: nil)
        return try parse(r.outputText)
    }

    func parse(_ text: String) throws -> GeneratedNotes {
        do { return NotesSchema.sanitise(try NotesSchema.parse(text)) }
        catch { throw OpenAIError.invalidOutput(error.localizedDescription) }
    }
}
