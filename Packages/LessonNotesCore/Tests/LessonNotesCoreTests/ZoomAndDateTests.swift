import XCTest
@testable import LessonNotesCore

final class ZoomFolderParserTests: XCTestCase {
    func testParsesStandardFolder() throws {
        let i = try XCTUnwrap(ZoomFolderParser.parse("2026-11-14 16.00.12 LetsMeet - EE"))
        XCTAssertEqual(i.lessonDate, "2026-11-14")
        XCTAssertEqual([i.hour, i.minute, i.second], [16, 0, 12])
        XCTAssertEqual(i.topic, "LetsMeet - EE")
    }

    func testParsesFullNameAndInitials() {
        XCTAssertEqual(ZoomFolderParser.parse("2026-11-14 16.00.12 Daniel")?.topic, "Daniel")
        XCTAssertEqual(ZoomFolderParser.parse("2026-11-14 16.00.12 LetsMeet - DT")?.topic, "LetsMeet - DT")
    }

    func testStripsMeetingIdSuffix() throws {
        let i = try XCTUnwrap(ZoomFolderParser.parse("2021-03-02 09.30.00 Maths with Sam 98765432101"))
        XCTAssertEqual(i.topic, "Maths with Sam")
        XCTAssertEqual(i.meetingID, "98765432101")
    }

    func testRejectsInvalidDates() {
        XCTAssertNil(ZoomFolderParser.parse("2026-02-30 16.00.12 X"))
        XCTAssertNil(ZoomFolderParser.parse("2026-13-01 16.00.12 X"))
        XCTAssertNil(ZoomFolderParser.parse("2026-11-14 25.00.12 X"))
        XCTAssertNil(ZoomFolderParser.parse("Lesson recordings"))
        XCTAssertNil(ZoomFolderParser.parse("14-11-2026 16.00.12 X"))
    }

    func testFolderTimeIsLocalNotUTC() throws {
        let i = try XCTUnwrap(ZoomFolderParser.parse("2026-07-14 16.00.12 X"))
        let londonStart = try XCTUnwrap(i.startDate(in: london))
        // British Summer Time: 16:00 local == 15:00 UTC.
        XCTAssertEqual(CoreFormat.iso8601(londonStart), "2026-07-14T15:00:12Z")
        let utcStart = try XCTUnwrap(i.startDate(in: utc))
        XCTAssertEqual(utcStart.timeIntervalSince(londonStart), 3600)
    }

    func testNonexistentDSTTimeIsRejected() throws {
        // Clocks go forward at 01:00 on 29 March 2026 in London.
        let i = try XCTUnwrap(ZoomFolderParser.parse("2026-03-29 01.30.00 X"))
        XCTAssertNil(i.startDate(in: london))
        let inferred = LessonDateInference.infer(DateEvidence(folderInfo: i), timeZone: london, now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertTrue(inferred.needsReview)
        XCTAssertEqual(inferred.lessonDate, "2026-03-29")
    }

    func testCloudFilenameTimestampIsUTC() throws {
        let d = try XCTUnwrap(ZoomFolderParser.parseCloudFileTimestamp("GMT20261114-160012_Recording_1920x1080.mp4"))
        XCTAssertEqual(CoreFormat.iso8601(d), "2026-11-14T16:00:12Z")
    }

    func testFileClassification() {
        XCTAssertEqual(RecordingFileKind.classify("video1234567890.mp4"), .video)
        XCTAssertEqual(RecordingFileKind.classify("audio_only.m4a"), .audioOnly)
        XCTAssertEqual(RecordingFileKind.classify("double_click_to_convert_01.zoom"), .conversionPlaceholder)
        XCTAssertEqual(RecordingFileKind.classify("recording.conf"), .other)
    }
}

final class ReadinessTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_000)
    func obs(_ sizes: [Int64], gap: TimeInterval = 20) -> [RecordingReadiness.SizeObservation] {
        sizes.enumerated().map { .init(size: $0.element, at: t0.addingTimeInterval(Double($0.offset) * gap)) }
    }

    func testReadyWhenStableAndPlayable() {
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "zoom_0.mp4", siblings: ["zoom_0.mp4"], observations: obs([5, 5, 5]),
                                                   playable: true, durationSeconds: 3500), .ready)
    }

    func testNotReadyWhileConverting() {
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "zoom_0.mp4", siblings: ["zoom_0.mp4", "double_click_to_convert_01.zoom"],
                                                   observations: obs([5, 5, 5]), playable: true, durationSeconds: 3500), .conversionInProgress)
    }

    func testNotReadyWhileGrowing() {
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "zoom_0.mp4", siblings: [], observations: obs([5, 6]),
                                                   playable: nil, durationSeconds: nil), .stillWriting)
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "zoom_0.mp4", siblings: [], observations: obs([5, 5]),
                                                   playable: nil, durationSeconds: nil), .needsMoreObservations)
    }

    func testStabilityRequires20SecondGaps() {
        XCTAssertFalse(RecordingReadiness.isSizeStable(obs([5, 5, 5], gap: 5)))
        XCTAssertTrue(RecordingReadiness.isSizeStable(obs([5, 5, 5], gap: 20)))
    }

    func testShortOrUnplayableRejected() {
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "a.mp4", siblings: [], observations: obs([5, 5, 5]), playable: true, durationSeconds: 12), .tooShort)
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "a.mp4", siblings: [], observations: obs([5, 5, 5]), playable: false, durationSeconds: 100), .notPlayable)
        XCTAssertEqual(RecordingReadiness.evaluate(filename: "a.txt", siblings: [], observations: obs([5, 5, 5]), playable: true, durationSeconds: 100), .notMedia)
    }
}

