import Foundation
import AVFoundation
import LessonNotesCore

/// CI-only check of the real AVFoundation merge (LESSONNOTES_SELFTEST=merge). Uses synthetic clips
/// copied into the app's temporary folder; never touches lessons, recordings or the network.
enum SelfTest {
    static func runIfRequested() -> Bool {
        guard ProcessInfo.processInfo.environment["LESSONNOTES_SELFTEST"] == "merge" else { return false }
        Task.detached {
            let ok = await merge()
            exit(ok ? 0 : 1)
        }
        return true
    }

    static func merge() async -> Bool {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("selftest", isDirectory: true)
        func ref(_ name: String, _ seconds: Int, _ order: Int) -> RecordingRef {
            RecordingRef(filename: name, path: dir.appendingPathComponent(name).path, durationSec: seconds, recordedAt: nil, sha256: nil, fileSize: 0, order: order)
        }
        let cases: [(String, [RecordingRef], Int, String)] = [
            ("same-format", [ref("synthetic-a.mp4", 6, 0), ref("synthetic-b.mp4", 4, 1)], 10, AVAssetExportPresetPassthrough),
            ("mixed-format", [ref("synthetic-a.mp4", 6, 0), ref("synthetic-c.mp4", 5, 1)], 11, AVAssetExportPresetHighestQuality),
            ("three-parts", [ref("synthetic-b.mp4", 4, 0), ref("synthetic-a.mp4", 6, 1), ref("synthetic-b.mp4", 4, 2)], 14, AVAssetExportPresetPassthrough),
        ]
        var ok = true
        for (name, refs, expected, preset) in cases {
            let out = dir.appendingPathComponent("merged-\(name).mp4")
            do {
                let m = try await AVVideoMedia().merge(refs, to: out) { _ in }
                let asset = AVURLAsset(url: out)
                let v = try await asset.loadTracks(withMediaType: .video).count
                let a = try await asset.loadTracks(withMediaType: .audio).count
                let valid = await AVVideoMedia().validateMerged(out)
                let partials = (try? FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".partial") }) ?? []
                let used = AVVideoMedia.lastPreset ?? "?"
                let pass = abs(m.durationSec - expected) <= 1 && v == 1 && a == 1 && valid != nil && m.size > 0 && used == preset && partials.isEmpty
                print("SELFTEST \(name): \(pass ? "ok" : "FAILED") — one file, \(m.durationSec) s (expected \(expected)), \(m.size) bytes, video tracks \(v), audio tracks \(a), method \(used == AVAssetExportPresetPassthrough ? "stream copy" : "re-encode")")
                ok = ok && pass
            } catch {
                print("SELFTEST \(name): FAILED — \(error.localizedDescription)")
                ok = false
            }
        }
        print(ok ? "SELFTEST PASS" : "SELFTEST FAIL")
        return ok
    }
}
