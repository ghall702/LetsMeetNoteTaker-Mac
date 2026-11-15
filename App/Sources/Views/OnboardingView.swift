import SwiftUI
import AppKit
import LessonNotesCore

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var whisper: WhisperModelManager
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var websiteKey = ""
    @State private var openAIKey = ""
    @State private var keyError: String?
    @State private var busy = false

    let titles = ["Welcome", "LetsMeet website", "Rooms", "OpenAI", "AI model", "Zoom folder", "Transcription model", "Students", "System prompt", "Done"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Setup Assistant").font(.title2.weight(.semibold))
                Spacer()
                Text("Step \(step + 1) of \(titles.count) · \(titles[step])").foregroundStyle(.secondary)
            }
            .padding(20)
            ProgressView(value: Double(step), total: Double(titles.count - 1)).padding(.horizontal, 20)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) { content }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Button("Skip Setup") { finish() }
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Back") { step -= 1; keyError = nil }.disabled(step == 0)
                Button(step == titles.count - 1 ? "Finish" : "Continue") {
                    if step == titles.count - 1 { finish() } else { step += 1; keyError = nil }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
        }
        .frame(width: 720, height: 600)
    }

    @ViewBuilder var content: some View {
        switch step {
        case 0:
            Text("Lesson Notes turns your Zoom lesson recordings into lesson notes for LetsMeet.").font(.title3)
            Text("Before you start, here is exactly where information goes:").font(.headline)
            PrivacyPoints()
        case 1:
            Text("Paste your LetsMeet website API key. Create one in Admin Tools → Lesson notes manager → Mac app connection.")
            SecretField(title: model.hasWebsiteKey ? "Key saved — paste a new one to replace it" : "ghln_…", text: $websiteKey)
            HStack {
                Button("Save Key & Test Connection") {
                    let k = websiteKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard k.hasPrefix("ghln_") else { keyError = "Website API keys start with “ghln_”."; return }
                    keyError = model.saveKey(k, account: .website)
                    guard keyError == nil else { return }
                    websiteKey = ""
                    busy = true
                    Task { await model.testWebsite(); busy = false }
                }
                .disabled(websiteKey.isEmpty)
                if model.hasWebsiteKey { Button("Test Again") { busy = true; Task { await model.testWebsite(); busy = false } } }
            }
            if let keyError { Text(keyError).foregroundStyle(.red) }
            ResultLine(result: model.websiteTest)
        case 2:
            Text("Your pupils' rooms are loaded from the website. Each room has a permanent ID that is used for every submission.")
            Button("Refresh Rooms") { Task { await model.refreshRooms() } }.disabled(!model.hasWebsiteKey)
            if model.rooms.rooms.isEmpty { Text("No rooms loaded yet.").foregroundStyle(.secondary) }
            ForEach(model.rooms.rooms) { Label($0.name, systemImage: "door.left.hand.open") }
        case 3:
            Text("Paste your OpenAI API key. It is used only to write the notes from the transcript text.")
            SecretField(title: model.hasOpenAIKey ? "Key saved — paste a new one to replace it" : "sk-…", text: $openAIKey)
            HStack {
                Button("Save Key & Test") {
                    keyError = model.saveKey(openAIKey, account: .openAI)
                    guard keyError == nil else { return }
                    openAIKey = ""
                    busy = true
                    Task { await model.testOpenAIKey(); busy = false }
                }
                .disabled(openAIKey.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let keyError { Text(keyError).foregroundStyle(.red) }
            ResultLine(result: model.openAITest)
        case 4:
            Text("Choose the OpenAI model that writes your notes, then press Test Model to check it can produce lesson notes.")
            OpenAISettings().frame(minHeight: 380)
        case 5:
            Text("Choose your Zoom recordings folder (usually Documents → Zoom). macOS asks you to pick it once so Lesson Notes can read it.")
            HStack {
                Text((model.settings.zoomFolderPath as NSString).abbreviatingWithTildeInPath).font(.body.monospaced())
                Spacer()
                Button("Choose Folder…") { model.chooseZoomFolder() }
            }
            if model.settings.zoomFolderBookmark != nil { Label("Folder access granted", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
            Toggle("Watch this folder for new recordings", isOn: Binding(get: { model.settings.watchFolder }, set: { v in model.updateSettings { $0.watchFolder = v }; model.startWatching() }))
        case 6:
            Text("Download a transcription model. Transcription runs on this Mac only. The recommended model for this Mac is marked.")
            TranscriptionSettings().frame(minHeight: 380)
        case 7:
            Text("Link each pupil to their LetsMeet room. Add initials or meeting names so recordings are matched automatically (for example “DT” for Daniel).")
            StudentsQuickSetup()
        case 8:
            Text("This is the default instruction given to the AI for every pupil. You can edit it now or later in Settings → Prompt, and give individual pupils their own prompt in Students.")
            PromptSettings().frame(minHeight: 380)
        default:
            Text("You're ready.").font(.title3)
            if model.setupIssues.isEmpty {
                Label("Everything is set up. New Zoom recordings will appear on the Dashboard and as notifications.", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
            } else {
                Text("Still to do (you can finish these later in Settings):")
                ForEach(model.setupIssues, id: \.self) { Label($0, systemImage: "circle") }
            }
            Text("Lesson Notes lives in the menu bar. To import older recordings use File → Import Folder….").foregroundStyle(.secondary)
        }
    }

    func finish() {
        model.updateSettings { $0.onboardingCompleted = true }
        dismiss()
    }
}

struct StudentsQuickSetup: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            let mapped = Set(model.mappings.map(\.roomId))
            ForEach(model.rooms.rooms) { room in
                HStack {
                    Text(room.name)
                    Spacer()
                    if let m = model.mappings.first(where: { $0.roomId == room.roomId }) {
                        Label(m.displayName + (m.code.isEmpty ? "" : " (\(m.code))"), systemImage: "checkmark").foregroundStyle(.green)
                    } else {
                        Button("Add Student") {
                            model.store.upsertMapping(StudentMapping(roomId: room.roomId, roomName: room.name, displayName: room.name))
                            model.reload()
                        }
                    }
                }
            }
            if model.rooms.rooms.isEmpty { Text("Load rooms first (step 3).").foregroundStyle(.secondary) }
            if !model.rooms.rooms.filter({ !mapped.contains($0.roomId) }).isEmpty {
                Text("After adding, edit names, initials and rules in the Students section.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
