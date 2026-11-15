import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import LessonNotesCore

let sampleStatsJSON = #"""
{"fetched_at":"2026-11-18T10:00:01Z",
 "gateway":{"ok":true,"generated_at":"2026-11-18T10:00:00Z","timezone":"Europe/London",
   "volume":{"path":"/srv/sftpgo/data/recordings","real_path":"/mnt/storage/sftpgo/data/recordings","total_bytes":3000000000000,"used_bytes":475000000000,"available_bytes":2400000000000,"free_bytes":2525000000000},
   "recordings":{"count":121,"bytes":450000000000,"indexed_at":"2026-11-18T09:59:00Z"},
   "traffic":{"scope":"media-gateway","since":"2026-11-01T00:00:00Z","days":[
     {"date":"2026-10-31","upload_bytes":5000000000,"playback_bytes":1000000000},
     {"date":"2026-11-01","upload_bytes":7000000000,"playback_bytes":2000000000},
     {"date":"2026-11-15","upload_bytes":3000000000,"playback_bytes":500000000},
     {"date":"2026-11-16","upload_bytes":12000000000,"playback_bytes":8000000000},
     {"date":"2026-11-18","upload_bytes":1240000000,"playback_bytes":300000000}]},
   "server_traffic":{"scope":"host-network-interfaces","available":true,"since":"2026-11-01T00:00:00Z","days":[
     {"date":"2026-11-18","rx_bytes":1300000000,"tx_bytes":400000000}]}},
 "recordings":{"ready":120,"uploading":1,"failed":0,"delete_pending":0,"ready_bytes":449000000000}}
