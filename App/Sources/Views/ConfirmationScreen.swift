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

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    topBar.appearIn(0)
                    ScreenTitle(title: pupilName.map { "Confirm \($0)'s lesson" } ?? "Confirm lesson",
                                subtitle: "Check the details, add any lesson files, then the app does the rest — transcribe, write the notes and send them to LetsMeet.")
                        .appearIn(1)
                    HStack(alignment: .top, spacing: 16) {
                        VStack(spacing: 16) {
                            whoCard.appearIn(2)
                            recordingsCard.appearIn(3)
                        }
                        .frame(maxWidth: .infinity)
                        filesCard
                            .frame(maxWidth: .infinity)
                            .appearIn(4)
                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 18)
                .padding(.bottom, 20)
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

    // MARK: Top

    var topBar: some View {
        HStack(spacing: 8) {
            Button { close() } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                    Text("Dashboard")
                }
                .font(.system(size: 13)).foregroundStyle(Theme.ink2)
            }
            .buttonStyle(.plain)
            Text("/ New lesson").font(.system(size: 13)).foregroundStyle(Theme.ink3)
            Spacer()
            if request.fromDetection { Pill(text: "Zoom has finished converting", tone: .sage, dot: true) }
        }
    }

    // MARK: Who and when

    /// Pupil cards: the suggestions first, then whoever is currently chosen.
    var pupilCards: [StudentOption] {
        var out: [StudentOption] = []
        for s in suggestions {
            let id = s.mappingId.map { "m:\($0)" } ?? "r:\(s.roomId)"
            if let o = options.first(where: { $0.id == id }), !out.contains(o) { out.append(o) }
            if out.count == 2 { break }
        }
        if let sel = selectedOption, !out.contains(sel) {
            if out.count == 2 { out[1] = sel } else { out.append(sel) }
        }
        return out
    }

    var whoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Who and when").eyebrow()
            HStack(spacing: 9) {
                ForEach(pupilCards) { o in pupilCard(o) }
                Menu {
                    ForEach(options) { o in Button(o.title) { withAnimation(Theme.spring) { studentId = o.id } } }
                } label: {
                    Text(pupilCards.isEmpty ? "Choose a pupil…" : "Other…")
                        .font(.system(size: 12.5)).foregroundStyle(Theme.ink2)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(Theme.raised.opacity(0.6)))
                .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(Theme.line, lineWidth: 1.5))
                .frame(maxWidth: pupilCards.isEmpty ? .infinity : 130)
                .disabled(options.isEmpty)
            }
            if options.isEmpty {
                Label("No rooms loaded. Add your website key in Settings and refresh rooms.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(Theme.clayInk)
            }
            HStack(spacing: 9) {
                field("Date") {
                    DatePicker("", selection: $lessonDate, displayedComponents: .date).labelsHidden().datePickerStyle(.field)
                }
                field("Started") {
                    HStack(spacing: 6) {
                        if hasStartTime {
                            DatePicker("", selection: $startTime, displayedComponents: .hourAndMinute).labelsHidden().datePickerStyle(.field)
                        }
                        Toggle(hasStartTime ? "" : "Known", isOn: $hasStartTime.animation(Theme.spring))
                            .toggleStyle(.checkbox).font(.system(size: 12))
                    }
                }
                .frame(maxWidth: 190)
                field("From") {
                    Text(session.inferredDate.source.label).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink).lineLimit(1)
                }
            }
            ForEach(session.inferredDate.notes, id: \.self) {
                Label($0, systemImage: "info.circle").font(.system(size: 11.5)).foregroundStyle(Theme.sandInk)
            }
            if session.inferredDate.needsReview {
                Toggle("I have checked the date", isOn: $dateChecked).toggleStyle(.checkbox).font(.system(size: 12.5))
            }
            Toggle("Remember this pupil for “\(session.zoomInfo?.topic ?? session.topic)”", isOn: $remember)
                .toggleStyle(.checkbox).font(.system(size: 12)).foregroundStyle(Theme.ink2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
    }

    func pupilCard(_ o: StudentOption) -> some View {
        let on = o.id == studentId
        let suggestion = suggestions.first { ($0.mappingId.map { "m:\($0)" } ?? "r:\($0.roomId)") == o.id }
        return Button { withAnimation(Theme.spring) { studentId = o.id } } label: {
            HStack(spacing: 9) {
                Avatar(name: o.name, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(o.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink).lineLimit(1)
                    Text(suggestion.map { "Suggested · " + $0.reason } ?? o.roomName)
                        .font(.system(size: 11)).foregroundStyle(Theme.ink3).lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(on ? Theme.raised : Theme.raised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(on ? Theme.forest : Theme.line, lineWidth: 1.5))
            .shadow(color: Theme.forest.opacity(on ? 0.12 : 0), radius: 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    func field<C: View>(_ label: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Theme.ink3)
            content()
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.raised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.line2))
    }

    // MARK: Recordings

    var recordingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(rows.count > 1 ? "Recordings · drag to reorder" : "Recordings").eyebrow()
                Spacer()
                if rows.count > 1 {
                    Text("\(selection.count) of \(rows.count) included").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                }
            }
            VStack(spacing: 8) {
                ForEach(rows) { row in
                    recordingRow(row)
                        .transition(.asymmetric(insertion: .scale(scale: 0.96).combined(with: .opacity), removal: .opacity))
                        .onDrag {
                            draggingRow = row.id
                            return NSItemProvider(object: row.id as NSString)
                        }
                        .onDrop(of: [UTType.plainText], delegate: RecordingReorderDelegate(target: row.id, rows: $rows, dragging: $draggingRow))
                }
            }
            addRecordingZone
            if let recordingError {
                Label(recordingError, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.clayInk)
            }
            if !session.excludedAudioOnly.isEmpty {
                Text("Zoom's separate audio-only file was left out because a video recording exists.")
                    .font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
            if selectedRows.count > 1 {
                HStack(spacing: 9) {
                    modeCard(.combined, title: "Combine into one lesson", detail: "One set of notes, one joined video.")
                    modeCard(.separate, title: "Keep separate", detail: "A note and a video for each.")
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
            .strokeBorder(Theme.forest.opacity(recordingDropTargeted ? 0.35 : 0), lineWidth: 3))
        .onDrop(of: [UTType.fileURL], isTargeted: $recordingDropTargeted.animation(Theme.spring)) { providers in
            loadURLs(providers) { addRecordings($0) }
            return true
        }
        .animation(Theme.spring, value: rows.map(\.id))
        .animation(Theme.spring, value: selectedRows.count > 1)
    }

    func recordingRow(_ row: RecordingRow) -> some View {
        let included = selection.contains(row.id)
        let part = selectedRows.firstIndex { $0.id == row.id }.map { $0 + 1 }
        return HStack(spacing: 11) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(Theme.ink3)
                .help("Drag to reorder")
            Toggle("", isOn: Binding(get: { included }, set: { on in
                withAnimation(Theme.spring) { if on { selection.insert(row.id) } else { selection.remove(row.id) } }
            }))
            .toggleStyle(.checkbox).labelsHidden()
            .accessibilityLabel("Include \(row.rec.filename)")
            Button { previewItem = row } label: {
                ZStack {
                    if let t = row.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fill) }
                    else { HillsArt(sun: false).opacity(0.7) }
                    Image(systemName: "play.fill").font(.system(size: 12)).foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.3), radius: 3)
                    if let d = row.rec.durationSeconds {
                        Text(CoreFormat.duration(Int(d)))
                            .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(.black.opacity(0.45)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(4)
                    }
                }
                .frame(width: 84, height: 50)
                .background(Color(nsColor: NSColor(hex: 0x2B2E2B)))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .help("Preview")
            .accessibilityLabel("Preview \(row.rec.filename)")
            VStack(alignment: .leading, spacing: 2) {
                Text(row.rec.filename).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.middle)
                Text(rowDetail(row))
                    .font(.system(size: 11.5)).foregroundStyle(Theme.ink3).lineLimit(1)
            }
            Spacer(minLength: 4)
            if let part, selectedRows.count > 1 {
                Pill(text: "Part \(part)", tone: row.addedByUser ? .sage : .neutral)
            }
            if row.addedByUser {
                Button { removeRecording(row) } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
                    .help("Remove this recording").accessibilityLabel("Remove \(row.rec.filename)")
            }
        }
        .padding(9)
        .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(row.addedByUser ? Theme.sageTint.opacity(0.5) : Theme.raised.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(row.addedByUser ? Theme.sage.opacity(0.6) : Theme.line2))
        .opacity(included ? 1 : 0.55)
    }

    var addRecordingZone: some View {
        Button { addRecordings(chooseRecordings()) } label: {
            HStack(spacing: 10) {
                Image(systemName: recordingDropTargeted ? "play.rectangle" : "plus")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.sageInk)
                    .frame(width: 28, height: 28)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(recordingDropTargeted ? Theme.raised : Theme.sageTint))
                if recordingDropTargeted {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Release to add as Part \(selectedRows.count + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.forest)
                        Text("Read from where it is. Nothing is moved.").font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
                    }
                } else {
                    addRecordingLabel.font(.system(size: 12.5))
                }
                Spacer()
                if !recordingDropTargeted { Text("MP4 · M4A").font(.system(size: 11)).foregroundStyle(Theme.ink3) }
            }
            .padding(.horizontal, 12).padding(.vertical, recordingDropTargeted ? 14 : 9)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(recordingDropTargeted ? Theme.sageTint : Color.clear))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(recordingDropTargeted ? Theme.forest : Theme.sage.opacity(0.7),
                              style: dropStroke(recordingDropTargeted)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add a recording")
    }

    /// Dashed outline for a drop zone; solid while something is dragged over it.
    func dropStroke(_ active: Bool) -> StrokeStyle {
        let dash: [CGFloat] = active ? [] : [6, 5]
        return StrokeStyle(lineWidth: 1.5, dash: dash)
    }

    var addRecordingLabel: Text {
        let a: Text = Text("Add a recording").fontWeight(.semibold).foregroundColor(Theme.ink)
        let b: Text = Text(" · drop an MP4 here, or ").foregroundColor(Theme.ink2)
        let c: Text = Text("choose…").underline().foregroundColor(Theme.ink2)
        return a + b + c
    }

    func modeCard(_ m: ProcessingMode, title: String, detail: String) -> some View {
        let on = mode == m
        return Button { withAnimation(Theme.spring) { mode = m } } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Circle().strokeBorder(on ? Theme.forest : Theme.ink3, lineWidth: on ? 5 : 1.5).frame(width: 16, height: 16)
                    Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                }
                Text(detail).font(.system(size: 11.5)).foregroundStyle(Theme.ink2)
            }
            .padding(.horizontal, 13).padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 15, style: .continuous).fill(on ? Theme.sageTint.opacity(0.6) : Theme.raised.opacity(0.6)))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).strokeBorder(on ? Theme.forest : Theme.line, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    // MARK: Lesson files

    var filesCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 11) {
                IconBadge(systemName: "paperclip", tone: .sage, size: 36)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lesson files").font(Theme.serif(20)).foregroundStyle(Theme.ink)
                    Text("Optional · slides, pupil work, your model answers").font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                Spacer()
                if !files.isEmpty { Pill(text: "\(files.count) added", tone: .sage).transition(.scale.combined(with: .opacity)) }
            }
            if files.isEmpty {
                bigDropZone
            } else {
                ForEach($files) { $f in
                    FileCard(file: $f) { withAnimation(Theme.spring) { files.removeAll { $0.id == f.id } } }
                        .transition(.asymmetric(insertion: .move(edge: .top).combined(with: .opacity), removal: .opacity.combined(with: .scale(scale: 0.95))))
                }
                if files.count < LibraryStore.maxStoredFiles { smallDropZone }
            }
            if let fileError {
                Label(fileError, systemImage: "exclamationmark.triangle").font(.system(size: 11.5)).foregroundStyle(Theme.clayInk)
            }
            if effectiveMode == .separate && !files.isEmpty {
                Text("With separate processing, the files are added to every part.").font(.system(size: 11)).foregroundStyle(Theme.ink3)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(padding: 18)
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

    var bigDropZone: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Theme.sageInk)
                .frame(width: 64, height: 64)
                .background(RoundedRectangle(cornerRadius: 20, style: .continuous).fill(filesDropTargeted ? Theme.raised : Theme.sageTint))
                .scaleEffect(filesDropTargeted ? 1.08 : 1)
            VStack(spacing: 6) {
                Text(filesDropTargeted ? "Release to add" : "Drop lesson files here").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                Text(filesDropTargeted ? "They’ll be copied into the app — your originals aren’t changed."
                                       : "OpenAI uses them to write better notes, and the pupil can download them once you approve the lesson.")
                    .font(.system(size: 12)).foregroundStyle(Theme.ink2).multilineTextAlignment(.center).frame(maxWidth: 330)
            }
            if !filesDropTargeted {
                Button { withAnimation(Theme.spring) { addFiles(AttachmentPicker.choose()) } } label: {
                    Label("Choose files…", systemImage: "plus")
                }
                .buttonStyle(.soft)
                HStack(spacing: 6) {
                    ForEach(["PDF", "Word", "PowerPoint", "Excel", "Images", "Text"], id: \.self) {
                        Text($0).font(.system(size: 10.5, weight: .medium)).foregroundStyle(Theme.ink3)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(Capsule().fill(Theme.line2))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .padding(.vertical, 24).padding(.horizontal, 20)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(filesDropTargeted ? Theme.sageTint : Theme.raised.opacity(0.35)))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
            .strokeBorder(filesDropTargeted ? Theme.forest : Theme.sage.opacity(0.7),
                          style: dropStroke(filesDropTargeted)))
    }

    var smallDropZone: some View {
        HStack(spacing: 12) {
            Image(systemName: "square.and.arrow.up").font(.system(size: 15)).foregroundStyle(Theme.sageInk)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.raised))
            Text(filesDropTargeted ? "Release to add" : "Drop more files here").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(Theme.ink)
            Spacer()
            Button { withAnimation(Theme.spring) { addFiles(AttachmentPicker.choose()) } } label: { Label("Choose…", systemImage: "plus") }
                .buttonStyle(.softCompact)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(filesDropTargeted ? Theme.sageTint : Color.clear))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(filesDropTargeted ? Theme.forest : Theme.sage.opacity(0.7), style: dropStroke(filesDropTargeted)))
    }

    // MARK: Action bar

    var actionBar: some View {
        HStack(spacing: 14) {
            AppLogo(size: 36)
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryTitle).font(.system(size: 13.5, weight: .semibold)).foregroundStyle(Theme.ink)
                HStack(spacing: 6) {
                    Pill(text: recordingSummary, tone: selectedRows.count > 1 && mode == nil ? .sand : .neutral)
                    Pill(text: fileSummary, tone: files.isEmpty ? .neutral : .sage)
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.clayInk).lineLimit(2)
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
            }
            .buttonStyle(.primaryLarge)
            .keyboardShortcut(.defaultAction)
            .disabled(!canConfirm || working)
            .help(confirmHint ?? "")
        }
        .padding(.horizontal, 26).padding(.vertical, 14)
        .background(Theme.surface.opacity(0.92))
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 1) }
    }

    var summaryTitle: String {
        var parts = [pupilName ?? "Choose a pupil", lessonDate.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))]
        if hasStartTime { parts.append(startTime.formatted(date: .omitted, time: .shortened)) }
        return parts.joined(separator: " · ")
    }

    var recordingSummary: String {
        let n = selectedRows.count
        var s = "\(n) recording\(n == 1 ? "" : "s")"
        if n > 1 { s += mode == .combined ? " · combined" : (mode == .separate ? " · separate" : " · choose how") }
        let total = selectedRows.compactMap(\.rec.durationSeconds).reduce(0, +)
        if total > 0 { s += " · \(Int((total / 60).rounded())) min" }
        return s
    }

    var fileSummary: String {
        guard !files.isEmpty else { return "No files" }
        let shared = files.filter(\.shareWithPupil).count
        return "\(files.count) file\(files.count == 1 ? "" : "s") · \(shared) for the pupil"
    }

    var confirmHint: String? {
        if studentId.isEmpty { return "Choose the pupil first" }
        if selection.isEmpty { return "Include at least one recording" }
        if effectiveMode == nil { return "Choose whether to combine the recordings or keep them separate" }
        if session.inferredDate.needsReview && !dateChecked { return "Tick “I have checked the date”" }
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
        if rows.count == 1 { selection = [rows[0].id] }
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

/// One lesson file on the Confirm screen: what it is, and who gets it.
struct FileCard: View {
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
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Text(ext.isEmpty ? "FILE" : String(ext.prefix(4)))
                    .font(.system(size: 9.5, weight: .bold)).foregroundStyle(tone.ink)
                    .frame(width: 40, height: 46)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tone.fill))
                VStack(alignment: .leading, spacing: 2) {
                    Text(file.filename).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.ink)
                        .lineLimit(1).truncationMode(.middle).help(file.filename)
                    Text(Int64(file.byteCount).formatted(.byteCount(style: .file))).font(.system(size: 11.5)).foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 4)
                Button(action: onRemove) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.ink3)
                    .help("Remove this file").accessibilityLabel("Remove \(file.filename)")
            }
            Text("What is it?").font(.system(size: 11)).foregroundStyle(Theme.ink3).padding(.top, 10).padding(.bottom, 6)
            RoleSegments(role: $file.role)
                .disabled(!file.includeInContext)
                .opacity(file.includeInContext ? 1 : 0.5)
            HStack(spacing: 8) {
                UseToggle(isOn: $file.includeInContext, title: "AI reads it", detail: "for the notes")
                UseToggle(isOn: $file.shareWithPupil, title: "Pupil gets it", detail: "as a download")
            }
            .padding(.top, 10)
            if let note = statusNote {
                Text(note).font(.system(size: 11)).foregroundStyle(Theme.ink3).padding(.top, 7)
                    .transition(.opacity)
            }
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.raised.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Theme.line2))
        .hoverLift()
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

