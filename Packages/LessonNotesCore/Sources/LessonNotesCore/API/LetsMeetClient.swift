import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Errors from the Let's Meet website API, carrying the server's message verbatim.
public struct LetsMeetAPIError: Error, Equatable, LocalizedError, Sendable {
    public var httpStatus: Int
    public var code: String
    public var message: String
    public var fields: [APIFieldError]
    public var noteId: String?
    public var retryAfter: TimeInterval?
    /// For `version_conflict`: the website's current version and who changed it.
    public var currentVersion: Int?
    public var lastChangedBy: String?
    public var remoteUpdatedAt: String?

    public init(httpStatus: Int, code: String, message: String, fields: [APIFieldError] = [], noteId: String? = nil, retryAfter: TimeInterval? = nil,
                currentVersion: Int? = nil, lastChangedBy: String? = nil, remoteUpdatedAt: String? = nil) {
        self.httpStatus = httpStatus
        self.code = code
        self.message = message
        self.fields = fields
        self.noteId = noteId
        self.retryAfter = retryAfter
        self.currentVersion = currentVersion
        self.lastChangedBy = lastChangedBy
        self.remoteUpdatedAt = remoteUpdatedAt
    }

    public var errorDescription: String? {
        var s = message
        if !fields.isEmpty { s += " " + fields.map { "\($0.field): \($0.message)" }.joined(separator: "; ") }
        return s
    }

    /// Spec §7: retry only on 429 and 5xx (network errors are handled separately).
    public var isRetryable: Bool { httpStatus == 429 || (500...599).contains(httpStatus) }
}

public enum LetsMeetClientError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case missingKey
    case invalidKeyFormat
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "The website address must be a valid HTTPS URL."
        case .missingKey: return "Add your Let's Meet website API key in Settings."
        case .invalidKeyFormat: return "Website API keys start with “ghln_”."
        case .decoding(let m): return "Unexpected response from the website: \(m)"
        }
    }
}

public struct LetsMeetClient: Sendable {
    public static let defaultBaseURL = "https://georgehalltuition.com/api/public/lesson-notes"
    /// Website limits (updated by the website team; single place to change).
    public static let maxTranscriptBytes = APILimits.maxTranscriptBytes
    public static let maxBodyBytes = APILimits.maxRequestBodyBytes

    public var baseURL: URL
    public var apiKey: String
    public var transport: HTTPTransport

