import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

final class LetsMeetAPITests: XCTestCase {
    let key = "ghln_TESTKEY0000000000000000000000000000000000"

    func client(_ t: StubTransport) throws -> LetsMeetClient {
        try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL + "/", apiKey: key, transport: t)
    }

    func sampleSubmission(id: String = "mac-TEST-2026-11-14-1600-a-abc123", transcript: String = "George: Right, let's look at …") -> NoteSubmission {
        NoteSubmission(submissionId: id, roomId: roomEE, lessonDate: "2026-11-14", startedAt: "2026-11-14T16:00:12Z", endedAt: "2026-11-14T16:58:40Z",
                       title: "Adding fractions", summary: NoteSummary(overview: "We practised.", keyPoints: ["LCM"]),
                       transcript: transcript, privateNotes: "Private", recordings: [SubmissionRecording(filename: "zoom_0.mp4", durationSec: 3508,
                       recordedAt: "2026-11-14T16:00:12Z", order: 0, sha256: String(repeating: "a", count: 64))], mode: .single,
                       generator: SubmissionGenerator(appVersion: "1.0.0", transcriptionModel: "whisperkit/x", summaryModel: "m"))
    }

    func testValidatesConfiguration() {
        let t = StubTransport { _ in .init(status: 200, body: Data()) }
        XCTAssertThrowsError(try LetsMeetClient(baseURLString: "http://georgehalltuition.com/api", apiKey: key, transport: t))
        XCTAssertThrowsError(try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "", transport: t))
        XCTAssertThrowsError(try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "sk-wrong", transport: t))
    }

    func testPingSendsBearerAndParses() async throws {
        let t = StubTransport { _ in StubTransport.json(200, #"{"ok":true,"key_id":"7487e543","server_time":"2026-11-14T01:46:27.602Z","api_version":1}"#) }
        let p = try await client(t).ping()
        XCTAssertTrue(p.ok)
        let r = t.requests.value[0]
        XCTAssertEqual(r.url?.absoluteString, "https://georgehalltuition.com/api/public/lesson-notes/ping")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    }

    func testPingErrors401And403() async throws {
        for (code, err) in [(401, "unauthorized"), (403, "key_revoked")] {
            let t = StubTransport { _ in StubTransport.json(code, #"{"error":{"code":"\#(err)","message":"Server says \#(err)"}}"#) }
            do { _ = try await client(t).ping(); XCTFail() } catch let e as LetsMeetAPIError {
                XCTAssertEqual(e.code, err)
                XCTAssertEqual(e.message, "Server says \(err)")
                XCTAssertFalse(e.isRetryable)
            }
        }
    }

    func testRooms() async throws {
        let t = StubTransport { _ in StubTransport.json(200, #"{"rooms":[{"room_id":"\#(roomEE)","name":"LetsMeet - EE"}]}"#) }
        let rooms = try await client(t).rooms()
        XCTAssertEqual(rooms, [Room(roomId: roomEE, name: "LetsMeet - EE")])
    }

    func testSubmitCreatedThenReplayed() async throws {
        let calls = Box<Int>(0)
        let t = StubTransport { _ in
            calls.mutate { $0 += 1 }
            let replay = calls.value > 1
            return StubTransport.json(replay ? 200 : 201, #"{"note_id":"n1","submission_id":"s","room_id":"\#(roomEE)","status":"pending","created_at":"x","updated_at":"x","published_at":null,"replayed":\#(replay)}"#)
        }
        let c = try client(t)
        let body = try sampleSubmission().jsonData()
        let a = try await c.submit(body: body)
        let b = try await c.submit(body: body)
        XCTAssertEqual(a.replayed, false)
        XCTAssertEqual(b.replayed, true)
        XCTAssertEqual(t.requests.value[0].httpBody, t.requests.value[1].httpBody, "retries resend identical bytes")
        XCTAssertEqual(t.requests.value[0].value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(t.requests.value[0].httpMethod, "POST")
    }

    func testSubmissionHasOnlyDocumentedFields() throws {
        let obj = try JSONSerialization.jsonObject(with: sampleSubmission().jsonData()) as! [String: Any]
        let allowed: Set<String> = ["submission_id", "room_id", "lesson_date", "started_at", "ended_at", "title", "summary", "transcript",
                                    "private_notes", "recordings", "mode", "generator"]
        XCTAssertTrue(Set(obj.keys).isSubset(of: allowed))
        XCTAssertNil(obj["audio"]); XCTAssertNil(obj["video"])
        let rec = (obj["recordings"] as! [[String: Any]])[0]
        XCTAssertEqual(Set(rec.keys), ["filename", "duration_sec", "recorded_at", "order", "sha256"])
        XCTAssertEqual(Set((obj["summary"] as! [String: Any]).keys), ["overview", "key_points"])
    }

    func testConflictValidationAndRateLimitErrors() async throws {
        let t409 = StubTransport { _ in StubTransport.json(409, #"{"error":{"code":"submission_conflict","message":"Conflict","note_id":"n9"}}"#) }
        do { _ = try await client(t409).submit(sampleSubmission()); XCTFail() } catch let e as LetsMeetAPIError {
            XCTAssertEqual(e.noteId, "n9"); XCTAssertFalse(e.isRetryable)
            guard case .fatal(let je) = FailureClass.classify(e) else { return XCTFail() }
            XCTAssertEqual(je.kind, .submissionConflict)
        }
        let t422 = StubTransport { _ in StubTransport.json(422, #"{"error":{"code":"unknown_room","message":"Unknown room","fields":[{"field":"room_id","message":"not found"}]}}"#) }
        do { _ = try await client(t422).submit(sampleSubmission()); XCTFail() } catch let e as LetsMeetAPIError {
            XCTAssertEqual(e.code, "unknown_room"); XCTAssertEqual(e.fields.first?.field, "room_id")
            XCTAssertTrue(e.localizedDescription.contains("Unknown room"))
        }
        let t429 = StubTransport { _ in StubTransport.json(429, #"{"error":{"code":"rate_limited","message":"Slow down"}}"#, headers: ["Retry-After": "42"]) }
        do { _ = try await client(t429).ping(); XCTFail() } catch let e as LetsMeetAPIError {
            XCTAssertTrue(e.isRetryable); XCTAssertEqual(e.retryAfter, 42)
            XCTAssertEqual(FailureClass.classify(e), .retryable(message: "Slow down", retryAfter: 42))
        }
        let t500 = StubTransport { _ in StubTransport.json(500, "oops") }
        do { _ = try await client(t500).ping(); XCTFail() } catch let e as LetsMeetAPIError { XCTAssertTrue(e.isRetryable) }
        let t413 = StubTransport { _ in StubTransport.json(413, #"{"error":{"code":"transcript_too_large","message":"Too large"}}"#) }
        do { _ = try await client(t413).submit(sampleSubmission()); XCTFail() } catch let e as LetsMeetAPIError {
            guard case .fatal(let je) = FailureClass.classify(e) else { return XCTFail() }
            XCTAssertEqual(je.kind, .payloadTooLarge)
        }
    }

    func testStatusSingleAnd404MeansDeleted() async throws {
        let t = StubTransport { r in
            if r.url!.path.hasSuffix("missing") { return StubTransport.json(404, #"{"note_id":null,"submission_id":"missing","status":"deleted"}"#) }
            return StubTransport.json(200, #"{"note_id":"n","submission_id":"s1","room_id":"\#(roomEE)","status":"published","created_at":"a","updated_at":"b","published_at":"2026-11-15T10:00:00Z"}"#)
        }
        let c = try client(t)
        let ok = try await c.status(of: "s1")
        XCTAssertEqual(ok.status, .published)
        let gone = try await c.status(of: "missing")
        XCTAssertEqual(gone.status, .deleted)
        XCTAssertNil(gone.noteId)
    }

    func testBatchStatusChunksBy100InOrder() async throws {
        let t = StubTransport { r in
            let ids = bodyJSON(r)["submission_ids"] as! [String]
            let results = ids.map { #"{"note_id":"n","submission_id":"\#($0)","status":"pending"}"# }.joined(separator: ",")
            return StubTransport.json(200, #"{"results":[\#(results)]}"#)
        }
        let ids = (0..<250).map { "id-\($0)" }
        let out = try await client(t).statuses(of: ids)
        XCTAssertEqual(out.map(\.submissionId), ids)
        XCTAssertEqual(t.requests.value.count, 3)
        XCTAssertEqual((bodyJSON(t.requests.value[0])["submission_ids"] as! [String]).count, 100)
        XCTAssertEqual(t.requests.value[0].url?.path, "/api/public/lesson-notes/notes/status")
    }
}

final class SubmissionLimitTests: XCTestCase {
    func make(transcript: String, title: String = "Title", privateNotes: String? = nil) -> NoteSubmission {
        NoteSubmission(submissionId: "mac-TEST-2026-11-14-1600-a-abc123", roomId: roomEE, lessonDate: "2026-11-14", startedAt: nil, endedAt: nil,
                       title: title, summary: NoteSummary(), transcript: transcript, privateNotes: privateNotes, recordings: [], mode: .single, generator: nil)
    }

    func testLimitsAreTheUpdatedValues() {
        XCTAssertEqual(APILimits.maxTranscriptBytes, 5_000_000)
        XCTAssertEqual(APILimits.maxRequestBodyBytes, 6_000_000)
        XCTAssertEqual(LetsMeetClient.maxTranscriptBytes, 5_000_000)
        XCTAssertEqual(LetsMeetClient.maxBodyBytes, 6_000_000)
    }

    func testUTF8ByteCountingNotCharacters() {
        XCTAssertEqual(APILimits.utf8Bytes("é"), 2)
        XCTAssertEqual(APILimits.utf8Bytes("😀"), 4)
        XCTAssertEqual("😀".count, 1)
        // 1,250,001 emoji = 1.25M characters but 5,000,004 bytes → too large.
        let emoji = String(repeating: "😀", count: 1_250_001)
        let body = Data(count: 10)
        XCTAssertEqual(APILimits.check(transcript: emoji, encodedBody: body), .transcriptTooLarge(bytes: 5_000_004))
    }

    func testTranscriptExactlyAtLimitAccepted() throws {
        let t = String(repeating: "a", count: 5_000_000)
        let s = make(transcript: t)
        let body = try s.jsonData()
        XCTAssertNil(APILimits.check(transcript: t, encodedBody: body))
        XCTAssertTrue(SubmissionValidator.validate(s).isEmpty, "\(SubmissionValidator.validate(s))")
        XCTAssertEqual(s.transcript?.utf8.count, 5_000_000, "transcript sent unaltered")
    }

    func testTranscriptOneByteOverRejected() throws {
        let t = String(repeating: "a", count: 5_000_001)
        let s = make(transcript: t)
        XCTAssertEqual(APILimits.check(transcript: t, encodedBody: try s.jsonData()), .transcriptTooLarge(bytes: 5_000_001))
        XCTAssertTrue(SubmissionValidator.validate(s).contains { $0.field == "transcript" })
    }

    func testBodyLimitCanBeExceededWithTranscriptUnderLimit() throws {
        // 4.99 MB of quotes: each `"` is escaped to `\"` in JSON, doubling the body size.
        let t = String(repeating: "\"", count: 4_990_000)
        let s = make(transcript: t)
        let body = try s.jsonData()
        XCTAssertLessThan(t.utf8.count, APILimits.maxTranscriptBytes)
        XCTAssertGreaterThan(body.count, APILimits.maxRequestBodyBytes)
        XCTAssertEqual(APILimits.check(transcript: t, encodedBody: body), .bodyTooLarge(bytes: body.count))
        XCTAssertTrue(SubmissionValidator.validate(s).contains { $0.field == "body" })
    }

    func testTranscriptPlusNotesPushesBodyOverLimit() throws {
        let t = String(repeating: "b", count: 4_995_000)
        let s = make(transcript: t, privateNotes: String(repeating: "\u{1}", count: 9_000)) // control chars escape to 6 bytes each
        let body = try s.jsonData()
        XCTAssertLessThan(body.count, APILimits.maxRequestBodyBytes) // still fits
        let big = make(transcript: String(repeating: "\u{1}", count: 1_100_000))
        XCTAssertGreaterThan(try big.jsonData().count, APILimits.maxRequestBodyBytes)
    }

    func testMissingOrEmptyTranscriptIsInvalid() {
        var s = make(transcript: "")
        XCTAssertTrue(SubmissionValidator.validate(s).contains { $0.field == "transcript" })
        s.transcript = nil
        XCTAssertTrue(SubmissionValidator.validate(s).contains { $0.field == "transcript" })
    }

    func testValidatorFieldRules() {
        var s = make(transcript: "x", title: "")
        s.roomId = "ABC"
        s.lessonDate = "14/11/2026"
        s.submissionId = "bad id!"
        s.summary.keyPoints = Array(repeating: "k", count: 31)
        let fields = Set(SubmissionValidator.validate(s).map(\.field))
        XCTAssertTrue(fields.isSuperset(of: ["title", "room_id", "lesson_date", "submission_id", "summary.key_points"]))
    }
}
