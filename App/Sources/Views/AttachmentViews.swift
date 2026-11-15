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

/// One file: name, size, what it is (for OpenAI) and whether OpenAI sees it at all.
struct AttachmentRowView: View {
    var filename: String
    var byteCount: Int
    @Binding var role: AttachmentRole
    @Binding var includeInContext: Bool
    var onOpen: (() -> Void)?
    var onRemove: (() -> Void)?
    var contextOnly: Bool

    init(filename: String, byteCount: Int, role: Binding<AttachmentRole>, includeInContext: Binding<Bool>,
         contextOnly: Bool = false, onOpen: (() -> Void)? = nil, onRemove: (() -> Void)? = nil) {
        self.contextOnly = contextOnly
        self.filename = filename
        self.byteCount = byteCount
        self._role = role
        self._includeInContext = includeInContext
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
                if contextOnly {
                    Text("Context only").font(.caption2.weight(.medium)).padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.purple.opacity(0.15), in: Capsule()).foregroundStyle(.purple).fixedSize()
                        .help("Used as OpenAI context only; not uploaded to LetsMeet")
                }
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
            Toggle(isOn: $includeInContext) {
                Text(includeInContext ? "Include in AI context" : "Include in AI context — off: uploaded for the pupil only, not sent to OpenAI")
            }
            .toggleStyle(.checkbox)
            .help("Off: the file is only uploaded for the pupil; OpenAI never sees it")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

/// Lesson files for one job (History and the Regenerate sheet).
/// - Before upload: files can be swapped (while the lesson isn't running).
/// - After upload: the website can't change a note's files, so extra files are "context only",
///   and "Redo with Different Files" makes a new note from the saved transcript.
struct JobAttachmentsSection: View {
    @EnvironmentObject var model: AppModel
    var job: Job
    var showsHeader: Bool
    var onRegenerate: (() -> Void)?
    @State private var confirmRedo = false

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
                        .disabled(job.uploadAttachments.count >= AttachmentRules.maxFiles)
                } else if job.hasTranscript {
                    Button("Add Context-Only File…") { model.addFiles(AttachmentPicker.choose(), to: job, contextOnly: true) }
                        .help("Used by OpenAI when you regenerate; not uploaded (the website can't add files to an uploaded note)")
                }
                if uploaded && job.hasTranscript {
                    Button("Redo with Different Files…") { confirmRedo = true }
                        .help("Make a new note from the saved transcript with a different set of files")
                }
            }
            if job.filesChangedSinceNotes == true, job.notes != nil {
                HStack {
                    Label("The files or their AI settings have changed since these notes were written.", systemImage: "arrow.triangle.2.circlepath")
                        .font(.callout)
                    Spacer()
                    if let onRegenerate { Button("Regenerate Notes…") { onRegenerate() }.buttonStyle(.borderedProminent) }
                }
                .padding(8)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
            }
            if files.isEmpty {
                Text(job.attachmentsEditable ? "Optional: slides, the pupil's work or your model answers. They help OpenAI write the notes and the pupil can download them once you approve."
                                             : "No files were attached to this note.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(files) { a in
                AttachmentRowView(filename: a.filename, byteCount: a.byteCount,
                                  role: Binding(get: { a.role }, set: { model.setAttachmentRole(job: job, id: a.id, role: $0) }),
                                  includeInContext: Binding(get: { a.includeInContext }, set: { model.setAttachmentIncluded(job: job, id: a.id, included: $0) }),
                                  contextOnly: a.contextOnly,
                                  onOpen: { NSWorkspace.shared.open(model.store.attachmentURL(jobId: job.id, a)) },
                                  onRemove: (job.attachmentsEditable || a.contextOnly) ? { model.removeAttachment(job: job, id: a.id) } : nil)
                Divider()
            }
            if !files.isEmpty || uploaded {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
        .alert("Redo with different files?", isPresented: $confirmRedo) {
            Button("Make New Note") { model.redoWithDifferentFiles(job) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A new lesson is created from the saved transcript (no re-transcription) with a copy of these files. It waits in History so you can swap files, then press Start. It is uploaded as a NEW note, because LetsMeet can't change the files of an uploaded note — afterwards, delete or reject the old note in Admin Tools.")
        }
    }

    var caption: String {
        if uploaded {
            return "Uploaded files can't be changed on LetsMeet. You can change any file's type or AI switch, or add context-only files, and then Regenerate Notes (the website note is updated, its files stay the same). To change the files pupils download, use Redo with Different Files."
        }
        if job.attachmentsEditable && job.notes != nil {
            return "Notes were already written. Changing files here means a fresh upload (new submission ID); regenerate to use the new files."
        }
        if !job.attachmentsEditable { return "Files can be swapped while this lesson isn't running (e.g. when it is held or needs attention)." }
        return "Files can be added or removed until the note is uploaded."
    }
}
