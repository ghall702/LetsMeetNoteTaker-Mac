import Foundation

/// Spec §7: 5 s, 15 s, 45 s, 2 min, 5 min, 15 min, then every 30 min, for at most 24 h,
/// with jitter; `Retry-After` is honoured.
public struct RetryPolicy: Sendable {
    public static let schedule: [TimeInterval] = [5, 15, 45, 120, 300, 900]
    public static let steadyInterval: TimeInterval = 1800
    public static let maxWindow: TimeInterval = 24 * 3600

    public var jitterFraction: Double
    public init(jitterFraction: Double = 0.2) { self.jitterFraction = jitterFraction }

    /// Base delay for the n-th retry (attempt 1 = first retry).
    public static func baseDelay(forAttempt attempt: Int) -> TimeInterval {
        let i = max(1, attempt) - 1
        return i < schedule.count ? schedule[i] : steadyInterval
    }

    /// Next attempt time, or nil if the 24 h window is exhausted.
    public func nextAttempt(attempt: Int, firstRetryAt: Date, now: Date, retryAfter: TimeInterval?,
                            random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }) -> Date? {
        let base = Self.baseDelay(forAttempt: attempt)
        let jitter = base * jitterFraction
        var delay = base + random(-jitter...jitter)
        if let retryAfter { delay = max(delay, retryAfter) }
        let next = now.addingTimeInterval(max(1, delay))
        if next.timeIntervalSince(firstRetryAt) > Self.maxWindow { return nil }
        return next
    }
}

/// Classification of any error raised while processing a job.
public enum FailureClass: Equatable, Sendable {
    case offline
    case retryable(message: String, retryAfter: TimeInterval?)
    case fatal(JobError)
    case cancelled

    public static func classify(_ error: Error, now: Date = Date()) -> FailureClass {
        if error is CancellationError { return .cancelled }
        if let t = error as? TransportError {
            switch t {
            case .offline: return .offline
            case .network(let m): return .retryable(message: m, retryAfter: nil)
            case .notHTTP: return .retryable(message: t.localizedDescription, retryAfter: nil)
            }
        }
        if let e = error as? LetsMeetAPIError {
            if e.isRetryable { return .retryable(message: e.message, retryAfter: e.retryAfter) }
            let kind: JobError.Kind
            switch (e.httpStatus, e.code) {
            case (413, _): kind = .payloadTooLarge
            case (409, _): kind = .submissionConflict
            case (401, _), (403, _): kind = .authentication
            case (422, _), (400, _): kind = .validation
            default: kind = .general
            }
            return .fatal(JobError(message: e.localizedDescription, kind: kind, httpStatus: e.httpStatus, code: e.code, occurredAt: now))
        }
        if let e = error as? OpenAIError {
            if e.isRetryable { return .retryable(message: e.localizedDescription, retryAfter: e.retryAfter) }
            return .fatal(JobError(message: e.localizedDescription, kind: .openAI, occurredAt: now))
        }
        if let e = error as? LetsMeetClientError {
            return .fatal(JobError(message: e.localizedDescription, kind: .authentication, occurredAt: now))
        }
        return .fatal(JobError(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription, occurredAt: now))
    }
}
