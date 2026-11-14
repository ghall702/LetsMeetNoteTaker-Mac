import Foundation

/// A Let's Meet room as returned by `GET /rooms`.
public struct Room: Codable, Hashable, Identifiable, Sendable {
    public var roomId: String
    public var name: String
    public var id: String { roomId }

    enum CodingKeys: String, CodingKey { case roomId = "room_id", name }
    public init(roomId: String, name: String) { self.roomId = roomId; self.name = name }

    public static func isValidRoomId(_ s: String) -> Bool {
        s.count == 32 && s.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

public struct CachedRooms: Codable, Sendable, Equatable {
    public var rooms: [Room]
    public var fetchedAt: Date?
    public init(rooms: [Room] = [], fetchedAt: Date? = nil) { self.rooms = rooms; self.fetchedAt = fetchedAt }

    public func name(for roomId: String) -> String? { rooms.first { $0.roomId == roomId }?.name }
    public func contains(_ roomId: String) -> Bool { rooms.contains { $0.roomId == roomId } }
}

public enum MatchRuleKind: String, Codable, CaseIterable, Sendable {
    case meetingNameContains
    case folderNameContains
    case folderPathPrefix
    case regex

    public var label: String {
        switch self {
        case .meetingNameContains: return "Meeting name contains"
        case .folderNameContains: return "Folder name contains"
        case .folderPathPrefix: return "Folder path starts with"
        case .regex: return "Regular expression"
        }
    }
}

public struct MatchRule: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var kind: MatchRuleKind
    public var value: String
    public init(id: UUID = UUID(), kind: MatchRuleKind, value: String) { self.id = id; self.kind = kind; self.value = value }

    public var isValid: Bool {
        let v = value.trimmingCharacters(in: .whitespaces)
        guard !v.isEmpty else { return false }
        if kind == .regex { return (try? NSRegularExpression(pattern: v, options: [.caseInsensitive])) != nil }
        return true
    }
}

public enum PromptMode: String, Codable, CaseIterable, Sendable {
    case global
    case custom

    public var label: String { self == .global ? "Use Global Default Prompt" : "Use Custom System Prompt" }
}

/// A local student ↔ room mapping (spec §4.2 plus per-student prompt settings).
public struct StudentMapping: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var roomId: String
    /// Last room name seen from the website (display only — matching uses `roomId`).
    public var roomName: String
    public var displayName: String
    /// Initials or student code used in Zoom meeting names, e.g. "DT".
    public var code: String
    /// Optional context passed to the AI, e.g. "Year 5" or "GCSE English Language".
    public var context: String
    public var rules: [MatchRule]
    public var enabled: Bool
    public var promptMode: PromptMode
    public var customPrompt: String
    public var createdAt: Date

    public init(id: UUID = UUID(), roomId: String, roomName: String = "", displayName: String, code: String = "",
                context: String = "", rules: [MatchRule] = [], enabled: Bool = true, promptMode: PromptMode = .global,
                customPrompt: String = "", createdAt: Date = Date()) {
        self.id = id
        self.roomId = roomId
        self.roomName = roomName
        self.displayName = displayName
        self.code = code
        self.context = context
        self.rules = rules
        self.enabled = enabled
        self.promptMode = promptMode
        self.customPrompt = customPrompt
        self.createdAt = createdAt
    }

    // Tolerate files written by older versions that lack newer keys.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        roomId = try c.decode(String.self, forKey: .roomId)
        roomName = try c.decodeIfPresent(String.self, forKey: .roomName) ?? ""
        displayName = try c.decode(String.self, forKey: .displayName)
        code = try c.decodeIfPresent(String.self, forKey: .code) ?? ""
        context = try c.decodeIfPresent(String.self, forKey: .context) ?? ""
        rules = try c.decodeIfPresent([MatchRule].self, forKey: .rules) ?? []
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        promptMode = try c.decodeIfPresent(PromptMode.self, forKey: .promptMode) ?? .global
        customPrompt = try c.decodeIfPresent(String.self, forKey: .customPrompt) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
    }

    /// Room name to display: the latest from the website if known.
    public func currentRoomName(in rooms: CachedRooms) -> String { rooms.name(for: roomId) ?? roomName }

    public func roomExists(in rooms: CachedRooms) -> Bool {
        // With no rooms cached yet we cannot tell, so don't block.
        rooms.rooms.isEmpty || rooms.contains(roomId)
    }
}

public struct MatchContext: Sendable, Equatable {
    public var topic: String
    public var folderName: String
    public var folderPath: String
    public init(topic: String, folderName: String, folderPath: String) {
        self.topic = topic
        self.folderName = folderName
        self.folderPath = folderPath
    }

    public init(session: ProposedSession) {
        self.init(topic: session.zoomInfo?.topic ?? session.topic, folderName: session.folderName, folderPath: session.folderPath)
    }
}

public struct StudentSuggestion: Equatable, Sendable, Identifiable {
    public var id: String { roomId }
    public var mappingId: UUID?
    public var roomId: String
    public var displayName: String
    public var score: Int
    public var reason: String
}

