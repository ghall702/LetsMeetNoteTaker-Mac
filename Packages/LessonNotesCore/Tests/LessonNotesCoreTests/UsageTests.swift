import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

func iso(_ s: String) -> Date { CoreFormat.parseISO8601(s)! }

func usageSSE(id: String, text: String, input: Int, cached: Int, output: Int, status: String = "completed") -> String {
    let escaped = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
    let type = status == "completed" ? "response.completed" : "response.incomplete"
    let incomplete = status == "completed" ? "" : #","incomplete_details":{"reason":"max_output_tokens"}"#
    return """
    data: {"type":"response.created","response":{"id":"\(id)","status":"in_progress"}}
    data: {"type":"\(type)","response":{"id":"\(id)","status":"\(status)"\(incomplete),"model":"gpt-6.1-sol","output":[{"type":"message","content":[{"type":"output_text","text":\(escaped)}]}],"usage":{"input_tokens":\(input),"input_tokens_details":{"cached_tokens":\(cached)},"output_tokens":\(output),"output_tokens_details":{"reasoning_tokens":100},"total_tokens":\(input + output)}}}

    """
}

final class UsageAccountingTests: XCTestCase {
    let s = UsageSettings()

    func rec(_ date: String, _ total: Int, model: String = "gpt-6.1-sol", input: Int? = nil, cached: Int = 0, lesson: UUID? = UUID(),
             eligible: Bool? = nil, id: String? = nil, usageKnown: Bool = true) -> UsageRecord {
        let inTok = input ?? total * 9 / 10
        let u = usageKnown ? TokenUsage(inputTokens: inTok, cachedInputTokens: cached, outputTokens: total - inTok, totalTokens: total) : nil
        return UsageRecord(responseId: id, date: iso(date), model: model, lessonId: lesson, jobId: nil, purpose: .lessonNotes, outcome: .succeeded,
                           usage: u, estimatedCostUSD: nil, complimentaryEligible: eligible ?? s.isComplimentary(model))
    }

    func testParseUsageAndCost() throws {
        let u = try XCTUnwrap(TokenUsage.parse(["input_tokens": 15_200, "input_tokens_details": ["cached_tokens": 1_000], "output_tokens": 2_400,
                                                "output_tokens_details": ["reasoning_tokens": 900], "total_tokens": 17_600]))
        XCTAssertEqual(u, TokenUsage(inputTokens: 15_200, cachedInputTokens: 1_000, outputTokens: 2_400, reasoningTokens: 900, totalTokens: 17_600))
        XCTAssertNil(TokenUsage.parse(nil))
        XCTAssertNil(TokenUsage.parse([String: Any]()), "missing usage is unknown, not zero")
        let price = try XCTUnwrap(s.price(for: "gpt-6.1-sol"))
        // 14,200 × $2 + 1,000 × $0.10 + 2,400 × $10 per 1M
        XCTAssertEqual(price.cost(of: u)!, (14_200 * 2.0 + 1_000 * 0.10 + 2_400 * 10.0) / 1_000_000, accuracy: 1e-12)
        let long = TokenUsage(inputTokens: 300_000, cachedInputTokens: 0, outputTokens: 1_000, totalTokens: 301_000)
        XCTAssertEqual(price.cost(of: long)!, (300_000 * 4.0 + 1_000 * 15.0) / 1_000_000, accuracy: 1e-12, "long-context tier")
        XCTAssertNotNil(s.price(for: "gpt-6.1-sol-2026-11-01"), "dated snapshots match by prefix")
        XCTAssertNil(s.price(for: "gpt-6.1-solar"))
        XCTAssertNil(s.price(for: "unknown-model"))
    }

    func testUTCDayBoundaries() {
        XCTAssertEqual(UsageCalendar.utcDay(iso("2026-11-14T23:59:59Z")), "2026-11-14")
        XCTAssertEqual(UsageCalendar.utcDay(iso("2026-11-15T00:00:00Z")), "2026-11-15")
        // 00:30 British Summer Time is 23:30 UTC the previous day.
        XCTAssertEqual(UsageCalendar.utcDay(iso("2026-07-15T00:30:00+01:00")), "2026-07-14")
        XCTAssertEqual(UsageCalendar.nextReset(after: iso("2026-11-14T23:33:00Z")), iso("2026-11-15T00:00:00Z"))
        XCTAssertEqual(UsageCalendar.nextReset(after: iso("2026-11-15T00:00:00Z")), iso("2026-11-16T00:00:00Z"))
        let ledger = [rec("2026-11-14T23:59:00Z", 100_000), rec("2026-11-15T00:01:00Z", 30_000)]
        XCTAssertEqual(UsageAccounting.today(ledger, now: iso("2026-11-14T23:59:30Z"), settings: s).totalTokens, 100_000)
        XCTAssertEqual(UsageAccounting.today(ledger, now: iso("2026-11-15T00:02:00Z"), settings: s).totalTokens, 30_000, "counter resets at 00:00 UTC")
        XCTAssertEqual(UsageAccounting.lastDays(ledger, now: iso("2026-11-15T00:02:00Z"), days: 2, settings: s).totalTokens, 130_000, "history kept")
    }

