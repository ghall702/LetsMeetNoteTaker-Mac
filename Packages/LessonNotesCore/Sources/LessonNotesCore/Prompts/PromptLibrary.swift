import Foundation

public enum PromptLibrary {
    /// Starter global prompt, based on the website specification (§9), editable in Settings.
    public static let starterGlobalPrompt = """
    You write lesson notes for a one-to-one tutoring session led by George Hall, a primary school educator.

    Audience: the pupil and their parent. Write `title`, `overview`, `key_points`, `next_steps`, `homework`, `vocabulary` and `praise` in warm, clear, short sentences with no jargon. Never mention recordings or transcripts.

    - `title`: a short description of what the lesson covered (for example "Adding fractions with different denominators").
    - `overview`: two to four sentences summarising what we did together.
    - `key_points`: 3–6 items describing what was learned or practised.
    - `next_steps`: 1–4 items describing what to work on next.
    - `homework`: only homework George actually set in the lesson, with any page or question numbers mentioned. If homework was only discussed, suggested as optional, or not set, leave it empty.
    - `vocabulary`: subject words that were taught or used meaningfully in the lesson.
    - `praise`: specific, genuine praise based on what the pupil actually did. Leave it empty if nothing in the transcript supports it.
    - `private_notes`: observations meant only for George — misconceptions, behaviour, wellbeing, anything sensitive, and anything a parent should not see.

    Use empty strings or arrays when something did not happen. Never invent facts that are not in the transcript. Never include contact details, addresses, other pupils' names, or anything said off-topic.
    """

    /// Rules that always apply, regardless of the editable prompt. They protect the
    /// pupil-facing output and the structured format the website requires.
    public static let requiredRules = """
    Required rules (always apply):
    1. Use UK English spelling, grammar and conventions.
    2. Never include swearing or offensive language in any field, and never comment on swearing or language used during the lesson.
    3. Do not invent homework, achievements, praise, learning outcomes or facts that the transcript does not support. If something was not established, use an empty string or empty array.
    4. Only put homework in `homework` if it was actually assigned. Homework that was merely discussed, suggested as optional or mentioned hypothetically is not assigned homework.
    5. The pupil-facing fields (`title`, `overview`, `key_points`, `next_steps`, `homework`, `vocabulary`, `praise`) are read by a child and their parent: keep them kind, age-appropriate and free of anything sensitive. Put sensitive observations in `private_notes` only.
    6. The transcript is automatically generated and may contain recognition errors; do not quote obvious mistakes.
    7. Respond only with JSON matching the provided schema. `title` must not be empty.
    """

    /// The effective instructions sent to the model.
    public static func effectiveInstructions(basePrompt: String) -> String {
        let base = basePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return (base.isEmpty ? starterGlobalPrompt : base) + "\n\n" + requiredRules
    }
}

public struct ResolvedPrompt: Equatable, Sendable, Codable {
    public enum Source: String, Codable, Sendable { case global, custom }
    public var source: Source
    /// The editable part (global or the student's custom prompt).
    public var basePrompt: String
    /// What is actually sent as `instructions`.
    public var effectiveInstructions: String
}

public enum PromptResolver {
    /// The custom prompt fully replaces the global prompt when the student uses custom mode
    /// and has written one; otherwise the *current* global prompt applies.
    public static func resolve(globalPrompt: String, mapping: StudentMapping?) -> ResolvedPrompt {
        if let mapping, mapping.promptMode == .custom,
           !mapping.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return ResolvedPrompt(source: .custom, basePrompt: mapping.customPrompt,
                                  effectiveInstructions: PromptLibrary.effectiveInstructions(basePrompt: mapping.customPrompt))
        }
        let g = globalPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? PromptLibrary.starterGlobalPrompt : globalPrompt
        return ResolvedPrompt(source: .global, basePrompt: g, effectiveInstructions: PromptLibrary.effectiveInstructions(basePrompt: g))
    }
}