public enum MappingMatcher {
    static func normalise(_ s: String) -> String {
        s.lowercased().folding(options: [.diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func tokens(_ s: String) -> [String] { normalise(s).split(separator: " ").map(String.init) }

    static func containsPhrase(_ haystack: String, _ needle: String) -> Bool {
        let h = " " + normalise(haystack) + " "
        let n = normalise(needle)
        guard !n.isEmpty else { return false }
        return h.contains(" " + n + " ")
    }

    /// Ranked suggestions, best first. One entry per room.
    public static func rank(_ ctx: MatchContext, mappings: [StudentMapping], rooms: CachedRooms) -> [StudentSuggestion] {
        var best: [String: StudentSuggestion] = [:]
        func offer(_ s: StudentSuggestion) {
            if let cur = best[s.roomId], cur.score > s.score || (cur.score == s.score && cur.mappingId != nil) { return }
            best[s.roomId] = s
        }
        let topicNorm = normalise(ctx.topic)

        for m in mappings where m.enabled && m.roomExists(in: rooms) {
            let roomName = m.currentRoomName(in: rooms)
            var score = 0
            var reason = ""
            func consider(_ s: Int, _ r: String) { if s > score { score = s; reason = r } }

            if !roomName.isEmpty {
                let rn = normalise(roomName)
                if !rn.isEmpty && rn == topicNorm { consider(100, "Meeting name is the room name “\(roomName)”") }
                else if rn.count >= 4 && containsPhrase(ctx.topic, roomName) { consider(90, "Meeting name contains the room name “\(roomName)”") }
            }
            for rule in m.rules where rule.isValid {
                let v = rule.value.trimmingCharacters(in: .whitespaces)
                switch rule.kind {
                case .regex:
                    if let re = try? NSRegularExpression(pattern: v, options: [.caseInsensitive]) {
                        let target = ctx.topic + "\n" + ctx.folderName
                        if re.firstMatch(in: target, range: NSRange(location: 0, length: (target as NSString).length)) != nil {
                            consider(85, "Matches pattern \(v)")
                        }
                    }
                case .meetingNameContains:
                    if ctx.topic.range(of: v, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        consider(70 + min(v.count, 20), "Meeting name contains “\(v)”")
                    }
                case .folderNameContains:
                    if ctx.folderName.range(of: v, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                        consider(60 + min(v.count, 20), "Folder name contains “\(v)”")
                    }
                case .folderPathPrefix:
                    let p = (v as NSString).expandingTildeInPath
                    if ctx.folderPath.lowercased().hasPrefix(p.lowercased()) {
                        consider(50 + min(p.count / 4, 20), "Folder is inside \(v)")
                    }
                }
            }
            let code = m.code.trimmingCharacters(in: .whitespaces)
            if code.count >= 2 && tokens(ctx.topic).contains(normalise(code)) {
                consider(75, "Meeting name contains the code “\(code)”")
            }
            let name = m.displayName.trimmingCharacters(in: .whitespaces)
            if name.count >= 2 && containsPhrase(ctx.topic, name) {
                consider(65, "Meeting name contains “\(name)”")
            } else if name.count >= 2 && containsPhrase(ctx.folderName, name) {
                consider(55, "Folder name contains “\(name)”")
            }
            if score > 0 {
                offer(StudentSuggestion(mappingId: m.id, roomId: m.roomId, displayName: m.displayName, score: score, reason: reason))
            }
        }

        // Rooms without a mapping can still be suggested by exact name.
        for room in rooms.rooms where best[room.roomId] == nil {
            let rn = normalise(room.name)
            if !rn.isEmpty && rn == topicNorm {
                offer(StudentSuggestion(mappingId: nil, roomId: room.roomId, displayName: room.name, score: 95, reason: "Meeting name is the room name"))
            } else if rn.count >= 4 && containsPhrase(ctx.topic, room.name) {
                offer(StudentSuggestion(mappingId: nil, roomId: room.roomId, displayName: room.name, score: 85, reason: "Meeting name contains the room name"))
            }
        }
        return best.values.sorted { $0.score != $1.score ? $0.score > $1.score : $0.displayName < $1.displayName }
    }

    /// The rule added by “Remember this for next time”.
    public static func rememberRule(for ctx: MatchContext) -> MatchRule? {
        let topic = ctx.topic.trimmingCharacters(in: .whitespaces)
        if !topic.isEmpty { return MatchRule(kind: .meetingNameContains, value: topic) }
        let folder = ctx.folderName.trimmingCharacters(in: .whitespaces)
        if !folder.isEmpty { return MatchRule(kind: .folderNameContains, value: folder) }
        return nil
    }

    /// Adds the remember rule to a mapping unless an equivalent rule already exists.
    public static func applyRemember(_ ctx: MatchContext, to mapping: inout StudentMapping) -> Bool {
        guard let rule = rememberRule(for: ctx) else { return false }
        let exists = mapping.rules.contains { $0.kind == rule.kind && $0.value.caseInsensitiveCompare(rule.value) == .orderedSame }
        if exists { return false }
        mapping.rules.append(rule)
        return true
    }
}