    func testComplimentaryAllowanceAndEstimatedSpend() throws {
        let a = rec("2026-11-14T10:00:00Z", 200_000, input: 180_000)
        let b = rec("2026-11-14T11:00:00Z", 100_000, input: 90_000)
        let other = rec("2026-11-14T12:00:00Z", 10_000, model: "gpt-other", input: 9_000)
        var settings = s
        settings.prices.append(ModelPrice(modelPrefix: "gpt-other", inputPerMillion: 1, cachedInputPerMillion: 0.5, outputPerMillion: 4))
        let sum = UsageAccounting.summarise([a, b, other], settings: settings)
        XCTAssertEqual(sum.totalTokens, 310_000)
        XCTAssertEqual(sum.eligibleTokens, 300_000)
        XCTAssertEqual(sum.estimatedComplimentaryTokens, 250_000, "capped at the daily allowance")
        XCTAssertEqual(sum.estimatedPaidTokens, 60_000, "50k over the allowance + 10k ineligible")
        let costB = settings.price(for: "gpt-6.1-sol")!.cost(of: b.usage!)!
        let costOther = settings.price(for: "gpt-other")!.cost(of: other.usage!)!
        XCTAssertEqual(sum.estimatedSpendUSD, costB * 0.5 + costOther, accuracy: 1e-9, "only the excess and ineligible requests are estimated as paid")
        XCTAssertGreaterThan(sum.listPriceValueUSD, sum.estimatedSpendUSD)
        // Under the allowance: no estimated spend.
        XCTAssertEqual(UsageAccounting.summarise([b], settings: settings).estimatedSpendUSD, 0)
        // Separate days get separate allowances.
        let nextDay = rec("2026-11-15T01:00:00Z", 200_000)
        XCTAssertEqual(UsageAccounting.summarise([a, nextDay], settings: settings).estimatedPaidTokens, 0)
    }

    func testUnknownUsageIsNotGuessed() {
        let sum = UsageAccounting.summarise([rec("2026-11-14T10:00:00Z", 0, usageKnown: false), rec("2026-11-14T10:05:00Z", 1_000)], settings: s)
        XCTAssertEqual(sum.requests, 2)
        XCTAssertEqual(sum.requestsWithUnknownUsage, 1)
        XCTAssertEqual(sum.totalTokens, 1_000)
    }

    func testMonthAndTopLessons() {
        let big = UUID(), small = UUID()
        let ledger = [rec("2026-11-01T09:00:00Z", 50_000, lesson: big), rec("2026-11-02T09:00:00Z", 10_000, lesson: big),
                      rec("2026-11-03T09:00:00Z", 5_000, lesson: small), rec("2026-10-31T09:00:00Z", 99_000)]
        let month = UsageAccounting.month(ledger, now: iso("2026-11-14T12:00:00Z"), settings: s)
        XCTAssertEqual(month.totalTokens, 65_000)
        XCTAssertEqual(month.lessonCount, 2)
        let novRecords = ledger.filter { UsageCalendar.utcMonth($0.date) == "2026-11" }
        let top = UsageAccounting.topLessons(novRecords, settings: s)
        XCTAssertEqual(top.first?.lessonId, big)
        XCTAssertEqual(top.first?.totalTokens, 60_000)
        XCTAssertEqual(top.first?.requests, 2)
    }
}

