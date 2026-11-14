import SwiftUI
import AppKit
import LessonNotesCore

struct ImportGroup: Identifiable {
    var id: String { session.id }
    var session: ProposedSession
    var studentOptionId: String
    var mode: ProcessingMode?
    var dateChecked: Bool
    var alreadyImported: Bool
    var queued: Bool
    var note: String?

    var needsMode: Bool { session.recordings.count > 1 }
}

/// Historical import: scan → inspect → group into proposed lessons → review → queue.
struct ImportView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let roots: [URL]

    init(roots: [URL]) { self.roots = roots }

    enum Phase: Equatable { case scanning(Int, Int), inspecting(Int, Int), ready, failed(String) }

    @State private var phase: Phase = .scanning(0, 0)
    @State private var groups: [ImportGroup] = []
    @State private var selection = Set<String>()
    @State private var converting: [String] = []
    @State private var review: ReviewRequest?
    @State private var summary: String?
    @State private var queueing = false
    @State private var includeDuplicates = false
    @State private var scanTask: Task<Void, Never>?

    var options: [StudentOption] { StudentOption.all(mappings: model.mappings, rooms: model.rooms) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Import recordings").font(.title2.weight(.semibold))
                    Text(roots.count == 1 ? roots[0].path : "\(roots.count) files").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }
            switch phase {
            case .scanning(let files, let media):
                ProgressView { Text("Scanning folders… \(files) files checked, \(media) recordings found") }
                    .progressViewStyle(.linear)
            case .inspecting(let done, let total):
                ProgressView(value: Double(done), total: Double(max(total, 1))) { Text("Reading recording details… \(done) of \(total)") }
            case .failed(let m):
                Label(m, systemImage: "xmark.octagon").foregroundStyle(.red)
            case .ready:
                readyContent
            }
            Spacer(minLength: 0)
            HStack {
                if let summary { Label(summary, systemImage: "checkmark.circle").foregroundStyle(.green) }
                Spacer()
                Button("Close") { scanTask?.cancel(); dismiss() }.keyboardShortcut(.cancelAction)
                if phase == .ready {
                    Button("Review Selected…") {
                        if let g = groups.first(where: { selection.contains($0.id) }) { review = ReviewRequest(session: g.session, fromDetection: false) }
                    }
                    .disabled(selection.count != 1)
                    Button("Confirm & Queue Selected (\(queueableCount))") { Task { await queueSelected() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(queueableCount == 0 || queueing)
                }
            }
        }
        .padding(20)
        .frame(width: 1040, height: 700)
        .task { scanTask = Task { await scan() } }
        .sheet(item: $review, onDismiss: refreshQueued) { req in
            ConfirmationSheet(request: req).environmentObject(model)
        }
    }

    var readyContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(groups.count) proposed lessons from \(groups.reduce(0) { $0 + $1.session.recordings.count }) recordings. Check each pupil, date and processing choice, then confirm. Rows marked ⚠︎ need the date checked.")
                .font(.callout).foregroundStyle(.secondary)
            if !converting.isEmpty {
                Label("\(converting.count) folder(s) skipped because Zoom has not finished converting them.", systemImage: "hourglass").font(.caption).foregroundStyle(.orange)
            }
            Table(groups, selection: $selection) {
                TableColumn("Date") { g in
                    HStack(spacing: 4) {
                        if g.session.inferredDate.needsReview { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).help(g.session.inferredDate.notes.joined(separator: "\n")) }
                        Text(g.session.inferredDate.lessonDate.isEmpty ? "Unknown" : CoreFormat.longUKDate(g.session.inferredDate.lessonDate))
                    }
                }.width(min: 120, ideal: 140)
                TableColumn("Time") { g in
                    Text(g.session.inferredDate.startedAt.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—").foregroundStyle(.secondary)
                }.width(60)
                TableColumn("Meeting / folder") { g in
                    VStack(alignment: .leading) {
                        Text(g.session.topic).lineLimit(1)
                        Text(g.session.recordings.map(\.filename).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }.width(min: 200, ideal: 260)
                TableColumn("Pupil") { g in
                    Picker("Pupil", selection: binding(g.id).studentOptionId) {
                        Text("Choose…").tag("")
                        ForEach(options) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden()
                }.width(min: 160, ideal: 200)
                TableColumn("Recordings") { g in
                    if g.needsMode {
                        Picker("Mode", selection: binding(g.id).mode) {
                            Text("\(g.session.recordings.count) recordings: choose…").tag(ProcessingMode?.none)
                            Text("Combine").tag(ProcessingMode?.some(.combined))
                            Text("Separate").tag(ProcessingMode?.some(.separate))
                        }
                        .labelsHidden()
                    } else {
                        Text(g.session.recordings.first?.durationSeconds.map { CoreFormat.duration(Int($0)) } ?? "1 recording").foregroundStyle(.secondary)
                    }
                }.width(min: 150, ideal: 180)
                TableColumn("Check") { g in
                    if g.queued { StatusChip("Queued", color: .green, icon: "checkmark") }
                    else if g.alreadyImported { StatusChip("Already imported", color: .gray) }
                    else if g.session.inferredDate.needsReview { Toggle("Date OK", isOn: binding(g.id).dateChecked).toggleStyle(.checkbox) }
                    else if let n = g.note { Text(n).font(.caption).foregroundStyle(.orange) }
                    else { Text("Ready").foregroundStyle(.secondary) }
                }.width(min: 110, ideal: 130)
            }
            Toggle("Include recordings that were already processed (creates new notes)", isOn: $includeDuplicates).font(.caption)
        }
    }

    func binding(_ id: String) -> Binding<ImportGroup> {
        Binding(get: { groups.first { $0.id == id } ?? groups[0] },
                set: { v in if let i = groups.firstIndex(where: { $0.id == id }) { groups[i] = v } })
    }

    func isQueueable(_ g: ImportGroup) -> Bool {
        !g.queued && (!g.alreadyImported || includeDuplicates) && !g.studentOptionId.isEmpty && (!g.needsMode || g.mode != nil)
            && (!g.session.inferredDate.needsReview || g.dateChecked) && !g.session.inferredDate.lessonDate.isEmpty
    }

    var queueableCount: Int { groups.filter { selection.contains($0.id) && isQueueable($0) }.count }

    func scan() async {
        let roots = self.roots
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try FolderScanner.scan(roots: roots) { p in
                    Task { @MainActor in phase = .scanning(p.filesVisited, p.mediaFound) }
                }
            }.value
            converting = result.foldersStillConverting
            phase = .inspecting(0, result.recordings.count)
            let enriched = await MediaInspector.enrich(result.recordings) { done, total in
                Task { @MainActor in phase = .inspecting(done, total) }
            }
            let sessions = SessionGrouper.group(enriched, timeZone: model.settings.timeZone)
            let processedPaths = Set(model.store.allLessons.flatMap { $0.recordings.map(\.path) })
            groups = sessions.map { s in
                let best = MappingMatcher.rank(MatchContext(session: s), mappings: model.mappings, rooms: model.rooms).first
                var optionId = best.map { b in b.mappingId.map { "m:\($0)" } ?? "r:\(b.roomId)" } ?? ""
                if !options.contains(where: { $0.id == optionId }) { optionId = "" }
                let already = s.recordings.contains { processedPaths.contains($0.path) }
                return ImportGroup(session: s, studentOptionId: optionId, mode: nil, dateChecked: false, alreadyImported: already, queued: false)
            }
            selection = Set(groups.filter { !$0.alreadyImported }.map(\.id))
            phase = groups.isEmpty ? .failed("No MP4 or M4A recordings were found.") : .ready
        } catch is CancellationError {
            dismiss()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refreshQueued() {
        let processed = Set(model.store.allLessons.flatMap { $0.recordings.map(\.path) })
        for i in groups.indices where groups[i].session.recordings.allSatisfy({ processed.contains($0.path) }) && !groups[i].alreadyImported {
            groups[i].queued = true
        }
    }

    /// Bulk confirmation of the selected, fully specified groups.
    func queueSelected() async {
        queueing = true
        defer { queueing = false }
        var queued = 0, skipped = 0
        let tz = model.settings.timeZone
        for i in groups.indices where selection.contains(groups[i].id) && isQueueable(groups[i]) {
            let g = groups[i]
            guard let option = options.first(where: { $0.id == g.studentOptionId }) else { continue }
            var refs: [RecordingRef] = []
            var duplicate = false
            for (order, r) in g.session.recordings.enumerated() {
                let url = URL(fileURLWithPath: r.path)
                let hash = try? await Task.detached(priority: .utility) { try SHA256Hasher.hexOfFile(at: url) }.value
                if let hash, !model.store.previousProcessing(sha256: hash).isEmpty { duplicate = true }
                refs.append(RecordingRef(filename: r.filename, path: r.path, bookmark: try? FolderAccess.bookmark(for: url),
                                         durationSec: Int((r.durationSeconds ?? 0).rounded()), recordedAt: r.recordingTimestamp,
                                         sha256: hash, fileSize: r.fileSize, order: order))
            }
            if duplicate && !includeDuplicates {
                groups[i].note = "Already processed — skipped"
                skipped += 1
                continue
            }
            let mode: ProcessingMode = g.needsMode ? (g.mode ?? .combined) : .single
            let c = LessonConfirmation(roomId: option.roomId, roomName: option.roomName, studentId: option.mappingId,
                                       pupilName: model.store.mapping(id: option.mappingId)?.displayName ?? option.roomName,
                                       lessonDate: g.session.inferredDate.lessonDate, startedAt: g.session.inferredDate.startedAt,
                                       dateSource: g.session.inferredDate.needsReview ? .manual : g.session.inferredDate.source,
                                       mode: mode, meetingTopic: g.session.topic, sourceFolder: g.session.folderPath, recordings: refs)
            do {
                try model.confirm(c, remember: nil, createMappingName: nil)
                groups[i].queued = true
                queued += 1
            } catch {
                groups[i].note = error.localizedDescription
            }
            _ = tz
        }
        summary = "Queued \(queued) lesson\(queued == 1 ? "" : "s")" + (skipped > 0 ? "; skipped \(skipped) already processed" : "") + "."
        selection = []
    }
}
