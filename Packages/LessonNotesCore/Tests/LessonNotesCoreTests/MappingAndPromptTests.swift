import XCTest
@testable import LessonNotesCore

final class MappingTests: XCTestCase {
    let rooms = CachedRooms(rooms: [Room(roomId: roomEE, name: "LetsMeet - EE"), Room(roomId: roomDT, name: "LetsMeet SD")], fetchedAt: Date())

    func ctx(_ topic: String, folder: String? = nil, path: String = "/z") -> MatchContext {
        MatchContext(topic: topic, folderName: folder ?? "2026-11-14 16.00.12 \(topic)", folderPath: path)
    }

    func testRoomNameInTopicIsStrongest() {
        let m = [StudentMapping(roomId: roomEE, displayName: "Ellie")]
        let s = MappingMatcher.rank(ctx("LetsMeet - EE"), mappings: m, rooms: rooms)
        XCTAssertEqual(s.first?.displayName, "Ellie")
        XCTAssertEqual(s.first?.score, 100)
    }

    func testInitialsCodeSuggestsDaniel() {
        let m = [StudentMapping(roomId: roomDT, displayName: "Daniel", code: "DT"), StudentMapping(roomId: roomEE, displayName: "Ellie", code: "EE")]
        XCTAssertEqual(MappingMatcher.rank(ctx("LetsMeet - DT"), mappings: m, rooms: rooms).first?.displayName, "Daniel")
        XCTAssertEqual(MappingMatcher.rank(ctx("Daniel"), mappings: m, rooms: rooms).first?.displayName, "Daniel")
    }

