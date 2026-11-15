import Foundation
import AVFoundation
import AppKit
import LessonNotesCore

enum VideoMergeError: LocalizedError {
    case noTracks(String)
    case exportFailed(String)
    case invalidOutput(String)
    var errorDescription: String? {
        switch self {
        case .noTracks(let f): return "“\(f)” has no audio or video."
        case .exportFailed(let m): return "Exporting the joined video failed: \(m)"
        case .invalidOutput(let m): return "The joined video did not pass checks: \(m)"
        }
    }
}

/// Recording access, AVFoundation merging and checks for video uploads. Original recordings are
/// only ever read; merged files are written to the videos folder.
struct AVVideoMedia: VideoMediaProviding {
    /// The export preset the last successful merge used (for the CI self-test).
    nonisolated(unsafe) static var lastPreset: String?

    func sourceInfo(_ rec: RecordingRef) async -> SourceFile {
        (try? await FolderAccess.withAccess(bookmark: rec.bookmark, path: rec.path) { url -> SourceFile in
            guard FileManager.default.isReadableFile(atPath: url.path),
                  let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value else {
                return SourceFile(exists: false, size: 0)
            }
            return SourceFile(exists: true, size: size)
        }) ?? SourceFile(exists: false, size: 0)
    }

    func withAccess(bookmark: Data?, path: String, _ body: @Sendable (URL) async throws -> Void) async throws {
        try await FolderAccess.withAccess(bookmark: bookmark, path: path) { url in
            guard FileManager.default.isReadableFile(atPath: url.path) else { throw PipelineError.recordingMissing((path as NSString).lastPathComponent) }
            try await body(url)
        }
    }

    func validateMerged(_ url: URL) async -> MergedVideo? {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value, size > 0 else { return nil }
        let asset = AVURLAsset(url: url)
        guard let d = try? await asset.load(.duration), d.seconds.isFinite, d.seconds > 0,
              (try? await asset.load(.isPlayable)) == true else { return nil }
        return MergedVideo(size: size, durationSec: Int(d.seconds.rounded()))
    }

    func merge(_ recs: [RecordingRef], to output: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> MergedVideo {
        // Open every original with security-scoped access for the whole merge.
        var opened: [(URL, Bool)] = []
        defer { for (u, scoped) in opened where scoped { u.stopAccessingSecurityScopedResource() } }
        for r in recs {
            if let b = r.bookmark, let res = FolderAccess.resolve(b) { opened.append((res.url, true)) }
            else { opened.append((URL(fileURLWithPath: r.path), false)) }
        }
        let assets = opened.map { AVURLAsset(url: $0.0, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]) }

        // Build one continuous timeline in the saved order.
        let comp = AVMutableComposition()
        let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let aTrack = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var expected = 0.0
        var videoFormats = Set<String>(), audioFormats = Set<String>()
        var anyVideo = false, anyAudio = false
        for (i, asset) in assets.enumerated() {
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            let vs = try await asset.loadTracks(withMediaType: .video)
            let as_ = try await asset.loadTracks(withMediaType: .audio)
            if vs.isEmpty && as_.isEmpty { throw VideoMergeError.noTracks(recs[i].filename) }
            if let v = vs.first {
                anyVideo = true
                try vTrack?.insertTimeRange(range, of: v, at: cursor)
                if i == 0 { vTrack?.preferredTransform = try await v.load(.preferredTransform) }
                videoFormats.insert(await Self.signature(v))
            } else {
                vTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
            }
            if let a = as_.first {
                anyAudio = true
                try aTrack?.insertTimeRange(range, of: a, at: cursor)
                audioFormats.insert(await Self.signature(a))
            } else {
                aTrack?.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: duration))
            }
            cursor = CMTimeAdd(cursor, duration)
            expected += duration.seconds
        }
        if !anyVideo, let t = vTrack { comp.removeTrack(t) }
        if !anyAudio, let t = aTrack { comp.removeTrack(t) }

        // Lossless stream copy when every part has the same format; otherwise re-encode.
        let canCopy = videoFormats.count <= 1 && audioFormats.count <= 1
        let partial = output.deletingLastPathComponent().appendingPathComponent(output.lastPathComponent + ".partial.mp4")
        var lastError: Error?
        for preset in (canCopy ? [AVAssetExportPresetPassthrough, AVAssetExportPresetHighestQuality] : [AVAssetExportPresetHighestQuality]) {
            try? FileManager.default.removeItem(at: partial)
            do {
                try await Self.export(comp, preset: preset, to: partial, progress: progress)
                let checked = try await Self.check(partial, expectedSeconds: expected, needVideo: anyVideo, needAudio: anyAudio)
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: partial, to: output)
                Self.lastPreset = preset
                return checked
            } catch is CancellationError {
                try? FileManager.default.removeItem(at: partial)
                throw CancellationError()
            } catch {
                lastError = error
            }
        }
        try? FileManager.default.removeItem(at: partial)
        throw lastError ?? VideoMergeError.exportFailed("unknown error")
    }

    static func signature(_ track: AVAssetTrack) async -> String {
        guard let descs = try? await track.load(.formatDescriptions), let d = descs.first else { return "?" }
        let sub = CMFormatDescriptionGetMediaSubType(d)
        if CMFormatDescriptionGetMediaType(d) == kCMMediaType_Video {
            let dim = CMVideoFormatDescriptionGetDimensions(d)
            return "v\(sub)-\(dim.width)x\(dim.height)"
        }
        if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d)?.pointee {
            return "a\(sub)-\(Int(asbd.mSampleRate))-\(asbd.mChannelsPerFrame)"
        }
        return "a\(sub)"
    }

    static func export(_ comp: AVComposition, preset: String, to url: URL, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let session = AVAssetExportSession(asset: comp, presetName: preset) else { throw VideoMergeError.exportFailed("preset \(preset) unavailable") }
        session.outputURL = url
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true   // index at the front: browsers can seek straight away
        let poller = Task {
            while !Task.isCancelled {
                progress(Double(session.progress))
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
        defer { poller.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously { c.resume() }
            }
        } onCancel: {
            session.cancelExport()
        }
        try Task.checkCancellation()
        guard session.status == .completed else {
            throw VideoMergeError.exportFailed(session.error?.localizedDescription ?? "status \(session.status.rawValue)")
        }
        progress(1)
    }

    /// The joined file must open, be playable, contain the expected tracks and last as long as the parts.
    static func check(_ url: URL, expectedSeconds: Double, needVideo: Bool, needAudio: Bool) async throws -> MergedVideo {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let d = try await asset.load(.duration).seconds
        guard d.isFinite, d > 0 else { throw VideoMergeError.invalidOutput("no duration") }
        let tolerance = max(2.0, expectedSeconds * 0.01)
        guard abs(d - expectedSeconds) <= tolerance else {
            throw VideoMergeError.invalidOutput(String(format: "duration %.0f s, expected %.0f s", d, expectedSeconds))
        }
        if needVideo, try await asset.loadTracks(withMediaType: .video).isEmpty { throw VideoMergeError.invalidOutput("no video track") }
        if needAudio, try await asset.loadTracks(withMediaType: .audio).isEmpty { throw VideoMergeError.invalidOutput("no audio track") }
        guard try await asset.load(.isPlayable) else { throw VideoMergeError.invalidOutput("not playable") }
        let size = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw VideoMergeError.invalidOutput("empty file") }
        return MergedVideo(size: size, durationSec: Int(d.rounded()))
    }

    /// Duration of an MP4 chosen for replacement.
    static func duration(of url: URL) async -> Int? {
        guard let d = try? await AVURLAsset(url: url).load(.duration).seconds, d.isFinite, d > 0 else { return nil }
        return Int(d.rounded())
    }
}

