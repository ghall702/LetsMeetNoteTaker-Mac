import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ReasoningEffort: String, Codable, CaseIterable, Sendable, Identifiable {
    case modelDefault = "default"
    case none, minimal, low, medium, high, xhigh

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .modelDefault: return "Model default (not sent)"
        case .none: return "None"
        case .minimal: return "Minimal"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        }
    }
    /// Value for `reasoning.effort`, or nil to omit the parameter.
    public var apiValue: String? { self == .modelDefault ? nil : rawValue }
}

public enum OpenAIError: Error, LocalizedError, Equatable, Sendable {
    case missingKey
    case invalidKey(String)
    case permissionDenied(String)
    case modelUnavailable(String)
    case reasoningUnsupported(String)
    case structuredOutputUnsupported(String)
    case badRequest(String)
    case rateLimited(String, retryAfter: TimeInterval?)
    case quotaExceeded(String)
    case server(Int, String)
    case refusal(String)
    case emptyOutput
    case incomplete(String)
    case streamInterrupted
    case invalidOutput(String)
    case unexpected(String)

    public var errorDescription: String? {
        switch self {
        case .missingKey: return "Add your OpenAI API key in Settings."
        case .invalidKey(let m): return "Check your OpenAI key in Settings. (\(m))"
        case .permissionDenied(let m): return "Your OpenAI key does not have permission for this request. \(m)"
        case .modelUnavailable(let m): return "The selected OpenAI model is not available to your account. Choose another model in Settings. (\(m))"
        case .reasoningUnsupported(let m): return "This model does not accept the chosen reasoning effort. Set Reasoning effort to “Model default” or pick a different value. (\(m))"
        case .structuredOutputUnsupported(let m): return "This model does not support structured JSON output, which lesson notes require. Choose another model. (\(m))"
        case .badRequest(let m): return "OpenAI rejected the request: \(m)"
        case .rateLimited(let m, _): return "OpenAI rate limit reached; will retry. (\(m))"
        case .quotaExceeded: return JobError.creditsMessage
        case .server(let s, let m): return "OpenAI server error \(s); will retry. \(m)"
        case .refusal(let m): return "OpenAI declined to write notes." + (m.isEmpty ? "" : " (\(m))")
        case .emptyOutput: return "OpenAI declined to write notes (empty response)."
        case .incomplete(let r):
            return r == "max_output_tokens"
                ? "OpenAI reached its output limit before finishing the notes, even when the notes were generated in two parts. Nothing incomplete was saved. Try a model with a larger output limit, a lower reasoning effort, or raise “Maximum output tokens” in Settings → OpenAI."
                : "OpenAI stopped before finishing the notes (\(r)). Nothing incomplete was saved."
        case .streamInterrupted: return "The connection to OpenAI ended before the notes were complete; will retry. Nothing incomplete was saved."
        case .invalidOutput(let m): return "OpenAI returned notes in an unexpected format: \(m)"
        case .unexpected(let m): return "Unexpected OpenAI response: \(m)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .rateLimited, .server, .streamInterrupted: return true
        default: return false
        }
    }

    public var retryAfter: TimeInterval? {
        if case .rateLimited(_, let r) = self { return r }
        return nil
    }
}

public struct OpenAIModelInfo: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var created: Int?
    public var ownedBy: String?
    enum CodingKeys: String, CodingKey { case id, created, ownedBy = "owned_by" }
    public init(id: String, created: Int? = nil, ownedBy: String? = nil) { self.id = id; self.created = created; self.ownedBy = ownedBy }
}

struct ModelsListResponse: Codable { var data: [OpenAIModelInfo] }

public struct ResponsesRequest: Sendable, Equatable {
    public var model: String
    public var instructions: String
    public var userContent: String
    public var reasoningEffort: ReasoningEffort
    public var maxOutputTokens: Int?

    public init(model: String, instructions: String, userContent: String, reasoningEffort: ReasoningEffort = .modelDefault, maxOutputTokens: Int? = nil) {
        self.model = model
        self.instructions = instructions
        self.userContent = userContent
        self.reasoningEffort = reasoningEffort
        self.maxOutputTokens = maxOutputTokens
    }

    /// JSON body for `POST /v1/responses`. `store` is always false.
    public func body(stream: Bool) -> [String: Any] {
        var b: [String: Any] = [
            "model": model,
            "store": false,
            "instructions": instructions,
            "input": [["role": "user", "content": userContent]],
            "text": NotesSchema.textFormat,
            "stream": stream,
        ]
        if let e = reasoningEffort.apiValue { b["reasoning"] = ["effort": e] }
        if let m = maxOutputTokens { b["max_output_tokens"] = m }
        return b
    }
}

