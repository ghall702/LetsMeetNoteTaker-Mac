import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

let roomEE = "3ae368a1b979e5f6e0aba39d3103b7e1"
let roomDT = "fb01c9b1eef909f27d1d49a6b1a1c9e3"
let london = TimeZone(identifier: "Europe/London")!
let utc = TimeZone(identifier: "UTC")!

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: T
    init(_ v: T) { _value = v }
    var value: T {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    func mutate(_ body: (inout T) -> Void) { lock.lock(); body(&_value); lock.unlock() }
}

/// Records requests and answers with a handler.
final class StubTransport: HTTPTransport, @unchecked Sendable {
    struct Reply { var status: Int; var body: Data; var headers: [String: String] = [:] }
    let requests = Box<[URLRequest]>([])
    var handler: (URLRequest) throws -> Reply

    init(_ handler: @escaping (URLRequest) throws -> Reply) { self.handler = handler }

    static func json(_ status: Int, _ s: String, headers: [String: String] = [:]) -> Reply {
        Reply(status: status, body: Data(s.utf8), headers: headers)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.mutate { $0.append(request) }
        let r = try handler(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: r.status, httpVersion: "HTTP/1.1", headerFields: r.headers)!
        return (r.body, http)
    }

    func streamLines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        let (data, http) = try await send(request)
        let text = String(decoding: data, as: UTF8.self)
        let stream = AsyncThrowingStream<String, Error> { c in
            for l in text.split(separator: "\n", omittingEmptySubsequences: false) { c.yield(String(l)) }
            c.finish()
        }
        return (http, stream)
    }
}

func bodyJSON(_ r: URLRequest) -> [String: Any] {
    guard let d = r.httpBody, let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
    return o
}

func tempDir() -> URL {
    let u = FileManager.default.temporaryDirectory.appendingPathComponent("lnc-tests-" + UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}

// MARK: Pipeline mocks

final class MockExtractor: AudioExtracting, @unchecked Sendable {
    let calls = Box<[String]>([])
    let created = Box<[URL]>([])
    var failWith: Error?
    func extractAudio(for recording: RecordingRef, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        calls.mutate { $0.append(recording.filename) }
        if let failWith { throw failWith }
        let u = directory.appendingPathComponent(recording.id.uuidString + ".wav")
        try Data(repeating: 1, count: 128).write(to: u)
        created.mutate { $0.append(u) }
        progress(1)
        return u
    }
}

final class MockTranscriber: Transcribing, @unchecked Sendable {
    let calls = Box<Int>(0)
    var textFor: (URL) -> [TranscriptSegment] = { url in
        [TranscriptSegment(start: 0, end: 5, text: "Hello from \(url.lastPathComponent.prefix(8))"),
         TranscriptSegment(start: 5, end: 9, text: "We practised fractions.")]
    }
    var failWith: Error?
    func transcribe(audioURL: URL, language: String?, progress: @escaping @Sendable (Double) -> Void) async throws -> TranscriptionOutput {
        calls.mutate { $0 += 1 }
        if let failWith { throw failWith }
        progress(1)
        return TranscriptionOutput(segments: textFor(audioURL), modelId: "whisperkit/test-model", language: "en")
    }
}

final class MockNotes: NotesProducing, @unchecked Sendable {
    let calls = Box<Int>(0)
    let lastInstructions = Box<String>("")
    let lastTranscript = Box<String>("")
    var failWith: Error?
    func produceNotes(transcript: String, context: NotesRequestContext, instructions: String,
                      progress: @escaping @Sendable (Double, String) -> Void) async throws -> ProducedNotes {
        calls.mutate { $0 += 1 }
        lastInstructions.value = instructions
        lastTranscript.value = transcript
        if let failWith { throw failWith }
        return ProducedNotes(notes: GeneratedNotes(title: "Fractions", overview: "We practised fractions.", keyPoints: ["Common denominators"],
                                                   privateNotes: "Watch numerator/denominator."), model: "test-model", effort: .modelDefault)
    }
}

final class MockSubmitter: NoteSubmitting, @unchecked Sendable {
    let bodies = Box<[Data]>([])
    /// Results to return in order; the last one repeats.
    var results: [Result<NoteStatusResponse, Error>] = []
    func submit(body: Data) async throws -> NoteStatusResponse {
        let n = bodies.value.count
        bodies.mutate { $0.append(body) }
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let sid = obj["submission_id"] as! String
        if !results.isEmpty {
            let r = results[min(n, results.count - 1)]
            switch r {
            case .success(var s): s.submissionId = sid; return s
            case .failure(let e): throw e
            }
        }
        return NoteStatusResponse(noteId: "note-\(n)", submissionId: sid, status: .pending, replayed: false)
    }
}

struct Harness {
    let dir: URL
    let store: LibraryStore
    let extractor = MockExtractor()
    let transcriber = MockTranscriber()
    let notes = MockNotes()
    let submitter = MockSubmitter()
    let online = Box<Bool>(true)
    let clock = Box<Date>(Date(timeIntervalSince1970: 1_800_000_000))
    let tempRoot: URL

    init() throws {
        dir = tempDir()
        store = try LibraryStore(directory: dir.appendingPathComponent("store"))
        tempRoot = dir.appendingPathComponent("tmp")
    }

    func engine() -> JobEngine {
        let ex = extractor, tr = transcriber, no = notes, su = submitter, on = online, cl = clock
        let deps = EngineDependencies(extractor: ex, transcriber: tr, makeNotesProducer: { no }, makeSubmitter: { su },
                                      isOnline: { on.value }, appVersion: "1.0.0-test")
        return JobEngine(store: store, deps: deps, tempRoot: tempRoot, retryPolicy: RetryPolicy(jitterFraction: 0), now: { cl.value })
    }

    func makeRecordings(_ n: Int, base: Date = Date(timeIntervalSince1970: 1_800_000_000)) -> [RecordingRef] {
        (0..<n).map { i in
            RecordingRef(filename: "zoom_\(i).mp4", path: "/tmp/zoom_\(i).mp4", durationSec: 600,
                         recordedAt: base.addingTimeInterval(Double(i) * 900), sha256: String(repeating: String(i % 10), count: 64),
                         fileSize: 1000, order: i)
        }
    }

    @discardableResult
    func addLesson(mode: ProcessingMode, recordings n: Int, held: Bool = false) throws -> Lesson {
        var s = store.settings
        s.timeZoneIdentifier = "Europe/London"
        let c = LessonConfirmation(roomId: roomEE, roomName: "LetsMeet - EE", studentId: nil, pupilName: "Ellie", lessonDate: "2027-01-15",
                                   startedAt: Date(timeIntervalSince1970: 1_800_000_000), dateSource: .zoomFolder, mode: mode,
                                   meetingTopic: "LetsMeet - EE", sourceFolder: "/tmp", recordings: makeRecordings(n))
        let l = try LessonFactory.make(c, settings: s, held: held, now: clock.value)
        store.addLesson(l)
        return l
    }
}
