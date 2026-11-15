import SwiftUI
import AppKit
import LessonNotesCore

/// Regenerate notes from the saved transcript, review/compare, then replace or discard.
struct RegenerateSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let lessonId: UUID
    let jobId: UUID
    let initialDraftId: UUID?

    init(lessonId: UUID, jobId: UUID, initialDraftId: UUID? = nil) {
        self.lessonId = lessonId
        self.jobId = jobId
        self.initialDraftId = initialDraftId
    }

    enum Phase: Equatable { case options, generating, review(UUID) }

    @State private var phase: Phase = .options
    @State private var useTemporaryPrompt = false
    @State private var temporaryPrompt = ""
    @State private var modelId = ""
    @State private var effort: ReasoningEffort = .modelDefault
    @State private var extra = ""
    @State private var progressValue = 0.0
    @State private var progressMessage = "Writing lesson notes…"
    @State private var error: String?
    @State private var confirmReplace = false
    @State private var resultMessage: String?
    @State private var task: Task<Void, Never>?

    var lesson: Lesson? { model.lesson(lessonId) }
    var job: Job? { lesson?.jobs.first { $0.id == jobId } }
    var mapping: StudentMapping? { model.store.mapping(id: lesson?.studentId) }
    var currentPrompt: ResolvedPrompt { PromptResolver.resolve(globalPrompt: model.settings.globalPrompt, mapping: mapping) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Regenerate Notes").font(.title2.weight(.semibold))
                    if let l = lesson { Text("\(l.pupilName) · \(CoreFormat.longUKDate(l.lessonDate)) · uses the saved transcript (no re-transcription)").foregroundStyle(.secondary) }
                }
                Spacer()
            }
            .padding(20)
            Divider()
            switch phase {
            case .options: optionsView
            case .generating: generatingView
            case .review(let id): reviewView(id)
            }
        }
        .frame(width: 1000, height: 760)
        .onAppear(perform: setUp)
        .onDisappear { task?.cancel() }
    }

    func setUp() {
        modelId = model.settings.openAIModel
        effort = model.settings.reasoningEffort
        temporaryPrompt = currentPrompt.basePrompt
        if let id = initialDraftId { phase = .review(id) }
    }

    // MARK: Options

    var optionsView: some View {
        VStack(spacing: 0) {
            Form {
                Section("Prompt") {
                    Picker("Prompt", selection: $useTemporaryPrompt) {
                        Text(currentPrompt.source == .custom ? "Student's custom prompt (current)" : "Global default prompt (current)").tag(false)
                        Text("Temporary custom prompt (this regeneration only)").tag(true)
                    }
                    .pickerStyle(.radioGroup)
                    if useTemporaryPrompt {
                        TextEditor(text: $temporaryPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 160)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        Text("Not saved. Your global and student prompts stay as they are.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let job {
                    Section {
                        JobAttachmentsSection(job: job, showsHeader: false)
                    } header: {
                        Text("Lesson files used as context")
                    } footer: {
                        Text("Tick or untick files, change what they are, or add a context-only file. These choices are saved and used for this regeneration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Additional instructions (optional, this version only)") {
                    TextEditor(text: $extra)
                        .frame(minHeight: 70)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                    Text("For example: “Add more detail on the persuasive techniques we analysed.”").font(.caption).foregroundStyle(.secondary)
                }
                Section("Model") {
                    HStack {
                        TextField("OpenAI model", text: $modelId).font(.body.monospaced())
                        Menu("Choose") {
                            ForEach(ModelCatalog.filterForNotes(model.modelList.models).prefix(40)) { m in
                                Button(m.id) { modelId = m.id }
                            }
                        }
                        .fixedSize()
                    }
                    Picker("Reasoning effort", selection: $effort) {
                        ForEach(ReasoningEffort.allCases) { Text($0.label).tag($0) }
                    }
                    Text("Only used for this regeneration; your default model in Settings is not changed.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.horizontal, 20).textSelection(.enabled) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Generate New Version") { generate() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(modelId.trimmingCharacters(in: .whitespaces).isEmpty || (useTemporaryPrompt && temporaryPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) || !(job?.hasTranscript ?? false))
            }
            .padding(20)
        }
    }

    func generate() {
        guard let job else { return }
        error = nil
        progressValue = 0
        phase = .generating
        let options = RegenerationOptions(prompt: useTemporaryPrompt ? .temporary(temporaryPrompt) : .current, additionalInstructions: extra)
        task = Task {
            do {
                let v = try await model.regenerate(job, options: options, model: modelId, effort: effort) { p, m in
                    Task { @MainActor in progressValue = p; progressMessage = m }
                }
                phase = .review(v.id)
            } catch is CancellationError {
                phase = .options
            } catch {
                self.error = error.localizedDescription
                phase = .options
            }
        }
    }

    var generatingView: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: progressValue).frame(width: 360)
            Text(progressMessage).foregroundStyle(.secondary)
            Text("The notes are only accepted once OpenAI reports the response as complete.").font(.caption).foregroundStyle(.tertiary)
            Button("Cancel") { task?.cancel(); phase = .options }
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Review

    func describe(_ v: NoteVersion) -> String {
        var s = "Generated " + v.createdAt.shortDateTime + " with " + v.model
        if let e = v.effort, e != .modelDefault { s += " · effort " + e.label }
        if v.promptSource == .temporary { s += " · temporary prompt" }
        if v.additionalInstructions != nil { s += " · with additional instructions" }
        return s
    }

    @ViewBuilder func reviewView(_ versionId: UUID) -> some View {
        if let job, let draft = job.allNoteVersions.first(where: { $0.id == versionId }) {
            let current = job.currentVersion?.notes ?? job.notes ?? GeneratedNotes(title: "")
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(describe(draft)).font(.caption).foregroundStyle(.secondary)
                        CompareNotesView(left: current, leftTitle: "Current notes", right: draft.notes, rightTitle: "New version", rightAdjustments: draft.adjustments)
                    }
                    .padding(20)
                }
                Divider()
                if let resultMessage { Label(resultMessage, systemImage: "checkmark.circle.fill").foregroundStyle(.green).padding(.top, 8) }
                if let error { Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.top, 8) }
                HStack {
                    if draft.state == .draft {
                        Button("Discard This Version", role: .destructive) { model.discardDraft(job, draft); dismiss() }
                    } else {
                        Text("This version is \(draft.state.rawValue).").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                    Button("Regenerate Again…") { phase = .options }
                    if draft.state == .draft {
                        Button("Replace Existing Notes…") { confirmReplace = true }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(20)
                .alert("Replace the existing notes?", isPresented: $confirmReplace) {
                    Button("Replace") {
                        do {
                            let outcome = try model.acceptDraft(job, draft)
                            resultMessage = outcome == .replacementQueued
                                ? "Replacement queued — the website note will return to Waiting for approval."
                                : "Notes replaced locally; they will be submitted with the full transcript."
                            dismiss()
                        } catch {
                            self.error = error.localizedDescription
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(job.stage == .submitted
                         ? "The note on the LetsMeet website will be updated (no duplicate is created) and will return to Waiting for approval until you approve it again. The current version is kept in this Mac's version history."
                         : "The local notes will be replaced before they are submitted. The current version is kept in the version history.")
                }
            }
        } else {
            Text("This version is no longer available.").padding()
        }
    }
}
