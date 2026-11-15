import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - Response of GET /media/stats (see server/media-gateway/STATS.md)

public struct MediaStatsResponse: Codable, Sendable, Equatable {
    public var fetchedAt: String?
    public var gateway: GatewayStats?
    public var recordings: WebsiteRecordingCounts?
    enum CodingKeys: String, CodingKey { case fetchedAt = "fetched_at", gateway, recordings }
    public init(fetchedAt: String? = nil, gateway: GatewayStats?, recordings: WebsiteRecordingCounts?) {
        self.fetchedAt = fetchedAt; self.gateway = gateway; self.recordings = recordings
    }
}

public struct GatewayStats: Codable, Sendable, Equatable {
    public var generatedAt: String?
    public var timezone: String?
    public var volume: VolumeStats
    public var recordings: GatewayRecordingIndex
    public var traffic: TrafficHistory?
    public var serverTraffic: ServerTrafficHistory?
    enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", timezone, volume, recordings, traffic, serverTraffic = "server_traffic" }
    public init(generatedAt: String? = nil, timezone: String?, volume: VolumeStats, recordings: GatewayRecordingIndex, traffic: TrafficHistory?, serverTraffic: ServerTrafficHistory?) {
        self.generatedAt = generatedAt; self.timezone = timezone; self.volume = volume; self.recordings = recordings; self.traffic = traffic; self.serverTraffic = serverTraffic
    }
}

public struct VolumeStats: Codable, Sendable, Equatable {
    public var path: String?
    public var realPath: String?
    public var totalBytes: Int64
    public var usedBytes: Int64
    public var availableBytes: Int64
    public var freeBytes: Int64?
    enum CodingKeys: String, CodingKey { case path, realPath = "real_path", totalBytes = "total_bytes", usedBytes = "used_bytes", availableBytes = "available_bytes", freeBytes = "free_bytes" }
    public init(path: String? = nil, realPath: String? = nil, totalBytes: Int64, usedBytes: Int64, availableBytes: Int64, freeBytes: Int64? = nil) {
        self.path = path; self.realPath = realPath; self.totalBytes = totalBytes; self.usedBytes = usedBytes; self.availableBytes = availableBytes; self.freeBytes = freeBytes
    }
}

public struct GatewayRecordingIndex: Codable, Sendable, Equatable {
    /// nil while the gateway's first scan is still running.
    public var count: Int?
    public var bytes: Int64?
    public var indexedAt: String?
    enum CodingKeys: String, CodingKey { case count, bytes, indexedAt = "indexed_at" }
    public init(count: Int?, bytes: Int64?, indexedAt: String? = nil) { self.count = count; self.bytes = bytes; self.indexedAt = indexedAt }
}

public struct TrafficDay: Codable, Sendable, Equatable {
    public var date: String
    public var uploadBytes: Int64
    public var playbackBytes: Int64
    enum CodingKeys: String, CodingKey { case date, uploadBytes = "upload_bytes", playbackBytes = "playback_bytes" }
    public init(date: String, uploadBytes: Int64, playbackBytes: Int64) { self.date = date; self.uploadBytes = uploadBytes; self.playbackBytes = playbackBytes }
}

public struct TrafficHistory: Codable, Sendable, Equatable {
    public var scope: String?
    public var since: String?
    public var days: [TrafficDay]
    public init(scope: String? = "media-gateway", since: String?, days: [TrafficDay]) { self.scope = scope; self.since = since; self.days = days }
}

public struct ServerTrafficDay: Codable, Sendable, Equatable {
    public var date: String
    public var rxBytes: Int64
    public var txBytes: Int64
    enum CodingKeys: String, CodingKey { case date, rxBytes = "rx_bytes", txBytes = "tx_bytes" }
    public init(date: String, rxBytes: Int64, txBytes: Int64) { self.date = date; self.rxBytes = rxBytes; self.txBytes = txBytes }
}

public struct ServerTrafficHistory: Codable, Sendable, Equatable {
    public var scope: String?
    public var available: Bool
    public var since: String?
    public var days: [ServerTrafficDay]
    public init(scope: String? = "host-network-interfaces", available: Bool, since: String?, days: [ServerTrafficDay]) {
        self.scope = scope; self.available = available; self.since = since; self.days = days
    }
}

public struct WebsiteRecordingCounts: Codable, Sendable, Equatable {
    public var ready: Int?
    public var uploading: Int?
    public var failed: Int?
    public var deletePending: Int?
    public var readyBytes: Int64?
    enum CodingKeys: String, CodingKey { case ready, uploading, failed, deletePending = "delete_pending", readyBytes = "ready_bytes" }
    public init(ready: Int?, uploading: Int?, failed: Int?, deletePending: Int?, readyBytes: Int64?) {
        self.ready = ready; self.uploading = uploading; self.failed = failed; self.deletePending = deletePending; self.readyBytes = readyBytes
    }
}

