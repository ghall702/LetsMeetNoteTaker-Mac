import Foundation
import AVFoundation
import AppKit
import LessonNotesCore

struct MediaInfo: Sendable {
    var playable: Bool
    var durationSeconds: Double?
    var creationDate: Date?
}

enum MediaInspector {
    static func inspect(_ url: URL) async -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        var duration: Double?
        if let d = try? await asset.load(.duration), d.isNumeric { duration = d.seconds }
        var created: Date?
        if let item = try? await asset.load(.creationDate) {
            created = try? await item.load(.dateValue)
        }
        return MediaInfo(playable: playable, durationSeconds: duration, creationDate: created)
    }

    static func thumbnail(_ url: URL, maxSize: CGSize = CGSize(width: 320, height: 180)) async -> NSImage? {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .video), !tracks.isEmpty else { return nil }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = maxSize
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let t = CMTime(seconds: min(10, max(0, duration / 3)), preferredTimescale: 600)
        guard let result = try? await gen.image(at: t) else { return nil }
        let cg = result.image
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    /// Adds AVFoundation metadata to scanned recordings with bounded concurrency.
    static func enrich(_ recs: [ScannedRecording], progress: @escaping @Sendable (Int, Int) -> Void) async -> [ScannedRecording] {
        var out = recs
        let total = recs.count
        var done = 0
        let width = 4
        var index = 0
        let paths = recs.map(\.path)
        await withTaskGroup(of: (Int, MediaInfo).self) { group in
            while index < min(width, total) {
                let i = index
                let url = URL(fileURLWithPath: paths[i])
                group.addTask { (i, await MediaInspector.inspect(url)) }
                index += 1
            }
            while let next = await group.next() {
                out[next.0].durationSeconds = next.1.durationSeconds
                out[next.0].embeddedCreationDate = next.1.creationDate
                done += 1
                progress(done, total)
                if index < total {
                    let i = index
                    let url = URL(fileURLWithPath: paths[i])
                    group.addTask { (i, await MediaInspector.inspect(url)) }
                    index += 1
                }
            }
        }
        return out
    }
}

enum AudioExtractionError: LocalizedError {
    case noAudioTrack(String)
    case readerFailed(String)
    var errorDescription: String? {
        switch self {
        case .noAudioTrack(let f): return "“\(f)” has no audio track."
        case .readerFailed(let m): return "Could not read the recording's audio: \(m)"
        }
    }
}

/// Extracts 16 kHz mono 16-bit PCM WAV into the app's temporary folder.
/// Audio never leaves the Mac; the file is deleted by the engine as soon as transcription ends.
struct AVAudioExtractor: AudioExtracting {
    func extractAudio(for recording: RecordingRef, into directory: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let out = directory.appendingPathComponent(recording.id.uuidString + ".wav")
        try await FolderAccess.withAccess(bookmark: recording.bookmark, path: recording.path) { url in
            guard FileManager.default.isReadableFile(atPath: url.path) else {
                throw PipelineError.recordingMissing(recording.filename)
            }
            try await Self.extract(from: url, to: out, filename: recording.filename, progress: progress)
        }
        return out
    }

    static func extract(from url: URL, to out: URL, filename: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw AudioExtractionError.noAudioTrack(filename) }
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw AudioExtractionError.readerFailed("unsupported audio format") }
        reader.add(output)

        try await Task.detached(priority: .userInitiated) {
            FileManager.default.createFile(atPath: out.path, contents: nil)
            let handle = try FileHandle(forWritingTo: out)
            defer { try? handle.close() }
            try handle.write(contentsOf: wavHeader(dataBytes: 0))
            guard reader.startReading() else { throw AudioExtractionError.readerFailed(reader.error?.localizedDescription ?? "start failed") }
            var bytes: UInt32 = 0
            var lastReport = Date.distantPast
            while let buffer = output.copyNextSampleBuffer() {
                if Task.isCancelled { reader.cancelReading(); throw CancellationError() }
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let length = CMBlockBufferGetDataLength(block)
                var data = Data(count: length)
                let status = data.withUnsafeMutableBytes { raw in
                    CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
                }
                guard status == kCMBlockBufferNoErr else { continue }
                try handle.write(contentsOf: data)
                bytes &+= UInt32(truncatingIfNeeded: length)
                if duration > 0, Date().timeIntervalSince(lastReport) > 0.5 {
                    lastReport = Date()
                    let t = CMSampleBufferGetPresentationTimeStamp(buffer).seconds
                    progress(min(1, max(0, t / duration)))
                }
            }
            if reader.status == .failed { throw AudioExtractionError.readerFailed(reader.error?.localizedDescription ?? "read failed") }
            try handle.seek(toOffset: 0)
            try handle.write(contentsOf: wavHeader(dataBytes: bytes))
            progress(1)
        }.value
    }

    static func wavHeader(dataBytes: UInt32) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        let sampleRate: UInt32 = 16_000, channels: UInt16 = 1, bits: UInt16 = 16
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 &+ dataBytes)
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(channels); u32(sampleRate)
        u32(sampleRate * UInt32(channels) * UInt32(bits / 8)); u16(channels * bits / 8); u16(bits)
        d.append(contentsOf: Array("data".utf8)); u32(dataBytes)
        return d
    }
}
