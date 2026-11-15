import SwiftUI
import AppKit
import UniformTypeIdentifiers
import LessonNotesCore

/// A file chosen in the Confirm sheet, before it is copied into the app's storage.
struct PendingAttachment: Identifiable, Equatable {
    var id = UUID()
    var url: URL
    var filename: String
    var byteCount: Int
    var role: AttachmentRole = .other
    var includeInContext = true
    var shareWithPupil = true
}

enum AttachmentPicker {
    /// Shows an Open panel for lesson files (allowed types only). Returns the chosen URLs.
    @MainActor static func choose() -> [URL] {
        let panel = NSOpenPanel()
        panel.title = "Add lesson files"
        panel.message = "PDF, Word, PowerPoint, Excel, text, CSV or images — up to 5 files, 20 MB each. The pupil can download them once you approve the notes."
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = AttachmentRules.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
        return panel.runModal() == .OK ? panel.urls : []
    }

    static func size(_ url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
    }
}

/// One file: name, size, what it is (for OpenAI), whether OpenAI sees it and whether the
/// pupil gets it.
struct AttachmentRowView: View {
    var filename: String
    var byteCount: Int
    @Binding var role: AttachmentRole
    @Binding var includeInContext: Bool
    @Binding var shareWithPupil: Bool
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var canChangeSharing: Bool

    init(filename: String, byteCount: Int, role: Binding<AttachmentRole>, includeInContext: Binding<Bool>, shareWithPupil: Binding<Bool>,
         canChangeSharing: Bool = true, onOpen: (() -> Void)? = nil, onRemove: (() -> Void)? = nil) {
        self.filename = filename
        self.byteCount = byteCount
        self._role = role
        self._includeInContext = includeInContext
        self._shareWithPupil = shareWithPupil
        self.canChangeSharing = canChangeSharing
        self.onOpen = onOpen
        self.onRemove = onRemove
    }

    var body: some View {
        // Every line is allowed to shrink to the available width (long file names are
        // truncated in the middle), so the row never pushes the sheet wider than it is.
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: role.systemImage).foregroundStyle(.tint).frame(width: 18)
                Text(filename)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(-1)
                    .help(filename)
                Text(Int64(byteCount).formatted(.byteCount(style: .file))).font(.caption).foregroundStyle(.secondary).fixedSize()
                if let onOpen { Button("Open") { onOpen() }.buttonStyle(.link).fixedSize() }
                if let onRemove {
                    Button(role: .destructive) { onRemove() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Remove this file").accessibilityLabel("Remove \(filename)")
                }
            }
            Picker("This file is", selection: $role) {
                ForEach(AttachmentRole.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480, alignment: .leading)
            .disabled(!includeInContext)
            .help("Tells OpenAI what this file is")
            HStack(spacing: 18) {
                Toggle("Include in AI context", isOn: $includeInContext)
                    .toggleStyle(.checkbox)
                    .help("Off: OpenAI never sees this file")
                Toggle("Share with pupil", isOn: $shareWithPupil)
                    .toggleStyle(.checkbox)
                    .disabled(!canChangeSharing)
                    .help("Off: the file stays on this Mac and is not uploaded to LetsMeet")
            }
            if let note = statusNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }

    var statusNote: String? {
        switch (includeInContext, shareWithPupil) {
        case (true, true): return nil
        case (true, false): return "Used by OpenAI only — kept on this Mac, not uploaded for the pupil."
        case (false, true): return "Uploaded for the pupil only — not sent to OpenAI."
        case (false, false): return "Not used: neither sent to OpenAI nor uploaded."
        }
    }
}

/// Lesson files for one job (History and the Regenerate sheet).
/// - Before upload: files can be changed while the lesson isn't mid-upload.
/// - After upload: changes stay on this Mac until George sends them — Update Files Only
///   (no re-approval) or together with regenerated notes (back to Waiting for approval).
struct JobAttachmentsSection: View {
    @EnvironmentObject var model: AppModel
    var job: Job
    var showsHeader: Bool
    var onRegenerate: (() -> Void)?
    @State private var confirmFilesOnly = false

    init(job: Job, showsHeader: Bool = true, onRegenerate: (() -> Void)? = nil) {
        self.job = job
        self.showsHeader = showsHeader
        self.onRegenerate = onRegenerate
    }

