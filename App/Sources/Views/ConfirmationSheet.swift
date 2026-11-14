import SwiftUI
import AppKit
import LessonNotesCore

/// Student option in pickers: a saved mapping, or a website room with no mapping yet.
struct StudentOption: Identifiable, Hashable {
    var id: String
    var title: String
    var roomId: String
    var roomName: String
    var mappingId: UUID?

    static func all(mappings: [StudentMapping], rooms: CachedRooms) -> [StudentOption] {
        var out: [StudentOption] = mappings.filter { $0.enabled && $0.roomExists(in: rooms) }.map {
            StudentOption(id: "m:\($0.id)", title: $0.displayName + " (\($0.currentRoomName(in: rooms)))", roomId: $0.roomId,
                          roomName: $0.currentRoomName(in: rooms), mappingId: $0.id)
        }
        let mapped = Set(mappings.map(\.roomId))
        out += rooms.rooms.filter { !mapped.contains($0.roomId) }.map {
            StudentOption(id: "r:\($0.roomId)", title: $0.name + " (room, no student mapping)", roomId: $0.roomId, roomName: $0.name, mappingId: nil)
        }
        return out
    }
}

struct RecordingRow: Identifiable {
    var id: String { rec.path }
    var rec: ScannedRecording
    var thumbnail: NSImage?
    var sha256: String?
    var hashError: String?
}

