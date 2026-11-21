import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LessonNotesCore

/// Student option in pickers: a saved mapping, or a website room with no mapping yet.
struct StudentOption: Identifiable, Hashable {
    var id: String
    var title: String
    var name: String
    var roomId: String
    var roomName: String
    var mappingId: UUID?

    static func all(mappings: [StudentMapping], rooms: CachedRooms) -> [StudentOption] {
        var out: [StudentOption] = mappings.filter { $0.enabled && $0.roomExists(in: rooms) }.map {
            StudentOption(id: "m:\($0.id)", title: $0.displayName + " (\($0.currentRoomName(in: rooms)))", name: $0.displayName,
                          roomId: $0.roomId, roomName: $0.currentRoomName(in: rooms), mappingId: $0.id)
        }
        let mapped = Set(mappings.map(\.roomId))
        out += rooms.rooms.filter { !mapped.contains($0.roomId) }.map {
            StudentOption(id: "r:\($0.roomId)", title: $0.name + " (room, no student mapping)", name: $0.name,
                          roomId: $0.roomId, roomName: $0.name, mappingId: nil)
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
    /// Dropped onto the Confirm screen rather than found in the Zoom folder.
    var addedByUser = false
}

/// Full-window screen for confirming one lesson: who and when, which recordings (in order,
/// with MP4s you can drop in), lesson files, and how to process them.
struct ConfirmationScreen: View {
    @EnvironmentObject var model: AppModel
    let request: ReviewRequest
    /// Set when shown as a sheet (historical import); otherwise the screen replaces the
    /// main window's content and closing returns to it.
    var onClose: (() -> Void)?

    init(request: ReviewRequest, onClose: (() -> Void)? = nil) {
        self.request = request
        self.onClose = onClose
    }

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
    @State private var files: [PendingAttachment] = []
    @State private var fileError: String?
    @State private var recordingError: String?
    @State private var draggingRow: String?
    @State private var recordingDropTargeted = false
    @State private var filesDropTargeted = false

    var session: ProposedSession { request.session }
    var tz: TimeZone { model.settings.timeZone }
    var options: [StudentOption] { StudentOption.all(mappings: model.mappings, rooms: model.rooms) }
    var selectedOption: StudentOption? { options.first { $0.id == studentId } }
    var selectedRows: [RecordingRow] { rows.filter { selection.contains($0.id) } }
    var effectiveMode: ProcessingMode? { selectedRows.count == 1 ? .single : mode }
    var pupilName: String? {
        guard let o = selectedOption else { return nil }
        return model.store.mapping(id: o.mappingId)?.displayName ?? o.name
    }

    @State private var showDatePicker = false
    @State private var showTimePicker = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backLink.appearIn(0)
                    hero.padding(.top, 10).appearIn(1)
                    HStack(alignment: .top, spacing: 40) {
                        recordingsSection.frame(maxWidth: .infinity, alignment: .topLeading).appearIn(2)
                        filesSection.frame(maxWidth: .infinity, alignment: .topLeading).appearIn(3)
                    }
                    .padding(.top, 28)
                }
                .padding(.horizontal, 34)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            actionBar
        }
        .navigationTitle("Confirm lesson")
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

    func close() {
        if let onClose { onClose(); return }
        withAnimation(Theme.spring) { model.reviewRequest = nil }
    }

    // MARK: Header

    var backLink: some View {
        Button { close() } label: {
            HStack(spacing: 5) {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                Text(onClose == nil ? "Dashboard" : "Back to import")
            }
            .font(.system(size: 13)).foregroundStyle(Theme.ink3)
        }
        .buttonStyle(.plain)
    }

    var heroGradient: LinearGradient {
        LinearGradient(colors: [Color(light: 0xF3E7D6, dark: 0x3A3226), Theme.sand, Theme.sageTint],
                       startPoint: .leading, endPoint: .trailing)
    }

