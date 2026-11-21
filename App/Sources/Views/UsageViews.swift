import SwiftUI
import AppKit
import LessonNotesCore

enum UsageFormat {
    static func tokens(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_GB")
        return f.string(from: NSNumber(value: n)) ?? String(n)
    }

    static func usd(_ v: Double) -> String {
        if v == 0 { return "$0.00" }
        if v < 0.01 { return "< $0.01" }
        return String(format: "$%.2f", v)
    }

    static func countdown(to date: Date, from now: Date) -> String {
        let s = max(0, Int(date.timeIntervalSince(now)))
        return String(format: "%dh %02dm", s / 3600, (s % 3600) / 60)
    }
}

extension AppModel {
    var usageRecords: [UsageRecord] { _ = usageVersion; return usageMonitor.ledger.all }
}

/// Green / amber / red depending on how much of the daily allowance is used.
func allowanceColor(used: Int, allowance: Int) -> Color {
    guard allowance > 0 else { return .red }
    let f = Double(used) / Double(allowance)
    if f >= 0.9 { return .red }
    if f >= 0.7 { return .orange }
    return .green
}

/// Compact daily panel (Dashboard and Usage page).
struct UsagePanel: View {
    @EnvironmentObject var model: AppModel
    var compact = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            let now = context.date
            let s = model.settings.usage
            let records = model.usageRecords
            let today = UsageAccounting.today(records, now: now, settings: s)
            let month = UsageAccounting.month(records, now: now, settings: s)
            let allowance = s.dailyComplimentaryTokens
            let used = today.eligibleTokens
            let color = allowanceColor(used: used, allowance: allowance)
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(UsageFormat.tokens(today.totalTokens)).font(.title2.weight(.semibold).monospacedDigit())
                    Text("tokens used today (UTC)").foregroundStyle(.secondary)
                    Spacer()
                    StatusChip(color == .green ? "Within allowance" : (used > allowance ? "Over allowance" : "Approaching limit"), color: color,
                               icon: color == .green ? "checkmark.circle" : "exclamationmark.triangle")
                }
                ProgressView(value: Double(min(used, allowance)), total: Double(max(allowance, 1)))
                    .tint(color)
                    .accessibilityLabel("Complimentary allowance used: \(UsageFormat.tokens(used)) of \(UsageFormat.tokens(allowance))")
                HStack(spacing: 18) {
                    stat("Complimentary allowance", UsageFormat.tokens(allowance))
                    stat("Est. remaining", UsageFormat.tokens(max(0, allowance - used)))
                    stat("Resets in", UsageFormat.countdown(to: UsageCalendar.nextReset(after: now), from: now))
                    stat("Lessons today", "\(today.lessonCount)")
                    stat("Est. spend today", UsageFormat.usd(today.estimatedSpendUSD))
                    if !compact { stat("Est. spend this month", UsageFormat.usd(month.estimatedSpendUSD)) }
                }
                if compact { Text("Est. spend this month: \(UsageFormat.usd(month.estimatedSpendUSD))").font(.caption).foregroundStyle(.secondary) }
                if today.requestsWithUnknownUsage > 0 {
                    Text("\(today.requestsWithUnknownUsage) request(s) today returned no usage figures (counted as unknown).").font(.caption).foregroundStyle(.secondary)
                }
                if today.requestsWithoutPrice > 0 {
                    Text("Some requests used a model with no price set — add it in Settings → OpenAI.").font(.caption).foregroundStyle(.orange)
                }
                if s.protectionEnabled {
                    Label("Free allowance protection is on (local safeguard, not an OpenAI billing cap).", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary)
                }
                Text("Token counts are exactly as reported by OpenAI for requests made by this app. Complimentary and spending figures are estimates; OpenAI's billing decides what is actually charged.")
                    .font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.callout.weight(.semibold).monospacedDigit())
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// Per-lesson usage summary (actual figures from OpenAI; cost clearly an estimate).
struct LessonUsageSummary: View {
    @EnvironmentObject var model: AppModel
    var jobId: UUID

