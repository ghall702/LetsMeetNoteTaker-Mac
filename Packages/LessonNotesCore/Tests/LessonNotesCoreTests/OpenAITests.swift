import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

let validNotesJSON = ###"{"title":"The water cycle","overview":"We learned about evaporation.","key_points":["Evaporation"],"next_steps":["Draw it"],"homework":"Draw and label the water cycle.","vocabulary":["evaporation"],"praise":"Great answers!","key_quotes":[],"learning_content":"## Evaporation\nWater turns into **vapour**.","worked_examples":[],"private_notes":""}"###

func responseObject(text: String) -> String {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
    return #"{"id":"resp_1","status":"completed","model":"m","output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":\#(escaped)}]}]}"#
}

final class OpenAIRequestTests: XCTestCase {
    func testRequestBodyShape() throws {
        let r = ResponsesRequest(model: "gpt-x", instructions: "Do it", userContent: "Transcript", reasoningEffort: .modelDefault)
        let b = r.body(stream: true)
        XCTAssertEqual(b["store"] as? Bool, false)
        XCTAssertEqual(b["stream"] as? Bool, true)
        XCTAssertNil(b["reasoning"], "no reasoning parameter unless chosen")
        XCTAssertNil(b["temperature"])
        let format = (b["text"] as! [String: Any])["format"] as! [String: Any]
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
        XCTAssertEqual(format["name"] as? String, "lesson_notes")
        let schema = format["schema"] as! [String: Any]
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as! [String], ["title", "overview", "key_points", "next_steps", "homework", "vocabulary", "praise",
                                                         "key_quotes", "learning_content", "worked_examples", "private_notes"])
        let input = b["input"] as! [[String: Any]]
        XCTAssertEqual(input[0]["role"] as? String, "user")
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: b))

        let withEffort = ResponsesRequest(model: "o", instructions: "", userContent: "", reasoningEffort: .high).body(stream: false)
        XCTAssertEqual((withEffort["reasoning"] as? [String: Any])?["effort"] as? String, "high")
    }

    func testCreateResponseParsesOutputText() async throws {
        let t = StubTransport { _ in StubTransport.json(200, responseObject(text: validNotesJSON)) }
        let c = try OpenAIClient(apiKey: "sk-test", transport: t)
        let r = try await c.createResponse(ResponsesRequest(model: "m", instructions: "i", userContent: "u"))
        XCTAssertEqual(try NotesSchema.parse(r.outputText).title, "The water cycle")
        XCTAssertEqual(t.requests.value[0].url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(t.requests.value[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")
    }

    func testStreamingParsesDeltasAndCompletion() async throws {
        let escaped = String(data: try JSONSerialization.data(withJSONObject: [String(validNotesJSON.prefix(20))]), encoding: .utf8)!.dropFirst().dropLast()
        let sse = """
        event: response.created
        data: {"type":"response.created","response":{"id":"r"}}

        event: response.output_text.delta
        data: {"type":"response.output_text.delta","delta":\(escaped)}

        event: response.completed
        data: {"type":"response.completed","response":\(responseObject(text: validNotesJSON))}

        """
        let t = StubTransport { _ in StubTransport.json(200, sse) }
        let c = try OpenAIClient(apiKey: "sk", transport: t)
        let progress = Box<Int>(0)
        let r = try await c.streamResponse(ResponsesRequest(model: "m", instructions: "i", userContent: "u")) { n in progress.value = n }
        XCTAssertEqual(r.outputText, validNotesJSON)
        XCTAssertEqual(progress.value, 20)
        XCTAssertEqual(t.requests.value[0].value(forHTTPHeaderField: "Accept"), "text/event-stream")
    }

    func testRefusalAndIncomplete() async throws {
        let refusal = #"{"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"I can't help"}]}]}"#
        let c1 = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, refusal) })
        do { _ = try await c1.createResponse(ResponsesRequest(model: "m", instructions: "", userContent: "")); XCTFail() }
        catch let e as OpenAIError { XCTAssertEqual(e, .refusal("I can't help")); XCTAssertFalse(e.isRetryable) }
        let inc = #"{"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output":[]}"#
        let c2 = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, inc) })
        do { _ = try await c2.createResponse(ResponsesRequest(model: "m", instructions: "", userContent: "")); XCTFail() }
        catch let e as OpenAIError { XCTAssertEqual(e, .incomplete("max_output_tokens")) }
    }

    func testErrorMapping() {
        func map(_ s: Int, _ body: String) -> OpenAIError { OpenAIClient.mapError(status: s, data: Data(body.utf8), retryAfter: 7) }
        XCTAssertEqual(map(401, #"{"error":{"message":"Incorrect API key"}}"#), .invalidKey("Incorrect API key"))
        XCTAssertEqual(map(404, #"{"error":{"message":"The model `x` does not exist","code":"model_not_found"}}"#), .modelUnavailable("The model `x` does not exist"))
        XCTAssertEqual(map(400, #"{"error":{"message":"Unsupported parameter: 'reasoning.effort' is not supported with this model.","param":"reasoning.effort"}}"#),
                       .reasoningUnsupported("Unsupported parameter: 'reasoning.effort' is not supported with this model."))
        XCTAssertEqual(map(400, #"{"error":{"message":"Invalid parameter: 'text.format' of type 'json_schema' is not supported with this model.","param":"text.format"}}"#),
                       .structuredOutputUnsupported("Invalid parameter: 'text.format' of type 'json_schema' is not supported with this model."))
        XCTAssertEqual(map(429, #"{"error":{"message":"quota","code":"insufficient_quota"}}"#), .quotaExceeded("quota"))
        XCTAssertEqual(map(429, #"{"error":{"message":"slow"}}"#), .rateLimited("slow", retryAfter: 7))
        XCTAssertTrue(map(503, "").isRetryable)
        XCTAssertFalse(map(401, "").isRetryable)
        XCTAssertFalse(map(429, #"{"error":{"message":"q","code":"insufficient_quota"}}"#).isRetryable)
    }
}

final class ModelDiscoveryTests: XCTestCase {
    let list = #"{"object":"list","data":[{"id":"text-embedding-3-large","created":1,"owned_by":"system"},{"id":"gpt-image-1","created":2,"owned_by":"system"},{"id":"whisper-1","created":3,"owned_by":"system"},{"id":"gpt-4o-mini-tts","created":4,"owned_by":"system"},{"id":"gpt-4o-realtime-preview","created":5,"owned_by":"system"},{"id":"omni-moderation-latest","created":6,"owned_by":"system"},{"id":"gpt-4o-transcribe","created":7,"owned_by":"system"},{"id":"dall-e-3","created":8,"owned_by":"system"},{"id":"gpt-3.5-turbo-instruct","created":9,"owned_by":"system"},{"id":"gpt-4.1","created":100,"owned_by":"system"},{"id":"o4-mini","created":200,"owned_by":"system"},{"id":"gpt-future-9","created":900,"owned_by":"system"},{"id":"ft:gpt-4.1-mini:acme::abc","created":300,"owned_by":"acme"},{"id":"babbage-002","created":10,"owned_by":"system"}]}"#

    func testListsAndFiltersModels() async throws {
        let t = StubTransport { _ in StubTransport.json(200, self.list) }
        let models = try await OpenAIClient(apiKey: "sk", transport: t).listModels()
        XCTAssertEqual(t.requests.value[0].url?.absoluteString, "https://api.openai.com/v1/models")
        let filtered = ModelCatalog.filterForNotes(models).map(\.id)
        XCTAssertEqual(filtered, ["gpt-future-9", "ft:gpt-4.1-mini:acme::abc", "o4-mini", "gpt-4.1"], "newest first; new families kept without a hard-coded list")
    }

    func testSearch() {
        let m = ["gpt-4.1", "gpt-4.1-mini", "o4-mini"].map { OpenAIModelInfo(id: $0) }
        XCTAssertEqual(ModelCatalog.search(m, query: "mini").map(\.id), ["gpt-4.1-mini", "o4-mini"])
        XCTAssertEqual(ModelCatalog.search(m, query: "4.1 mini").map(\.id), ["gpt-4.1-mini"])
        XCTAssertEqual(ModelCatalog.search(m, query: "").count, 3)
    }

    func testAvailabilityNeverSilentlyChanges() {
        var cache = CachedModelList(models: [OpenAIModelInfo(id: "gpt-4.1")], fetchedAt: Date())
        XCTAssertEqual(ModelCatalog.availability(of: "gpt-4.1", in: cache), .available)
        XCTAssertEqual(ModelCatalog.availability(of: "retired-model", in: cache), .notInList)
        cache.fetchedAt = nil
        XCTAssertEqual(ModelCatalog.availability(of: "x", in: cache), .unknown)
    }

    func testCachedModelListPersists() throws {
        let h = try Harness()
        h.store.updateModelList { $0 = CachedModelList(models: [OpenAIModelInfo(id: "gpt-4.1", created: 1)], fetchedAt: Date(timeIntervalSince1970: 5)) }
        XCTAssertEqual(try LibraryStore(directory: h.store.directory).modelList.models.map(\.id), ["gpt-4.1"])
    }

    func testModelTesterSuccessUsesSampleDataOnly() async throws {
        let t = StubTransport { _ in StubTransport.json(200, responseObject(text: validNotesJSON)) }
        let v = await ModelTester.run(client: try OpenAIClient(apiKey: "sk", transport: t), model: "gpt-x", effort: .low)
        XCTAssertTrue(v.structuredOutputWorks)
        XCTAssertEqual(v.reasoningEffortAccepted, true)
        let body = bodyJSON(t.requests.value[0])
        XCTAssertEqual(body["model"] as? String, "gpt-x")
        XCTAssertEqual(body["store"] as? Bool, false)
        let content = ((body["input"] as! [[String: Any]])[0]["content"] as! String)
        XCTAssertTrue(content.contains("TEST with invented sample data"))
    }

    func testModelTesterReportsIncompatibility() async throws {
        let t = StubTransport { _ in StubTransport.json(400, #"{"error":{"message":"'reasoning.effort' is not supported","param":"reasoning.effort"}}"#) }
        let v = await ModelTester.run(client: try OpenAIClient(apiKey: "sk", transport: t), model: "gpt-x", effort: .high)
        XCTAssertFalse(v.structuredOutputWorks)
        XCTAssertEqual(v.reasoningEffortAccepted, false)
        XCTAssertTrue(v.message.contains("reasoning effort"))

        let bad = StubTransport { _ in StubTransport.json(200, responseObject(text: "not json")) }
        let v2 = await ModelTester.run(client: try OpenAIClient(apiKey: "sk", transport: bad), model: "gpt-y", effort: .modelDefault)
        XCTAssertFalse(v2.structuredOutputWorks)
        XCTAssertNil(v2.reasoningEffortAccepted)
    }
}

final class NotesSchemaAndGeneratorTests: XCTestCase {
    func testParseRejectsMissingOrExtraKeys() {
        XCTAssertThrowsError(try NotesSchema.parse(#"{"title":"x"}"#))
        XCTAssertThrowsError(try NotesSchema.parse(validNotesJSON.replacingOccurrences(of: "}", with: #","audio":"x"}"#)))
        XCTAssertThrowsError(try NotesSchema.parse(validNotesJSON.replacingOccurrences(of: #""The water cycle""#, with: #""  ""#)))
        XCTAssertThrowsError(try NotesSchema.parse(validNotesJSON.replacingOccurrences(of: #"["Evaporation"]"#, with: #""Evaporation""#)))
        XCTAssertNoThrow(try NotesSchema.parse(validNotesJSON))
    }

    func testSanitiseFitsServerLimits() {
        let n = GeneratedNotes(title: String(repeating: "t", count: 300), overview: " o ", keyPoints: Array(repeating: "", count: 3) + (0..<40).map { "p\($0)" },
                               nextSteps: ["a", "A", "b"], vocabulary: [String(repeating: "v", count: 250)], praise: String(repeating: "😀", count: 600))
        let s = NotesSchema.sanitise(n)
        XCTAssertLessThanOrEqual(s.title.utf16.count, 200)
        XCTAssertEqual(s.overview, "o")
        XCTAssertEqual(s.keyPoints.count, 30)
        XCTAssertEqual(s.nextSteps, ["a", "b"])
        XCTAssertLessThanOrEqual(s.vocabulary[0].utf16.count, 200)
        XCTAssertLessThanOrEqual(s.praise.utf16.count, 1000)
        let summary = NotesSchema.summary(from: GeneratedNotes(title: "T"))
        XCTAssertEqual(summary.homework, "")
        XCTAssertEqual(summary.keyPoints, [])
    }

    struct ScriptedPerformer: ResponsesPerforming {
        let requests = Box<[ResponsesRequest]>([])
        func perform(_ request: ResponsesRequest, onProgress: (@Sendable (Int) -> Void)?) async throws -> ResponsesResult {
            requests.mutate { $0.append(request) }
            return ResponsesResult(outputText: validNotesJSON, refusal: nil, status: "completed", incompleteReason: nil, model: request.model)
        }
    }

    func testShortTranscriptSingleRequestWithSelectedModel() async throws {
        let p = ScriptedPerformer()
        let g = NotesGenerator(performer: p, model: "chosen-model", effort: .medium)
        let notes = try await g.generate(transcript: "short", context: NotesRequestContext(pupilName: "Ellie", pupilContext: "Year 5", lessonDate: "2026-11-14"),
                                         instructions: "INSTR")
        XCTAssertEqual(notes.title, "The water cycle")
        XCTAssertEqual(p.requests.value.count, 1)
        XCTAssertEqual(p.requests.value[0].model, "chosen-model")
        XCTAssertEqual(p.requests.value[0].reasoningEffort, .medium)
        XCTAssertTrue(p.requests.value[0].userContent.hasPrefix("Pupil: Ellie\nPupil context: Year 5\nLesson date: 14 November 2026\n"))
    }

    func testLongTranscriptIsChunkedThenConsolidated() async throws {
        let p = ScriptedPerformer()
        let g = NotesGenerator(performer: p, model: "m", effort: .modelDefault, chunkThresholdTokens: 10_000)
        let line = String(repeating: "word ", count: 20)
        let transcript = Array(repeating: line, count: 2000).joined(separator: "\n") // ~200k chars ≈ 50k tokens
        _ = try await g.generate(transcript: transcript, context: NotesRequestContext(pupilName: "E", lessonDate: "2026-11-14"), instructions: "I")
        let reqs = p.requests.value
        XCTAssertGreaterThan(reqs.count, 2)
        XCTAssertTrue(reqs.last!.userContent.contains("Partial notes (JSON)"))
        XCTAssertTrue(reqs.last!.instructions.contains("combining partial notes"))
        // Every chunk together covers the whole transcript.
        let chunks = TranscriptChunker.chunk(transcript, maxTokens: 7_500)
        XCTAssertEqual(chunks.joined(separator: "\n"), transcript)
    }
}
