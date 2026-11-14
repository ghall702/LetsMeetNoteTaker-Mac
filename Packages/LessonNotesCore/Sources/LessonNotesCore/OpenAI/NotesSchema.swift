import Foundation

/// Structured output returned by the model (spec §9 schema, version 2 with
/// `learning_content`, `worked_examples` and `key_quotes`).
public struct GeneratedNotes: Codable, Equatable, Sendable {
    public var title: String
    public var overview: String
    public var keyPoints: [String]
    public var nextSteps: [String]
    public var homework: String
    public var vocabulary: [String]
    public var praise: String
    public var keyQuotes: [String]
    public var learningContent: String
    public var workedExamples: [String]
    public var privateNotes: String

    enum CodingKeys: String, CodingKey {
        case title, overview, keyPoints = "key_points", nextSteps = "next_steps", homework, vocabulary, praise,
             keyQuotes = "key_quotes", learningContent = "learning_content", workedExamples = "worked_examples",
             privateNotes = "private_notes"
    }

    public init(title: String, overview: String = "", keyPoints: [String] = [], nextSteps: [String] = [], homework: String = "",
                vocabulary: [String] = [], praise: String = "", keyQuotes: [String] = [], learningContent: String = "",
                workedExamples: [String] = [], privateNotes: String = "") {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.nextSteps = nextSteps
        self.homework = homework
        self.vocabulary = vocabulary
        self.praise = praise
        self.keyQuotes = keyQuotes
        self.learningContent = learningContent
        self.workedExamples = workedExamples
        self.privateNotes = privateNotes
    }

    /// Lenient decoding so notes saved by version 1 (without the new fields) still load.
    /// Model output is checked strictly by `NotesSchema.parse` before decoding.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        overview = try c.decodeIfPresent(String.self, forKey: .overview) ?? ""
        keyPoints = try c.decodeIfPresent([String].self, forKey: .keyPoints) ?? []
        nextSteps = try c.decodeIfPresent([String].self, forKey: .nextSteps) ?? []
        homework = try c.decodeIfPresent(String.self, forKey: .homework) ?? ""
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? []
        praise = try c.decodeIfPresent(String.self, forKey: .praise) ?? ""
        keyQuotes = try c.decodeIfPresent([String].self, forKey: .keyQuotes) ?? []
        learningContent = try c.decodeIfPresent(String.self, forKey: .learningContent) ?? ""
        workedExamples = try c.decodeIfPresent([String].self, forKey: .workedExamples) ?? []
        privateNotes = try c.decodeIfPresent(String.self, forKey: .privateNotes) ?? ""
    }

    /// Fields that differ from another version (for the comparison view).
    public func changedFields(comparedTo o: GeneratedNotes) -> [String] {
        var out: [String] = []
        if title != o.title { out.append("title") }
        if overview != o.overview { out.append("overview") }
        if learningContent != o.learningContent { out.append("learning_content") }
        if workedExamples != o.workedExamples { out.append("worked_examples") }
        if keyQuotes != o.keyQuotes { out.append("key_quotes") }
        if keyPoints != o.keyPoints { out.append("key_points") }
        if vocabulary != o.vocabulary { out.append("vocabulary") }
        if nextSteps != o.nextSteps { out.append("next_steps") }
        if homework != o.homework { out.append("homework") }
        if praise != o.praise { out.append("praise") }
        if privateNotes != o.privateNotes { out.append("private_notes") }
        return out
    }
}

/// Website field limits (§8.3), counted in UTF-16 code units like the server.
public enum NoteLimits {
    public static let title = 200
    public static let overview = 2000
    public static let homework = 2000
    public static let praise = 1000
    public static let learningContent = 20_000
    public static let privateNotes = 10_000
    public static let keyPoints = (items: 30, length: 500)
    public static let nextSteps = (items: 20, length: 500)
    public static let vocabulary = (items: 50, length: 200)
    public static let workedExamples = (items: 20, length: 5000)
    public static let keyQuotes = (items: 20, length: 500)
}

public enum NotesSchema {
    public static let name = "lesson_notes"
    public static let requiredFields = ["title", "overview", "key_points", "next_steps", "homework", "vocabulary", "praise",
                                        "key_quotes", "learning_content", "worked_examples", "private_notes"]
    static let arrayFields: Set<String> = ["key_points", "next_steps", "vocabulary", "key_quotes", "worked_examples"]