public enum MediaStatsError: Error, LocalizedError, Equatable {
    /// The website doesn't have the statistics endpoint yet (404).
    case notAvailable
    public var errorDescription: String? {
        "LetsMeet doesn't provide server statistics yet (the /media/stats endpoint isn't set up)."
    }
}

public protocol MediaStatsFetching: Sendable {
    func mediaStats() async throws -> MediaStatsResponse
}

extension LetsMeetClient: MediaStatsFetching {
    public func mediaStats() async throws -> MediaStatsResponse {
        let (data, http) = try await transport.send(makeRequest("media/stats"))
        if http.statusCode == 404 { throw MediaStatsError.notAvailable }
        guard http.statusCode == 200 else { throw Self.decodeError(data, http) }
        do { return try JSONDecoder().decode(MediaStatsResponse.self, from: data) }
        catch { throw LetsMeetClientError.decoding(String(describing: error)) }
    }
}

// MARK: - Calculations

/// Storage split for the doughnut chart. All figures come from the server; nothing is estimated.
public struct StorageBreakdown: Sendable, Equatable {
    public var total: Int64
    public var used: Int64
    public var available: Int64
    /// Lesson recordings (nil while the gateway is still indexing).
    public var recordings: Int64?
    /// Used space that isn't lesson recordings (other files, filesystem metadata).
    public var otherUsed: Int64?
    /// Space neither used nor available to the gateway (e.g. ext4 blocks reserved for root).
    public var reserved: Int64

    public init(volume v: VolumeStats, recordingsBytes: Int64?) {
        let t = max(0, v.totalBytes), u = max(0, v.usedBytes), a = max(0, v.availableBytes)
        let rec = recordingsBytes.map { min(max(0, $0), u) }
        total = t
        used = u
        available = a
        recordings = rec
        otherUsed = rec.map { u - $0 }
        reserved = max(0, t - u - a)
    }

    public func fraction(_ part: Int64) -> Double { total > 0 ? Double(part) / Double(total) : 0 }
    public var usedFraction: Double { fraction(used) }
    public var availableFraction: Double { fraction(available) }
    /// True when less than `threshold` (0–1) of the volume is available.
    public func isLow(threshold: Double) -> Bool { total > 0 && availableFraction < threshold }
}

public struct BandwidthTotals: Sendable, Equatable {
    public var upload: Int64 = 0
    public var playback: Int64 = 0
    public var total: Int64 { upload + playback }
    public init(upload: Int64 = 0, playback: Int64 = 0) { self.upload = upload; self.playback = playback }
}

public struct BandwidthSummary: Sendable, Equatable {
    public var today = BandwidthTotals()
    public var week = BandwidthTotals()
    public var month = BandwidthTotals()
    public init() {}
}

public enum Bandwidth {
    /// "yyyy-MM-dd" for `date` in `tz`.
    public static func day(_ date: Date, _ tz: TimeZone) -> String { CoreFormat.lessonDateString(date, timeZone: tz) }

    /// Monday of the calendar week containing `date` (weeks run Monday–Sunday).
    public static func weekStart(_ date: Date, _ tz: TimeZone) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        cal.firstWeekday = 2
        let weekday = cal.component(.weekday, from: date)       // 1 = Sunday … 7 = Saturday
        let back = (weekday + 5) % 7                             // days since Monday
        return day(cal.date(byAdding: .day, value: -back, to: date)!, tz)
    }

    /// Totals for today, this week (Mon–Sun) and this calendar month, in `tz`.
    public static func summarise(_ days: [(date: String, upload: Int64, playback: Int64)], now: Date, timeZone tz: TimeZone) -> BandwidthSummary {
        let today = day(now, tz), monday = weekStart(now, tz), month = String(today.prefix(7))
        var s = BandwidthSummary()
        for d in days {
            if d.date == today { s.today.upload += d.upload; s.today.playback += d.playback }
            if d.date >= monday && d.date <= today { s.week.upload += d.upload; s.week.playback += d.playback }
            if d.date.hasPrefix(month) && d.date <= today { s.month.upload += d.upload; s.month.playback += d.playback }
        }
        return s
    }

    public static func summarise(_ t: TrafficHistory, now: Date, timeZone tz: TimeZone) -> BandwidthSummary {
        summarise(t.days.map { ($0.date, $0.uploadBytes, $0.playbackBytes) }, now: now, timeZone: tz)
    }

    /// Whole-server traffic: inbound (rx) as "upload", outbound (tx) as "playback/downloads".
    public static func summarise(_ t: ServerTrafficHistory, now: Date, timeZone tz: TimeZone) -> BandwidthSummary {
        summarise(t.days.map { ($0.date, $0.rxBytes, $0.txBytes) }, now: now, timeZone: tz)
    }
}