    var hero: some View {
        ZStack(alignment: .leading) {
            heroGradient
            HillsArt(dark: colorScheme == .dark)
                .frame(width: 380)
                .mask(LinearGradient(colors: [.clear, .black, .black], startPoint: .leading, endPoint: .trailing))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
            VStack(alignment: .leading, spacing: 8) {
                Text(request.fromDetection ? "New lesson · Zoom has finished converting" : "New lesson")
                    .font(.system(size: 10.5, weight: .semibold)).tracking(1.6).textCase(.uppercase)
                    .foregroundStyle(Theme.sandInk)
                Text(pupilName.map { "Confirm \($0)'s lesson" } ?? "Confirm lesson")
                    .font(Theme.serif(34)).foregroundStyle(Theme.ink)
                HStack(spacing: 8) {
                    pupilChip
                    dateChip
                    timeChip
                }
                .padding(.top, 4)
                ForEach(session.inferredDate.notes, id: \.self) {
                    Label($0, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(Theme.sandInk)
                }
                if session.inferredDate.needsReview {
                    Toggle("I've checked the date", isOn: $dateChecked).toggleStyle(.checkbox).font(.system(size: 12.5))
                }
                if options.isEmpty {
                    Label("No rooms loaded. Add your website key in Settings and refresh rooms.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12)).foregroundStyle(Theme.clayInk)
                }
            }
            .padding(.horizontal, 26).padding(.vertical, 20)
        }
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    func chipBackground(_ tone: Theme.Tone) -> some View {
        Capsule().fill(Theme.raised.opacity(0.6))
            .overlay(Capsule().fill(tone.fill.opacity(0.55)))
            .overlay(Capsule().strokeBorder(tone.ink.opacity(0.22)))
    }

    var pupilChip: some View {
        HStack(spacing: 7) {
            if let name = pupilName { Avatar(name: name, size: 20) }
            Menu {
                if !suggestions.isEmpty {
                    Section("Suggested") {
                        ForEach(suggestions.prefix(3)) { s in
                            let id = s.mappingId.map { "m:\($0)" } ?? "r:\(s.roomId)"
                            Button("\(s.displayName) — \(s.reason)") { withAnimation(Theme.spring) { studentId = id } }
                        }
                    }
                }
                Section("All pupils") {
                    ForEach(options) { o in Button(o.title) { withAnimation(Theme.spring) { studentId = o.id } } }
                }
                Divider()
                Toggle("Remember for “\(session.zoomInfo?.topic ?? session.topic)”", isOn: $remember)
            } label: {
                Text(pupilName ?? "Choose a pupil")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .disabled(options.isEmpty)
        }
        .font(.system(size: 13, weight: .semibold))
        .padding(.leading, pupilName == nil ? 12 : 6).padding(.trailing, 10).padding(.vertical, 6)
        .background(chipBackground(.clay))
    }

    var dateChip: some View {
        Button { showDatePicker = true } label: {
            HStack(spacing: 6) {
                Text(lessonDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(chipBackground(.sand))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showDatePicker, arrowEdge: .bottom) {
            DatePicker("Lesson date", selection: $lessonDate, displayedComponents: .date)
                .datePickerStyle(.graphical).labelsHidden().padding(14)
        }
    }

    var timeChip: some View {
        Button { showTimePicker = true } label: {
            HStack(spacing: 6) {
                Text(hasStartTime ? startTime.formatted(date: .omitted, time: .shortened) : "Add start time")
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.ink3)
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(hasStartTime ? Theme.ink : Theme.ink2)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(chipBackground(.lavender))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showTimePicker, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Start time known", isOn: $hasStartTime.animation(Theme.spring)).toggleStyle(.checkbox)
                if hasStartTime {
                    DatePicker("Start time", selection: $startTime, displayedComponents: .hourAndMinute)
                        .datePickerStyle(.field)
                }
            }
            .padding(14)
            .frame(width: 220, alignment: .leading)
        }
    }

    func sectionHeader(_ title: String, icon: String, tone: Theme.Tone) -> some View {
        HStack(spacing: 10) {
            IconBadge(systemName: icon, tone: tone, size: 30)
            Text(title).font(Theme.serif(21)).foregroundStyle(Theme.ink)
        }
    }

    // MARK: Recordings

    var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("Recordings", icon: "video", tone: .sand)
                Spacer()
                if selectedRows.count > 1 { ModeSwitch(mode: $mode).transition(.opacity) }
            }
            .padding(.bottom, 6)
            ForEach(rows) { row in
                VStack(spacing: 0) {
                    recordingRow(row)
                    Divider().overlay(Theme.line2)
                }
                .transition(.asymmetric(insertion: .scale(scale: 0.97).combined(with: .opacity), removal: .opacity))
                .onDrag {
                    draggingRow = row.id
                    return NSItemProvider(object: row.id as NSString)
                }
                .onDrop(of: [UTType.plainText], delegate: RecordingReorderDelegate(target: row.id, rows: $rows, dragging: $draggingRow))
            }
            addLine(recordingDropTargeted ? "Release to add as Part \(selectedRows.count + 1)" : "Add a recording — or drop an MP4 here",
                    tone: .sand, active: recordingDropTargeted) { addRecordings(chooseRecordings()) }
            if let recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.clayInk)
            }
            if !session.excludedAudioOnly.isEmpty {
                Text("Zoom's separate audio-only file was left out because a video recording exists.")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.sand.opacity(recordingDropTargeted ? 0.6 : 0)))
        .padding(-12)
        .onDrop(of: [UTType.fileURL], isTargeted: $recordingDropTargeted.animation(Theme.spring)) { providers in
            loadURLs(providers) { addRecordings($0) }
            return true
        }
        .animation(Theme.spring, value: rows.map(\.id))
        .animation(Theme.spring, value: selectedRows.count > 1)
    }

