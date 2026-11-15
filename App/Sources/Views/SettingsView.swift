import SwiftUI
import AppKit
import LessonNotesCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        TabView(selection: $model.settingsTab) {
            WebsiteSettings().tabItem { Label("Website", systemImage: "globe") }.tag(0)
            OpenAISettings().tabItem { Label("OpenAI", systemImage: "sparkles") }.tag(1)
            PromptSettings().tabItem { Label("Prompt", systemImage: "text.quote") }.tag(2)
            TranscriptionSettings().tabItem { Label("Transcription", systemImage: "waveform") }.tag(3)
            RecordingSettings().tabItem { Label("Recordings", systemImage: "video") }.tag(4)
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }.tag(5)
            PrivacyInfo().tabItem { Label("Privacy", systemImage: "lock.shield") }.tag(6)
        }
        .padding(12)
        .navigationTitle("Settings")
    }
}

struct WebsiteSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var baseURL = ""
    @State private var key = ""
    @State private var keyError: String?
    @State private var testing = false

    var body: some View {
        Form {
            Section("LetsMeet website") {
                TextField("Website address", text: $baseURL)
                    .onSubmit(saveURL)
                HStack {
                    if LetsMeetClient.validateBaseURL(baseURL) == nil { Text("Must be an HTTPS address.").foregroundStyle(.red).font(.caption) }
                    Spacer()
                    Button("Reset to Default") { baseURL = LetsMeetClient.defaultBaseURL; saveURL() }
                    Button("Save Address", action: saveURL).disabled(baseURL == model.settings.websiteBaseURL || LetsMeetClient.validateBaseURL(baseURL) == nil)
                }
            }
            Section {
                SecretField(title: model.hasWebsiteKey ? "Saved in Keychain — paste a new key to replace it" : "ghln_…", text: $key)
                HStack {
                    if let keyError { Text(keyError).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    if model.hasWebsiteKey { Button("Remove Key", role: .destructive) { model.removeKey(.website) } }
                    Button("Save Key") {
                        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard k.hasPrefix("ghln_") else { keyError = "Website API keys start with “ghln_”."; return }
                        keyError = model.saveKey(k, account: .website)
                        if keyError == nil { key = "" }
                    }
                    .disabled(key.isEmpty)
                }
                HStack {
                    Button {
                        testing = true
                        Task { await model.testWebsite(); testing = false }
                    } label: { Text("Test Connection") }
                    .disabled(!model.hasWebsiteKey || testing)
                    if testing { ProgressView().controlSize(.small) }
                }
                ResultLine(result: model.websiteTest)
            } header: {
                Text("Website API key")
            } footer: {
                Text("Create a key in Admin Tools → Lesson notes manager → Mac app connection. It is stored only in your Mac's Keychain.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Rooms") {
                HStack {
                    Text("\(model.rooms.rooms.count) rooms" + (model.rooms.fetchedAt.map { " · updated \($0.shortDateTime)" } ?? ""))
                    Spacer()
                    if model.isRefreshingRooms { ProgressView().controlSize(.small) }
                    Button("Refresh Rooms") { Task { await model.refreshRooms() } }.disabled(!model.hasWebsiteKey)
                }
                ForEach(model.rooms.rooms) { r in
                    HStack { Text(r.name); Spacer(); Text(r.roomId).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { baseURL = model.settings.websiteBaseURL }
    }

    func saveURL() {
        guard let u = LetsMeetClient.validateBaseURL(baseURL) else { return }
        model.updateSettings { $0.websiteBaseURL = u.absoluteString }
        baseURL = u.absoluteString
        model.websiteTest = nil
    }
}

struct OpenAISettings: View {
    @EnvironmentObject var model: AppModel
    @State private var key = ""
    @State private var keyError: String?
    @State private var search = ""
    @State private var customModel = ""
    @State private var showAll = false
    @State private var testingKey = false
    @State private var chunkTokens = 100_000

    var filteredModels: [OpenAIModelInfo] {
        let base = showAll ? model.modelList.models.sorted { $0.id < $1.id } : ModelCatalog.filterForNotes(model.modelList.models)
        return ModelCatalog.search(base, query: search)
    }

    var body: some View {
        Form {
            Section {
                SecretField(title: model.hasOpenAIKey ? "Saved in Keychain — paste a new key to replace it" : "sk-…", text: $key)
                HStack {
                    if let keyError { Text(keyError).foregroundStyle(.red).font(.caption) }
                    Spacer()
                    if model.hasOpenAIKey { Button("Remove Key", role: .destructive) { model.removeKey(.openAI) } }
                    Button("Save Key") {
                        keyError = model.saveKey(key, account: .openAI)
                        if keyError == nil { key = ""; Task { await model.refreshModels() } }
                    }
                    .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                HStack {
                    Button("Test Connection") {
                        testingKey = true
                        Task { await model.testOpenAIKey(); testingKey = false }
                    }
                    .disabled(!model.hasOpenAIKey || testingKey)
                    if testingKey { ProgressView().controlSize(.small) }
                }
                ResultLine(result: model.openAITest)
            } header: {
                Text("OpenAI API key")
            } footer: {
                Text("Your own key, stored only in the Keychain. Only transcript text and lesson context are sent to OpenAI, with store: false.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    TextField("Search models", text: $search).textFieldStyle(.roundedBorder)
                    Toggle("Show all", isOn: $showAll).toggleStyle(.checkbox).help("Include models that look unsuitable (embeddings, audio, images…)")
                    Button {
                        Task { await model.refreshModels() }
                    } label: {
                        if model.isRefreshingModels { ProgressView().controlSize(.small) } else { Label("Refresh Models", systemImage: "arrow.clockwise") }
                    }
                    .disabled(!model.hasOpenAIKey || model.isRefreshingModels)
                }
                if let e = model.modelsError { Label(e, systemImage: "exclamationmark.triangle").foregroundStyle(.red).font(.caption) }
                ModelPickerList(models: filteredModels, selected: model.settings.openAIModel,
                                verifications: model.modelList.verifications) { id in
                    model.updateSettings { $0.openAIModel = id }
                }
                .frame(height: 200)
                Text(model.modelList.fetchedAt.map { "\(model.modelList.models.count) models on your account · list updated \($0.shortDateTime) (cached for offline use)" } ?? "Save your key and press Refresh Models to load the models available to your account.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("Custom model ID", text: $customModel).textFieldStyle(.roundedBorder)
                    Button("Use Custom Model") { model.updateSettings { $0.openAIModel = customModel.trimmingCharacters(in: .whitespaces) }; customModel = "" }
                        .disabled(customModel.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Model")
            } footer: {
                Text("The list comes live from your OpenAI account (GET /v1/models). Not every listed model supports structured lesson-notes output — use Test Model to check before relying on one. Your choice is never changed automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Selected model") {
                LabeledContent("Model in use") { Text(model.settings.openAIModel.isEmpty ? "None selected" : model.settings.openAIModel).font(.body.monospaced()).textSelection(.enabled) }
                availabilityWarning
                Picker("Reasoning effort", selection: Binding(get: { model.settings.reasoningEffort }, set: { v in model.updateSettings { $0.reasoningEffort = v } })) {
                    ForEach(ReasoningEffort.allCases) { Text($0.label).tag($0) }
                }
                Text("Only reasoning models accept a reasoning effort, and accepted values vary by model. Leave it on “Model default” unless Test Model confirms the value works.")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Test Model") { Task { await model.testSelectedModel() } }
                        .disabled(model.settings.openAIModel.isEmpty || !model.hasOpenAIKey || model.isTestingModel)
                    if model.isTestingModel { ProgressView().controlSize(.small); Text("Sending a small sample (not a pupil transcript)…").font(.caption) }
                }
                if let v = model.modelList.verifications[model.settings.openAIModel] {
                    VStack(alignment: .leading, spacing: 3) {
                        Label(v.message, systemImage: v.structuredOutputWorks ? "checkmark.circle.fill" : "xmark.octagon.fill")
                            .foregroundStyle(v.structuredOutputWorks ? .green : .red).textSelection(.enabled)
                        Text("Tested \(v.testedAt.shortDateTime) with reasoning effort “\(v.reasoningEffortTested.label)”"
                             + (v.reasoningEffortAccepted == true ? " (accepted)" : v.reasoningEffortAccepted == false ? " (rejected)" : "")
                             + String(format: " · %.1fs", v.elapsedSeconds))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            UsageSettingsSection()

            Section("Output length") {
                Toggle("Let the model use its full output allowance (recommended)", isOn: Binding(get: { model.settings.maxOutputTokens == nil }, set: { useDefault in
                    model.updateSettings { $0.maxOutputTokens = useDefault ? nil : 32_000 }
                }))
                if let limit = model.settings.maxOutputTokens {
                    Stepper(value: Binding(get: { limit }, set: { v in model.updateSettings { $0.maxOutputTokens = v } }), in: 4_000...200_000, step: 4_000) {
                        Text("Maximum output tokens: \(limit.formatted())")
                    }
                    Text("If this is above what your model allows, OpenAI will reject the request — use Test Model to check.").font(.caption).foregroundStyle(.secondary)
                }
                Text("Notes are only accepted when OpenAI reports a complete response. If a model runs out of output space, the notes are written in two parts and combined; incomplete notes are never saved or submitted.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Long transcripts") {
                Stepper(value: $chunkTokens, in: 8_000...1_000_000, step: 8_000) {
                    Text("Split transcripts longer than about \(chunkTokens.formatted()) tokens")
                }
                .onChange(of: chunkTokens) { _, v in model.updateSettings { $0.chunkThresholdTokens = v } }
                Text("Longer transcripts are summarised in parts and then combined. Set this below your model's context window. (The full transcript is still uploaded to the website.)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { chunkTokens = model.settings.chunkThresholdTokens }
    }

    @ViewBuilder var availabilityWarning: some View {
        let id = model.settings.openAIModel
        if !id.isEmpty {
            switch ModelCatalog.availability(of: id, in: model.modelList) {
            case .available: Label("Available on your account", systemImage: "checkmark.circle").foregroundStyle(.green).font(.caption)
            case .notInList: Label("This model is not in your account's current model list. It may have been retired — choose a replacement or test it.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
            case .unknown: Label("Model list not loaded yet.", systemImage: "questionmark.circle").foregroundStyle(.secondary).font(.caption)
            }
        }
    }
}

/// Searchable, selectable model list (a plain List inside a grouped Form does not render reliably).
struct ModelPickerList: View {
    var models: [OpenAIModelInfo]
    var selected: String
    var verifications: [String: ModelVerification]
    var onSelect: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if models.isEmpty {
                    Text("No models to show. Save your OpenAI key and press Refresh Models.")
                        .font(.callout).foregroundStyle(.secondary).padding(12)
                }
                ForEach(models) { m in
                    Button { onSelect(m.id) } label: { row(m) }
                        .buttonStyle(.plain)
                        .accessibilityLabel(m.id + (m.id == selected ? ", selected" : ""))
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
    }

    func row(_ m: OpenAIModelInfo) -> some View {
        let isSelected = m.id == selected
        return HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle").foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(m.id).font(.body.monospaced())
            Spacer()
            if let v = verifications[m.id] {
                StatusChip(v.structuredOutputWorks ? "Tested ✓" : "Test failed", color: v.structuredOutputWorks ? .green : .red)
            }
            if let c = m.created {
                Text(Date(timeIntervalSince1970: TimeInterval(c)).formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear)
        .contentShape(Rectangle())
    }
}

struct PromptSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = ""
    @State private var showPreview = false
    @State private var confirmReset = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Global system prompt").font(.headline)
            Text("Used for every student who has not set a custom prompt. Changes apply to all future lessons for those students. Required rules (UK English, no swearing, no invented homework or praise, the JSON format) are always added.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $draft)
                .font(.system(.body, design: .monospaced))
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.3)))
            HStack {
                let customCount = model.mappings.filter { $0.promptMode == .custom }.count
                Text("\(model.mappings.count - customCount) student(s) use this prompt · \(customCount) use a custom prompt").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Preview Effective Instructions…") { showPreview = true }
                Button("Restore Default Prompt…") { confirmReset = true }
                Button("Revert") { draft = model.settings.globalPrompt }.disabled(draft == model.settings.globalPrompt)
                Button("Save") { model.updateSettings { $0.globalPrompt = draft } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(draft == model.settings.globalPrompt || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding()
        .onAppear { draft = model.settings.globalPrompt }
        .sheet(isPresented: $showPreview) {
            PromptPreviewSheet(title: "Effective global instructions", subtitle: "Global prompt + required rules",
                               text: PromptLibrary.effectiveInstructions(basePrompt: draft))
        }
        .alert("Restore the default prompt?", isPresented: $confirmReset) {
            Button("Restore Default", role: .destructive) { draft = PromptLibrary.starterGlobalPrompt; model.updateSettings { $0.globalPrompt = draft } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your edits to the global prompt will be replaced by the built-in default prompt. Students with their own custom prompt are not affected.") }
    }
}

struct TranscriptionSettings: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var whisper: WhisperModelManager

    var body: some View {
        Form {
            Section {
                ForEach(whisper.available) { m in
                    HStack {
                        Image(systemName: model.transcriptionModelName == m.name ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(whisper.downloaded[m.name] != nil ? Color.accentColor : .secondary)
                            .onTapGesture { if whisper.downloaded[m.name] != nil { model.updateSettings { $0.transcriptionModel = m.name } } }
                            .accessibilityLabel(model.transcriptionModelName == m.name ? "Selected" : "Select")
                        VStack(alignment: .leading) {
                            HStack {
                                Text(m.name).font(.body.monospaced())
                                if m.recommended { StatusChip("Recommended for this Mac", color: .blue) }
                            }
                            Text(whisper.downloaded[m.name].map { "Downloaded · \($0.byteString) on disk" } ?? "Download \(m.approxSize)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let p = whisper.downloading[m.name] {
                            ProgressView(value: p).frame(width: 120)
                            Text("\(Int(p * 100))%").font(.caption.monospacedDigit())
                        } else if whisper.preparing.contains(m.name) {
                            ProgressView().controlSize(.small); Text("Preparing…").font(.caption)
                        } else if whisper.downloaded[m.name] != nil {
                            if model.transcriptionModelName != m.name {
                                Button("Use") { model.updateSettings { $0.transcriptionModel = m.name } }
                            }
                            Button("Delete", role: .destructive) { whisper.delete(m.name) }
                        } else {
                            Button("Download") {
                                Task {
                                    await whisper.download(m.name)
                                    if model.settings.transcriptionModel.isEmpty, whisper.downloaded[m.name] != nil {
                                        model.updateSettings { $0.transcriptionModel = m.name }
                                    }
                                }
                            }
                        }
                    }
                }
                if let e = whisper.lastError { Text(e).foregroundStyle(.red).font(.caption).textSelection(.enabled) }
                HStack {
                    Text("Storage used by models: \(whisper.totalStorage.byteString)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if whisper.isLoadingList { ProgressView().controlSize(.small) }
                    Button("Refresh List") { Task { await whisper.refreshAvailable() } }
                }
            } header: {
                Text("Whisper models (on-device)")
            } footer: {
                Text("Transcription runs entirely on this Mac with WhisperKit (Core ML). Models download from Hugging Face. Larger “large-v3 turbo” models are more accurate; smaller ones are faster. Audio and video are never uploaded.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Picker("Maximum simultaneous transcriptions", selection: Binding(get: { model.settings.maxConcurrentTranscriptions }, set: { v in
                    model.updateSettings { $0.maxConcurrentTranscriptions = v }
                    Task { await model.engine.tick() }
                })) {
                    ForEach(1...8, id: \.self) { n in Text(n == 1 ? "1 transcription at a time" : "\(n) simultaneous transcriptions").tag(n) }
                }
                memoryAdvice
            } header: {
                Text("Simultaneous transcriptions")
            } footer: {
                Text("Each simultaneous transcription loads its own copy of the model. Lessons that already have a transcript and only need OpenAI or uploading never wait for a transcription slot. Lowering the limit never stops a transcription in progress; under macOS memory pressure fewer new transcriptions are started.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Language") {
                Picker("Spoken language", selection: Binding(get: { model.settings.transcriptionLanguage ?? "auto" }, set: { v in
                    model.updateSettings { $0.transcriptionLanguage = v == "auto" ? nil : v }
                })) {
                    Text("English").tag("en")
                    Text("Detect automatically").tag("auto")
                }
                Text("Whisper has a single English model; UK spelling is applied when the notes are written.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task { await whisper.refreshAvailable() }
    }
}

extension TranscriptionSettings {
    @ViewBuilder var memoryAdvice: some View {
        let name = model.transcriptionModelName ?? ""
        let per = WhisperModelManager.estimatedMemoryBytes(name)
        let total = per * Int64(model.settings.maxConcurrentTranscriptions)
        let ram = Int64(ProcessInfo.processInfo.physicalMemory)
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_073_741_824) }
        if model.settings.maxConcurrentTranscriptions > 1 && total > ram / 2 {
            Label("About \(gb(total)) of memory may be needed (≈ \(gb(per)) per transcription with \(name.isEmpty ? "this model" : name)); this Mac has \(gb(ram)). This may slow your Mac or cause memory pressure — consider a lower number.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Text("Estimated memory: about \(gb(total)) of \(gb(ram)).").font(.caption).foregroundStyle(.secondary)
        }
        if model.memoryPressure != .normal {
            Label(model.memoryPressure == .critical ? "macOS reports critical memory pressure: only one new transcription is started at a time."
                                                    : "macOS reports memory pressure: fewer new transcriptions are being started.",
                  systemImage: "memorychip").font(.caption).foregroundStyle(.orange)
        }
    }
}

struct RecordingSettings: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Form {
            Section("Zoom recordings folder") {
                HStack {
                    Text((model.settings.zoomFolderPath as NSString).abbreviatingWithTildeInPath).font(.body.monospaced()).textSelection(.enabled)
                    Spacer()
                    Button("Choose…") { model.chooseZoomFolder() }
                }
                if model.settings.zoomFolderBookmark == nil {
                    Text("Choose the folder once so Lesson Notes may read it (macOS privacy protection). Zoom's default is ~/Documents/Zoom.").font(.caption).foregroundStyle(.orange)
                }
                if let e = model.watchError { Text(e).foregroundStyle(.red).font(.caption) }
                Toggle("Watch folder automatically", isOn: Binding(get: { model.settings.watchFolder }, set: { v in
                    model.updateSettings { $0.watchFolder = v }
                    model.startWatching()
                }))
                Toggle("Process automatically after I confirm the pupil and recordings", isOn: Binding(get: { model.settings.autoProcessAfterConfirm }, set: { v in
                    model.updateSettings { $0.autoProcessAfterConfirm = v }
                }))
            }
            Section("Time zone") {
                Picker("Zoom folder times are in", selection: Binding(get: { model.settings.timeZoneIdentifier ?? "" }, set: { v in
                    model.updateSettings { $0.timeZoneIdentifier = v.isEmpty ? nil : v }
                })) {
                    Text("This Mac's time zone (\(TimeZone.current.identifier))").tag("")
                    ForEach(TimeZone.knownTimeZoneIdentifiers.sorted(), id: \.self) { Text($0).tag($0) }
                }
                Text("Zoom names folders using local time. Lesson dates are calculated in this time zone.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Website upload") {
                Label("The complete transcript is always uploaded with the notes.", systemImage: "doc.text")
                Text("Limits: transcript up to \(APILimits.maxTranscriptBytes.byteStringDecimal); whole upload up to \(APILimits.maxRequestBodyBytes.byteStringDecimal). Lessons over the limit are kept on this Mac and marked “Needs attention” — they are never shortened.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @State private var launchError: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        do { try LaunchAtLogin.set(v); launchError = nil } catch { launchError = error.localizedDescription }
                        launchAtLogin = LaunchAtLogin.isEnabled
                    }
                if LaunchAtLogin.requiresApproval { Text("Approve Lesson Notes in System Settings → General → Login Items.").font(.caption).foregroundStyle(.orange) }
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.red) }
            }
            Section("Notifications") {
                Toggle("Notify when notes are submitted", isOn: Binding(get: { model.settings.notifyOnSubmitted }, set: { v in model.updateSettings { $0.notifyOnSubmitted = v } }))
            }
            Section("Processing") {
                Stepper(value: Binding(get: { model.settings.maxConcurrentJobs }, set: { v in model.updateSettings { $0.maxConcurrentJobs = v } }), in: 1...4) {
                    Text("OpenAI and website work: up to \(model.settings.maxConcurrentJobs) lesson(s) at once (transcriptions are set in Settings → Transcription)")
                }
                Toggle("Pause processing", isOn: Binding(get: { model.isPaused }, set: { model.setPaused($0) }))
            }
            Section("Local data") {
                Picker("Keep local transcripts for", selection: Binding(get: { model.settings.retention }, set: { v in
                    model.updateSettings { $0.retention = v }
                    model.store.applyRetention(v)
                })) {
                    ForEach(RetentionPeriod.allCases) { Text($0.label).tag($0) }
                }
                Text("Transcripts are only deleted after they have been uploaded. Temporary audio is always deleted after each job. Original Zoom recordings are never deleted.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Data Folder in Finder") { NSWorkspace.shared.activateFileViewerSelecting([AppInfo.supportDirectory]) }
            }
            Section("Data safety") {
                let h = model.store.health
                if let p = h.backupPath {
                    Label("Your data was backed up before this update and checked: \((p as NSString).lastPathComponent)", systemImage: "checkmark.shield").font(.callout)
                }
                if h.recoveredJobs > 0 {
                    Text("\(h.recoveredJobs) lesson(s) were set to resume from the last step already completed.").font(.caption).foregroundStyle(.secondary)
                }
                if let e = h.backupError ?? h.migrationError { Label(e, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout) }
                Text("Before each update the lesson history, settings, students and every saved transcript are copied to a Backups folder and verified. Backups are never deleted automatically.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Show Backups in Finder") {
                    let dir = model.store.backupsDirectory
                    NSWorkspace.shared.activateFileViewerSelecting([FileManager.default.fileExists(atPath: dir.path) ? dir : model.store.directory])
                }
            }
            Section {
                Button("Run Setup Assistant Again") { model.showOnboarding = true; model.showMainWindow() }
            }
        }
        .formStyle(.grouped)
    }
}

struct PrivacyInfo: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Privacy and safeguarding").font(.title3.weight(.semibold))
                PrivacyPoints()
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PrivacyPoints: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Recordings and audio stay on this Mac. Transcription happens on-device; extracted audio is temporary and deleted after each job. Original Zoom recordings are never deleted.", systemImage: "desktopcomputer")
            Label("OpenAI receives the transcript text and lesson context (pupil name, date) to write the notes, using your own API key with store: false.", systemImage: "sparkles")
            Label("The LetsMeet website receives the notes, private tutor notes, the complete transcript and recording file names/metadata. New notes wait for your approval; pupils only ever see approved pupil-facing notes.", systemImage: "globe")
            Label("API keys are kept in the macOS Keychain. Transcripts, notes and keys are never written to logs. No analytics or other third parties.", systemImage: "key")
            Label("Local transcripts follow your retention setting and can be deleted from History at any time. Deleting local data never deletes website records.", systemImage: "trash")
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
