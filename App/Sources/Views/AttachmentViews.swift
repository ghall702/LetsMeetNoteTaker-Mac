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

    init(filename: String, byteCount: Int, role: Binding<AttachmentRole>, includeInContext: Binding<Bool>,
         onOpen: (() -> Void)? = nil, onRemove: (() -> Void)? = nil) {
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

/// Lesson files for one job in History: add/remove until notes are written; type and
/// AI-context switch can be changed at any time.
struct JobAttachmentsSection: View {
    @EnvironmentObject var model: AppModel
    var job: Job
    init(job: Job) { self.job = job }

    var files: [LessonAttachment] { job.submittedAttachments ?? job.attachments ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Lesson files", systemImage: "paperclip").font(.headline)
                Spacer()
                if job.attachmentsEditable && files.count < AttachmentRules.maxFiles {
                    Button("Add Files…") { model.addFiles(AttachmentPicker.choose(), to: job) }
                }
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
                                  onOpen: { NSWorkspace.shared.open(model.store.attachmentURL(jobId: job.id, a)) },
                                  onRemove: job.attachmentsEditable ? { model.removeAttachment(job: job, id: a.id) } : nil)
                Divider()
            }
            if !files.isEmpty {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var caption: String {
        if job.stage == .submitted { return "Uploaded with the note. The pupil can download them once you approve it. Changing a file's type or AI switch only affects future regenerations." }
        if !job.attachmentsEditable { return "Files are fixed now the notes have been written. Type and AI switch still apply when you regenerate." }
        return "Files can be added or removed until the notes are written."
    }
}