/// Streams a file to the media server's signed URL (raw PUT body, Content-Length), reporting progress.
final class URLSessionSignedUploader: NSObject, SignedUploading, @unchecked Sendable {
    let session: URLSession

    override init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300          // no data for 5 minutes = interrupted
        config.timeoutIntervalForResource = 4 * 3600    // the signed URL lasts 2 h; the gateway allows 4 h transfers
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        session = URLSession(configuration: config)
    }

    final class ProgressDelegate: NSObject, URLSessionTaskDelegate {
        let progress: @Sendable (Int64, Int64) -> Void
        let total: Int64
        init(progress: @escaping @Sendable (Int64, Int64) -> Void, total: Int64) { self.progress = progress; self.total = total }
        func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
            progress(totalBytesSent, total)
        }
    }

    func upload(file: URL, size: Int64, to target: SignedUpload, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        var req = URLRequest(url: target.url)
        req.httpMethod = target.method.isEmpty ? "PUT" : target.method
        for (k, v) in target.headers ?? ["Content-Type": "video/mp4"] { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue(String(size), forHTTPHeaderField: "Content-Length")
        let delegate = ProgressDelegate(progress: progress, total: size)
        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: req, fromFile: file, delegate: delegate)
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as URLError where e.code == .cancelled {
            throw CancellationError()
        } catch {
            throw SignedUploadError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SignedUploadError.network("No response from the media server.") }
        switch http.statusCode {
        case 200, 201: return
        case 403: throw SignedUploadError.expired
        case 400: throw SignedUploadError.incomplete
        case 413: throw SignedUploadError.tooLarge
        default: throw SignedUploadError.http(http.statusCode)
        }
    }
}

/// Upload progress shown in the app, from the real bytes URLSession reports as sent.
struct VideoProgress: Equatable {
    var message: String
    var fraction: Double
    var sentBytes: Int64
    var totalBytes: Int64
    var rate = TransferRate()
    var updatedAt: Date
    var bytesPerSecond: Double? { rate.bytesPerSecond }
    var secondsRemaining: Double? { rate.secondsRemaining(sent: sentBytes, total: totalBytes) }
}