    func testRulesAndRegex() {
        let m = [StudentMapping(roomId: roomDT, displayName: "Daniel", rules: [MatchRule(kind: .regex, value: #"^gcse\s+eng"#)]),
                 StudentMapping(roomId: roomEE, displayName: "Ellie", rules: [MatchRule(kind: .folderPathPrefix, value: "/Volumes/Archive/Ellie")])]
        XCTAssertEqual(MappingMatcher.rank(ctx("GCSE English prep"), mappings: m, rooms: rooms).first?.displayName, "Daniel")
        XCTAssertEqual(MappingMatcher.rank(ctx("Lesson", path: "/Volumes/Archive/Ellie/2025"), mappings: m, rooms: rooms).first?.displayName, "Ellie")
        XCTAssertTrue(MappingMatcher.rank(ctx("Unrelated"), mappings: m, rooms: rooms).isEmpty)
    }

    func testDisabledAndMissingRoomsExcluded() {
        let gone = "c9dfb0a8d59e2f7812880c6f9564009c"
        let m = [StudentMapping(roomId: roomEE, displayName: "Ellie", code: "EE", enabled: false),
                 StudentMapping(roomId: gone, displayName: "Old", code: "EE")]
        let s = MappingMatcher.rank(ctx("EE"), mappings: m, rooms: rooms)
        XCTAssertFalse(s.contains { $0.displayName == "Ellie" || $0.displayName == "Old" })
        XCTAssertFalse(m[1].roomExists(in: rooms))
    }

    func testRenamedRoomStillMatchesById() {
        let m = StudentMapping(roomId: roomEE, roomName: "Old Name", displayName: "Ellie")
        let renamed = CachedRooms(rooms: [Room(roomId: roomEE, name: "LetsMeet - Ellie E")], fetchedAt: Date())
        XCTAssertEqual(m.currentRoomName(in: renamed), "LetsMeet - Ellie E")
        XCTAssertEqual(MappingMatcher.rank(ctx("LetsMeet - Ellie E"), mappings: [m], rooms: renamed).first?.mappingId, m.id)
    }

    func testUnmappedRoomSuggestedByName() {
        let s = MappingMatcher.rank(ctx("LetsMeet SD"), mappings: [], rooms: rooms)
        XCTAssertEqual(s.first?.roomId, roomDT)
        XCTAssertNil(s.first?.mappingId)
    }

    func testRememberRuleAddedOnce() {
        var m = StudentMapping(roomId: roomEE, displayName: "Ellie")
        XCTAssertTrue(MappingMatcher.applyRemember(ctx("Maths with E"), to: &m))
        XCTAssertFalse(MappingMatcher.applyRemember(ctx("maths with e"), to: &m))
        XCTAssertEqual(m.rules.count, 1)
        XCTAssertEqual(m.rules[0].kind, .meetingNameContains)
        XCTAssertEqual(MappingMatcher.rank(ctx("Maths with E"), mappings: [m], rooms: rooms).first?.mappingId, m.id)
    }

    func testMappingsPersistAndDecodeOldFormat() throws {
        let h = try Harness()
        var m = StudentMapping(roomId: roomEE, displayName: "Ellie", code: "EE", promptMode: .custom, customPrompt: "Custom!")
        m.rules = [MatchRule(kind: .meetingNameContains, value: "EE")]
        h.store.upsertMapping(m)
        let reopened = try LibraryStore(directory: h.store.directory)
        var r = try XCTUnwrap(reopened.mappings.first)
        XCTAssertEqual(r.createdAt.timeIntervalSince1970, m.createdAt.timeIntervalSince1970, accuracy: 0.01)
        r.createdAt = m.createdAt
        XCTAssertEqual(r, m)
        let old = #"{"id":"\#(UUID().uuidString)","roomId":"\#(roomEE)","displayName":"X"}"#
        let decoded = try JSONCoding.decoder().decode(StudentMapping.self, from: Data(old.utf8))
        XCTAssertEqual(decoded.promptMode, .global)
        XCTAssertTrue(decoded.enabled)
    }
}

final class PromptTests: XCTestCase {
    func testGlobalInheritanceIncludingFutureChanges() {
        let m = StudentMapping(roomId: roomEE, displayName: "Ellie")
        XCTAssertEqual(PromptResolver.resolve(globalPrompt: "Global v1", mapping: m).basePrompt, "Global v1")
        XCTAssertEqual(PromptResolver.resolve(globalPrompt: "Global v2", mapping: m).basePrompt, "Global v2")
        XCTAssertEqual(PromptResolver.resolve(globalPrompt: "Global v2", mapping: m).source, .global)
    }

    func testCustomPromptReplacesGlobal() {
        let m = StudentMapping(roomId: roomDT, displayName: "Daniel", promptMode: .custom, customPrompt: "GCSE English Language: AO1–AO6")
        let r = PromptResolver.resolve(globalPrompt: "Global", mapping: m)
        XCTAssertEqual(r.source, .custom)
        XCTAssertTrue(r.effectiveInstructions.hasPrefix("GCSE English Language"))
        XCTAssertFalse(r.effectiveInstructions.contains("Global"))
    }

    func testEmptyCustomFallsBackToGlobal() {
        let m = StudentMapping(roomId: roomDT, displayName: "Daniel", promptMode: .custom, customPrompt: "   ")
        XCTAssertEqual(PromptResolver.resolve(globalPrompt: "Global", mapping: m).source, .global)
    }

    func testRequiredRulesAlwaysAppended() {
        for m in [nil, StudentMapping(roomId: roomDT, displayName: "D", promptMode: .custom, customPrompt: "Only this")] {
            let r = PromptResolver.resolve(globalPrompt: "Anything", mapping: m)
            XCTAssertTrue(r.effectiveInstructions.contains("Never include profanity"))
            XCTAssertTrue(r.effectiveInstructions.contains("British English"))
            XCTAssertTrue(r.effectiveInstructions.contains("explicitly assigned"))
            XCTAssertTrue(r.effectiveInstructions.contains("Never write filler"))
        }
    }

    func testGlobalPromptPersistsInSettings() throws {
        let h = try Harness()
        h.store.updateSettings { $0.globalPrompt = "My edited prompt" }
        XCTAssertEqual(try LibraryStore(directory: h.store.directory).settings.globalPrompt, "My edited prompt")
        h.store.updateSettings { $0.globalPrompt = PromptLibrary.starterGlobalPrompt }
        XCTAssertEqual(try LibraryStore(directory: h.store.directory).settings.globalPrompt, PromptLibrary.starterGlobalPrompt)
    }

    func testPromptSnapshotIsTakenAtSummarisationAndKeptForRetries() async throws {
        let h = try Harness()
        var m = StudentMapping(roomId: roomEE, displayName: "Ellie", promptMode: .custom, customPrompt: "Snapshot prompt A")
        h.store.upsertMapping(m)
        var l = try h.addLesson(mode: .single, recordings: 1)
        h.store.updateLesson(id: l.id) { $0.studentId = m.id }
        h.submitter.results = [.failure(TransportError.network("down")), .success(NoteStatusResponse(noteId: "n", submissionId: "", status: .pending))]
        let engine = h.engine()
        await engine.runUntilIdle()
        l = h.store.lesson(id: l.id)!
        XCTAssertEqual(l.jobs[0].promptSnapshot?.basePrompt, "Snapshot prompt A")
        XCTAssertTrue(h.notes.lastInstructions.value.hasPrefix("Snapshot prompt A"))
        // Prompt edited after summarisation: the retry keeps the snapshot and does not re-summarise.
        m.customPrompt = "Changed prompt B"
        h.store.upsertMapping(m)
        h.clock.value = h.clock.value.addingTimeInterval(10)
        await engine.runUntilIdle()
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].stage, .submitted)
        XCTAssertEqual(h.notes.calls.value, 1)
        XCTAssertEqual(h.store.lesson(id: l.id)!.jobs[0].promptSnapshot?.basePrompt, "Snapshot prompt A")
    }
}