"""#

final class MediaStatsTests: XCTestCase {
    let london = TimeZone(identifier: "Europe/London")!
    func date(_ iso: String) -> Date { CoreFormat.parseISO8601(iso)! }

    func testDecodesWebsiteResponse() throws {
        let r = try JSONDecoder().decode(MediaStatsResponse.self, from: Data(sampleStatsJSON.utf8))
        let g = try XCTUnwrap(r.gateway)
        XCTAssertEqual(g.volume.realPath, "/mnt/storage/sftpgo/data/recordings", "the HDD, not the system disk")
        XCTAssertEqual(g.volume.totalBytes, 3_000_000_000_000)
        XCTAssertEqual(g.recordings.count, 121)
        XCTAssertEqual(g.traffic?.days.count, 5)
        XCTAssertEqual(g.serverTraffic?.days.first?.txBytes, 400_000_000)
        XCTAssertEqual(r.recordings?.ready, 120)
        XCTAssertEqual(r.recordings?.readyBytes, 449_000_000_000)
        // Index still building: counts are null, not zero.
        let building = try JSONDecoder().decode(GatewayRecordingIndex.self, from: Data(#"{"count":null,"bytes":null}"#.utf8))
        XCTAssertNil(building.count)
    }

    func testStorageBreakdown() throws {
        let v = VolumeStats(totalBytes: 3_000_000_000_000, usedBytes: 475_000_000_000, availableBytes: 2_400_000_000_000)
        let b = StorageBreakdown(volume: v, recordingsBytes: 450_000_000_000)
        XCTAssertEqual(b.recordings, 450_000_000_000)
        XCTAssertEqual(b.otherUsed, 25_000_000_000)
        XCTAssertEqual(b.reserved, 125_000_000_000, "ext4 reserved blocks shown separately")
        XCTAssertEqual(b.usedFraction, 475.0 / 3000.0, accuracy: 1e-9)
        XCTAssertEqual(b.availableFraction, 0.8, accuracy: 1e-9)
        XCTAssertEqual(b.recordings! + b.otherUsed! + b.reserved + b.available, b.total)
        XCTAssertFalse(b.isLow(threshold: 0.10))
        XCTAssertTrue(StorageBreakdown(volume: VolumeStats(totalBytes: 100, usedBytes: 95, availableBytes: 5), recordingsBytes: nil).isLow(threshold: 0.10))
        let unknown = StorageBreakdown(volume: v, recordingsBytes: nil)
        XCTAssertNil(unknown.recordings)
        XCTAssertNil(unknown.otherUsed, "unknown stays unknown, not zero")
        XCTAssertEqual(StorageBreakdown(volume: v, recordingsBytes: 999_000_000_000_000).recordings, 475_000_000_000, "clamped to used")
        XCTAssertEqual(StorageBreakdown(volume: VolumeStats(totalBytes: 0, usedBytes: 0, availableBytes: 0), recordingsBytes: 0).usedFraction, 0)
    }

    func testBandwidthTodayWeekMonth() throws {
        let r = try JSONDecoder().decode(MediaStatsResponse.self, from: Data(sampleStatsJSON.utf8))
        // Wednesday 18 November 2026.
        let s = Bandwidth.summarise(r.gateway!.traffic!, now: date("2026-11-18T10:00:00Z"), timeZone: london)
        XCTAssertEqual(s.today, BandwidthTotals(upload: 1_240_000_000, playback: 300_000_000))
        XCTAssertEqual(s.week, BandwidthTotals(upload: 13_240_000_000, playback: 8_300_000_000), "Mon 16 – Wed 18; Sunday 15 is last week")
        XCTAssertEqual(s.month, BandwidthTotals(upload: 23_240_000_000, playback: 10_800_000_000), "1–18 November; 31 October excluded")
        XCTAssertEqual(s.today.total, 1_540_000_000)
        let server = Bandwidth.summarise(r.gateway!.serverTraffic!, now: date("2026-11-18T10:00:00Z"), timeZone: london)
        XCTAssertEqual(server.today, BandwidthTotals(upload: 1_300_000_000, playback: 400_000_000))
    }

    func testCalendarBoundaries() {
        XCTAssertEqual(Bandwidth.weekStart(date("2026-11-15T12:00:00Z"), london), "2026-11-09", "Sunday belongs to the week that began Monday 9th")
        XCTAssertEqual(Bandwidth.weekStart(date("2026-11-16T00:30:00Z"), london), "2026-11-16", "Monday starts a new week")
        XCTAssertEqual(Bandwidth.day(date("2026-11-18T23:30:00Z"), london), "2026-11-18")
        XCTAssertEqual(Bandwidth.day(date("2026-11-18T23:30:00Z"), TimeZone(identifier: "Asia/Tokyo")!), "2026-11-19")
        // British Summer Time: 23:30 UTC on 30 June is 00:30 on 1 July in London — a new month.
        let s = Bandwidth.summarise([("2026-06-30", 10, 0), ("2026-07-01", 5, 0)], now: date("2026-06-30T23:30:00Z"), timeZone: london)
        XCTAssertEqual(s.today.upload, 5)
        XCTAssertEqual(s.month.upload, 5)
        XCTAssertEqual(s.week.upload, 15, "Tue 30 June and Wed 1 July are the same week")
        // Week spanning a month boundary.
        let w = Bandwidth.summarise([("2026-10-26", 1, 0), ("2026-10-31", 2, 0), ("2026-11-01", 4, 0)], now: date("2026-11-01T12:00:00Z"), timeZone: london)
        XCTAssertEqual(w.week.upload, 7)
        XCTAssertEqual(w.month.upload, 4)
        XCTAssertEqual(Bandwidth.summarise([], now: Date(), timeZone: london), BandwidthSummary(), "no history → zero traffic recorded, not invented")
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteFormat.string(3_000_000_000_000), "3.00 TB")
        XCTAssertEqual(ByteFormat.string(450_000_000_000), "450 GB")
        XCTAssertEqual(ByteFormat.string(1_240_000_000), "1.24 GB")
        XCTAssertEqual(ByteFormat.string(8_500_000), "8.50 MB")
        XCTAssertEqual(ByteFormat.string(2_952_000_000_000), "2.95 TB")
        XCTAssertEqual(ByteFormat.string(2_000_000_000_000, unit: .gb), "2000 GB")
        XCTAssertEqual(ByteFormat.string(1_500_000_000, unit: .mb), "1500 MB")
        XCTAssertEqual(ByteFormat.string(25_000_000_000, unit: .tb), "0.03 TB")
        XCTAssertEqual(ByteFormat.string(512), "512 bytes")
        XCTAssertEqual(ByteFormat.percent(0.158), "16%")
        XCTAssertEqual(ByteFormat.percent(0.0832), "8.3%")
        XCTAssertEqual(ByteFormat.percent(0.0001), "<0.1%")
        XCTAssertEqual(ByteFormat.duration(90), "1 min 30 s")
        XCTAssertEqual(ByteFormat.duration(45), "45 s")
        XCTAssertEqual(ByteFormat.duration(7_500), "2 h 5 min")
    }

    func testTransferRateAndTimeRemaining() {
        var r = TransferRate(smoothing: 1)   // no smoothing: easy numbers
        let t0 = Date(timeIntervalSince1970: 1_000)
        r.update(sent: 0, at: t0)
        XCTAssertNil(r.bytesPerSecond, "needs two samples")
        r.update(sent: 4_000_000, at: t0.addingTimeInterval(0.2))
        XCTAssertNil(r.bytesPerSecond, "samples closer than 0.5 s are ignored")
        r.update(sent: 8_500_000, at: t0.addingTimeInterval(1))
        XCTAssertEqual(r.bytesPerSecond!, 8_500_000, accuracy: 1)
        XCTAssertEqual(r.secondsRemaining(sent: 1_240_000_000, total: 2_000_000_000)!, 89.4, accuracy: 0.1)
        XCTAssertNil(r.secondsRemaining(sent: 10, total: 10))
        r.update(sent: 100, at: t0.addingTimeInterval(2))
        XCTAssertNil(r.bytesPerSecond, "a restarted upload resets the rate")
    }

    func testVideoCountsCountMergedLessonOnce() async throws {
        let v = try VideoHarness()
        v.h.store.updateSettings { $0.video.deleteMergedAfterUpload = false }
        _ = try await v.submitted(.combined, recordings: 4, sizes: [1, 2, 3, 4])
        _ = try await v.submitted(.single, recordings: 1, sizes: [90])
        let l3 = try await v.submitted(.single, recordings: 1)
        v.h.store.updateLesson(id: l3.id) { $0.recordings[0].path = "/missing.mp4" }
        // Test lessons share recording paths; set the sizes once for all of them.
        v.media.sizes = ["/tmp/zoom_0.mp4": 10, "/tmp/zoom_1.mp4": 20, "/tmp/zoom_2.mp4": 30, "/tmp/zoom_3.mp4": 40]
        await v.engine().runUntilIdle()
        let c = VideoQueueCounts.count(v.h.store.allLessons.flatMap(\.jobs))
        XCTAssertEqual(c.completed, 2, "four recordings joined into one MP4 = one video")
        XCTAssertEqual(c.completedBytes, (10 + 20 + 30 + 40) + 10, "one joined MP4 + one single recording")
        XCTAssertEqual(c.averageCompletedSize, 55)
        XCTAssertEqual(c.failed, 1)
        XCTAssertEqual(c.uploading + c.awaiting, 0)
        XCTAssertEqual(VideoQueueCounts.count(v.h.store.allLessons.flatMap(\.jobs), origin: .backfill), VideoQueueCounts())
    }

    func testDisplayPhases() {
        var s = VideoUploadState(origin: .automatic, uploadId: "u", noteId: "n", sourceRecordingIds: [UUID(), UUID()], originalFilename: "a.mp4", title: "t", now: Date())
        XCTAssertEqual(s.displayPhase(paused: false), .queued)
        s.lastCompletedStage = "checked"; XCTAssertEqual(s.displayPhase(paused: false), .preparing)
        s.stage = .merging; XCTAssertEqual(s.displayPhase(paused: false), .merging)
        s.stage = .registering; XCTAssertEqual(s.displayPhase(paused: false), .readyToUpload)
        s.stage = .uploading; XCTAssertEqual(s.displayPhase(paused: false), .uploading)
        XCTAssertEqual(s.displayPhase(paused: true), .paused)
        s.stage = .completing; XCTAssertEqual(s.displayPhase(paused: false), .verifying)
        s.stage = .ready; XCTAssertEqual(s.displayPhase(paused: true), .completed)
        s.stage = .failed; XCTAssertEqual(s.displayPhase(paused: false), .failed)
    }

    // MARK: Cache, stale data, unavailable server

    final class StubFetcher: MediaStatsFetching, @unchecked Sendable {
        var result: Result<MediaStatsResponse, Error>
        init(_ r: Result<MediaStatsResponse, Error>) { result = r }
        func mediaStats() async throws -> MediaStatsResponse { try result.get() }
    }

    func testCacheKeepsLastFiguresAndMarksThemStale() async throws {
        let dir = tempDir()
        let good = try JSONDecoder().decode(MediaStatsResponse.self, from: Data(sampleStatsJSON.utf8))
        let cache = MediaStatsCache(directory: dir)
        XCTAssertNil(cache.snapshot.stats)
        XCTAssertTrue(cache.snapshot.isStale(now: Date(), refreshInterval: 60), "nothing yet")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        var s = await cache.refresh(using: StubFetcher(.success(good)), now: t0)
        XCTAssertEqual(s.stats, good)
        XCTAssertNil(s.lastError)
        XCTAssertFalse(s.isStale(now: t0.addingTimeInterval(60), refreshInterval: 60))
        XCTAssertTrue(s.isStale(now: t0.addingTimeInterval(600), refreshInterval: 60), "old figures are stale")
        // Server unavailable: figures kept, error shown, marked stale — never replaced by zeros.
        let down = LetsMeetAPIError(httpStatus: 503, code: "storage_unavailable", message: "Media server unreachable", retryAfter: 30)
        s = await cache.refresh(using: StubFetcher(.failure(down)), now: t0.addingTimeInterval(30))
        XCTAssertEqual(s.stats, good)
        XCTAssertEqual(s.fetchedAt, t0)
        XCTAssertEqual(s.lastError, "Media server unreachable")
        XCTAssertTrue(s.isStale(now: t0.addingTimeInterval(31), refreshInterval: 60))
        // Survives a restart.
        let reopened = MediaStatsCache(directory: dir)
        XCTAssertEqual(reopened.snapshot.stats, good)
        XCTAssertEqual(reopened.snapshot.lastError, "Media server unreachable")
        // Recovery clears the error.
        s = await reopened.refresh(using: StubFetcher(.success(good)), now: t0.addingTimeInterval(90))
        XCTAssertNil(s.lastError)
        XCTAssertFalse(s.isStale(now: t0.addingTimeInterval(91), refreshInterval: 60))
    }

    func testClientMapsMissingEndpointAndErrors() async throws {
        var status = 404
        let t = StubTransport { _ in status == 404 ? StubTransport.json(404, #"{"error":{"code":"not_found","message":"no"}}"#)
            : (status == 503 ? StubTransport.json(503, #"{"error":{"code":"storage_unavailable","message":"Media server unreachable","retryable":true}}"#, headers: ["Retry-After": "30"])
               : StubTransport.json(200, sampleStatsJSON)) }
        let c = try LetsMeetClient(baseURLString: LetsMeetClient.defaultBaseURL, apiKey: "ghln_K", transport: t)
        do { _ = try await c.mediaStats(); XCTFail() } catch { XCTAssertEqual(error as? MediaStatsError, .notAvailable) }
        XCTAssertEqual(t.requests.value[0].url?.path, "/api/public/lesson-notes/media/stats")
        XCTAssertEqual(t.requests.value[0].value(forHTTPHeaderField: "Authorization"), "Bearer ghln_K")
        status = 503
        do { _ = try await c.mediaStats(); XCTFail() } catch let e as LetsMeetAPIError { XCTAssertEqual(e.code, "storage_unavailable"); XCTAssertEqual(e.retryAfter, 30) }
        status = 200
        let ok = try await c.mediaStats()
        XCTAssertEqual(ok.gateway?.recordings.count, 121)
        let cache = MediaStatsCache(directory: tempDir())
        let s = await cache.refresh(using: StubFetcher(.failure(MediaStatsError.notAvailable)))
        XCTAssertTrue(s.notAvailable)
        XCTAssertNil(s.stats)
    }

    // MARK: Real upload progress, simultaneous uploads, transfer log

    final class SlowUploader: SignedUploading, @unchecked Sendable {
        let active = Box<Int>(0), maxActive = Box<Int>(0)
        func upload(file: URL, size: Int64, to target: SignedUpload, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
            active.mutate { $0 += 1 }
            maxActive.mutate { [a = active.value] in $0 = max($0, a) }
            for i in 1...4 {
                try await Task.sleep(nanoseconds: 30_000_000)
                progress(size * Int64(i) / 4, size)
            }
            active.mutate { $0 -= 1 }
        }
    }

    func testSimultaneousUploadsReportIndependentByteProgress() async throws {
        let v = try VideoHarness()
        v.h.store.updateSettings { $0.video.maxConcurrentUploads = 2 }
        let a = try await v.submitted(.single, recordings: 1, sizes: [4_000])
        let b = try await v.submitted(.single, recordings: 1, sizes: [4_000])
        let uploader = SlowUploader()
        let log = VideoTransferLog(directory: v.h.store.directory, timeZone: london)
        let api = v.api, dir = v.videos
        let engine = VideoUploadEngine(store: v.h.store, deps: VideoDependencies(makeAPI: { api }, media: v.media, uploader: uploader, isOnline: { true },
                                                                                  videosDirectory: { dir }, transferLog: log), probePacing: 0)
        let events = Box<[VideoEvent]>([])
        await engine.setEventHandler { e in events.mutate { $0.append(e) } }
        await engine.runUntilIdle()
        XCTAssertEqual(uploader.maxActive.value, 2, "two uploads at once")
        for id in [a.jobs[0].id, b.jobs[0].id] {
            let bytes: [Int64] = events.value.compactMap {
                if case .progress(let j, let m, _, let sent, let total) = $0, j == id, m == "Uploading video", total == 4_000 { return sent } else { return nil }
            }
            XCTAssertEqual(bytes, [0, 1_000, 2_000, 3_000, 4_000], "real byte counts per upload, in order")
        }
        // The transfer log has the bytes actually sent, and survives a restart.
        log.save()
        let today = Bandwidth.day(Date(), london)
        XCTAssertEqual(VideoTransferLog(directory: v.h.store.directory, timeZone: london).byDay[today], 8_000)
        XCTAssertEqual(log.summary(now: Date()).today.upload, 8_000)
    }

    func testMediaServerNotFoundIsRetriedAndWebsiteNotFoundIsNotSkipped() async throws {
        let v = try VideoHarness()
        v.uploader.errors = [SignedUploadError.http(404)]
        let l = try await v.submitted(.single, recordings: 1)
        await v.engine().runUntilIdle()
        var s = v.h.store.job(id: l.jobs[0].id)!.video!
        XCTAssertNotEqual(s.stage, .failed, "gateway 404 = not accepting uploads yet → retried")
        XCTAssertNotNil(s.nextAttemptAt)
        let v2 = try VideoHarness()
        v2.api.registerErrors = [LetsMeetAPIError(httpStatus: 404, code: "not_found", message: "No such route")]
        let l2 = try await v2.submitted(.single, recordings: 1)
        await v2.engine().runUntilIdle()
        s = v2.h.store.job(id: l2.jobs[0].id)!.video!
        XCTAssertEqual(s.stage, .failed, "a generic website 404 is not mistaken for a deleted note")
        v2.api.registerErrors = [LetsMeetAPIError(httpStatus: 404, code: "note_not_found", message: "gone")]
        await v2.engine().retry(jobId: l2.jobs[0].id)
        await v2.engine().runUntilIdle()
        XCTAssertEqual(v2.h.store.job(id: l2.jobs[0].id)?.video?.stage, .skipped)
    }
}
