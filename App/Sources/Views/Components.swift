import SwiftUI
import AppKit
import AVKit
import LessonNotesCore

struct StatusChip: View {
    var text: String
    var color: Color
    var icon: String?

    init(job: Job) {
        text = job.displayStatus
        switch job.stage {
        case .submitted:
            switch job.remoteStatus ?? .pending {
            case .pending: color = .orange; icon = "hourglass"
            case .published: color = .green; icon = "checkmark.seal.fill"
            case .rejected: color = .red; icon = "xmark.octagon"
            case .deleted: color = .gray; icon = "trash"
            }
        case .failed: color = .red; icon = job.error?.kind == .payloadTooLarge ? "exclamationmark.triangle.fill" : "exclamationmark.circle.fill"
        case .cancelled: color = .gray; icon = "stop.circle"
        case .held: color = .blue; icon = "pause.circle"
        case .queued: color = .secondary; icon = "tray"
        default: color = .accentColor; icon = "gearshape.2"
        }
    }

    init(_ text: String, color: Color, icon: String? = nil) {
        self.text = text
        self.color = color
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 4) {
            if let icon { Image(systemName: icon).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Status: \(text)")
    }
}

/// Password-style field with reveal/hide.
struct SecretField: View {
    var title: String
    @Binding var text: String
    @State private var revealed = false

    init(title: String, text: Binding<String>) {
        self.title = title
        self._text = text
    }

    var body: some View {
        HStack {
            Group {
                if revealed {
                    TextField(title, text: $text)
                } else {
                    SecureField(title, text: $text)
                }
            }
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .autocorrectionDisabled()
            Button {
                revealed.toggle()
            } label: {
                Image(systemName: revealed ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(revealed ? "Hide" : "Reveal")
            .accessibilityLabel(revealed ? "Hide key" : "Reveal key")
        }
    }
}

struct Card<Content: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage).font(.headline)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct ResultLine: View {
    var result: ConnectionResult?
    var body: some View {
        if let result {
            Label(result.message, systemImage: result.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(result.ok ? .green : .red)
                .font(.callout)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct JobProgressRow: View {
    @EnvironmentObject var model: AppModel
    var lesson: Lesson
    var job: Job

    var body: some View {
        let p = model.progress[job.id]
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(lesson.pupilName).font(.callout.weight(.semibold))
                Text(CoreFormat.longUKDate(lesson.lessonDate)).font(.caption).foregroundStyle(.secondary)
                if lesson.jobs.count > 1 { Text("part \(job.partLetter)").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                StatusChip(job: job)
            }
            if job.stage.isActive {
                ProgressView(value: p?.fraction ?? 0)
                    .progressViewStyle(.linear)
                Text(p?.message ?? job.statusMessage ?? job.stage.label).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            } else if let m = job.statusMessage, job.stage != .submitted {
                Text(m).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// AVPlayerView wrapper for previews (local playback only).
struct PlayerView: NSViewRepresentable {
    var url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.controlsStyle = .floating
        v.player = AVPlayer(url: url)
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if (v.player?.currentItem?.asset as? AVURLAsset)?.url != url { v.player = AVPlayer(url: url) }
    }

    static func dismantleNSView(_ v: AVPlayerView, coordinator: ()) {
        v.player?.pause()
        v.player = nil
    }
}

struct PreviewSheet: View {
    var url: URL
    var title: String
    @Environment(\.dismiss) private var dismiss
    init(url: URL, title: String) { self.url = url; self.title = title }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            PlayerView(url: url)
        }
        .frame(minWidth: 720, minHeight: 460)
    }
}

extension Int64 {
    var byteString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

extension Date {
    var shortDateTime: String { formatted(date: .abbreviated, time: .shortened) }
}
