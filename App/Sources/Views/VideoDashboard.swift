import SwiftUI
import Charts
import LessonNotesCore

/// Live storage, video counts and bandwidth. Every figure comes from the server statistics
/// (LetsMeet → media gateway) or from this Mac's own queue and upload log, and says which.
struct VideoDashboard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            serverStatusBar
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 16) {
                    StorageCard().frame(minWidth: 470, maxWidth: .infinity)
                    VideoCountsCard().frame(minWidth: 420, maxWidth: .infinity)
                }
                VStack(spacing: 16) {
                    StorageCard()
                    VideoCountsCard()
                }
            }
            BandwidthCard().id("bandwidth")
        }
    }

    var snapshot: MediaStatsSnapshot { model.statsSnapshot }

    var serverStatusBar: some View {
        HStack(spacing: 8) {
            if model.isRefreshingStats { ProgressView().controlSize(.small) }
            if snapshot.stats != nil {
                let stale = snapshot.isStale(now: Date(), refreshInterval: TimeInterval(model.settings.video.statsRefreshSeconds))
                Image(systemName: stale ? "exclamationmark.triangle.fill" : "dot.radiowaves.left.and.right")
                    .foregroundStyle(stale ? .orange : .green)
                Text(stale ? "Showing the last figures received" : "Live from the media server")
                    .font(.callout.weight(.medium))
                if let f = snapshot.fetchedAt { Text("· updated \(f.formatted(date: .abbreviated, time: .standard))").font(.callout).foregroundStyle(.secondary) }
                if stale, let e = snapshot.lastError { Text("· \(e)").font(.callout).foregroundStyle(.orange).lineLimit(1) }
            } else if snapshot.notAvailable {
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                Text("Server statistics aren't available yet — LetsMeet needs its /media/stats endpoint and the updated media gateway. Figures below are from this Mac only.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let e = snapshot.lastError {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text("Couldn't reach the server statistics: \(e)").font(.callout).foregroundStyle(.orange)
            } else {
                Text("Fetching server statistics…").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button { model.refreshStats() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.isRefreshingStats)
        }
    }
}

// MARK: Storage

struct StorageSlice: Identifiable {
    var id: String { name }
    var name: String
    var bytes: Int64
    var color: Color
}

struct StorageCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Storage", systemImage: "internaldrive") {
            if let g = model.statsSnapshot.stats?.gateway {
                let b = StorageBreakdown(volume: g.volume, recordingsBytes: g.recordings.bytes)
                let unit = model.settings.video.byteUnit
                HStack(alignment: .center, spacing: 20) {
                    Chart(slices(b)) { s in
                        SectorMark(angle: .value("Bytes", Double(s.bytes)), innerRadius: .ratio(0.64), angularInset: 1.2)
                            .cornerRadius(3)
                            .foregroundStyle(s.color)
                    }
                    .chartLegend(.hidden)
                    .frame(width: 150, height: 150)
                    .overlay {
                        VStack(spacing: 0) {
                            Text(ByteFormat.percent(b.usedFraction)).font(.title2.weight(.bold).monospacedDigit())
                            Text("used").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Storage \(ByteFormat.percent(b.usedFraction)) used")
                    VStack(alignment: .leading, spacing: 7) {
                        ForEach(slices(b)) { s in
                            HStack(spacing: 6) {
                                Circle().fill(s.color).frame(width: 9, height: 9)
                                Text(s.name).font(.callout).lineLimit(1).fixedSize()
                                Spacer(minLength: 8)
                                Text(ByteFormat.string(s.bytes, unit: unit)).font(.callout.monospacedDigit()).lineLimit(1).fixedSize()
                                Text(ByteFormat.percent(b.fraction(s.bytes))).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1).frame(width: 44, alignment: .trailing)
                            }
                        }
                        if b.recordings == nil {
                            Text("The media server is still counting its recordings.").font(.caption).foregroundStyle(.secondary)
                        }
                        Divider()
                        HStack {
                            Text("Total capacity").font(.callout.weight(.medium))
                            Spacer()
                            Text(ByteFormat.string(b.total, unit: unit)).font(.callout.weight(.medium).monospacedDigit())
                        }
                        HStack {
                            Text("Used \(ByteFormat.string(b.used, unit: unit)) · available \(ByteFormat.string(b.available, unit: unit))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                if b.isLow(threshold: Double(model.settings.video.lowSpacePercent) / 100) {
                    Label("Less than \(model.settings.video.lowSpacePercent)% of the storage volume is free.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red).font(.callout)
                }
                Text("Volume: \(g.volume.realPath ?? g.volume.path ?? "recordings folder") — the drive that holds the recordings")
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("No storage figures yet. They come from the media server once LetsMeet's statistics endpoint is available.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    func slices(_ b: StorageBreakdown) -> [StorageSlice] {
        var out: [StorageSlice] = []
        if let r = b.recordings { out.append(StorageSlice(name: "Lesson recordings", bytes: r, color: .accentColor)) }
        if let o = b.otherUsed { out.append(StorageSlice(name: "Other files", bytes: o, color: .orange)) }
        else { out.append(StorageSlice(name: "Used", bytes: b.used, color: .orange)) }
        if b.reserved > 0 { out.append(StorageSlice(name: "File system reserve", bytes: b.reserved, color: .gray)) }
        out.append(StorageSlice(name: "Available", bytes: b.available, color: .green.opacity(0.45)))
        return out
    }
}

// MARK: Counts

struct VideoCountsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Videos", systemImage: "film.stack") {
            let unit = model.settings.video.byteUnit
            if let s = model.statsSnapshot.stats {
                Text("On the server").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                    GridRow {
                        stat(s.gateway?.recordings.count.map { "\($0)" } ?? "—", "Stored videos")
                        stat(s.recordings?.ready.map { "\($0)" } ?? "—", "Ready on LetsMeet", .green)
                        stat(s.gateway?.recordings.bytes.map { ByteFormat.string($0, unit: unit) } ?? "—", "Total size")
                    }
                    GridRow {
                        stat(average(s).map { ByteFormat.string($0, unit: unit) } ?? "—", "Average size")
                        stat(unconfirmed(s).map { "\($0)" } ?? "—", "On server, not confirmed")
                        stat(s.recordings?.failed.map { "\($0)" } ?? "—", "Failed on LetsMeet", (s.recordings?.failed ?? 0) > 0 ? .red : .primary)
                    }
                }
            }
            let c = model.videoCounts
            Text("This Mac").font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
            Grid(alignment: .leading, horizontalSpacing: 22, verticalSpacing: 8) {
                GridRow {
                    stat("\(c.completed)", "Uploaded by this Mac", .green)
                    stat("\(c.uploading)", model.settings.video.paused && c.uploading > 0 ? "Uploading (paused)" : "Uploading now", .accentColor)
                    stat("\(c.awaiting)", "Awaiting upload")
                }
                GridRow {
                    stat("\(c.failed)", "Failed", c.failed > 0 ? .red : .primary)
                    stat("\(c.alreadyOnLetsMeet)", "Already on LetsMeet")
                    stat(ByteFormat.string(c.completedBytes, unit: unit), "Uploaded in total")
                }
            }
            Text("A lesson whose recordings were joined counts as one video.").font(.caption2).foregroundStyle(.tertiary)
        }
    }

    func average(_ s: MediaStatsResponse) -> Int64? {
        guard let n = s.gateway?.recordings.count, n > 0, let b = s.gateway?.recordings.bytes else { return nil }
        return b / Int64(n)
    }

    /// Files on the server without a ready recording on LetsMeet (uploads awaiting confirmation, or strays).
    func unconfirmed(_ s: MediaStatsResponse) -> Int? {
        guard let files = s.gateway?.recordings.count, let ready = s.recordings?.ready else { return nil }
        return max(0, files - ready)
    }

    func stat(_ value: String, _ label: String, _ color: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: Bandwidth

struct TrafficBar: Identifiable {
    var id: String { day + kind }
    var day: String
    var date: Date
    var kind: String
    var bytes: Int64
}

struct BandwidthCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Card(title: "Bandwidth", systemImage: "arrow.up.arrow.down") {
            let unit = model.settings.video.byteUnit
            let separate = model.settings.video.separateTraffic
            let now = Date()
            if let g = model.statsSnapshot.stats?.gateway, let t = g.traffic {
                let tz = TimeZone(identifier: g.timezone ?? "") ?? model.settings.timeZone
                let s = Bandwidth.summarise(t, now: now, timeZone: tz)
                Text("Media server traffic — uploads to and playback/downloads from the media gateway" + (t.since.flatMap(CoreFormat.parseISO8601).map { ", recorded since \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""))
                    .font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 24) {
                    table(s, unit: unit, separate: separate, labels: ("Uploads", "Playback"))
                    chart(t, tz: tz, separate: separate)
                }
                if let st = g.serverTraffic, st.available {
                    let w = Bandwidth.summarise(st, now: now, timeZone: tz)
                    Divider()
                    Text("Whole server (all network interfaces: includes SFTP, updates etc.)").font(.caption).foregroundStyle(.secondary)
                    table(w, unit: unit, separate: separate, labels: ("Received", "Sent"))
                }
            } else {
                Text("This Mac's video uploads (server traffic, including playback, appears once server statistics are available)")
                    .font(.caption).foregroundStyle(.secondary)
                table(model.transferLog.summary(now: now), unit: unit, separate: false, labels: ("Uploaded", ""))
            }
            if let rate = model.currentUploadRate {
                Label("Uploading now at \(ByteFormat.string(Int64(rate), unit: unit))/s", systemImage: "speedometer").font(.callout)
            }
        }
    }

    func table(_ s: BandwidthSummary, unit: ByteUnit, separate: Bool, labels: (String, String)) -> some View {
        Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow {
                head("Period").gridColumnAlignment(.leading)
                if separate { head(labels.0); head(labels.1) }
                head("Total")
            }
            GridRow {
                cell("Today").gridColumnAlignment(.leading)
                if separate { cell(ByteFormat.string(s.today.upload, unit: unit)); cell(ByteFormat.string(s.today.playback, unit: unit)) }
                cell(ByteFormat.string(s.today.total, unit: unit), bold: true)
            }
            GridRow {
                cell("This week")
                if separate { cell(ByteFormat.string(s.week.upload, unit: unit)); cell(ByteFormat.string(s.week.playback, unit: unit)) }
                cell(ByteFormat.string(s.week.total, unit: unit), bold: true)
            }
            GridRow {
                cell("This month")
                if separate { cell(ByteFormat.string(s.month.upload, unit: unit)); cell(ByteFormat.string(s.month.playback, unit: unit)) }
                cell(ByteFormat.string(s.month.total, unit: unit), bold: true)
            }
        }
        .fixedSize()
    }

    func head(_ t: String) -> Text { Text(t).font(.caption.weight(.semibold)).foregroundColor(.secondary) }
    func cell(_ t: String, bold: Bool = false) -> Text { Text(t).font(bold ? .callout.monospacedDigit().weight(.semibold) : .callout.monospacedDigit()) }

    func chart(_ t: TrafficHistory, tz: TimeZone, separate: Bool) -> some View {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        let days = t.days.suffix(14)
        let bars: [TrafficBar] = days.flatMap { d -> [TrafficBar] in
            guard let date = f.date(from: d.date) else { return [] }
            return separate
                ? [TrafficBar(day: d.date, date: date, kind: "Uploads", bytes: d.uploadBytes), TrafficBar(day: d.date, date: date, kind: "Playback", bytes: d.playbackBytes)]
                : [TrafficBar(day: d.date, date: date, kind: "Total", bytes: d.uploadBytes + d.playbackBytes)]
        }
        return Chart(bars) { b in
            BarMark(x: .value("Day", b.date, unit: .day), y: .value("Bytes", Double(b.bytes)))
                .foregroundStyle(by: .value("Kind", b.kind))
        }
        .chartForegroundStyleScale(domain: separate ? ["Uploads", "Playback"] : ["Total"],
                                   range: separate ? [Color.accentColor, Color.purple] : [Color.accentColor])
        .chartYAxis {
            AxisMarks { v in
                AxisGridLine()
                AxisValueLabel { if let d = v.as(Double.self) { Text(ByteFormat.string(Int64(d))) } }
            }
        }
        .chartXAxis { AxisMarks(values: .stride(by: .day, count: 2)) { _ in AxisValueLabel(format: .dateTime.day().month(.abbreviated)) } }
        .frame(minWidth: 260, maxWidth: .infinity, minHeight: 150, maxHeight: 170)
        .overlay { if bars.isEmpty { Text("No traffic recorded yet").font(.caption).foregroundStyle(.secondary) } }
    }
}