final class UsageLedgerTests: XCTestCase {
    func testPersistsDedupesAndSurvivesDamage() throws {
        let dir = tempDir()
        let ledger = UsageLedger(directory: dir)
        let r = UsageRecord(responseId: "resp_1", date: Date(), model: "gpt-6.1-sol", lessonId: UUID(), jobId: nil, purpose: .lessonNotes,
                            outcome: .succeeded, usage: TokenUsage(inputTokens: 10, cachedInputTokens: 0, outputTokens: 5, totalTokens: 15),
                            estimatedCostUSD: nil, complimentaryEligible: true)
        XCTAssertTrue(ledger.append(r))
        var dup = r; dup.id = UUID()
        XCTAssertFalse(ledger.append(dup), "same OpenAI response is never counted twice")
        XCTAssertEqual(ledger.all.count, 1)
        // Damaged line appended (e.g. power cut mid-write) does not lose earlier records.
        let h = try FileHandle(forWritingTo: ledger.url); _ = try h.seekToEnd(); try h.write(contentsOf: Data("{\"broken".utf8)); try h.close()
        let reopened = UsageLedger(directory: dir)
        XCTAssertEqual(reopened.all.map(\.id), [r.id])
        XCTAssertEqual(reopened.all.first?.usage, r.usage)
        XCTAssertFalse(reopened.append(dup), "dedupe survives restarts")
    }
}

final class UsageMonitorTests: XCTestCase {
    func monitor(_ settings: UsageSettings, now: Date = iso("2026-11-14T20:00:00Z"), dir: URL = tempDir()) -> UsageMonitor {
        UsageMonitor(ledger: UsageLedger(directory: dir), settings: { settings }, now: { now })
    }

