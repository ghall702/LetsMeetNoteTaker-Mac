import SwiftUI
import AppKit
import LessonNotesCore

/// Renders GitHub-flavoured Markdown blocks (headings, lists, tables, quotes, code) the way the
/// website does; inline bold/italic/code/links use AttributedString.
struct MarkdownText: View {
    var text: String
    init(_ text: String) { self.text = text }

    static func inline(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }

    var body: some View {
        let blocks = MarkdownBlocks.parse(text)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in block(b) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder func block(_ b: MarkdownBlock) -> some View {
        switch b {
        case .heading(let level, let t):
            Self.inline(t).font(level <= 1 ? .title3.weight(.semibold) : (level == 2 ? .headline : .subheadline.weight(.semibold)))
                .padding(.top, 4)
        case .paragraph(let t):
            Self.inline(t).fixedSize(horizontal: false, vertical: true)
        case .list(let items):
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(it.ordered ? "\(it.number ?? i + 1)." : "•").monospacedDigit().foregroundStyle(.secondary)
                        Self.inline(it.text).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.leading, CGFloat(it.level) * 16)
                }
            }
        case .quote(let t):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Self.inline(t).italic().fixedSize(horizontal: false, vertical: true)
            }
        case .code(let t):
            Text(t).font(.system(.callout, design: .monospaced))
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
        case .table(let header, let rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                GridRow { ForEach(header.indices, id: \.self) { Self.inline(header[$0]).fontWeight(.semibold) } }
                Divider()
                ForEach(rows.indices, id: \.self) { r in
                    GridRow { ForEach(rows[r].indices, id: \.self) { Self.inline(rows[r][$0]) } }
                }
            }
            .padding(8)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
        case .rule:
            Divider()
        }
    }
}

/// Preview of a set of notes. Empty sections are hidden, exactly as on the website.
struct NotesView: View {
    var notes: GeneratedNotes
    var adjustments: [String] = []
    var showTitle = false
    var highlight: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showTitle { section("title", "Title") { Text(notes.title).font(.headline).textSelection(.enabled) } }
            if !notes.overview.isEmpty { section("overview", "Overview") { MarkdownText(notes.overview) } }
            if !notes.learningContent.isEmpty { section("learning_content", "What we learned") { MarkdownText(notes.learningContent) } }
            if !notes.workedExamples.isEmpty {
                section("worked_examples", "Worked examples") {
                    ForEach(Array(notes.workedExamples.enumerated()), id: \.offset) { _, ex in
                        MarkdownText(ex)
                            .padding(8)
                            .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
            if !notes.keyQuotes.isEmpty { section("key_quotes", "Key quotes") { bullets(notes.keyQuotes) } }
            if !notes.keyPoints.isEmpty { section("key_points", "Key points") { bullets(notes.keyPoints) } }
            if !notes.vocabulary.isEmpty { section("vocabulary", "Vocabulary") { bullets(notes.vocabulary) } }
            if !notes.nextSteps.isEmpty { section("next_steps", "Next steps") { bullets(notes.nextSteps) } }
            if !notes.homework.isEmpty { section("homework", "Homework") { MarkdownText(notes.homework) } }
            if !notes.praise.isEmpty { section("praise", "Praise") { MarkdownText(notes.praise) } }
            if !notes.privateNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Private tutor notes (never shown to pupils)", systemImage: "lock.fill").font(.caption.weight(.semibold))
                    MarkdownText(notes.privateNotes)
                }
                .padding(8)
                .background(Color.purple.opacity(highlight.contains("private_notes") ? 0.16 : 0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if !adjustments.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Adjusted to fit the website limits", systemImage: "scissors").font(.caption.weight(.semibold)).foregroundStyle(.orange)
                    ForEach(adjustments, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }

    @ViewBuilder func section<C: View>(_ key: String, _ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                if highlight.contains(key) { Text("changed").font(.caption2.weight(.semibold)).foregroundStyle(.orange) }
            }
            content()
        }
        .padding(highlight.contains(key) ? 6 : 0)
        .background(highlight.contains(key) ? Color.orange.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    func bullets(_ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("•").foregroundStyle(.secondary)
                    MarkdownText(item)
                }
            }
        }
    }
}

/// Side-by-side comparison of two versions.
struct CompareNotesView: View {
    var left: GeneratedNotes
    var leftTitle: String
    var right: GeneratedNotes
    var rightTitle: String
    var rightAdjustments: [String] = []

    var body: some View {
        let changed = Set(right.changedFields(comparedTo: left))
        VStack(alignment: .leading, spacing: 8) {
            Text(changed.isEmpty ? "No differences." : "Changed: " + right.changedFields(comparedTo: left).joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 16) {
                column(leftTitle, left, [], [])
                Divider()
                column(rightTitle, right, changed, rightAdjustments)
            }
        }
    }

    func column(_ title: String, _ n: GeneratedNotes, _ highlight: Set<String>, _ adj: [String]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            NotesView(notes: n, adjustments: adj, showTitle: true, highlight: highlight)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}
