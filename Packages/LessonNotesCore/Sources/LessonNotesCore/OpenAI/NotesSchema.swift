import Foundation

/// Structured output returned by the model (spec §9 schema).
public struct GeneratedNotes: Codable, Equatable, Sendable {
    public var title: String
    public var overview: String
    public var keyPoints: [String]
    public var nextSteps: [String]
    public var homework: String
    public var vocabulary: [String]
    public var praise: String
    public var privateNotes: String

    enum CodingKeys: String, CodingKey {
        case title, overview, keyPoints = "key_points", nextSteps = "next_steps", homework, vocabulary, praise, privateNotes = "private_notes"
    }

    public init(title: String, overview: String = "", keyPoints: [String] = [], nextSteps: [String] = [], homework: String = "",
                vocabulary: [String] = [], praise: String = "", privateNotes: String = "") {
        self.title = title
        self.overview = overview
        self.keyPoints = keyPoints
        self.nextSteps = nextSteps
        self.homework = homework
        self.vocabulary = vocabulary
        self.praise = praise
        self.privateNotes = privateNotes
    }
}

public enum NotesSchema {
    public static let name = "lesson_notes"

    /// Strict JSON schema enforced through the Responses API `text.format`.
    /// It is independent of any user-editable prompt.
    public static var jsonSchema: [String: Any] {
        let str: [String: Any] = ["type": "string"]
        let arr: [String: Any] = ["type": "array", "items": ["type": "string"]]
        return [
            "type": "object",
            "additionalProperties": false,
            "required": ["title", "overview", "key_points", "next_steps", "homework", "vocabulary", "praise", "private_notes"],
            "properties": [
                "title": str, "overview": str, "key_points": arr, "next_steps": arr,
                "homework": str, "vocabulary": arr, "praise": str, "private_notes": str,
            ],
        ]
    }

    public static var textFormat: [String: Any] {
        ["format": ["type": "json_schema", "name": name, "strict": true, "schema": jsonSchema]]
    }

    public enum ParseError: Error, LocalizedError, Equatable {
        case notJSON(String)
        case emptyTitle

        public var errorDescription: String? {
            switch self {
            case .notJSON(let m): return "The AI response was not valid lesson-notes JSON (\(m))."
            case .emptyTitle: return "The AI response had no title."
            }
        }
    }

    /// Decodes and validates the model output (all keys required, correct types).
    public static func parse(_ text: String) throws -> GeneratedNotes {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8), !trimmed.isEmpty else { throw ParseError.notJSON("empty output") }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ParseError.notJSON("not a JSON object") }
        let required = ["title", "overview", "key_points", "next_steps", "homework", "vocabulary", "praise", "private_notes"]
        for key in required where obj[key] == nil { throw ParseError.notJSON("missing \(key)") }
        let extra = Set(obj.keys).subtracting(required)
        if !extra.isEmpty { throw ParseError.notJSON("unexpected keys \(extra.sorted().joined(separator: ", "))") }
        do {
            let notes = try JSONDecoder().decode(GeneratedNotes.self, from: data)
            if notes.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { throw ParseError.emptyTitle }
            return notes
        } catch let e as ParseError {
            throw e
        } catch {
            throw ParseError.notJSON("wrong field types")
        }
    }

    /// Clean up model output and fit it to the website limits (§8.3).
    public static func sanitise(_ n: GeneratedNotes) -> GeneratedNotes {
        func clean(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }
        func fit(_ s: String, _ max: Int) -> String {
            let c = clean(s)
            if c.utf16.count <= max { return c }
            var out = ""
            for ch in c {
                if out.utf16.count + String(ch).utf16.count > max - 1 { break }
                out.append(ch)
            }
            return out + "…"
        }
        func items(_ a: [String], maxItems: Int, maxLen: Int) -> [String] {
            var seen = Set<String>()
            var out: [String] = []
            for raw in a {
                let v = fit(raw, maxLen)
                guard !v.isEmpty, !seen.contains(v.lowercased()) else { continue }
                seen.insert(v.lowercased())
                out.append(v)
                if out.count == maxItems { break }
            }
            return out
        }
        return GeneratedNotes(title: fit(n.title, 200),
                              overview: fit(n.overview, 2000),
                              keyPoints: items(n.keyPoints, maxItems: 30, maxLen: 500),
                              nextSteps: items(n.nextSteps, maxItems: 20, maxLen: 500),
                              homework: fit(n.homework, 2000),
                              vocabulary: items(n.vocabulary, maxItems: 50, maxLen: 200),
                              praise: fit(n.praise, 1000),
                              privateNotes: fit(n.privateNotes, 10_000))
    }

    /// Map into the website `summary` object, omitting empty values.
    public static func summary(from n: GeneratedNotes) -> NoteSummary {
        func opt(_ s: String) -> String? { s.isEmpty ? nil : s }
        func optA(_ a: [String]) -> [String]? { a.isEmpty ? nil : a }
        return NoteSummary(overview: opt(n.overview), keyPoints: optA(n.keyPoints), nextSteps: optA(n.nextSteps),
                           homework: opt(n.homework), vocabulary: optA(n.vocabulary), praise: opt(n.praise))
    }
}
