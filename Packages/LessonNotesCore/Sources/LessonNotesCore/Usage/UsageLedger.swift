import Foundation

/// Append-only local log of OpenAI requests (`usage-ledger.jsonl`, one JSON record per line).
/// Survives restarts; records are never edited or deleted by the app.
public final class UsageLedger: @unchecked Sendable {
    public let url: URL
    private let lock = NSLock()
    private var records: [UsageRecord] = []
    private var responseIds: Set<String> = []
    public var onChange: (@Sendable () -> Void)?

    public init(directory: URL) {
        url = directory.appendingPathComponent("usage-ledger.jsonl")
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let decoder = JSONCoding.decoder()
        for line in data.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            // A damaged line is skipped (never rewritten), so one bad line cannot lose the rest.
            if let r = try? decoder.decode(UsageRecord.self, from: Data(line)) {
                records.append(r)
                if let rid = r.responseId { responseIds.insert(rid) }
            }
        }
    }

    public var all: [UsageRecord] { lock.lock(); defer { lock.unlock() }; return records }

    /// Appends a record unless a record for the same OpenAI response already exists.
    /// - Returns: false if it was a duplicate.
    @discardableResult
    public func append(_ r: UsageRecord) -> Bool {
        lock.lock()
        if let rid = r.responseId, responseIds.contains(rid) { lock.unlock(); return false }
        var line = (try? JSONCoding.encoder().encode(r)) ?? Data()
        line.append(UInt8(ascii: "\n"))
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        if let h = try? FileHandle(forWritingTo: url) {
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: line)
            try? h.close()
        }
        records.append(r)
        if let rid = r.responseId { responseIds.insert(rid) }
        lock.unlock()
        onChange?()
        return true
    }

    public func records(onUTCDay day: String) -> [UsageRecord] { all.filter { $0.utcDay == day } }
    public func records(forJob jobId: UUID) -> [UsageRecord] { all.filter { $0.jobId == jobId } }
}

/// Summary of a period (tokens are exactly as reported; costs and complimentary figures are estimates).
public struct UsageSummary: Equatable, Sendable {
    public var requests: Int = 0
    public var requestsWithUnknownUsage: Int = 0
    public var inputTokens: Int = 0
    public var cachedInputTokens: Int = 0
    public var outputTokens: Int = 0
    public var totalTokens: Int = 0
    /// Tokens from complimentary-eligible models.
    public var eligibleTokens: Int = 0
    /// Estimated tokens covered by the complimentary allowance (capped per UTC day).
    public var estimatedComplimentaryTokens: Int = 0
    /// Estimated tokens that exceeded the allowance or used ineligible models.
    public var estimatedPaidTokens: Int = 0
    /// Estimated spend after the complimentary allowance (USD).
    public var estimatedSpendUSD: Double = 0
    /// Cost at full list price ignoring the allowance (USD), for reference.
    public var listPriceValueUSD: Double = 0
    /// Requests whose model has no price configured (cost unknown).
    public var requestsWithoutPrice: Int = 0
    public var lessons: Set<UUID> = []
    public var failedRequests: Int = 0

    public var lessonCount: Int { lessons.count }
}

public enum UsageAccounting {
    /// Summarises records, applying the complimentary allowance separately for each UTC day in
    /// chronological order: eligible-model tokens are treated as complimentary until the day's
    /// allowance is used up; the rest (and all ineligible-model tokens) are estimated as paid.
    public static func summarise(_ records: [UsageRecord], settings: UsageSettings) -> UsageSummary {
        var s = UsageSummary()
        let byDay = Dictionary(grouping: records, by: \.utcDay)
        for (_, dayRecords) in byDay {
            var remaining = settings.dailyComplimentaryTokens
            for r in dayRecords.sorted(by: { $0.date < $1.date }) {
                s.requests += 1
                if r.outcome == .failed { s.failedRequests += 1 }
                if r.outcome != .failed || r.usage != nil, let l = r.lessonId, r.purpose != .modelTest { s.lessons.insert(l) }
                guard let u = r.usage, let total = u.totalTokens else { s.requestsWithUnknownUsage += 1; continue }
                s.inputTokens += u.inputTokens ?? 0
                s.cachedInputTokens += u.cachedInputTokens ?? 0
                s.outputTokens += u.outputTokens ?? 0
                s.totalTokens += total
                let cost = settings.price(for: r.model)?.cost(of: u) ?? r.estimatedCostUSD
                if cost == nil { s.requestsWithoutPrice += 1 }
                s.listPriceValueUSD += cost ?? 0
                if r.complimentaryEligible {
                    s.eligibleTokens += total
                    let free = min(total, max(0, remaining))
                    remaining -= free
                    s.estimatedComplimentaryTokens += free
                    let paid = total - free
                    s.estimatedPaidTokens += paid
                    if paid > 0, let cost, total > 0 { s.estimatedSpendUSD += cost * Double(paid) / Double(total) }
                } else {
                    s.estimatedPaidTokens += total
                    s.estimatedSpendUSD += cost ?? 0
                }
            }
        }
        return s
    }

    public static func today(_ ledger: [UsageRecord], now: Date, settings: UsageSettings) -> UsageSummary {
        let day = UsageCalendar.utcDay(now)
        return summarise(ledger.filter { $0.utcDay == day }, settings: settings)
    }

    public static func lastDays(_ ledger: [UsageRecord], now: Date, days: Int, settings: UsageSettings) -> UsageSummary {
        let set = Set(UsageCalendar.days(endingAt: now, count: days))
        return summarise(ledger.filter { set.contains($0.utcDay) }, settings: settings)
    }