/// Full-width segmented choice of what a file is, with a sliding selection.
struct RoleSegments: View {
    @Binding var role: AttachmentRole
    @Namespace private var space

    static func shortLabel(_ r: AttachmentRole) -> String {
        switch r {
        case .slides: return "Slides"
        case .studentWork: return "Student work"
        case .exemplar: return "My work"
        case .other: return "Other"
        }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(AttachmentRole.allCases) { r in
                let on = r == role
                Button { withAnimation(Theme.spring) { role = r } } label: {
                    HStack(spacing: 5) {
                        Image(systemName: r.systemImage).font(.system(size: 10.5))
                        Text(Self.shortLabel(r)).lineLimit(1)
                    }
                    .font(.system(size: 12, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.onForest : Theme.ink2)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background {
                        if on {
                            Capsule().fill(Theme.forest).matchedGeometryEffect(id: "role", in: space)
                        }
                    }
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .help(r.label)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.line2))
    }
}

/// A large on/off pill: switch, bold title, quiet detail.
struct UseToggle: View {
    @Binding var isOn: Bool
    var title: String
    var detail: String
    var body: some View {
        Button { withAnimation(Theme.spring) { isOn.toggle() } } label: {
            HStack(spacing: 8) {
                ZStack(alignment: isOn ? .trailing : .leading) {
                    Capsule().fill(isOn ? Theme.sageInk : Theme.ink3.opacity(0.45)).frame(width: 30, height: 18)
                    Circle().fill(.white).frame(width: 14, height: 14).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 1, y: 1)
                }
                label.font(.system(size: 12)).lineLimit(1).minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 9).padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(isOn ? Theme.sageTint : Theme.line2.opacity(0.6)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(detail)")
        .accessibilityValue(isOn ? "On" : "Off")
    }

    var label: Text {
        let a: Text = Text(title).fontWeight(.semibold).foregroundColor(Theme.ink)
        let b: Text = Text(" · " + detail).foregroundColor(Theme.ink2)
        return a + b
    }
}