public enum ByteUnit: String, Codable, Sendable, CaseIterable, Identifiable {
    case automatic, mb, gb, tb
    public var id: String { rawValue }
    public var label: String { self == .automatic ? "Automatic" : rawValue.uppercased() }
}

/// Decimal units (1 GB = 1,000,000,000 bytes), as disks and the Finder report them.
public enum ByteFormat {
    public static func string(_ bytes: Int64, unit: ByteUnit = .automatic) -> String {
        let b = Double(max(0, bytes))
        func f(_ v: Double, _ u: String) -> String {
            let digits = v >= 100 ? 0 : (v >= 10 ? 1 : 2)
            return String(format: "%.\(digits)f %@", v, u)
        }
        switch unit {
        case .mb: return f(b / 1e6, "MB")
        case .gb: return f(b / 1e9, "GB")
        case .tb: return f(b / 1e12, "TB")
        case .automatic:
            if b >= 1e12 { return f(b / 1e12, "TB") }
            if b >= 1e9 { return f(b / 1e9, "GB") }
            if b >= 1e6 { return f(b / 1e6, "MB") }
            if b >= 1e3 { return f(b / 1e3, "KB") }
            return "\(Int64(b)) bytes"
        }
    }

    public static func percent(_ fraction: Double) -> String {
        let p = fraction * 100
        return p > 0 && p < 0.1 ? "<0.1%" : String(format: p < 10 ? "%.1f%%" : "%.0f%%", p)
    }

    /// "1 min 30 s", "2 h 5 min", "45 s".
    public static func duration(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(0, s)) s" }
        if s < 3600 { return "\(s / 60) min" + (s % 60 > 0 ? " \(s % 60) s" : "") }
        return "\(s / 3600) h" + ((s % 3600) / 60 > 0 ? " \((s % 3600) / 60) min" : "")
    }
}

/// Upload speed from real byte counts (smoothed) and the time left.
public struct TransferRate: Sendable, Equatable {
    public private(set) var bytesPerSecond: Double?
    private var lastBytes: Int64?
    private var lastTime: Date?
    public var smoothing: Double

    public init(smoothing: Double = 0.3) { self.smoothing = smoothing }

    /// Feeds a progress sample; samples closer than `minInterval` are ignored for the rate.
    public mutating func update(sent: Int64, at t: Date, minInterval: TimeInterval = 0.5) {
        guard let lb = lastBytes, let lt = lastTime else { lastBytes = sent; lastTime = t; return }
        let dt = t.timeIntervalSince(lt)
        if sent < lb { lastBytes = sent; lastTime = t; bytesPerSecond = nil; return } // restarted
        guard dt >= minInterval else { return }
        let instant = Double(sent - lb) / dt
        bytesPerSecond = bytesPerSecond.map { $0 * (1 - smoothing) + instant * smoothing } ?? instant
        lastBytes = sent
        lastTime = t
    }

    public func secondsRemaining(sent: Int64, total: Int64) -> Double? {
        guard let r = bytesPerSecond, r > 1, total > sent else { return nil }
        return Double(total - sent) / r
    }
}

// MARK: - Local figures (this Mac's queue)

/// Video counts from this Mac's library. One lesson job = one video, however many recordings
/// were joined into it.
public struct VideoQueueCounts: Sendable, Equatable {
    public var completed = 0          // confirmed ready on LetsMeet (uploaded by this Mac)
    public var alreadyOnLetsMeet = 0  // found already there, not uploaded again
    public var uploading = 0          // registering, uploading or verifying
    public var merging = 0
    public var queued = 0
    public var failed = 0
    public var skipped = 0
    public var deleted = 0
    public var completedBytes: Int64 = 0

    public var awaiting: Int { queued + merging }
    public var averageCompletedSize: Int64? { completed > 0 ? completedBytes / Int64(completed) : nil }

    public init() {}

    public static func count(_ jobs: [Job], origin: VideoUploadState.Origin? = nil) -> VideoQueueCounts {
        var c = VideoQueueCounts()
        for j in jobs {
            guard let v = j.video, origin == nil || v.origin == origin else { continue }
            switch v.stage {
            case .ready:
                if v.adoptedExisting { c.alreadyOnLetsMeet += 1 } else { c.completed += 1; c.completedBytes += v.fileSize ?? 0 }
            case .registering, .uploading, .completing: c.uploading += 1
            case .merging: c.merging += 1
            case .queued: c.queued += 1
            case .failed: c.failed += 1
            case .skipped: c.skipped += 1
            case .deleted: c.deleted += 1
            }
        }
        return c
    }
}