struct ConfirmationSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let request: ReviewRequest

    init(request: ReviewRequest) { self.request = request }

    @State private var rows: [RecordingRow] = []
    @State private var selection = Set<String>()
    @State private var studentId: String = ""
    @State private var lessonDate = Date()
    @State private var hasStartTime = false
    @State private var startTime = Date()
    @State private var mode: ProcessingMode?
    @State private var remember = true
    @State private var dateChecked = false
    @State private var error: String?
    @State private var duplicateMessage: String?
    @State private var allowDuplicates = false
    @State private var previewItem: RecordingRow?
    @State private var working = false
    @State private var suggestions: [StudentSuggestion] = []

    var session: ProposedSession { request.session }
    var tz: TimeZone { model.settings.timeZone }
    var options: [StudentOption] { StudentOption.all(mappings: model.mappings, rooms: model.rooms) }
    var selectedOption: StudentOption? { options.first { $0.id == studentId } }
    var selectedRows: [RecordingRow] { rows.filter { selection.contains($0.id) } }
    var effectiveMode: ProcessingMode? { selectedRows.count == 1 ? .single : mode }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Confirm lesson").font(.title2.weight(.semibold))
                    Text(session.topic).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding([.horizontal, .top], 20)

            Form {
                Section("Student") {
                    Picker("Pupil", selection: $studentId) {
                        Text("Choose a pupil…").tag("")
                        ForEach(options) { Text($0.title).tag($0.id) }
                    }
                    if let s = suggestions.first, options.contains(where: { $0.roomId == s.roomId }) {
                        Label("Suggested: \(s.displayName) — \(s.reason)", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Label("No automatic match. Choose the pupil; tick “Remember” to match it next time.", systemImage: "questionmark.circle")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Toggle("Remember this for next time (match meeting name “\(session.zoomInfo?.topic ?? session.topic)”)", isOn: $remember)
                    if options.isEmpty {
                        Text("No rooms loaded. Add your website key in Settings and refresh rooms.").foregroundStyle(.orange)
                    }
                }
                Section("Date") {
                    DatePicker("Lesson date", selection: $lessonDate, displayedComponents: .date)
                    Toggle("Start time known", isOn: $hasStartTime)
                    if hasStartTime { DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute) }
                    Text("Detected from: \(session.inferredDate.source.label) · time zone \(tz.identifier)").font(.caption).foregroundStyle(.secondary)
                    ForEach(session.inferredDate.notes, id: \.self) { Label($0, systemImage: "info.circle").font(.caption).foregroundStyle(.orange) }
                    if session.inferredDate.needsReview {
                        Toggle("I have checked the date", isOn: $dateChecked)
                    }
                }
                Section {
                    recordingsList
                    HStack {
                        Button("Select All") { selection = Set(rows.map(\.id)) }.keyboardShortcut("a", modifiers: .command)
                        Button("Select None") { selection = [] }
                        Spacer()
                        Text("\(selection.count) of \(rows.count) selected · drag to reorder").font(.caption).foregroundStyle(.secondary)
                    }
                    if !session.excludedAudioOnly.isEmpty {
                        Text("Zoom's separate audio-only file was left out because a video recording exists.").font(.caption).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Recordings")
                }
                if selectedRows.count > 1 {
                    Section("How should these recordings be processed?") {
                        Picker("Processing", selection: $mode) {
                            Text("Choose…").tag(ProcessingMode?.none)
                            Text("Combine into one set of notes").tag(ProcessingMode?.some(.combined))
                            Text("Process separately (one note each)").tag(ProcessingMode?.some(.separate))
                        }
                        .pickerStyle(.radioGroup)
                    }
                }
            }
            .formStyle(.grouped)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).padding(.horizontal, 20)
            }
            HStack {
                if working { ProgressView().controlSize(.small); Text("Checking recordings…").foregroundStyle(.secondary) }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(model.settings.autoProcessAfterConfirm ? "Confirm & Process" : "Confirm") { Task { await confirm() } }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canConfirm || working)
            }
            .padding(20)
        }
        .frame(width: 760, height: 760)
        .task { await load() }
        .sheet(item: $previewItem) { row in
            PreviewSheet(url: URL(fileURLWithPath: row.rec.path), title: row.rec.filename)
        }
        .alert("Already processed", isPresented: Binding(get: { duplicateMessage != nil }, set: { if !$0 { duplicateMessage = nil } })) {
            Button("Cancel", role: .cancel) { duplicateMessage = nil }
            Button("Reprocess Anyway") {
                allowDuplicates = true
                duplicateMessage = nil
                Task { await confirm() }
            }
        } message: {
            Text(duplicateMessage ?? "")
        }
        .environment(\.timeZone, tz)
    }

    var canConfirm: Bool {
        !studentId.isEmpty && !selection.isEmpty && effectiveMode != nil && (!session.inferredDate.needsReview || dateChecked)
    }

    var recordingsList: some View {
        List(selection: $selection) {
            ForEach(rows) { row in
                HStack(spacing: 10) {
                    Toggle("", isOn: Binding(get: { selection.contains(row.id) }, set: { on in
                        if on { selection.insert(row.id) } else { selection.remove(row.id) }
                    }))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityLabel("Include \(row.rec.filename)")
                    ZStack {
                        RoundedRectangle(cornerRadius: 4).fill(Color.black.opacity(0.8))
                        if let t = row.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
                        else { Image(systemName: row.rec.kind == .audioOnly ? "waveform" : "film").foregroundStyle(.white) }
                    }
                    .frame(width: 96, height: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.rec.filename).font(.body.weight(.medium))
                        Text(detail(row.rec)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { previewItem = row } label: { Image(systemName: "play.circle.fill").font(.title2) }
                        .buttonStyle(.borderless)
                        .help("Preview")
                        .accessibilityLabel("Preview \(row.rec.filename)")
                }
                .tag(row.id)
                .padding(.vertical, 2)
            }
            .onMove { from, to in rows.move(fromOffsets: from, toOffset: to) }
        }
        .frame(minHeight: 150, maxHeight: 260)
    }

    func detail(_ r: ScannedRecording) -> String {
        var parts: [String] = []
        if let t = r.recordingTimestamp { parts.append(t.formatted(date: .abbreviated, time: .shortened)) }
        if let d = r.durationSeconds { parts.append(CoreFormat.duration(Int(d))) }
        parts.append(r.fileSize.byteString)
        return parts.joined(separator: " · ")
    }

    func load() async {
        rows = session.recordings.map { RecordingRow(rec: $0) }
        if rows.count == 1 { selection = [rows[0].id] }
        let inferred = session.inferredDate
        if let d = CoreFormat.parseLessonDate(inferred.lessonDate, timeZone: tz) { lessonDate = d }
        if let s = inferred.startedAt { hasStartTime = true; startTime = s; lessonDate = s }
        suggestions = MappingMatcher.rank(MatchContext(session: session), mappings: model.mappings, rooms: model.rooms)
        if let best = suggestions.first {
            studentId = best.mappingId.map { "m:\($0)" } ?? "r:\(best.roomId)"
            if !options.contains(where: { $0.id == studentId }) { studentId = "" }
        }
        // Metadata, thumbnails and hashes in the background.
        for i in rows.indices {
            let url = URL(fileURLWithPath: rows[i].rec.path)
            if rows[i].rec.durationSeconds == nil {
                let info = await MediaInspector.inspect(url)
                rows[i].rec.durationSeconds = info.durationSeconds
                rows[i].rec.embeddedCreationDate = info.creationDate
            }
            rows[i].thumbnail = await MediaInspector.thumbnail(url)
        }
        for i in rows.indices where rows[i].sha256 == nil {
            let url = URL(fileURLWithPath: rows[i].rec.path)
            do {
                rows[i].sha256 = try await Task.detached(priority: .utility) { try SHA256Hasher.hexOfFile(at: url) }.value
            } catch {
                rows[i].hashError = error.localizedDescription
            }
        }
    }

    func confirm() async {
        error = nil
        guard let option = selectedOption, let mode = effectiveMode else { return }
        let chosen = rows.filter { selection.contains($0.id) }
        working = true
        defer { working = false }
        // Wait for hashes of the selected recordings (duplicate detection).
        for _ in 0..<600 where rows.filter({ selection.contains($0.id) }).contains(where: { $0.sha256 == nil && $0.hashError == nil }) {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let current = rows.filter { selection.contains($0.id) }
        if !allowDuplicates {
            var lines: [String] = []
            for r in current {
                guard let h = r.sha256 else { continue }
                for p in model.store.previousProcessing(sha256: h) {
                    lines.append("“\(r.rec.filename)” was processed on \(p.processedAt.formatted(date: .abbreviated, time: .omitted)) for \(p.pupilName) (status: \(p.status)).")
                }
            }
            if !lines.isEmpty {
                duplicateMessage = lines.joined(separator: "\n") + "\n\nReprocessing creates a separate note on the website."
                return
            }
        }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let dateString = CoreFormat.lessonDateString(lessonDate, timeZone: tz)
        var started: Date?
        if hasStartTime {
            let d = cal.dateComponents([.year, .month, .day], from: lessonDate)
            let t = cal.dateComponents([.hour, .minute, .second], from: startTime)
            started = cal.date(from: DateComponents(year: d.year, month: d.month, day: d.day, hour: t.hour, minute: t.minute, second: t.second))
        }
        let refs: [RecordingRef] = current.enumerated().map { i, r in
            let url = URL(fileURLWithPath: r.rec.path)
            return RecordingRef(filename: r.rec.filename, path: r.rec.path, bookmark: try? FolderAccess.bookmark(for: url),
                                durationSec: Int((r.rec.durationSeconds ?? 0).rounded()), recordedAt: r.rec.recordingTimestamp,
                                sha256: r.sha256, fileSize: r.rec.fileSize, order: i)
        }
        _ = chosen
        let source: DateSource = (session.inferredDate.needsReview || !hasStartTime && session.inferredDate.startedAt != nil) ? .manual : session.inferredDate.source
        let confirmation = LessonConfirmation(roomId: option.roomId, roomName: option.roomName, studentId: option.mappingId,
                                              pupilName: model.store.mapping(id: option.mappingId)?.displayName ?? option.roomName,
                                              lessonDate: dateString, startedAt: started, dateSource: source, mode: mode,
                                              meetingTopic: session.topic, sourceFolder: session.folderPath, recordings: refs)
        do {
            try model.confirm(confirmation, remember: remember ? MatchContext(session: session) : nil,
                              createMappingName: option.mappingId == nil ? option.roomName : nil)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