    public init(baseURLString: String, apiKey: String, transport: HTTPTransport) throws {
        guard let url = Self.validateBaseURL(baseURLString) else { throw LetsMeetClientError.invalidBaseURL }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw LetsMeetClientError.missingKey }
        guard key.hasPrefix("ghln_") else { throw LetsMeetClientError.invalidKeyFormat }
        self.baseURL = url
        self.apiKey = key
        self.transport = transport
    }

    public static func validateBaseURL(_ s: String) -> URL? {
        var trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard let url = URL(string: trimmed), url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    func makeRequest(_ path: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var url = baseURL
        for comp in path.split(separator: "/") { url.appendPathComponent(String(comp)) }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        r.setValue("application/json", forHTTPHeaderField: "Accept")
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let body {
            r.httpBody = body
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        r.timeoutInterval = 60
        return r
    }

    static func decodeError(_ data: Data, _ http: HTTPURLResponse) -> LetsMeetAPIError {
        if let env = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data) {
            return LetsMeetAPIError(httpStatus: http.statusCode, code: env.error.code, message: env.error.message,
                                    fields: env.error.fields ?? [], noteId: env.error.noteId, retryAfter: http.retryAfterSeconds,
                                    currentVersion: env.error.currentVersion, lastChangedBy: env.error.lastChangedBy,
                                    remoteUpdatedAt: env.error.updatedAt)
        }
        let fallbackCode: String
        switch http.statusCode {
        case 401: fallbackCode = "unauthorized"
        case 403: fallbackCode = "key_revoked"
        case 429: fallbackCode = "rate_limited"
        case 500...599: fallbackCode = "server_error"
        default: fallbackCode = "http_\(http.statusCode)"
        }
        let snippet = String(decoding: data.prefix(300), as: UTF8.self)
        return LetsMeetAPIError(httpStatus: http.statusCode, code: fallbackCode,
                                message: "The website returned HTTP \(http.statusCode)." + (snippet.isEmpty ? "" : " \(snippet)"),
                                retryAfter: http.retryAfterSeconds)
    }

    func perform<T: Decodable>(_ request: URLRequest, okStatuses: Set<Int> = [200], as: T.Type) async throws -> (T, Int) {
        let (data, http) = try await transport.send(request)
        guard okStatuses.contains(http.statusCode) else { throw Self.decodeError(data, http) }
        do {
            return (try JSONDecoder().decode(T.self, from: data), http.statusCode)
        } catch {
            throw LetsMeetClientError.decoding(String(describing: error))
        }
    }

    // MARK: Endpoints

    public func ping() async throws -> PingResponse {
        try await perform(makeRequest("ping"), as: PingResponse.self).0
    }

    public func rooms() async throws -> [Room] {
        try await perform(makeRequest("rooms"), as: RoomsResponse.self).0.rooms
    }

    /// `POST /notes`. 201 = created, 200 = replay of an identical submission.
    public func submit(_ note: NoteSubmission) async throws -> NoteStatusResponse {
        let body = try note.jsonData()
        let (resp, status) = try await perform(makeRequest("notes", method: "POST", body: body), okStatuses: [200, 201], as: NoteStatusResponse.self)
        var r = resp
        if r.replayed == nil { r.replayed = (status == 200) }
        return r
    }

    /// Sends an already-encoded `POST /notes` body (retries resend identical bytes).
    public func submit(body: Data) async throws -> NoteStatusResponse {
        let (resp, status) = try await perform(makeRequest("notes", method: "POST", body: body), okStatuses: [200, 201], as: NoteStatusResponse.self)
        var r = resp
        if r.replayed == nil { r.replayed = (status == 200) }
        return r
    }

    /// `PATCH /notes/{note_id}` — replaces an existing note's content (returns it to pending).
    /// `body` is an encoded `NoteReplacement`; retries resend identical bytes with the same `update_id`.
    public func replace(noteId: String, body: Data) async throws -> NoteReplaceResponse {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        let safe = noteId.addingPercentEncoding(withAllowedCharacters: allowed) ?? noteId
        return try await perform(makeRequest("notes/\(safe)", method: "PATCH", body: body), as: NoteReplaceResponse.self).0
    }

    /// `GET /notes/{id}`; a 404 means the note was deleted (or never existed).
    public func status(of id: String) async throws -> NoteStatusResponse {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._:-"))
        let safe = id.addingPercentEncoding(withAllowedCharacters: allowed) ?? id
        let (data, http) = try await transport.send(makeRequest("notes/\(safe)"))
        if http.statusCode == 404 {
            if let r = try? JSONDecoder().decode(NoteStatusResponse.self, from: data) { return r }
            return NoteStatusResponse(noteId: nil, submissionId: id, status: .deleted)
        }
        guard http.statusCode == 200 else { throw Self.decodeError(data, http) }
        do { return try JSONDecoder().decode(NoteStatusResponse.self, from: data) }
        catch { throw LetsMeetClientError.decoding(String(describing: error)) }
    }

    /// `POST /notes/status` in batches of at most 100 ids, preserving order.
    public func statuses(of submissionIds: [String]) async throws -> [NoteStatusResponse] {
        var out: [NoteStatusResponse] = []
        var index = 0
        while index < submissionIds.count {
            let batch = Array(submissionIds[index..<min(index + 100, submissionIds.count)])
            let body = try JSONEncoder().encode(["submission_ids": batch])
            let resp = try await perform(makeRequest("notes/status", method: "POST", body: body), as: BatchStatusResponse.self).0
            out.append(contentsOf: resp.results)
            index += 100
        }
        return out
    }
}
