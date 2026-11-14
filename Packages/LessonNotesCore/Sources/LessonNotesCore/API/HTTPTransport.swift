import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum TransportError: Error, Equatable, LocalizedError {
    case notHTTP
    case offline(String)
    case network(String)

    public var errorDescription: String? {
        switch self {
        case .notHTTP: return "The server sent an unexpected response."
        case .offline(let m): return "No internet connection (\(m))."
        case .network(let m): return "Network error: \(m)"
        }
    }
}

/// Abstraction over URLSession so the API clients can be tested with stubs.
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
    /// Streams a response line by line (used for OpenAI server-sent events).
    func streamLines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>)
}

public final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    public init(timeout: TimeInterval = 120) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = 60 * 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        config.httpCookieStorage = nil
        #if canImport(Darwin)
        config.waitsForConnectivity = false
        #endif
        session = URLSession(configuration: config)
    }

    static func map(_ error: Error) -> Error {
        if let u = error as? URLError {
            switch u.code {
            case .notConnectedToInternet, .networkConnectionLost, .dataNotAllowed, .internationalRoamingOff:
                return TransportError.offline(u.localizedDescription)
            case .cancelled:
                return CancellationError()
            default:
                return TransportError.network(u.localizedDescription)
            }
        }
        return error
    }

    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
            return (data, http)
        } catch {
            throw Self.map(error)
        }
    }

    public func streamLines(_ request: URLRequest) async throws -> (HTTPURLResponse, AsyncThrowingStream<String, Error>) {
        #if canImport(Darwin)
        do {
            let (bytes, response) = try await session.bytes(for: request)
            guard let http = response as? HTTPURLResponse else { throw TransportError.notHTTP }
            let stream = AsyncThrowingStream<String, Error> { continuation in
                let task = Task {
                    do {
                        for try await line in bytes.lines { continuation.yield(line) }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: Self.map(error))
                    }
                }
                continuation.onTermination = { _ in task.cancel() }
            }
            return (http, stream)
        } catch {
            throw Self.map(error)
        }
        #else
        let (data, http) = try await send(request)
        let text = String(decoding: data, as: UTF8.self)
        let stream = AsyncThrowingStream<String, Error> { c in
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) { c.yield(String(line)) }
            c.finish()
        }
        return (http, stream)
        #endif
    }
}

extension HTTPURLResponse {
    /// `Retry-After` in seconds (integer seconds or HTTP date).
    public var retryAfterSeconds: TimeInterval? {
        guard let raw = value(forHTTPHeaderField: "Retry-After")?.trimmingCharacters(in: .whitespaces) else { return nil }
        if let s = TimeInterval(raw) { return max(0, s) }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let d = f.date(from: raw) { return max(0, d.timeIntervalSinceNow) }
        return nil
    }
}