    public static func month(_ ledger: [UsageRecord], now: Date, settings: UsageSettings) -> UsageSummary {
        let m = UsageCalendar.utcMonth(now)
        return summarise(ledger.filter { UsageCalendar.utcMonth($0.date) == m }, settings: settings)
    }

    public struct LessonUsage: Equatable, Sendable, Identifiable {
        public var id: UUID { lessonId }
        public var lessonId: UUID
        public var totalTokens: Int
        public var requests: Int
        public var listPriceUSD: Double?
        public var lastUsed: Date
    }

    /// Lessons ranked by tokens used.
    public static func topLessons(_ records: [UsageRecord], settings: UsageSettings, limit: Int = 10) -> [LessonUsage] {
        let grouped = Dictionary(grouping: records.filter { $0.lessonId != nil }, by: { $0.lessonId! })
        return grouped.map { id, rs in
            let costs = rs.compactMap { r in r.usage.flatMap { settings.price(for: r.model)?.cost(of: $0) } }
            return LessonUsage(lessonId: id, totalTokens: rs.compactMap(\.totalTokens).reduce(0, +), requests: rs.count,
                               listPriceUSD: costs.isEmpty ? nil : costs.reduce(0, +), lastUsed: rs.map(\.date).max()!)
        }
        .sorted { $0.totalTokens > $1.totalTokens }
        .prefix(limit).map { $0 }
    }
}

/// Central monitor used by `OpenAIClient`: records usage of every request and, when enabled,
/// blocks requests that could exceed the remaining complimentary allowance.
/// This is a local safeguard based on the app's own records — not an OpenAI billing cap.
public final class UsageMonitor: @unchecked Sendable {
    public let ledger: UsageLedger
    let settings: @Sendable () -> UsageSettings
    let now: @Sendable () -> Date
    private let lock = NSLock()
    private var reservations: [UUID: Int] = [:]

    public init(ledger: UsageLedger, settings: @escaping @Sendable () -> UsageSettings, now: @escaping @Sendable () -> Date = { Date() }) {
        self.ledger = ledger
        self.settings = settings
        self.now = now
    }

    /// Eligible tokens already used today plus tokens reserved by requests still in flight.
    public func committedEligibleTokensToday() -> Int {
        let s = settings()
        let used = UsageAccounting.today(ledger.all, now: now(), settings: s).eligibleTokens
        lock.lock(); defer { lock.unlock() }
        return used + reservations.values.reduce(0, +)
    }

    public func remainingComplimentaryTokens() -> Int {
        max(0, settings().dailyComplimentaryTokens - committedEligibleTokensToday())
    }

    public enum Decision: Equatable, Sendable {
        case allowed(reservation: UUID?)
        /// Not enough of today's allowance left; can run after the reset.
        case waitForReset(String, until: Date)
        /// Can never fit the daily allowance (or model is not complimentary): needs George.
        case blocked(String)
    }

    /// Pre-request check. `estimatedInput` comes from OpenAI's input-token count where available.
    public func check(model: String, estimatedInput: Int, maxOutput: Int?) -> Decision {
        let s = settings()
        guard s.protectionEnabled else { return .allowed(reservation: nil) }
        let fmt = NumberFormatter()
        fmt.numberStyle = .decimal
        func n(_ v: Int) -> String { fmt.string(from: NSNumber(value: v)) ?? String(v) }
        guard s.isComplimentary(model) else {
            return .blocked("Free allowance protection is on and “\(model)” is not in your list of complimentary models, so this request would be paid. Choose a complimentary model, add it to the list, or turn protection off.")
        }
        let needed = estimatedInput + (maxOutput ?? s.assumedOutputTokens) + s.safetyMarginTokens
        if needed > s.dailyComplimentaryTokens {
            return .blocked("This request needs about \(n(needed)) tokens (input \(n(estimatedInput)) + output allowance + safety margin), more than the whole daily complimentary allowance of \(n(s.dailyComplimentaryTokens)). Lower the maximum output, or turn protection off for this lesson.")
        }
        lock.lock()
        let used = UsageAccounting.today(ledger.all, now: now(), settings: s).eligibleTokens + reservations.values.reduce(0, +)
        let remaining = s.dailyComplimentaryTokens - used
        if needed > remaining {
            lock.unlock()
            let reset = UsageCalendar.nextReset(after: now())
            return .waitForReset("Waiting for the free OpenAI allowance to reset at 00:00 UTC: this lesson needs about \(n(needed)) tokens but only \(n(max(0, remaining))) of today's \(n(s.dailyComplimentaryTokens)) remain. It will be processed automatically after the reset.", until: reset)
        }
        let id = UUID()
        reservations[id] = needed
        lock.unlock()
        return .allowed(reservation: id)
    }

    public func release(_ reservation: UUID?) {
        guard let reservation else { return }
        lock.lock(); reservations[reservation] = nil; lock.unlock()
    }

    /// Records the outcome of one request (once per OpenAI response).
    public func record(responseId: String?, model: String, outcome: UsageRecord.Outcome, usage: TokenUsage?, error: String? = nil) {
        let s = settings()
        let ctx = UsageContext.current
        let cost = usage.flatMap { s.price(for: model)?.cost(of: $0) }
        ledger.append(UsageRecord(responseId: responseId, date: now(), model: model, lessonId: ctx?.lessonId, jobId: ctx?.jobId,
                                  purpose: ctx?.purpose ?? .other, outcome: outcome, errorSummary: error.map { String($0.prefix(160)) },
                                  usage: usage, estimatedCostUSD: cost, complimentaryEligible: s.isComplimentary(model)))
    }
}