    var files: [LessonAttachment] { job.attachments ?? job.submittedAttachments ?? [] }
    var uploaded: Bool { job.stage == .submitted }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if showsHeader { Label("Lesson files", systemImage: "paperclip").font(.headline) }
                Spacer()
                if job.attachmentsEditable {
                    Button("Add Files…") { model.addFiles(AttachmentPicker.choose(), to: job) }
                        .disabled(files.count >= LibraryStore.maxStoredFiles)
                }
            }
            if job.filesChangedSinceNotes == true, job.notes != nil, let onRegenerate {
                banner("The files or their AI settings have changed since these notes were written.", icon: "arrow.triangle.2.circlepath") {
                    Button("Regenerate Notes…") { onRegenerate() }
                }
            }
            if job.websiteFilesOutOfDate {
                banner("The files shared with the pupil differ from the ones on LetsMeet.", icon: "icloud.and.arrow.up") {
                    Button("Update Files on LetsMeet") { confirmFilesOnly = true }.buttonStyle(.borderedProminent)
                    if let onRegenerate { Button("Regenerate Notes with These Files…") { onRegenerate() } }
                }
            }
            if let fu = job.fileUpdate {
                HStack {
                    switch fu.state {
                    case .queued:
                        ProgressView().controlSize(.small)
                        Text(fu.message ?? "Updating files on LetsMeet…").font(.callout)
                    case .failed, .noteDeleted:
                        Label(fu.message ?? "Updating the files failed.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red).font(.callout)
                        Spacer()
                        if fu.state == .failed { Button("Retry") { model.retryFileUpdate(job) } }
                        Button("Dismiss") { model.discardFileUpdate(job) }
                    }
                }
            }
            if files.isEmpty {
                Text(job.attachmentsEditable ? "Optional: slides, the pupil's work or your model answers. They can help OpenAI write the notes and be shared with the pupil once you approve."
                                             : "No files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files) { a in
                AttachmentRowView(filename: a.filename, byteCount: a.byteCount,
                                  role: Binding(get: { a.role }, set: { model.setAttachmentRole(job: job, id: a.id, role: $0) }),
                                  includeInContext: Binding(get: { a.includeInContext }, set: { model.setAttachmentIncluded(job: job, id: a.id, included: $0) }),
                                  shareWithPupil: Binding(get: { a.shareWithPupil }, set: { model.setAttachmentShared(job: job, id: a.id, shared: $0) }),
                                  canChangeSharing: job.attachmentsEditable,
                                  onOpen: { NSWorkspace.shared.open(model.store.attachmentURL(jobId: job.id, a)) },
                                  onRemove: job.attachmentsEditable ? { model.removeAttachment(job: job, id: a.id) } : nil)
                Divider()
            }
            if uploaded, let remote = job.remoteFiles {
                Text(remote.isEmpty ? "On LetsMeet: no files." : "On LetsMeet: " + remote.map { f in
                    f.filename + (f.size.map { " (" + Int64($0).formatted(.byteCount(style: .file)) + ")" } ?? "")
                }.joined(separator: ", "))
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
        .alert("Update the files on LetsMeet?", isPresented: $confirmFilesOnly) {
            Button("Update Files") { model.updateFilesOnWebsite(job) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(job.remoteStatus == .published
                 ? "The note is published, so the pupil will see the new files straight away. The notes themselves don't change and don't need approving again."
                 : "The note's files are replaced. The notes themselves don't change.")
        }
    }

    func banner<B: View>(_ text: String, icon: String, @ViewBuilder buttons: () -> B) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(text, systemImage: icon).font(.callout)
            HStack { Spacer(); buttons() }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    var caption: String {
        if uploaded {
            return "Changes to files here stay on this Mac until you send them: Update Files on LetsMeet (the note stays approved), or Regenerate Notes — accepting new notes also sends the current shared files (the note returns to Waiting for approval)."
        }
        if job.stage == .submitting { return "Files can't be changed while the note is uploading." }
        if job.notes != nil { return "Notes were already written. Changing shared files means a fresh upload (new submission ID); regenerate to use changed files as context." }
        return "Files can be added or removed until the note is uploaded. Up to 5 shared with the pupil."
    }
}