    func client(_ m: UsageMonitor, count: Int? = 5_000, sse: String, posts: Box<[String]>) throws -> OpenAIClient {
        var c = try OpenAIClient(apiKey: "sk-secret-key", transport: StubTransport { r in
            posts.mutate { $0.append(r.url!.path) }
            if r.url!.path.hasSuffix("/input_tokens") {
                if let count { return StubTransport.json(200, #"{"object":"response.input_tokens","input_tokens":\#(count)}"#) }
                return StubTransport.json(404, #"{"error":{"message":"not found"}}"#)
            }
            return StubTransport.json(200, sse)
        })
        c.usageMonitor = m
        return c
    }

    func testRecordsActualUsageWithLessonContextOnly() async throws {
        var s = UsageSettings()
        s.protectionEnabled = false
        let m = monitor(s)
        let posts = Box<[String]>([])
        let c = try client(m, sse: usageSSE(id: "resp_A", text: validNotesJSON, input: 15_200, cached: 0, output: 2_400), posts: posts)
        let lesson = UUID(), job = UUID()
        _ = try await UsageContext.$current.withValue(UsageContext(lessonId: lesson, jobId: job, purpose: .lessonNotes)) {
            try await c.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "PRIVATE INSTRUCTIONS", userContent: "Pupil: Ellie\nTranscript: SECRET TRANSCRIPT"))
        }
        let r = try XCTUnwrap(m.ledger.all.first)
        XCTAssertEqual(r.responseId, "resp_A")
        XCTAssertEqual(r.lessonId, lesson)
        XCTAssertEqual(r.jobId, job)
        XCTAssertEqual(r.outcome, .succeeded)
        XCTAssertEqual(r.usage, TokenUsage(inputTokens: 15_200, cachedInputTokens: 0, outputTokens: 2_400, reasoningTokens: 100, totalTokens: 17_600))
        XCTAssertEqual(r.estimatedCostUSD!, 0.0544, accuracy: 1e-9)
        XCTAssertTrue(r.complimentaryEligible)
        let file = try String(contentsOf: m.ledger.url, encoding: .utf8)
        for secret in ["sk-secret-key", "SECRET TRANSCRIPT", "Ellie", "PRIVATE INSTRUCTIONS"] { XCTAssertFalse(file.contains(secret), secret) }
        XCTAssertFalse(posts.value.contains { $0.hasSuffix("/input_tokens") }, "no counting call when protection is off")
    }

    func testRetriesAreSeparateResponsesButReplaysAreNotDoubleCounted() async throws {
        let m = monitor(UsageSettings())
        let posts = Box<[String]>([])
        let first = try client(m, sse: usageSSE(id: "resp_1", text: validNotesJSON, input: 1_000, cached: 0, output: 500), posts: posts)
        _ = try await first.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: ""))
        _ = try await first.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: "")) // same id replayed
        XCTAssertEqual(m.ledger.all.count, 1)
        let second = try client(m, sse: usageSSE(id: "resp_2", text: validNotesJSON, input: 1_000, cached: 0, output: 500), posts: posts)
        _ = try await second.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: ""))
        XCTAssertEqual(m.ledger.all.count, 2, "a retry is a new billed response")
        XCTAssertEqual(UsageAccounting.today(m.ledger.all, now: iso("2026-11-14T21:00:00Z"), settings: UsageSettings()).totalTokens, 3_000)
    }

    func testIncompleteAndFailedRequestsRecorded() async throws {
        let m = monitor(UsageSettings())
        let posts = Box<[String]>([])
        let inc = try client(m, sse: usageSSE(id: "resp_inc", text: "{\"title\":", input: 2_000, cached: 0, output: 4_000, status: "incomplete"), posts: posts)
        do { _ = try await inc.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: "")); XCTFail() } catch {}
        XCTAssertEqual(m.ledger.all.last?.outcome, .incomplete)
        XCTAssertEqual(m.ledger.all.last?.usage?.totalTokens, 6_000, "billed tokens of an incomplete response are counted")
        var c = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(500, #"{"error":{"message":"boom"}}"#) })
        c.usageMonitor = m
        do { _ = try await c.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: "")); XCTFail() } catch {}
        XCTAssertEqual(m.ledger.all.last?.outcome, .failed)
        XCTAssertNil(m.ledger.all.last?.usage, "unknown, not zero")
    }

    func testProtectionBlocksBeforeSendingAndQueuesUntilReset() async throws {
        var s = UsageSettings()
        s.protectionEnabled = true
        let dir = tempDir()
        let m = monitor(s, dir: dir)
        m.ledger.append(UsageRecord(responseId: "resp_old", date: iso("2026-11-14T08:00:00Z"), model: "gpt-6.1-sol", lessonId: nil, jobId: nil,
                                    purpose: .lessonNotes, outcome: .succeeded,
                                    usage: TokenUsage(inputTokens: 200_000, cachedInputTokens: 0, outputTokens: 30_000, totalTokens: 230_000),
                                    estimatedCostUSD: nil, complimentaryEligible: true))
        let posts = Box<[String]>([])
        let c = try client(m, count: 5_000, sse: usageSSE(id: "resp_x", text: validNotesJSON, input: 5_000, cached: 0, output: 1_000), posts: posts)
        do {
            _ = try await c.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: ""))
            XCTFail("should be held back")
        } catch OpenAIError.allowanceWait(let message, let until) {
            XCTAssertEqual(until, iso("2026-11-15T00:00:00Z"))
            XCTAssertTrue(message.contains("00:00 UTC"))
        }
        XCTAssertEqual(posts.value.filter { $0.hasSuffix("/responses") }.count, 0, "the paid-risk request was never sent")
        XCTAssertEqual(posts.value.filter { $0.hasSuffix("/input_tokens") }.count, 1, "used OpenAI's input token count")
        XCTAssertEqual(m.ledger.all.count, 1, "nothing recorded for a request that was not sent")
        // The same request fits once 5,000 + 16,000 + 10,000 is within what is left.
        let m2 = monitor(s, now: iso("2026-11-15T00:05:00Z"), dir: dir)
        let c2 = try client(m2, count: 5_000, sse: usageSSE(id: "resp_y", text: validNotesJSON, input: 5_000, cached: 0, output: 1_000), posts: posts)
        _ = try await c2.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: ""))
        XCTAssertEqual(m2.ledger.all.count, 2)
    }

    func testProtectionEstimateUsesMaxOutputMarginAndReservations() {
        var s = UsageSettings()
        s.protectionEnabled = true
        s.dailyComplimentaryTokens = 100_000
        s.safetyMarginTokens = 5_000
        let m = monitor(s)
        guard case .allowed(let r1?) = m.check(model: "gpt-6.1-sol", estimatedInput: 40_000, maxOutput: 10_000) else { return XCTFail() }
        // 55,000 reserved by the in-flight request: a second identical one does not fit.
        guard case .waitForReset = m.check(model: "gpt-6.1-sol", estimatedInput: 40_000, maxOutput: 10_000) else { return XCTFail("reservation ignored") }
        m.release(r1)
        guard case .allowed = m.check(model: "gpt-6.1-sol", estimatedInput: 40_000, maxOutput: 10_000) else { return XCTFail() }
        // Larger than the whole allowance, or a non-complimentary model: blocked (needs George), never sent.
        guard case .blocked = m.check(model: "gpt-6.1-sol", estimatedInput: 120_000, maxOutput: nil) else { return XCTFail() }
        guard case .blocked = m.check(model: "gpt-paid-model", estimatedInput: 10, maxOutput: 10) else { return XCTFail() }
        // Off: everything allowed.
        s.protectionEnabled = false
        guard case .allowed(nil) = monitor(s).check(model: "gpt-paid-model", estimatedInput: 999_999, maxOutput: nil) else { return XCTFail() }
    }

    func testFallsBackToConservativeEstimateWhenCountUnavailable() async throws {
        var s = UsageSettings()
        s.protectionEnabled = true
        s.dailyComplimentaryTokens = 30_000
        s.safetyMarginTokens = 0
        s.assumedOutputTokens = 1_000
        let m = monitor(s)
        let posts = Box<[String]>([])
        let c = try client(m, count: nil, sse: usageSSE(id: "resp_z", text: validNotesJSON, input: 1, cached: 0, output: 1), posts: posts)
        let longText = String(repeating: "word ", count: 30_000) // ≈150k chars → ≈50k tokens estimated
        do { _ = try await c.streamResponse(ResponsesRequest(model: "gpt-6.1-sol", instructions: "", userContent: longText)); XCTFail() }
        catch OpenAIError.allowanceBlocked {} catch OpenAIError.allowanceWait {}
        XCTAssertEqual(posts.value.filter { $0.hasSuffix("/responses") }.count, 0)
    }

    func testEngineQueuesLessonUntilResetWithoutFailingIt() async throws {
        let h = try Harness()
        let reset = UsageCalendar.nextReset(after: h.clock.value)
        h.notes.failWith = OpenAIError.allowanceWait("Waiting for the free OpenAI allowance to reset at 00:00 UTC", until: reset)
        let l = try h.addLesson(mode: .single, recordings: 1)
        let engine = h.engine()
        await engine.runUntilIdle()
        var job = h.store.job(id: l.jobs[0].id)!
        XCTAssertEqual(job.stage, .summarising, "queued, not failed")
        XCTAssertNil(job.error)
        XCTAssertEqual(job.attempts, 0)
        XCTAssertEqual(job.nextAttemptAt, reset.addingTimeInterval(60))
        XCTAssertTrue(job.statusMessage?.contains("00:00 UTC") ?? false, String(describing: job.statusMessage))
        XCTAssertTrue(h.store.hasUsableTranscript(jobId: job.id))
        h.notes.failWith = nil
        h.clock.value = reset.addingTimeInterval(120)
        await engine.runUntilIdle()
        job = h.store.job(id: job.id)!
        XCTAssertEqual(job.stage, .submitted)
        XCTAssertEqual(h.transcriber.calls.value, 1)
    }

    func testEndToEndLessonUsageAttributedThroughEngine() async throws {
        let h = try Harness()
        let m = UsageMonitor(ledger: UsageLedger(directory: h.dir), settings: { UsageSettings() }, now: { h.clock.value })
        var c = try OpenAIClient(apiKey: "sk", transport: StubTransport { _ in StubTransport.json(200, usageSSE(id: "resp_E", text: validNotesJSON, input: 12_000, cached: 2_000, output: 3_000)) })
        c.usageMonitor = m
        let client = c
        let deps = EngineDependencies(extractor: h.extractor, transcriber: h.transcriber,
                                      makeNotesProducer: { OpenAINotesProducer(generator: NotesGenerator(performer: client, model: "gpt-6.1-sol", effort: .modelDefault)) },
                                      makeSubmitter: { h.submitter }, isOnline: { true }, appVersion: "t")
        let l = try h.addLesson(mode: .single, recordings: 1)
        await JobEngine(store: h.store, deps: deps, tempRoot: h.tempRoot, now: { h.clock.value }).runUntilIdle()
        XCTAssertEqual(h.store.job(id: l.jobs[0].id)?.stage, .submitted)
        let r = try XCTUnwrap(m.ledger.records(forJob: l.jobs[0].id).first)
        XCTAssertEqual(r.lessonId, l.id)
        XCTAssertEqual(r.purpose, .lessonNotes)
        XCTAssertEqual(r.usage?.cachedInputTokens, 2_000)
        XCTAssertEqual(r.usage?.totalTokens, 15_000)
        XCTAssertEqual(h.submitter.bodies.value.count, 1, "Let's Meet submission unaffected")
    }

    func testSettingsPersistAndOldSettingsDecode() throws {
        let h = try Harness()
        h.store.updateSettings { $0.usage.protectionEnabled = true; $0.usage.safetyMarginTokens = 20_000; $0.usage.complimentaryModels = ["gpt-6.1-sol", "gpt-6.1-terra"] }
        let re = try LibraryStore(directory: h.store.directory).settings.usage
        XCTAssertTrue(re.protectionEnabled)
        XCTAssertEqual(re.safetyMarginTokens, 20_000)
        XCTAssertTrue(re.isComplimentary("gpt-6.1-terra"))
        let old = try JSONCoding.decoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(old.usage.dailyComplimentaryTokens, 250_000)
        XCTAssertFalse(old.usage.protectionEnabled, "protection is opt-in")
    }
}