public struct ResponsesResult: Sendable, Equatable {
    public var outputText: String
    public var refusal: String?
    public var status: String
    public var incompleteReason: String?
    public var model: String?
}

public struct OpenAIClient: Sendable {
    public static let defaultBaseURL = URL(string: "https://api.openai.com/v1")!
    public var apiKey: String
    public var baseURL: URL
    public var transport: HTTPTransport

    public init(apiKey: String, transport: HTTPTransport, baseURL: URL = OpenAIClient.defaultBaseURL) throws {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw OpenAIError.missingKey }
        self.apiKey = key
        self.transport = transport
        self.baseURL = baseURL
    }

    func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, stream: Bool = false) throws -> URLRequest {
        var r = URLRequest(url: baseURL.appendingPathComponent(path))
        r.httpMethod = method
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        r.timeoutInterval = stream ? 600 : 300
        if let json {
            r.httpBody = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return r
    }

    // MARK: Errors

    public static func mapError(status: Int, data: Data, retryAfter: TimeInterval?) -> OpenAIError {
        var message = "HTTP \(status)"
        var code: String?
        var param: String?
        var type: String?
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let err = obj["error"] as? [String: Any] {
            message = (err["message"] as? String) ?? message
            code = err["code"] as? String
            param = err["param"] as? String
            type = err["type"] as? String
        }
        let lower = message.lowercased()
        if code == "insufficient_quota" || type == "insufficient_quota" || JobError.looksLikeOpenAICredits(message) {
            return .quotaExceeded(message)
        }
        switch status {
        case 401: return .invalidKey(message)
        case 403: return .permissionDenied(message)
        case 404: return .modelUnavailable(message)
        case 429:
            if code == "insufficient_quota" || type == "insufficient_quota" { return .quotaExceeded(message) }
            return .rateLimited(message, retryAfter: retryAfter)
        case 500...599: return .server(status, message)
        default:
            if code == "model_not_found" || lower.contains("does not exist") || lower.contains("model_not_found") {
                return .modelUnavailable(message)
            }
            if (param ?? "").hasPrefix("reasoning") || lower.contains("reasoning.effort") || lower.contains("reasoning effort") {
                return .reasoningUnsupported(message)
            }
            if (param ?? "").hasPrefix("text.format") || lower.contains("json_schema") || lower.contains("text.format") || lower.contains("structured output") {
                return .structuredOutputUnsupported(message)
            }
            return .badRequest(message)
        }
    }

    // MARK: Models

    public func listModels() async throws -> [OpenAIModelInfo] {
        let (data, http) = try await transport.send(try request("models"))
        guard http.statusCode == 200 else { throw Self.mapError(status: http.statusCode, data: data, retryAfter: http.retryAfterSeconds) }
        do { return try JSONDecoder().decode(ModelsListResponse.self, from: data).data }
        catch { throw OpenAIError.unexpected("could not read the model list") }
    }

    // MARK: Responses

    /// Extracts output text / refusal from a Responses API `response` object.
    public static func parseResponseObject(_ obj: [String: Any]) -> ResponsesResult {
        var text = ""
        var refusal: String?
        if let output = obj["output"] as? [[String: Any]] {
            for item in output where (item["type"] as? String) == "message" {
                for part in (item["content"] as? [[String: Any]]) ?? [] {
                    switch part["type"] as? String {
                    case "output_text": text += (part["text"] as? String) ?? ""
                    case "refusal": refusal = (refusal ?? "") + ((part["refusal"] as? String) ?? "")
                    default: break
                    }
                }
            }
        }
        if text.isEmpty, let t = obj["output_text"] as? String { text = t }
        let incomplete = (obj["incomplete_details"] as? [String: Any])?["reason"] as? String
        return ResponsesResult(outputText: text, refusal: refusal, status: (obj["status"] as? String) ?? "completed",
                               incompleteReason: incomplete, model: obj["model"] as? String)
    }

    static func check(_ r: ResponsesResult) throws {
        if let refusal = r.refusal, !refusal.isEmpty { throw OpenAIError.refusal(refusal) }
        if r.status == "incomplete" { throw OpenAIError.incomplete(r.incompleteReason ?? "incomplete") }
        if r.status == "failed" { throw OpenAIError.unexpected("response failed") }
        if r.status != "completed" { throw OpenAIError.incomplete(r.status) }
        if r.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw OpenAIError.emptyOutput }
    }

    /// Non-streaming request.
    public func createResponse(_ req: ResponsesRequest) async throws -> ResponsesResult {
        let (data, http) = try await transport.send(try request("responses", method: "POST", json: req.body(stream: false)))
        guard http.statusCode == 200 else { throw Self.mapError(status: http.statusCode, data: data, retryAfter: http.retryAfterSeconds) }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw OpenAIError.unexpected("not JSON") }
        if let err = obj["error"] as? [String: Any], let m = err["message"] as? String {
            if (err["code"] as? String) == "insufficient_quota" || JobError.looksLikeOpenAICredits(m) { throw OpenAIError.quotaExceeded(m) }
            throw OpenAIError.unexpected(m)
        }
        let r = Self.parseResponseObject(obj)
        try Self.check(r)
        return r
    }

    /// Streaming request (`stream: true`). `onProgress` receives the number of output characters so far.
    public func streamResponse(_ req: ResponsesRequest, onProgress: (@Sendable (Int) -> Void)? = nil) async throws -> ResponsesResult {
        let (http, lines) = try await transport.streamLines(try request("responses", method: "POST", json: req.body(stream: true), stream: true))
        guard http.statusCode == 200 else {
            var body = ""
            for try await line in lines { body += line + "\n"; if body.count > 20_000 { break } }
            throw Self.mapError(status: http.statusCode, data: Data(body.utf8), retryAfter: http.retryAfterSeconds)
        }
        var parser = SSEParser()
        var accumulated = ""
        var refusal = ""
        var final: ResponsesResult?
        for try await line in lines {
            try Task.checkCancellation()
            guard let event = parser.feed(line) else { continue }
            switch event.type {
            case "response.output_text.delta":
                accumulated += (event.payload["delta"] as? String) ?? ""
                onProgress?(accumulated.count)
            case "response.refusal.delta":
                refusal += (event.payload["delta"] as? String) ?? ""
            case "response.completed", "response.incomplete":
                if let resp = event.payload["response"] as? [String: Any] { final = Self.parseResponseObject(resp) }
            case "response.failed":
                let resp = event.payload["response"] as? [String: Any]
                let err = resp?["error"] as? [String: Any]
                let msg = (err?["message"] as? String) ?? "response failed"
                let code = err?["code"] as? String
                if code == "insufficient_quota" || JobError.looksLikeOpenAICredits(msg) { throw OpenAIError.quotaExceeded(msg) }
                if code == "server_error" || code == "rate_limit_exceeded" { throw OpenAIError.server(500, msg) }
                throw OpenAIError.unexpected(msg)
            case "error":
                let err = (event.payload["error"] as? [String: Any]) ?? event.payload
                let msg = (err["message"] as? String) ?? "stream error"
                let code = (err["code"] as? String) ?? ""
                if code == "insufficient_quota" || JobError.looksLikeOpenAICredits(msg) { throw OpenAIError.quotaExceeded(msg) }
                if code.contains("rate_limit") { throw OpenAIError.rateLimited(msg, retryAfter: nil) }
                if code.contains("server") { throw OpenAIError.server(500, msg) }
                throw OpenAIError.unexpected(msg)
            default:
                break
            }
        }
        // Only a terminal `response.completed` / `response.incomplete` event proves the stream finished.
        // Text received without it may be cut off, so it is never treated as complete.
        guard var result = final else {
            if !refusal.isEmpty { throw OpenAIError.refusal(refusal) }
            throw OpenAIError.streamInterrupted
        }
        if result.outputText.isEmpty && result.status == "completed" { result.outputText = accumulated }
        if result.refusal == nil, !refusal.isEmpty { result.refusal = refusal }
        try Self.check(result)
        return result
    }
}

/// Minimal server-sent-events parser for OpenAI streams. Each `data:` line carries a
/// complete JSON event with a `type` field, so blank separator lines are optional.
public struct SSEParser {
    public struct Event { public var type: String; public var payload: [String: Any] }
    private var eventName: String?
    public init() {}

    public mutating func feed(_ rawLine: String) -> Event? {
        let line = rawLine.hasSuffix("\r") ? String(rawLine.dropLast()) : rawLine
        if line.isEmpty { eventName = nil; return nil }
        if line.hasPrefix(":") { return nil }
        if line.hasPrefix("event:") {
            eventName = line.dropFirst(6).trimmingCharacters(in: .whitespaces)
            return nil
        }
        guard line.hasPrefix("data:") else { return nil }
        let data = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if data == "[DONE]" { return nil }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(data.utf8)) as? [String: Any] else { return nil }
        let type = (obj["type"] as? String) ?? eventName ?? "message"
        eventName = nil
        return Event(type: type, payload: obj)
    }
}
