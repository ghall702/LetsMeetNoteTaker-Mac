import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// The recordings endpoints (LESSON-RECORDINGS-API.md). Same base URL and `ghln_` key as notes.
public protocol RecordingsAPI: Sendable {
    func registerUpload(_ r: RegisterUploadRequest) async throws -> RecordingUploadResponse
    func completeUpload(recordingId: String, _ r: CompleteUploadRequest) async throws -> RecordingEnvelope
    func recording(id: String) async throws -> RemoteRecording
    func recordings(noteId: String) async throws -> [RemoteRecording]
    func availability(recordingId: String) async throws -> RecordingAvailability
    func playback(recordingId: String, download: Bool) async throws -> RecordingPlayback
    func reportFailed(recordingId: String, error: String) async throws -> RemoteRecording
    func replaceUpload(recordingId: String, _ r: ReplaceUploadRequest) async throws -> RecordingUploadResponse
    /// Returns the recording and whether it is fully deleted (false = 202 delete_pending).
    func deleteRecording(id: String) async throws -> (RemoteRecording?, Bool)
    /// Note status, used to resolve a note id from a submission id.
    func noteStatus(_ ref: String) async throws -> NoteStatusResponse
}

extension LetsMeetClient: RecordingsAPI {
    func jsonBody<T: Encodable>(_ v: T) throws -> Data { try JSONCoding.encoder().encode(v) }

    func recPath(_ id: String) -> String { "recordings/\(Self.safeId(id))" }

    public func registerUpload(_ r: RegisterUploadRequest) async throws -> RecordingUploadResponse {
        try await perform(makeRequest("recordings/upload", method: "POST", body: jsonBody(r)), okStatuses: [200, 201], as: RecordingUploadResponse.self).0
    }

    public func completeUpload(recordingId: String, _ r: CompleteUploadRequest) async throws -> RecordingEnvelope {
        try await perform(makeRequest(recPath(recordingId) + "/complete", method: "POST", body: jsonBody(r)), okStatuses: [200, 201], as: RecordingEnvelope.self).0
    }

    public func recording(id: String) async throws -> RemoteRecording {
        try await perform(makeRequest(recPath(id)), as: RecordingEnvelope.self).0.recording
    }

    public func recordings(noteId: String) async throws -> [RemoteRecording] {
        try await perform(makeRequest("notes/\(Self.safeId(noteId))/recordings"), as: NoteRecordingsResponse.self).0.recordings
    }

    public func availability(recordingId: String) async throws -> RecordingAvailability {
        try await perform(makeRequest(recPath(recordingId) + "/availability"), as: RecordingAvailability.self).0
    }

    public func playback(recordingId: String, download: Bool) async throws -> RecordingPlayback {
        var r = makeRequest(recPath(recordingId) + "/playback")
        if download, let u = r.url, var c = URLComponents(url: u, resolvingAgainstBaseURL: false) {
            c.queryItems = [URLQueryItem(name: "download", value: "1")]
            r.url = c.url
        }
        return try await perform(r, as: RecordingPlayback.self).0
    }

    public func reportFailed(recordingId: String, error: String) async throws -> RemoteRecording {
        let body = try JSONSerialization.data(withJSONObject: ["status": "failed", "error": String(error.prefix(500))], options: [.sortedKeys])
        return try await perform(makeRequest(recPath(recordingId), method: "PATCH", body: body), as: RecordingEnvelope.self).0.recording
    }

    public func replaceUpload(recordingId: String, _ r: ReplaceUploadRequest) async throws -> RecordingUploadResponse {
        try await perform(makeRequest(recPath(recordingId) + "/replace", method: "POST", body: jsonBody(r)), okStatuses: [200, 201], as: RecordingUploadResponse.self).0
    }

    public func deleteRecording(id: String) async throws -> (RemoteRecording?, Bool) {
        let (env, status) = try await perform(makeRequest(recPath(id), method: "DELETE"), okStatuses: [200, 202], as: RecordingEnvelope.self)
        return (env.recording, status == 200 && env.deleted != false)
    }

    public func noteStatus(_ ref: String) async throws -> NoteStatusResponse { try await status(of: ref) }
}
