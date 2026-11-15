import SwiftUI
import AppKit
import LessonNotesCore

struct StudentsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection: UUID?

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(model.mappings) { m in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(m.displayName).font(.body.weight(.medium))
                                if !m.enabled { StatusChip("Off", color: .gray) }
                                if !m.roomExists(in: model.rooms) { StatusChip("Room no longer exists", color: .red, icon: "exclamationmark.triangle") }
                            }
                            Text(m.currentRoomName(in: model.rooms) + (m.code.isEmpty ? "" : " · \(m.code)") + (m.promptMode == .custom ? " · custom prompt" : ""))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tag(m.id)
                    }
                }
                .overlay { if model.mappings.isEmpty { Text("No students yet").foregroundStyle(.secondary) } }
                HStack {
                    Button { addStudent() } label: { Image(systemName: "plus") }.help("Add student").accessibilityLabel("Add student")
                    Button { if let s = selection { model.store.deleteMapping(id: s); selection = nil } } label: { Image(systemName: "minus") }
                        .disabled(selection == nil).help("Delete student").accessibilityLabel("Delete student")
                    Spacer()
                    Menu("Add from Rooms") {
                        let mapped = Set(model.mappings.map(\.roomId))
                        let unmapped = model.rooms.rooms.filter { !mapped.contains($0.roomId) }
                        if unmapped.isEmpty { Text("Every room has a student") }
                        ForEach(unmapped) { r in
                            Button(r.name) { add(room: r) }
                        }
                        if unmapped.count > 1 {
                            Divider()
                            Button("Add All \(unmapped.count)") { unmapped.forEach { add(room: $0) } }
                        }
                    }
                    .fixedSize()
                }
                .padding(8)
            }
            .frame(minWidth: 260, idealWidth: 300, maxWidth: 400)

            Group {
                if let id = selection, let m = model.mappings.first(where: { $0.id == id }) {
                    StudentEditor(original: m).id(m.id)
                } else {
                    VStack(spacing: 8) {
                        Text("Select a student, or add one").foregroundStyle(.secondary)
                        Text("Rooms are loaded from the LetsMeet website. Students are matched to Zoom meetings by room name, initials, meeting name rules or patterns.")
                            .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Students")
        .onAppear {
            if model.demoSelectFirstStudent, let first = model.mappings.first(where: { $0.promptMode == .custom }) ?? model.mappings.first {
                model.demoSelectFirstStudent = false
                selection = first.id
            }
        }
        .toolbar {
            ToolbarItem {
                Button { Task { await model.refreshRooms() } } label: {
                    if model.isRefreshingRooms { ProgressView().controlSize(.small) } else { Label("Refresh Rooms", systemImage: "arrow.clockwise") }
                }
                .help("Refresh rooms from the website")
                .disabled(!model.hasWebsiteKey)
            }
        }
    }

    func addStudent() {
        let room = model.rooms.rooms.first
        let m = StudentMapping(roomId: room?.roomId ?? "", roomName: room?.name ?? "", displayName: "New student")
        model.store.upsertMapping(m)
        model.reload()
        selection = m.id
    }

    func add(room: Room) {
        let m = StudentMapping(roomId: room.roomId, roomName: room.name, displayName: room.name)
        model.store.upsertMapping(m)
        model.reload()
        selection = m.id
    }
}

struct StudentEditor: View {
    @EnvironmentObject var model: AppModel
    let original: StudentMapping
    @State private var draft: StudentMapping
    @State private var showPreview = false
    @State private var saved = false

    init(original: StudentMapping) {
        self.original = original
        _draft = State(initialValue: original)
    }

    var dirty: Bool { draft != original }
    var resolved: ResolvedPrompt { PromptResolver.resolve(globalPrompt: model.settings.globalPrompt, mapping: draft) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Student") {
                    TextField("Display name", text: $draft.displayName)
                    TextField("Initials or code (e.g. DT)", text: $draft.code)
                    TextField("Context for notes (e.g. Year 5, GCSE English Language)", text: $draft.context)
                    Toggle("Enabled for matching", isOn: $draft.enabled)
                }
                Section("LetsMeet room") {
                    Picker("Room", selection: $draft.roomId) {
                        if !model.rooms.contains(draft.roomId) {
                            Text(draft.roomId.isEmpty ? "Choose a room…" : "\(draft.roomName) (no longer exists)").tag(draft.roomId)
                        }
                        ForEach(model.rooms.rooms) { Text($0.name).tag($0.roomId) }
                    }
                    if !draft.roomExists(in: model.rooms) || draft.roomId.isEmpty {
                        Label("Room no longer exists — choose the pupil's current room.", systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    }
                    Text("Room ID: \(draft.roomId.isEmpty ? "—" : draft.roomId)").font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Section {
                    ForEach($draft.rules) { $rule in
                        HStack {
                            Picker("Type", selection: $rule.kind) {
                                ForEach(MatchRuleKind.allCases, id: \.self) { Text($0.label).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 190)
                            TextField("Value", text: $rule.value)
                            if !rule.isValid { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help("Invalid or empty") }
                            Button { draft.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).accessibilityLabel("Remove rule")
                        }
                    }
                    Button { draft.rules.append(MatchRule(kind: .meetingNameContains, value: "")) } label: { Label("Add Rule", systemImage: "plus") }
                } header: {
                    Text("Zoom matching rules")
                } footer: {
                    Text("The room name and the initials/code are matched automatically. Add rules for other meeting names, folders or regular expressions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("System prompt") {
                    Picker("Prompt mode", selection: $draft.promptMode) {
                        ForEach(PromptMode.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    if draft.promptMode == .custom {
                        TextEditor(text: $draft.customPrompt)
                            .font(.system(.body, design: .monospaced))
                            .frame(minHeight: 220)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
                        HStack {
                            Button("Start from Global Prompt") { draft.customPrompt = model.settings.globalPrompt }
                            Button("Reset to Default") { draft.promptMode = .global }
                                .help("Use the global default prompt again (the custom text is kept but not used)")
                        }
                        if draft.customPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            Text("The custom prompt is empty, so the global prompt is used.").font(.caption).foregroundStyle(.orange)
                        }
                    } else {
                        Text("This student uses the current global prompt, including any future changes to it.").font(.caption).foregroundStyle(.secondary)
                    }
                    Button("Preview Effective Prompt…") { showPreview = true }
                }
            }
            .formStyle(.grouped)
            HStack {
                if saved && !dirty { Label("Saved", systemImage: "checkmark").foregroundStyle(.green) }
                Spacer()
                Button("Revert") { draft = original }.disabled(!dirty)
                Button("Save") {
                    if let n = model.rooms.name(for: draft.roomId) { draft.roomName = n }
                    draft.rules = draft.rules.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
                    model.store.upsertMapping(draft)
                    model.reload()
                    saved = true
                }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!dirty || draft.displayName.trimmingCharacters(in: .whitespaces).isEmpty || !Room.isValidRoomId(draft.roomId))
            }
            .padding(12)
        }
        .sheet(isPresented: $showPreview) {
            PromptPreviewSheet(title: "Effective prompt for \(draft.displayName)", subtitle: resolved.source == .custom ? "Custom prompt + required rules" : "Global prompt + required rules", text: resolved.effectiveInstructions)
        }
    }
}

struct PromptPreviewSheet: View {
    var title: String
    var subtitle: String
    var text: String
    @Environment(\.dismiss) private var dismiss
    init(title: String, subtitle: String, text: String) { self.title = title; self.subtitle = subtitle; self.text = text }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Text(subtitle + ". The required lesson-notes JSON format is always enforced separately.").font(.caption).foregroundStyle(.secondary)
            ReadOnlyText(text: text)
            HStack { Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
        }
        .padding(16)
        .frame(width: 700, height: 560)
    }
}
