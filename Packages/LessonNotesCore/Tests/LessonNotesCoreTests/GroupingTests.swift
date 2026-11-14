import XCTest
@testable import LessonNotesCore

final class GroupingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000)

    func testZoomFolderRecordingsGroupedAndOrdered() {
        let f = "/Users/g/Documents/Zoom/2026-11-14 16.00.12 LetsMeet - EE"
        let recs = [ScannedRecording(path: f + "/zoom_10.mp4"), ScannedRecording(path: f + "/zoom_2.mp4"),
                    ScannedRecording(path: f + "/audio_only.m4a"), ScannedRecording(path: f + "/zoom_1.mp4")]
        let s = SessionGrouper.group(recs, timeZone: london, now: now)
        XCTAssertEqual(s.count, 1)
        XCTAssertEqual(s[0].recordings.map(\.filename), ["zoom_1.mp4", "zoom_2.mp4", "zoom_10.mp4"])
        XCTAssertEqual(s[0].excludedAudioOnly.map(\.filename), ["audio_only.m4a"])
        XCTAssertEqual(s[0].topic, "LetsMeet - EE")
        XCTAssertEqual(s[0].inferredDate.lessonDate, "2026-11-14")
    }

    func testRecordingTimestampsOrderBeforeFilenames() {
        let f = "/z/2026-11-14 16.00.12 Daniel"
        var a = ScannedRecording(path: f + "/a.mp4"); a.embeddedCreationDate = CoreFormat.parseISO8601("2026-11-14T16:40:00Z")
        var b = ScannedRecording(path: f + "/b.mp4"); b.embeddedCreationDate = CoreFormat.parseISO8601("2026-11-14T16:00:00Z")
        XCTAssertEqual(SessionGrouper.group([a, b], timeZone: london, now: now)[0].recordings.map(\.filename), ["b.mp4", "a.mp4"])
    }

    func testAudioOnlyKeptWhenNoVideo() {
        let f = "/z/2026-11-14 16.00.12 Daniel"
        let s = SessionGrouper.group([ScannedRecording(path: f + "/audio_only.m4a")], timeZone: london, now: now)
        XCTAssertEqual(s[0].recordings.count, 1)
    }

    func testSeparateSessionsAndHistoricalOrder() {
        let recs = [ScannedRecording(path: "/z/2026-11-14 16.00.12 Daniel/zoom_0.mp4"),
                    ScannedRecording(path: "/z/2026-11-07 16.00.00 Daniel/zoom_0.mp4"),
                    ScannedRecording(path: "/z/2026-11-14 17.00.00 LetsMeet - EE/zoom_0.mp4")]
        let s = SessionGrouper.group(recs, timeZone: london, now: now)
        XCTAssertEqual(s.map(\.folderName), ["2026-11-07 16.00.00 Daniel", "2026-11-14 16.00.12 Daniel", "2026-11-14 17.00.00 LetsMeet - EE"])
    }

    func testLooseFilesClusteredByTime() {
        func r(_ name: String, _ iso: String) -> ScannedRecording {
            ScannedRecording(path: "/Users/g/Downloads/" + name, embeddedCreationDate: CoreFormat.parseISO8601(iso), durationSeconds: 1200)
        }
        let recs = [r("a.mp4", "2026-11-14T16:00:00Z"), r("b.mp4", "2026-11-14T16:25:00Z"), r("c.mp4", "2026-11-15T10:00:00Z"),
                    ScannedRecording(path: "/Users/g/Downloads/nodate.mp4")]
        let s = SessionGrouper.group(recs, timeZone: london, now: now)
        let groups = s.map { $0.recordings.map(\.filename) }
        XCTAssertTrue(groups.contains(["a.mp4", "b.mp4"]))
        XCTAssertTrue(groups.contains(["c.mp4"]))
        XCTAssertTrue(groups.contains(["nodate.mp4"]))
        XCTAssertTrue(s.first { $0.recordings.map(\.filename) == ["nodate.mp4"] }!.inferredDate.needsReview)
    }

    func testLargeFolderScanGroupsHistoricalRecordings() throws {
        let root = tempDir()
        defer { try? FileManager.default.removeItem(at: root) }
        let fm = FileManager.default
        // 200 lessons, some with two parts, plus noise and one still converting.
        var expectedMedia = 0
        for i in 0..<200 {
            let day = 1 + (i % 28), month = 1 + (i / 28) % 12
            let folder = root.appendingPathComponent(String(format: "2025-%02d-%02d 16.%02d.00 LetsMeet - S%d", month, day, i % 60, i % 7))
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data([1]).write(to: folder.appendingPathComponent("zoom_0.mp4")); expectedMedia += 1
            if i % 5 == 0 { try Data([1]).write(to: folder.appendingPathComponent("zoom_1.mp4")); expectedMedia += 1 }
            try Data([1]).write(to: folder.appendingPathComponent("recording.conf"))
        }
        let converting = root.appendingPathComponent("2026-01-01 10.00.00 Converting")
        try fm.createDirectory(at: converting, withIntermediateDirectories: true)
        try Data([1]).write(to: converting.appendingPathComponent("zoom_0.mp4"))
        try Data([1]).write(to: converting.appendingPathComponent("double_click_to_convert_01.zoom"))

        let progressCount = Box<Int>(0)
        let result = try FolderScanner.scan(roots: [root]) { _ in progressCount.mutate { $0 += 1 } }
        XCTAssertEqual(result.recordings.count, expectedMedia)
        XCTAssertEqual(result.foldersStillConverting.count, 1)
        XCTAssertGreaterThan(progressCount.value, 1)
        let sessions = SessionGrouper.group(result.recordings, timeZone: london, now: now)
        XCTAssertEqual(sessions.count, 200)
        XCTAssertEqual(sessions.filter { $0.recordings.count == 2 }.count, 40)
        XCTAssertTrue(sessions.allSatisfy { $0.inferredDate.source == .zoomFolder && !$0.inferredDate.needsReview })
        XCTAssertEqual(sessions.map(\.inferredDate.lessonDate), sessions.map(\.inferredDate.lessonDate).sorted())
    }
}