    var body: some View {
        let records = model.usageRecords.filter { $0.jobId == jobId }
        if !records.isEmpty {
            let known = records.compactMap(\.usage)
            let s = model.settings.usage
            let input = known.compactMap(\.inputTokens).reduce(0, +)
            let cached = known.compactMap(\.cachedInputTokens).reduce(0, +)
            let output = known.compactMap(\.outputTokens).reduce(0, +)
            let total = known.compactMap(\.totalTokens).reduce(0, +)
            let costs = records.compactMap { r in r.usage.flatMap { s.price(for: r.model)?.cost(of: $0) } }
            VStack(alignment: .leading, spacing: 4) {
                Text("API usage").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 2) {
                    GridRow { Text("Input"); Text(UsageFormat.tokens(input) + " tokens" + (cached > 0 ? " (\(UsageFormat.tokens(cached)) cached)" : "")) }
                    GridRow { Text("Output"); Text(UsageFormat.tokens(output) + " tokens") }
                    GridRow { Text("Total"); Text(UsageFormat.tokens(total) + " tokens").fontWeight(.semibold) }
                    GridRow { Text("Estimated cost"); Text(costs.isEmpty ? "No price set" : UsageFormat.usd(costs.reduce(0, +)) + " at list price") }
                }
                .font(.callout.monospacedDigit())
                Text("\(records.count) OpenAI request\(records.count == 1 ? "" : "s")"
                     + (records.count != known.count ? " · \(records.count - known.count) without usage figures (unknown)" : "")
                     + (records.contains { $0.outcome != .succeeded } ? " · includes failed or incomplete attempts" : ""))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct PeriodRow: Identifiable {
    var id: String { name }
    let name: String
    let sum: UsageSummary
}

/// Full usage page: periods, top lessons and recent requests.
struct UsageView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                ScreenTitle(title: "API usage", subtitle: "OpenAI tokens, allowance and estimated spend").appearIn(0)
                Card(title: "Today", systemImage: "gauge.with.dots.needle.33percent") { UsagePanel() }.appearIn(1)
                periodsCard
                topLessonsCard
                recentCard
                Card(title: "About these figures", systemImage: "info.circle") {
                    Text("Usage is recorded from the moment this feature was installed; earlier requests were not saved, so they are not shown or estimated. Records are stored only on this Mac (usage-ledger.jsonl in the app's data folder) and contain token counts, model, time and lesson reference — no API keys, transcripts or pupil details. Importing OpenAI's own usage exports is not supported yet, because their format could not be verified; use OpenAI's usage dashboard for billed figures.")
                        .font(.callout).fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Link("OpenAI usage dashboard", destination: URL(string: "https://platform.openai.com/usage")!)
                        Link("OpenAI billing", destination: JobError.openAIBillingURL)
                        Button("Usage Settings…") { model.sidebar = .settings; model.settingsTab = 1 }
                    }
                }
            }
            .padding(.horizontal, 28).padding(.vertical, 22)
        }
        .navigationTitle("API Usage")
    }

    var periodsCard: some View {
        let now = Date()
        let s = model.settings.usage
        let records = model.usageRecords
        let yesterday = UsageCalendar.utcDay(now.addingTimeInterval(-86_400))
        let rows: [PeriodRow] = [
            PeriodRow(name: "Today", sum: UsageAccounting.today(records, now: now, settings: s)),
            PeriodRow(name: "Yesterday", sum: UsageAccounting.summarise(records.filter { $0.utcDay == yesterday }, settings: s)),
            PeriodRow(name: "Last 7 days", sum: UsageAccounting.lastDays(records, now: now, days: 7, settings: s)),
            PeriodRow(name: "This month", sum: UsageAccounting.month(records, now: now, settings: s)),
        ]
        return Card(title: "History (UTC)", systemImage: "calendar") {
            Grid(alignment: .trailing, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("Period").gridColumnAlignment(.leading)
                    Text("Tokens"); Text("Est. complimentary"); Text("Lessons"); Text("Est. spend"); Text("List-price value")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Divider()
                ForEach(rows) { row in
                    let name = row.name, sum = row.sum
                    GridRow {
                        Text(name).gridColumnAlignment(.leading)
                        Text(UsageFormat.tokens(sum.totalTokens))
                        Text(UsageFormat.tokens(sum.estimatedComplimentaryTokens))
                        Text("\(sum.lessonCount)")
                        Text(UsageFormat.usd(sum.estimatedSpendUSD)).foregroundStyle(sum.estimatedSpendUSD > 0 ? Color.orange : Color.primary)
                        Text(UsageFormat.usd(sum.listPriceValueUSD)).foregroundStyle(.secondary)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
            Text("“List-price value” is what the tokens would cost without the complimentary allowance.").font(.caption).foregroundStyle(.secondary)
        }
    }

    var topLessonsCard: some View {
        let now = Date()
        let month = UsageCalendar.utcMonth(now)
        let top = UsageAccounting.topLessons(model.usageRecords.filter { UsageCalendar.utcMonth($0.date) == month }, settings: model.settings.usage)
        return Card(title: "Lessons using the most tokens this month", systemImage: "list.number") {
            if top.isEmpty { Text("No lesson usage recorded yet this month.").foregroundStyle(.secondary) }
            ForEach(top) { item in
                let lesson = model.lesson(item.lessonId)
                Button { if lesson != nil { model.openLesson(item.lessonId) } } label: {
                    HStack {
                        Text(lesson.map { "\($0.pupilName) — \(CoreFormat.longUKDate($0.lessonDate))" } ?? "Lesson no longer in history")
                        Spacer()
                        Text("\(UsageFormat.tokens(item.totalTokens)) tokens · \(item.requests) request\(item.requests == 1 ? "" : "s")" +
                             (item.listPriceUSD.map { " · \(UsageFormat.usd($0)) list" } ?? ""))
                            .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    var recentCard: some View {
        let recent = Array(model.usageRecords.suffix(15).reversed())
        return Card(title: "Recent requests", systemImage: "clock") {
            if recent.isEmpty { Text("No OpenAI requests recorded yet.").foregroundStyle(.secondary) }
            ForEach(recent) { r in
                HStack {
                    Text(r.date.formatted(date: .abbreviated, time: .shortened)).frame(width: 150, alignment: .leading)
                    Text(r.purpose.label).frame(width: 190, alignment: .leading)
                    Text(r.model).font(.caption.monospaced()).frame(width: 140, alignment: .leading)
                    Spacer()
                    if let u = r.usage, let t = u.totalTokens {
                        Text("\(UsageFormat.tokens(u.inputTokens ?? 0)) in · \(UsageFormat.tokens(u.outputTokens ?? 0)) out · \(UsageFormat.tokens(t))")
                            .monospacedDigit()
                    } else {
                        Text("usage unknown").foregroundStyle(.secondary)
                    }
                    StatusChip(r.outcome.rawValue.capitalized, color: r.outcome == .succeeded ? .green : (r.outcome == .incomplete ? .orange : .red))
                }
                .font(.callout)
            }
        }
    }
}

/// Settings → OpenAI: allowance, complimentary models, protection and pricing.
struct UsageSettingsSection: View {
    @EnvironmentObject var model: AppModel
    @State private var modelsText = ""

    var s: UsageSettings { model.settings.usage }
    func set(_ body: @escaping (inout UsageSettings) -> Void) { model.updateSettings { body(&$0.usage) } }

    var body: some View {
        Section {
            Stepper(value: Binding(get: { s.dailyComplimentaryTokens }, set: { v in set { $0.dailyComplimentaryTokens = v } }), in: 0...10_000_000, step: 10_000) {
                Text("Daily complimentary allowance: \(UsageFormat.tokens(s.dailyComplimentaryTokens)) tokens (resets 00:00 UTC)")
            }
            HStack {
                TextField("Complimentary models (comma-separated)", text: $modelsText)
                    .onSubmit(saveModels)
                Button("Save", action: saveModels).disabled(modelsText == s.complimentaryModels.joined(separator: ", "))
            }
            if !model.settings.openAIModel.isEmpty && !s.isComplimentary(model.settings.openAIModel) {
                Label("Your selected model (\(model.settings.openAIModel)) is not in the complimentary list, so its usage is estimated as paid.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
            Toggle("Free allowance protection", isOn: Binding(get: { s.protectionEnabled }, set: { v in set { $0.protectionEnabled = v } }))
            if s.protectionEnabled {
                Stepper(value: Binding(get: { s.safetyMarginTokens }, set: { v in set { $0.safetyMarginTokens = v } }), in: 0...200_000, step: 5_000) {
                    Text("Safety margin: \(UsageFormat.tokens(s.safetyMarginTokens)) tokens")
                }
                Stepper(value: Binding(get: { s.assumedOutputTokens }, set: { v in set { $0.assumedOutputTokens = v } }), in: 1_000...200_000, step: 1_000) {
                    Text("Assumed output when no maximum is set: \(UsageFormat.tokens(s.assumedOutputTokens)) tokens")
                }
                Text("Before each OpenAI request the app counts the input tokens with OpenAI's token-counting endpoint (or a cautious estimate if that is unavailable), adds the maximum output (\(model.settings.maxOutputTokens.map(UsageFormat.tokens) ?? "assumed above")) and the safety margin, and only sends the request if that fits in today's remaining allowance. Otherwise the lesson waits until after 00:00 UTC — it is never switched to another model. This is a local safeguard based on this app's own records, not a guaranteed OpenAI billing cap: other apps or keys using your account are not counted, and OpenAI's billing decides what is complimentary.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            Text("Usage & free allowance")
        }
        Section {
            ForEach(Array(s.prices.enumerated()), id: \.offset) { i, p in
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(p.modelPrefix).font(.body.monospaced())
                        Spacer()
                        Button(role: .destructive) { set { $0.prices.remove(at: i) } } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
                            .accessibilityLabel("Remove price for \(p.modelPrefix)")
                    }
                    HStack {
                        priceField("Input $/1M", p.inputPerMillion) { v in set { $0.prices[i].inputPerMillion = v } }
                        priceField("Cached $/1M", p.cachedInputPerMillion) { v in set { $0.prices[i].cachedInputPerMillion = v } }
                        priceField("Output $/1M", p.outputPerMillion) { v in set { $0.prices[i].outputPerMillion = v } }
                    }
                    if !p.note.isEmpty { Text(p.note).font(.caption).foregroundStyle(.orange) }
                }
            }
            AddPriceRow { price in set { $0.prices.append(price) } }
            Link("Check current prices on openai.com", destination: URL(string: "https://openai.com/api/pricing/")!)
        } header: {
            Text("Model pricing (USD per 1M tokens)")
        } footer: {
            Text("Used only for cost estimates. Cached input is charged at the cached rate; GPT-6.1 Sol's higher long-prompt rate (over 272K input tokens) is applied automatically.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { modelsText = s.complimentaryModels.joined(separator: ", ") }
    }

    func saveModels() {
        let list = modelsText.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        set { $0.complimentaryModels = list }
        modelsText = list.joined(separator: ", ")
    }

    func priceField(_ title: String, _ value: Double, _ onChange: @escaping (Double) -> Void) -> some View {
        TextField(title, value: Binding(get: { value }, set: { onChange($0) }), format: .number.precision(.fractionLength(2...4)))
            .textFieldStyle(.roundedBorder)
            .frame(width: 110)
            .help(title)
    }
}

struct AddPriceRow: View {
    var onAdd: (ModelPrice) -> Void
    @State private var id = ""
    @State private var input = 0.0
    @State private var cached = 0.0
    @State private var output = 0.0

    init(onAdd: @escaping (ModelPrice) -> Void) { self.onAdd = onAdd }

    var body: some View {
        HStack {
            TextField("Model id", text: $id).frame(width: 150)
            TextField("Input", value: $input, format: .number).frame(width: 70)
            TextField("Cached", value: $cached, format: .number).frame(width: 70)
            TextField("Output", value: $output, format: .number).frame(width: 70)
            Button("Add Price") {
                onAdd(ModelPrice(modelPrefix: id.trimmingCharacters(in: .whitespaces), inputPerMillion: input, cachedInputPerMillion: cached, outputPerMillion: output))
                id = ""; input = 0; cached = 0; output = 0
            }
            .disabled(id.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .textFieldStyle(.roundedBorder)
    }
}