    static let partTones: [Theme.Tone] = [.sage, .sand, .clay, .lavender]

    func recordingRow(_ row: RecordingRow) -> some View {
        let included = selection.contains(row.id)
        let part = selectedRows.firstIndex { $0.id == row.id }
        return HStack(spacing: 13) {
            if rows.count > 1 {
                Toggle("", isOn: Binding(get: { included }, set: { on in
                    withAnimation(Theme.spring) { if on { selection.insert(row.id) } else { selection.remove(row.id) } }
                }))
                .toggleStyle(.checkbox).labelsHidden()
                .help(included ? "Included — untick to leave this recording out" : "Left out — tick to include")
                .accessibilityLabel("Include \(row.rec.filename)")
            }
            Button { previewItem = row } label: { thumbnail(row) }
                .buttonStyle(.plain)
                .help("Preview")
                .accessibilityLabel("Preview \(row.rec.filename)")
            VStack(alignment: .leading, spacing: 2) {
                Text(row.rec.filename).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(rowDetail(row)).font(.system(size: 12)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 6)
            if let part, selectedRows.count > 1 {
                Pill(text: "Part \(part + 1)", tone: Self.partTones[part % Self.partTones.count]).fixedSize()
            }
            if row.addedByUser {
                Button { removeRecording(row) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
                    .help("Remove this recording").accessibilityLabel("Remove \(row.rec.filename)")
            }
        }
        .padding(.vertical, 12)
        .opacity(included ? 1 : 0.5)
        .contentShape(Rectangle())
    }

    func thumbnail(_ row: RecordingRow) -> some View {
        ZStack {
            if let t = row.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
            else { HillsArt(sun: row.addedByUser).opacity(0.75) }
            Image(systemName: "play.fill").font(.system(size: 10)).foregroundStyle(.white)
                .shadow(color: .black.opacity(0.3), radius: 3)
            if let d = row.rec.durationSeconds {
                Text(CoreFormat.duration(Int(d)))
                    .font(.system(size: 9, weight: .semibold)).foregroundStyle(.white)
                    .padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45)))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(3)
            }
        }
        .frame(width: 62, height: 40)
        .background(Color(nsColor: NSColor(hex: 0x2B2E2B)))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 2)
    }

    /// Quiet "+" line that adds something (and lights up while a drop is over its section).
    func addLine(_ text: String, tone: Theme.Tone, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: active ? "arrow.down" : "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(tone.ink)
                    .frame(width: 26, height: 26)
                    .overlay(Circle().strokeBorder(tone.ink.opacity(0.6), style: StrokeStyle(lineWidth: 1.4, dash: active ? [] : [3, 3])))
                Text(text).font(.system(size: 13, weight: active ? .semibold : .regular)).foregroundStyle(active ? tone.ink : Theme.ink2)
            }
            .padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Lesson files

    var filesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                sectionHeader("Lesson files", icon: "paperclip", tone: .lavender)
                Spacer()
                Text("Optional").font(.system(size: 12)).foregroundStyle(Theme.ink3)
            }
            .padding(.bottom, 6)
            if files.isEmpty {
                emptyFiles.padding(.top, 8)
            } else {
                ForEach($files) { $f in
                    VStack(spacing: 0) {
                        FileRow(file: $f) { withAnimation(Theme.spring) { files.removeAll { $0.id == f.id } } }
                        Divider().overlay(Theme.line2)
                    }
                    .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity))
                }
                if files.count < LibraryStore.maxStoredFiles {
                    addLine(filesDropTargeted ? "Release to add" : "Add files — or drop them here", tone: .lavender, active: filesDropTargeted) {
                        withAnimation(Theme.spring) { addFiles(AttachmentPicker.choose()) }
                    }
                }
            }
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.clayInk)
            }
            if effectiveMode == .separate && !files.isEmpty {
                Text("With separate processing, the files are added to every part.").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Theme.lavender.opacity(filesDropTargeted ? 0.6 : 0)))
        .padding(-12)
        .onDrop(of: [UTType.fileURL], isTargeted: $filesDropTargeted.animation(Theme.spring)) { providers in
            loadURLs(providers) { urls in
                // Recordings dropped here go to the recordings list instead.
                let media = urls.filter { RecordingFileKind.classify($0.lastPathComponent).isMedia }
                if !media.isEmpty { addRecordings(media) }
                let docs = urls.filter { !RecordingFileKind.classify($0.lastPathComponent).isMedia }
                if !docs.isEmpty { withAnimation(Theme.spring) { addFiles(docs) } }
            }
            return true
        }
        .animation(Theme.spring, value: files.map(\.id))
    }

    var emptyFiles: some View {
        VStack(spacing: 10) {
            Image(systemName: filesDropTargeted ? "arrow.down" : "doc.on.doc")
                .font(.system(size: 20)).foregroundStyle(Theme.lavInk)
                .frame(width: 48, height: 48)
                .background(Circle().fill(Theme.lavender))
                .scaleEffect(filesDropTargeted ? 1.08 : 1)
            Text(filesDropTargeted ? "Release to add" : "Drop slides, pupil work or model answers here")
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).multilineTextAlignment(.center)
            Text("The AI uses them for better notes; the pupil can download them once you approve.")
                .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).multilineTextAlignment(.center).frame(maxWidth: 300)
            Button { withAnimation(Theme.spring) { addFiles(AttachmentPicker.choose()) } } label: { Label("Choose files…", systemImage: "plus") }
                .buttonStyle(.softCompact)
                .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22).padding(.horizontal, 16)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.lavender.opacity(0.25)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(Theme.lavInk.opacity(0.35), style: StrokeStyle(lineWidth: 1.4, dash: [6, 5])))
    }

    // MARK: Action bar

    var actionBar: some View {
        HStack(spacing: 12) {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.clayInk).lineLimit(2)
            } else {
                Text(summaryLine).font(.system(size: 13)).foregroundStyle(confirmHint == nil ? Theme.ink2 : Theme.sandInk).lineLimit(1)
            }
            Spacer()
            if working {
                ProgressView().controlSize(.small)
                Text("Checking recordings…").font(.system(size: 12)).foregroundStyle(Theme.ink2)
            }
            Button("Cancel") { close() }
                .buttonStyle(.soft)
                .keyboardShortcut(.cancelAction)
            Button { Task { await confirm() } } label: {
                HStack(spacing: 8) {
                    Text(model.settings.autoProcessAfterConfirm ? "Confirm & process" : "Confirm")
                    Image(systemName: "arrow.right")
                }
                .fixedSize()
            }
            .buttonStyle(.primaryLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm || working)
            .help(confirmHint ?? "")
        }
        .padding(.horizontal, 34).padding(.vertical, 16)
        .background(LinearGradient(colors: [Theme.sand.opacity(0.45), Theme.bg], startPoint: .leading, endPoint: .trailing))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line2).frame(height: 1) }
    }

    var summaryLine: String {
        if let hint = confirmHint { return hint }
        let n = selectedRows.count
        let how: String = mode == .separate ? "kept separate" : "combined"
        var s: String = "1 recording"
        if n != 1 { s = "\(n) recordings " + how }
        let total = selectedRows.compactMap(\.rec.durationSeconds).reduce(0, +)
        if total > 0 { s += " · \(Int((total / 60).rounded())) min" }
        s += files.isEmpty ? " · no files" : " · \(files.count) file\(files.count == 1 ? "" : "s")"
        return s
    }

    var confirmHint: String? {
        if studentId.isEmpty { return "Choose the pupil first" }
        if selection.isEmpty { return "Include at least one recording" }
        if effectiveMode == nil { return "Choose Combine or Separate for the recordings" }
        if session.inferredDate.needsReview && !dateChecked { return "Tick “I've checked the date”" }
        return nil
    }

    var canConfirm: Bool { confirmHint == nil }

    // MARK: Data

    func rowDetail(_ row: RecordingRow) -> String {
        let prefix: String = row.addedByUser ? "Added by you · " : ""
        return prefix + detail(row.rec)
    }

    func detail(_ r: ScannedRecording) -> String {
        var parts: [String] = []
        if let t = r.recordingTimestamp { parts.append(t.formatted(date: .omitted, time: .shortened)) }
        else if r.durationSeconds == nil { parts.append("Reading…") }
        parts.append(r.fileSize.byteString)
        return parts.joined(separator: " · ")
    }

    func load() async {
        rows = session.recordings.map { RecordingRow(rec: $0) }
        selection = Set(rows.map(\.id))
        let inferred = session.inferredDate
        if let d = CoreFormat.parseLessonDate(inferred.lessonDate, timeZone: tz) { lessonDate = d }
        if let s = inferred.startedAt { hasStartTime = true; startTime = s; lessonDate = s }
        suggestions = MappingMatcher.rank(MatchContext(session: session), mappings: model.mappings, rooms: model.rooms)
        if DemoData.mode == "mp4" {
            rows.append(RecordingRow(rec: ScannedRecording(path: NSTemporaryDirectory() + "Phone recording.mp4", fileSize: 88_000_000, durationSeconds: 401),
                                     addedByUser: true))
        }
        if DemoData.mode == "files" || DemoData.mode == "mp4" {
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            files = [PendingAttachment(url: tmp, filename: "macOS Preview Storm extract.pdf", byteCount: 563_000, role: .slides),
                     PendingAttachment(url: tmp, filename: "Daniel's paragraph.jpg", byteCount: 1_200_000, role: .studentWork),
                     PendingAttachment(url: tmp, filename: "Model answer.docx", byteCount: 41_000, role: .exemplar, includeInContext: true, shareWithPupil: false)]
            selection = Set(rows.map(\.id))
            mode = .combined
        }
        if let best = suggestions.first {
            studentId = best.mappingId.map { "m:\($0)" } ?? "r:\(best.roomId)"
            if !options.contains(where: { $0.id == studentId }) { studentId = "" }
        }
        for i in rows.indices { await inspect(rows[i].id) }
    }

    /// Duration, thumbnail and hash for one recording, in the background.
    func inspect(_ id: String) async {
        guard let i = rows.firstIndex(where: { $0.id == id }) else { return }
        let url = URL(fileURLWithPath: rows[i].rec.path)
        if rows[i].rec.durationSeconds == nil {
            let info = await MediaInspector.inspect(url)
            if let j = rows.firstIndex(where: { $0.id == id }) {
                rows[j].rec.durationSeconds = info.durationSeconds
                rows[j].rec.embeddedCreationDate = info.creationDate
            }
        }
        let thumb = await MediaInspector.thumbnail(url)
        if let j = rows.firstIndex(where: { $0.id == id }) { withAnimation(Theme.gentle) { rows[j].thumbnail = thumb } }
        guard rows.first(where: { $0.id == id })?.sha256 == nil else { return }
        do {
            let h = try await Task.detached(priority: .utility) { try SHA256Hasher.hexOfFile(at: url) }.value
            if let j = rows.firstIndex(where: { $0.id == id }) { rows[j].sha256 = h }
        } catch {
            if let j = rows.firstIndex(where: { $0.id == id }) { rows[j].hashError = error.localizedDescription }
        }
    }

    func chooseRecordings() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add a recording"
        panel.message = "Choose MP4 or M4A recordings to add to this lesson. They are read from where they are."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType.mpeg4Movie, UTType.mpeg4Audio]
        return panel.runModal() == .OK ? panel.urls : []
    }

    func addRecordings(_ urls: [URL]) {
        recordingError = nil
        var skipped: [String] = []
        var added: [String] = []
        for url in urls {
            guard RecordingFileKind.classify(url.lastPathComponent).isMedia else { skipped.append(url.lastPathComponent); continue }
            guard !rows.contains(where: { $0.id == url.path }) else { continue }
            let found = (try? FolderScanner.scan(roots: [url]))?.recordings.first
            guard let rec = found else { skipped.append(url.lastPathComponent); continue }
            withAnimation(Theme.spring) {
                rows.append(RecordingRow(rec: rec, addedByUser: true))
                selection.insert(rec.id)
            }
            added.append(rec.id)
        }
        if mode == nil && selectedRows.count > 1 && !added.isEmpty { mode = .combined }
        if !skipped.isEmpty {
            recordingError = "Only MP4 and M4A recordings can be added: " + skipped.joined(separator: ", ")
        }
        for id in added { Task { await inspect(id) } }
    }

    func removeRecording(_ row: RecordingRow) {
        withAnimation(Theme.spring) {
            rows.removeAll { $0.id == row.id }
            selection.remove(row.id)
        }
    }

    func loadURLs(_ providers: [NSItemProvider], then handle: @escaping ([URL]) -> Void) {
        let group = DispatchGroup()
        let box = DroppedURLs()
        for p in providers where p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { box.add(url) }
                group.leave()
            }
        }
        group.notify(queue: .main) { handle(box.all) }
    }

    func addFiles(_ urls: [URL]) {
        fileError = nil
        var problems: [String] = []
        for u in urls {
            guard files.count < LibraryStore.maxStoredFiles else { problems.append(AttachmentRules.Problem.tooMany.localizedDescription); break }
            let name = AttachmentRules.storedFilename(u.lastPathComponent, pdfPreviewPrefix: model.settings.pdfPreviewPrefix)
            let size = AttachmentPicker.size(u)
            if let p = AttachmentRules.check(filename: name, byteCount: size) { problems.append(p.localizedDescription); continue }
            files.append(PendingAttachment(url: u, filename: name, byteCount: size, role: AttachmentPicker.guessRole(name)))
        }
        if !problems.isEmpty { fileError = problems.joined(separator: " ") }
    }

    func confirm() async {
        error = nil
        guard let option = selectedOption, let mode = effectiveMode else { return }
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
        let source: DateSource = (session.inferredDate.needsReview || !hasStartTime && session.inferredDate.startedAt != nil) ? .manual : session.inferredDate.source
        let name = model.store.mapping(id: option.mappingId)?.displayName ?? option.roomName
        let confirmation = LessonConfirmation(roomId: option.roomId, roomName: option.roomName, studentId: option.mappingId,
                                              pupilName: name,
                                              lessonDate: dateString, startedAt: started, dateSource: source, mode: mode,
                                              meetingTopic: session.topic, sourceFolder: session.folderPath, recordings: refs)
        do {
            let lesson = try model.confirm(confirmation, remember: remember ? MatchContext(session: session) : nil,
                                           createMappingName: option.mappingId == nil ? option.roomName : nil)
            if !files.isEmpty {
                let failures = await model.attach(files, to: lesson)
                if !failures.isEmpty { model.banner = "Some lesson files could not be added: " + failures.joined(separator: " ") }
            }
            if let onClose { onClose() }
            withAnimation(Theme.spring) {
                if onClose == nil {
                    model.reviewRequest = nil
                    model.sidebar = .dashboard
                }
                model.toast = Toast(title: "\(name)'s lesson is on its way",
                                    detail: model.settings.autoProcessAfterConfirm
                                        ? "Transcribing on this Mac, then notes, then LetsMeet. Nothing else to do."
                                        : "It's ready to start on the Dashboard whenever you are.",
                                    lessonId: lesson.id)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Collects URLs from drop callbacks, which may arrive on any thread.
final class DroppedURLs: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.lock(); urls.append(url); lock.unlock() }
    var all: [URL] { lock.lock(); defer { lock.unlock() }; return urls }
}

/// Live reordering while a recording row is dragged over another.
struct RecordingReorderDelegate: DropDelegate {
    let target: String
    @Binding var rows: [RecordingRow]
    @Binding var dragging: String?

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let d = dragging, d != target,
              let from = rows.firstIndex(where: { $0.id == d }),
              let to = rows.firstIndex(where: { $0.id == target }) else { return }
        withAnimation(Theme.spring) {
            rows.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}

/// Combine / Separate, as a small sliding switch beside the Recordings heading.
struct ModeSwitch: View {
    @Binding var mode: ProcessingMode?
    @Namespace private var space

    var body: some View {
        HStack(spacing: 0) {
            option(.combined, "Combine")
            option(.separate, "Separate")
        }
        .padding(3)
        .background(Capsule().fill(Theme.line2))
    }

    func option(_ m: ProcessingMode, _ title: String) -> some View {
        let on = mode == m
        return Button { withAnimation(Theme.spring) { mode = m } } label: {
            Text(title)
                .font(.system(size: 12, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? Theme.ink : Theme.ink2)
                .padding(.horizontal, 12).padding(.vertical, 5)
                .background {
                    if on {
                        Capsule().fill(Theme.raised)
                            .shadow(color: .black.opacity(0.08), radius: 1.5, y: 1)
                            .matchedGeometryEffect(id: "mode", in: space)
                    }
                }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(m == .combined ? "One set of notes and one joined video" : "A note and a video for each recording")
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// One lesson file: what it is, and who gets it — no box, just a calm row.
struct FileRow: View {
    @Binding var file: PendingAttachment
    var onRemove: () -> Void

    var ext: String { (file.filename as NSString).pathExtension.uppercased() }
    var tone: Theme.Tone {
        switch ext {
        case "PDF": return .sage
        case "JPG", "JPEG", "PNG", "HEIC", "GIF", "WEBP": return .lavender
        case "DOC", "DOCX", "TXT", "RTF", "MD": return .sand
        case "PPT", "PPTX", "KEY": return .clay
        default: return .neutral
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 13) {
                Text(ext.isEmpty ? "FILE" : String(ext.prefix(4)))
                    .font(.system(size: 9, weight: .bold)).foregroundStyle(tone.ink)
                    .frame(width: 34, height: 40)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.fill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).help(file.filename)
                    Text(Int64(file.byteCount).formatted(.byteCount(style: .file))).font(.system(size: 12)).foregroundStyle(Theme.ink3)
                }
                .layoutPriority(1)
                Spacer(minLength: 4)
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
                    .help("Remove this file").accessibilityLabel("Remove \(file.filename)")
            }
            FlowPills(spacing: 14) {
                RoleMenu(role: $file.role)
                    .disabled(!file.includeInContext)
                    .opacity(file.includeInContext ? 1 : 0.5)
                    .help("What this file is, so the AI uses it properly")
                SmallSwitch(isOn: $file.includeInContext, title: "AI reads it")
                    .help("Off: OpenAI never sees this file")
                SmallSwitch(isOn: $file.shareWithPupil, title: "Pupil gets it")
                    .help("Off: the file stays on this Mac and is not uploaded to LetsMeet")
            }
            .padding(.leading, 47)
            if let note = statusNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.ink3).padding(.leading, 47)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 14)
        .animation(Theme.spring, value: file.includeInContext)
        .animation(Theme.spring, value: file.shareWithPupil)
    }

    var statusNote: String? {
        switch (file.includeInContext, file.shareWithPupil) {
        case (true, true): return nil
        case (true, false): return "Used by OpenAI only — kept on this Mac, not uploaded for the pupil."
        case (false, true): return "Uploaded for the pupil only — not sent to OpenAI."
        case (false, false): return "Not used: neither sent to OpenAI nor uploaded."
        }
    }
}

/// "Slides ⌄" — a colour-coded pill that opens the list of roles.
struct RoleMenu: View {
    @Binding var role: AttachmentRole

    static func shortLabel(_ r: AttachmentRole) -> String {
        switch r {
        case .slides: return "Slides"
        case .studentWork: return "Student work"
        case .exemplar: return "My work"
        case .other: return "Other"
        }
    }

    static func tone(_ r: AttachmentRole) -> Theme.Tone {
        switch r {
        case .slides: return .sage
        case .studentWork: return .lavender
        case .exemplar: return .sand
        case .other: return .neutral
        }
    }

    var body: some View {
        let tone = Self.tone(role)
        Menu {
            ForEach(AttachmentRole.allCases) { r in
                Button(r.label) { withAnimation(Theme.spring) { role = r } }
            }
        } label: {
            Text(Self.shortLabel(role))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .font(.system(size: 12.5, weight: .semibold))
        .foregroundStyle(tone.ink)
        .tint(tone.ink)
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Capsule().fill(tone.fill))
    }
}

/// A small switch with a label beside it.
struct SmallSwitch: View {
    @Binding var isOn: Bool
    var title: String
    var body: some View {
        Button { withAnimation(Theme.spring) { isOn.toggle() } } label: {
            HStack(spacing: 7) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.sage : Theme.ink3.opacity(0.35)).frame(width: 27, height: 16)
                    Circle().fill(.white).frame(width: 12, height: 12).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
                Text(title).font(.system(size: 12.5)).foregroundStyle(isOn ? Theme.ink : Theme.ink3)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}