final class DateInferenceTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_900_000_000) // 2030

    func testFolderDateBeatsModifiedFilesystemTimestamps() throws {
        // A historical recording copied in 2029: file dates are the copy time, folder is the truth.
        let folder = try XCTUnwrap(ZoomFolderParser.parse("2026-11-14 16.00.12 Daniel"))
        let copied = Date(timeIntervalSince1970: 1_870_000_000)
        let r = LessonDateInference.infer(DateEvidence(folderInfo: folder, fileCreationDate: copied, fileModificationDate: copied),
                                          timeZone: london, now: now)
        XCTAssertEqual(r.lessonDate, "2026-11-14")
        XCTAssertEqual(r.source, .zoomFolder)
        XCTAssertEqual(r.confidence, .high)
        XCTAssertFalse(r.needsReview)
        XCTAssertEqual(CoreFormat.iso8601(r.startedAt!), "2026-11-14T16:00:12Z") // GMT in November
    }

    func testMetadataUsedWhenNoFolder() {
        let meta = CoreFormat.parseISO8601("2026-10-01T15:30:00Z")!
        let r = LessonDateInference.infer(DateEvidence(embeddedCreationDate: meta, fileCreationDate: now), timeZone: london, now: now)
        XCTAssertEqual(r.source, .embeddedMetadata)
        XCTAssertEqual(r.lessonDate, "2026-10-01")
        XCTAssertEqual(r.startedAt, meta)
    }

    func testPlaceholderMetadataIgnored() {
        let bogus = Date(timeIntervalSince1970: -2_082_844_800) // 1904 epoch
        let created = CoreFormat.parseISO8601("2026-05-05T10:00:00Z")!
        let r = LessonDateInference.infer(DateEvidence(embeddedCreationDate: bogus, fileCreationDate: created), timeZone: london, now: now)
        XCTAssertEqual(r.source, .fileCreation)
        XCTAssertTrue(r.needsReview)
        XCTAssertNil(r.startedAt, "creation date must not be presented as an exact start time")
    }

    func testModificationDateIsLastResort() {
        let mod = CoreFormat.parseISO8601("2026-05-06T23:30:00Z")!
        let r = LessonDateInference.infer(DateEvidence(fileModificationDate: mod), timeZone: london, now: now)
        XCTAssertEqual(r.source, .fileModification)
        XCTAssertEqual(r.lessonDate, "2026-05-07", "local (BST) date, not UTC")
        XCTAssertTrue(r.needsReview)
    }

    func testDisagreeingMetadataFlagsReview() throws {
        let folder = try XCTUnwrap(ZoomFolderParser.parse("2026-11-14 16.00.12 X"))
        let meta = CoreFormat.parseISO8601("2026-11-20T10:00:00Z")!
        let r = LessonDateInference.infer(DateEvidence(folderInfo: folder, embeddedCreationDate: meta), timeZone: london, now: now)
        XCTAssertEqual(r.lessonDate, "2026-11-14")
        XCTAssertTrue(r.needsReview)
    }

    func testNoEvidence() {
        let r = LessonDateInference.infer(DateEvidence(), timeZone: london, now: now)
        XCTAssertEqual(r.source, .unknown)
        XCTAssertEqual(r.lessonDate, "")
        XCTAssertTrue(r.needsReview)
    }

    func testConfigurableTimeZone() throws {
        let folder = try XCTUnwrap(ZoomFolderParser.parse("2026-11-14 16.00.12 X"))
        let ny = TimeZone(identifier: "America/New_York")!
        let r = LessonDateInference.infer(DateEvidence(folderInfo: folder), timeZone: ny, now: now)
        XCTAssertEqual(CoreFormat.iso8601(r.startedAt!), "2026-11-14T21:00:12Z")
        XCTAssertEqual(r.lessonDate, "2026-11-14")
    }
}