extension VideoUploadState {
    /// What George sees for this video.
    public enum DisplayPhase: String, Sendable {
        case queued = "Queued", preparing = "Preparing video", merging = "Merging recordings", readyToUpload = "Ready to upload",
             uploading = "Uploading", verifying = "Verifying with server", completed = "Completed", failed = "Failed", paused = "Paused",
             skipped = "Skipped", deleted = "Deleted"
    }

    public func displayPhase(paused: Bool) -> DisplayPhase {
        if paused && stage.isActive { return .paused }
        switch stage {
        case .queued: return (lastCompletedStage == "resolved" || lastCompletedStage == "checked") ? .preparing : .queued
        case .merging: return .merging
        case .registering: return .readyToUpload
        case .uploading: return .uploading
        case .completing: return .verifying
        case .ready: return .completed
        case .failed: return .failed
        case .skipped: return .skipped
        case .deleted: return .deleted
        }
    }
}

// MARK: - Persistence

/// The last statistics received (kept across restarts so stale figures can still be shown, clearly marked).
public struct MediaStatsSnapshot: Codable, Sendable, Equatable {
    public var stats: MediaStatsResponse?
    public var fetchedAt: Date?
    public var lastAttemptAt: Date?
    public var lastError: String?
    public var notAvailable: Bool
    public init(stats: MediaStatsResponse? = nil, fetchedAt: Date? = nil, lastAttemptAt: Date? = nil, lastError: String? = nil, notAvailable: Bool = false) {
        self.stats = stats; self.fetchedAt = fetchedAt; self.lastAttemptAt = lastAttemptAt; self.lastError = lastError; self.notAvailable = notAvailable
    }

    /// Stale when the latest attempt failed, or the figures are older than three refresh intervals.
    public func isStale(now: Date, refreshInterval: TimeInterval) -> Bool {
        guard let f = fetchedAt else { return true }
        if let a = lastAttemptAt, a > f, lastError != nil { return true }
        return now.timeIntervalSince(f) > max(180, refreshInterval * 3)
    }
}

/// Fetches and caches server statistics in `media-stats.json` (no secrets are stored).
public final class MediaStatsCache: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var current: MediaStatsSnapshot

    public init(directory: URL) {
        url = directory.appendingPathComponent("media-stats.json")
        current = (try? Data(contentsOf: url)).flatMap { try? JSONCoding.decoder().decode(MediaStatsSnapshot.self, from: $0) } ?? MediaStatsSnapshot()
    }

    public var snapshot: MediaStatsSnapshot { lock.lock(); defer { lock.unlock() }; return current }

    /// Fetches new figures. On failure the previous figures are kept and the error recorded.
    @discardableResult
    public func refresh(using fetcher: MediaStatsFetching, now: Date = Date()) async -> MediaStatsSnapshot {
        var s = snapshot
        s.lastAttemptAt = now
        do {
            let r = try await fetcher.mediaStats()
            s.stats = r
            s.fetchedAt = now
            s.lastError = nil
            s.notAvailable = false
        } catch MediaStatsError.notAvailable {
            s.notAvailable = true
            s.lastError = MediaStatsError.notAvailable.localizedDescription
        } catch {
            s.notAvailable = false
            s.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
        store(s)
        return s
    }

    /// Replaces the stored snapshot (used for the screenshot sample data).
    public func store(_ s: MediaStatsSnapshot) {
        lock.lock(); current = s; lock.unlock()
        if let d = try? JSONCoding.encoder().encode(s) { try? d.write(to: url, options: [.atomic]) }
    }
}

/// Bytes this Mac has actually sent to the media server, per local day (from real upload progress).
public final class VideoTransferLog: @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    private var days: [String: Int64]
    private var unsaved = false
    private var lastSave = Date.distantPast
    public var timeZone: TimeZone

    public init(directory: URL, timeZone: TimeZone = .current) {
        url = directory.appendingPathComponent("video-transfers.json")
        self.timeZone = timeZone
        days = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: Int64].self, from: $0) } ?? [:]
    }

    public func add(_ bytes: Int64, at t: Date = Date()) {
        guard bytes > 0 else { return }
        lock.lock()
        days[Bandwidth.day(t, timeZone), default: 0] += bytes
        unsaved = true
        let due = t.timeIntervalSince(lastSave) > 10
        lock.unlock()
        if due { save(now: t) }
    }

    public func save(now: Date = Date()) {
        lock.lock()
        guard unsaved, let d = try? JSONEncoder().encode(days) else { lock.unlock(); return }
        unsaved = false
        lastSave = now
        lock.unlock()
        try? d.write(to: url, options: [.atomic])
    }

    public var byDay: [String: Int64] { lock.lock(); defer { lock.unlock() }; return days }

    public func summary(now: Date) -> BandwidthSummary {
        Bandwidth.summarise(byDay.map { ($0.key, $0.value, Int64(0)) }, now: now, timeZone: timeZone)
    }
}