    /// Strict JSON schema enforced through the Responses API `text.format`.
    /// It is independent of any user-editable prompt.
    public static var jsonSchema: [String: Any] {
        var props: [String: Any] = [:]
        for f in requiredFields {
            props[f] = arrayFields.contains(f) ? ["type": "array", "items": ["type": "string"]] as [String: Any] : ["type": "string"]
        }
        return ["type": "object", "additionalProperties": false, "required": requiredFields, "properties": props]
    }

    public static var textFormat: [String: Any] {
        ["format": ["type": "json_schema", "name": name, "strict": true, "schema": jsonSchema]]
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notJSON(String)
        case emptyTitle

        public var errorDescription: String? {
            switch self {
            case .notJSON(let m): return "The AI response was not complete, valid lesson-notes JSON (\(m))."
            case .emptyTitle: return "The AI response had no title."
            }
        }
    }

    /// Decodes and validates the complete model output: every field present with the right type.
    /// Truncated JSON fails here, so partial output is never accepted.
    public static func parse(_ text: String) throws -> GeneratedNotes {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { throw ParseError.notJSON("empty output") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON("incomplete or not a JSON object") }
        for key in requiredFields {
            guard let v = obj[key] else { throw ParseError.notJSON("missing \(key)") }
            if arrayFields.contains(key) {
                guard let a = v as? [Any], a.allSatisfy({ $0 is String }) else { throw ParseError.notJSON("\(key) is not a list of text") }
            } else if !(v is String) { throw ParseError.notJSON("\(key) is not text") }
        }
        let extra = Set(obj.keys).subtracting(requiredFields)
        if !extra.isEmpty { throw ParseError.notJSON("unexpected keys \(extra.sorted().joined(separator: ", "))") }
        let notes = try JSONDecoder().decode(GeneratedNotes.self, from: data)
        if notes.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ParseError.emptyTitle }
        return notes
    }

    // MARK: Empty-field normalisation

    /// Whole-value filler that means "nothing to report". Such values become "" / are dropped.
    static let fillerPatterns: [String] = [
        #"^(none|n/?a|nil|null|nothing|not applicable|not available|tbc|tbd|-+|—|–|\.+)$"#,
        #"^none (given|set|assigned|noted|recorded|identified|provided|today|this lesson)$"#,
        #"^no (homework|home work)( was| has been)?( set| assigned| given)?( this lesson| today| for this lesson)?$"#,
        #"^there (was|is) no homework( set| assigned| given)?( this lesson| today)?$"#,
        #"^no (relevant |significant |key |specific |meaningful |notable |particular |additional |new |further )*(quotations?|quotes?|worked examples?|examples?|vocabulary|terms?|misconceptions?|observations?|notes?|praise|feedback|next steps|key points|content|issues|concerns)( were| was| have been| has been)?( (identified|discussed|introduced|studied|noted|recorded|provided|given|covered|used|available|to report|to note))?( (in|during) (this|the) lesson| today)?$"#,
        #"^there (were|was|are|is) no (relevant |significant |key |specific |meaningful |notable |particular |additional |new |further )*(quotations?|quotes?|worked examples?|examples?|vocabulary|misconceptions?|observations?|concerns|issues)( (identified|discussed|introduced|studied|noted|to report))?( (in|during) (this|the) lesson| today)?$"#,
        #"^(nothing|none) (further |else |additional )?to (report|note|add)$"#,
        #"^no (further|additional) (observations|notes|comments)$"#,
        #"^(the pupil|you) should continue (practising|practicing)$"#,
        #"^(keep|continue) (practising|practicing)$"#,
        #"^there (was|is) insufficient (information|evidence) to (provide|give) (feedback|praise)$"#,
        #"^insufficient (information|evidence)$"#,
    ]

    static let fillerRegexes: [NSRegularExpression] = fillerPatterns.compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// True when a value is only whitespace or a stock "nothing to report" phrase.
    public static func isEmptyOrFiller(_ s: String) -> Bool {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        // Ignore Markdown emphasis/list markers and a trailing full stop for the comparison.
        t = t.replacingOccurrences(of: #"^[\-\*\+•]\s+"#, with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: #"[\*_`]"#, with: "", options: .regularExpression)
        t = t.trimmingCharacters(in: CharacterSet(charactersIn: " .!").union(.whitespacesAndNewlines))
        t = t.replacingOccurrences(of: "’", with: "'")
        if t.isEmpty { return true }
        guard t.count <= 120 else { return false }
        let range = NSRange(location: 0, length: (t as NSString).length)
        return fillerRegexes.contains { $0.firstMatch(in: t, range: range) != nil }
    }

    /// Trims to fit `max` UTF-16 units at the best boundary (paragraph, line, sentence, word)
    /// so Markdown is not left broken mid-line. Returns nil if no trimming was needed.
    public static func trimToLimit(_ s: String, max: Int) -> String? {
        guard s.utf16.count > max else { return nil }
        var prefix = ""
        for ch in s {
            if prefix.utf16.count + String(ch).utf16.count > max { break }
            prefix.append(ch)
        }
        let ns = prefix as NSString
        let minKeep = Int(Double(max) * 0.5)
        var cut = ns.length
        for sep in ["\n\n", "\n", ". ", "! ", "? ", " "] {
            let r = ns.range(of: sep, options: .backwards)
            if r.location != NSNotFound, r.location + r.length >= minKeep || sep == " " {
                cut = sep.hasPrefix(".") || sep.hasPrefix("!") || sep.hasPrefix("?") ? r.location + 1 : r.location
                break
            }
        }
        var out = ns.substring(to: cut).trimmingCharacters(in: .whitespacesAndNewlines)
        // Close an unterminated code fence so the Markdown still renders.
        if out.components(separatedBy: "```").count % 2 == 0 {
            if out.utf16.count + 4 <= max { out += "\n```" } else if let r = out.range(of: "```", options: .backwards) { out = String(out[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return out
    }

    public struct Normalised: Equatable, Sendable {
        public var notes: GeneratedNotes
        /// Human-readable notes about anything changed to meet the website limits.
        public var adjustments: [String]
    }

    /// Normalises model output: whitespace and filler become ""/[], empty array items are removed,
    /// duplicates dropped, and anything over the website limits is trimmed at a clean boundary
    /// (reported in `adjustments`, never silently).
    public static func normalise(_ n: GeneratedNotes) -> Normalised {
        var adjustments: [String] = []
        func text(_ s: String, _ field: String, _ max: Int, allowFiller: Bool = false) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !allowFiller && isEmptyOrFiller(t) { return "" }
            if let trimmed = trimToLimit(t, max: max) {
                adjustments.append("\(field) was \(t.utf16.count) characters; trimmed at a section/sentence boundary to the website limit of \(max).")
                return trimmed
            }
            return t
        }
        func list(_ a: [String], _ field: String, _ limits: (items: Int, length: Int)) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            var dropped = 0
            for raw in a {
                let v = text(raw, "\(field) item", limits.length)
                guard !v.isEmpty else { continue }
                let key = v.lowercased()
                guard !seen.contains(key) else { continue }
                seen.insert(key)
                if out.count == limits.items { dropped += 1; continue }
                out.append(v)
            }
            if dropped > 0 { adjustments.append("\(field) had \(out.count + dropped) items; the website accepts \(limits.items), so the last \(dropped) were left out.") }
            return out
        }
        let title = text(n.title, "title", NoteLimits.title, allowFiller: true)
        let notes = GeneratedNotes(
            title: title,
            overview: text(n.overview, "overview", NoteLimits.overview),
            keyPoints: list(n.keyPoints, "key_points", NoteLimits.keyPoints),
            nextSteps: list(n.nextSteps, "next_steps", NoteLimits.nextSteps),
            homework: text(n.homework, "homework", NoteLimits.homework),
            vocabulary: list(n.vocabulary, "vocabulary", NoteLimits.vocabulary),
            praise: text(n.praise, "praise", NoteLimits.praise),
            keyQuotes: list(n.keyQuotes, "key_quotes", NoteLimits.keyQuotes),
            learningContent: text(n.learningContent, "learning_content", NoteLimits.learningContent),
            workedExamples: list(n.workedExamples, "worked_examples", NoteLimits.workedExamples),
            privateNotes: text(n.privateNotes, "private_notes", NoteLimits.privateNotes))
        return Normalised(notes: notes, adjustments: adjustments)
    }

    public static func sanitise(_ n: GeneratedNotes) -> GeneratedNotes { normalise(n).notes }

    /// The website `summary` object. Every section is sent explicitly; empty sections are
    /// `""` / `[]` (the website hides them) — never placeholder text.
    public static func summary(from n: GeneratedNotes) -> NoteSummary {
        NoteSummary(overview: n.overview, keyPoints: n.keyPoints, nextSteps: n.nextSteps, homework: n.homework,
                    vocabulary: n.vocabulary, praise: n.praise, learningContent: n.learningContent,
                    workedExamples: n.workedExamples, keyQuotes: n.keyQuotes)
    }
}
