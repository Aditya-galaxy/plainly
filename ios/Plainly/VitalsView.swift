import Charts
import PlainlyCore
import SwiftUI

/// Vitals against the person's own usual, from Apple Health (Apple Watch and apps that sync to it) or the built-in
/// sample. Everything is worked out on this iPhone.
struct VitalsView: View {
    @Environment(AppModel.self) private var model
    @State private var loaded: Health.Loaded?
    @State private var busy = false
    @State private var error: String?
    @State private var showSettings = false
    @State private var path: [Metric] = []
    @State private var showWorkout = false

    var body: some View {
        let days = loaded?.days ?? sampleDays()
        let session = loaded == nil ? sampleWorkout() : loaded?.workout
        let report = analyse(days)
        let workout = session.map { analyseWorkout($0, age: loaded == nil ? 52 : nil) }
        let off = report.changes.filter { $0.direction == .worse }.count
        let lines = report.changes.filter { $0.direction != .steady }.map(\.text)
            + (workout?.recovery1min.map { ["After a \(workout!.durationMin)-minute workout, heart rate fell \($0) bpm in the first minute."] } ?? [])
            + report.alerts.map { "\($0.title)." }

        NavigationStack(path: $path) {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(report.changes.isEmpty ? "Not enough data yet" : off == 0 ? "A usual week" : "\(off) \(off == 1 ? "vital is" : "vitals are") off your usual")
                            .font(.title2.weight(.semibold))
                        Text(loaded == nil ? "Sample data. Compared with your own last 28 days."
                             : "From \(sourceName). Compared with your own last \(report.baselineDays) days.")
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 6)
                }

                if !report.alerts.isEmpty {
                    Section {
                        ForEach(report.alerts) { a in
                            VStack(alignment: .leading, spacing: 4) { Text(a.title).font(.headline).foregroundStyle(Color.high); Text(a.advice) }
                        }
                    } header: { Text(report.alerts.contains { $0.urgent } ? "Get care now" : "Talk to a doctor") }
                }

                if let rec = report.recovery {
                    Section {
                        HStack(spacing: 16) {
                            Gauge(value: Double(rec), in: 0...100) { EmptyView() } currentValueLabel: { Text("\(rec)") }
                                .gaugeStyle(.accessoryCircularCapacity).tint(rec < 35 ? Color.edge : Color.teal)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Recovery").font(.headline)
                                Text("50 is a normal day for you.").font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("This week") {
                    ForEach(report.changes, id: \.metric) { c in
                        NavigationLink { MetricDetail(change: c, days: days, baselineDays: report.baselineDays) } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(c.metric.label)
                                    Spacer()
                                    Text(c.direction == .steady ? "Usual" : c.direction == .worse ? "Off usual" : "Better")
                                        .font(.caption.weight(.semibold)).foregroundStyle(c.direction == .worse ? Color.edge : Color.secondary)
                                }
                                Chart(Array(days.enumerated()), id: \.offset) { i, d in
                                    if let v = c.metric.of(d) { LineMark(x: .value("day", i), y: .value(c.metric.unit, v)).foregroundStyle(c.direction == .worse ? Color.edge : Color.secondary.opacity(0.6)) }
                                }
                                .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false)).frame(height: 32)
                                Text(headline(c)).font(.footnote).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }

                if let session, let workout {
                    Section("Last workout") {
                        NavigationLink { WorkoutDetail(session: session, w: workout) } label: {
                            LabeledContent(session.name, value: "\(workout.durationMin) min, avg \(workout.avg) bpm")
                        }
                    }
                }

                Section {
                    Button(model.vitalsLines.isEmpty ? "Add to my doctor summary" : "Added to my doctor summary") { model.vitalsLines = lines }
                        .disabled(!model.vitalsLines.isEmpty || lines.isEmpty)
                }

                Section {
                    if loaded == nil {
                        Button("Connect Apple Health") { Task { await refresh(ask: true) } }
                    }
                    Button("Add Sample to Apple Health") { Task { await act { try await Health.shared.writeSample() } } }
                    if loaded != nil {
                        Button("Remove Sample from Apple Health", role: .destructive) { Task { await act { try await Health.shared.deleteSample() } } }
                    }
                } header: { Text("Apple Health") } footer: {
                    if let error { Text(error).foregroundStyle(Color.high) }
                    else { Text("Works with Apple Watch, and with WHOOP, Oura, Garmin and others once their app saves to Health. Plainly reads it on this iPhone and never uploads it.") }
                }
            }
            .listStyle(.insetGrouped)
            .navigationDestination(isPresented: $showWorkout) {
                if let session, let workout { WorkoutDetail(session: session, w: workout) }
            }
            .navigationDestination(for: Metric.self) { m in
                if let c = report.changes.first(where: { $0.metric == m }) { MetricDetail(change: c, days: days, baselineDays: report.baselineDays) }
            }
            .navigationTitle("Vitals")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Settings", systemImage: "gearshape") { showSettings = true } } }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .overlay { if busy { ProgressView() } }
        }
        .task {
            await refresh(ask: false)
            #if DEBUG
            if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-detail"), i + 1 < ProcessInfo.processInfo.arguments.count,
               let m = Metric(rawValue: ProcessInfo.processInfo.arguments[i + 1]) { path = [m] }
            if ProcessInfo.processInfo.arguments.contains("-workout") { showWorkout = true }
            if ProcessInfo.processInfo.arguments.contains("-settings") { showSettings = true }
            #endif
        }
    }

    /// The row's short line: "Up 7 bpm on your usual", "Down 53 min on your usual", "In your usual range".
    func headline(_ c: Change) -> String {
        if c.direction == .steady { return "In your usual range" }
        let amount = c.metric == .sleep ? fmtSleep(abs(c.delta)) : "\(fmt(c.metric == .spo2 ? abs(c.delta) : abs(c.delta).rounded())) \(c.metric.unit)"
        return "\(c.delta > 0 ? "Up" : "Down") \(amount) on your usual"
    }

    /// The devices and apps that wrote the data ("Apple Watch and WHOOP"), or Plainly's own sample.
    var sourceName: String {
        guard let l = loaded else { return "sample data" }
        if l.sampleOnly || l.sources.isEmpty { return "Apple Health (sample)" }
        let s = l.sources.sorted()
        return s.count == 1 ? s[0] : s.dropLast().joined(separator: ", ") + " and " + s.last!
    }

    func act(_ body: () async throws -> Void) async {
        error = nil; busy = true
        do { try await Health.shared.requestAccess(); try await body(); await refresh(ask: false) }
        catch { self.error = error.localizedDescription }
        busy = false
    }

    func refresh(ask: Bool) async {
        guard Health.shared.available else { return }
        do {
            if ask { try await Health.shared.requestAccess() }
            let l = try await Health.shared.load()
            loaded = (l.days.isEmpty && l.workout == nil) ? nil : l
        } catch { if ask { self.error = error.localizedDescription } }
    }
}

struct WorkoutDetail: View {
    let session: PlainlyCore.Session
    let w: WorkoutSummary
    @State private var t: Double?
    @State private var playing = false

    var body: some View {
        let endT = Double(session.samples.last?.t ?? 1)
        let shown = t.map { tt in session.samples.filter { Double($0.t) <= tt } } ?? session.samples
        let live = t.flatMap { tt in session.samples.min { abs(Double($0.t) - tt) < abs(Double($1.t) - tt) } }
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(live?.bpm ?? w.avg)").font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        Text(live == nil ? "average bpm" : "bpm").foregroundStyle(.secondary)
                        Spacer()
                        if let live { Text(clock(live.t)).foregroundStyle(.secondary).monospacedDigit() }
                    }
                    Chart {
                        ForEach(ZONES.dropFirst(), id: \.id) { z in
                            RectangleMark(yStart: .value("from", z.from * Double(w.maxEstimate)), yEnd: .value("to", min(z.to * Double(w.maxEstimate), Double(w.maxEstimate) + 5)))
                                .foregroundStyle(zoneColor(z.id).opacity(0.15))
                        }
                        ForEach(shown, id: \.t) { s in LineMark(x: .value("t", s.t), y: .value("bpm", s.bpm)).foregroundStyle(Color.primary) }
                        RuleMark(x: .value("stop", session.endT)).lineStyle(StrokeStyle(dash: [4, 4])).foregroundStyle(.secondary)
                        if t == nil {
                            ForEach(w.highs, id: \.t) { PointMark(x: .value("t", $0.t), y: .value("bpm", $0.bpm)).foregroundStyle(Color.high) }
                            ForEach(w.lows, id: \.t) { PointMark(x: .value("t", $0.t), y: .value("bpm", $0.bpm)).foregroundStyle(Color.low) }
                        }
                        if let live { PointMark(x: .value("t", live.t), y: .value("bpm", live.bpm)).symbolSize(100).foregroundStyle(Color.high) }
                    }
                    .chartXScale(domain: 0...endT)
                    .chartYScale(domain: 60...(Double(max(w.maxEstimate, session.samples.map(\.bpm).max() ?? 0)) + 5))
                    .chartXAxis(.hidden).frame(height: 200)
                    Button(playing ? "Pause" : (t != nil && t! < endT) ? "Resume" : "Replay") {
                        if let tt = t, tt >= endT { t = 0 }
                        playing.toggle()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.vertical, 6)
            }
            Section("Summary") {
                LabeledContent("Peak", value: "\(w.peak.bpm) bpm at \(clock(w.peak.t))")
                LabeledContent("Lowest between efforts", value: "\(w.lows.map(\.bpm).min() ?? w.low.bpm) bpm")
                if let r = w.recovery1min { LabeledContent("Drop 1 min after stopping", value: "\(r) bpm") }
            }
            Section {
                ForEach(w.zoneMin.filter { $0.minutes > 0 }, id: \.zone.id) { z in LabeledContent(z.zone.name, value: "\(fmt(z.minutes)) min") }
            } header: { Text("Time in zones") } footer: { Text("Zones use an estimated maximum of \(w.maxEstimate) bpm. Real maximums vary.") }
            Section { ForEach(w.notes, id: \.self) { Text($0).font(.subheadline) } }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        // Replay at 60× speed: a 39-minute recording plays in about 40 seconds.
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-replay") { try? await Task.sleep(for: .seconds(3)); playing = true }
            #endif
        }
        .task(id: playing) {
            guard playing else { return }
            var cur = t ?? 0
            while playing && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                cur += 0.033 * 60
                if cur >= endT { t = endT; playing = false; break }
                t = cur
            }
        }
    }

    func zoneColor(_ id: Int) -> Color {
        [2: Color(red: 0.5, green: 0.82, blue: 0.7), 3: Color(red: 0.95, green: 0.82, blue: 0.56),
         4: Color(red: 0.93, green: 0.62, blue: 0.45), 5: Color(red: 0.85, green: 0.33, blue: 0.31)][id] ?? .gray
    }
}


/// One vital in depth: 35 days against the person's own usual band, this week's numbers, and a plain-words explanation.
struct MetricDetail: View {
    @Environment(AppModel.self) private var model
    let change: Change
    let days: [Day]
    let baselineDays: Int

    var body: some View {
        let m = change.metric
        let pts = days.enumerated().compactMap { i, d in m.of(d).map { (i, $0) } }
        let base = days.dropLast(7).suffix(baselineDays).compactMap(m.of)
        let mean = base.isEmpty ? 0 : base.reduce(0, +) / Double(base.count)
        let sd = base.count > 1 ? (base.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(base.count - 1)).squareRoot() : 0
        let e = model.vitalExplained[m]
        ScrollViewReader { proxy in
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(show(change.recent)).font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        Text(m == .sleep ? "a night this week" : "this week").foregroundStyle(.secondary)
                    }
                    Chart {
                        RectangleMark(xStart: .value("s", 0), xEnd: .value("e", days.count - 1),
                                      yStart: .value("lo", mean - sd), yEnd: .value("hi", mean + sd))
                            .foregroundStyle(Color.teal.opacity(0.12))
                        RectangleMark(xStart: .value("s", days.count - 7), xEnd: .value("e", days.count - 1))
                            .foregroundStyle(Color.primary.opacity(0.05))
                        ForEach(pts, id: \.0) { i, v in
                            LineMark(x: .value("day", i), y: .value(m.unit, v)).foregroundStyle(Color.primary.opacity(0.8))
                            PointMark(x: .value("day", i), y: .value(m.unit, v)).symbolSize(i >= days.count - 7 ? 30 : 12)
                                .foregroundStyle(i >= days.count - 7 ? (change.direction == .worse ? Color.edge : Color.teal) : Color.secondary)
                        }
                    }
                    .chartXAxis { AxisMarks(values: [0, days.count - 8, days.count - 1]) { v in
                        AxisValueLabel { Text(v.as(Int.self) == days.count - 1 ? "Today" : v.as(Int.self) == 0 ? "5 weeks ago" : "1 week ago") } } }
                    .chartYScale(domain: .automatic(includesZero: false))
                    .frame(height: 220)
                    Text("Shaded band: your usual range over the previous \(baselineDays) days.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section {
                LabeledContent("This week", value: show(change.recent))
                LabeledContent("Your usual", value: show(change.baseline))
                LabeledContent("Change", value: (change.delta > 0 ? "+" : "−") + (m == .sleep ? fmtSleep(abs(change.delta)) : "\(fmt(m == .spo2 ? abs(change.delta) : abs(change.delta).rounded())) \(m.unit)"))
            }
            Section {
                if let e { Text(e.text).id("meaning") } else { HStack { ProgressView(); Text("Writing an explanation").foregroundStyle(.secondary) }.id("meaning") }
            } header: { Text("What it means") } footer: { if let e, e.source != .rules { Text(e.source.rawValue) } }
            let dive = deepDive(m, days: days)
            Section("Deep dive") {
                LabeledContent("Days off your usual this week", value: "\(dive.offDays) of \(dive.recentCount)").id("deep")
                LabeledContent("Longest run off usual", value: dive.longestRun == 1 ? "1 day" : "\(dive.longestRun) days")
                if let b = dive.bestDay { LabeledContent("Best day this week", value: "\(show(b.value)), \(dayName(b.date))") }
                if let w = dive.worstDay { LabeledContent("Hardest day this week", value: "\(show(w.value)), \(dayName(w.date))") }
                LabeledContent("Your usual range", value: "\(show(dive.usualLow)) to \(show(dive.usualHigh))")
                if let st = dive.steadiness {
                    LabeledContent("Day-to-day swings", value: st > 1.5 ? "Bigger than usual" : st < 0.67 ? "Smaller than usual" : "About usual")
                }
            }
            Section("Week by week") {
                Chart(dive.weeks, id: \.label) { w in
                    BarMark(x: .value("week", w.label), y: .value(m.unit, w.value))
                        .foregroundStyle(w.label == "This week" ? (change.direction == .worse ? Color.edge : Color.teal) : Color.secondary.opacity(0.4))
                        .annotation(position: .top) { Text(show(w.value)).font(.caption2).foregroundStyle(.secondary) }
                }
                .chartYScale(domain: .automatic(includesZero: false)).chartYAxis(.hidden).frame(height: 160).padding(.vertical, 6)
            }
            Section {
                Blanket(metric: m, days: days, low: dive.usualLow, high: dive.usualHigh).frame(height: CGFloat(min(days.count, 35)) * 7)
                    .padding(.vertical, 6).id("blanket")
            } header: { Text(m == .sleep ? "Night by night" : "Day by day") } footer: {
                Text("One row per \(m == .sleep ? "night" : "day"), newest at the bottom. Amber is worse than your usual, green is better, grey is usual.")
            }
            let info = infoPack(m)
            Section("About \(m.label.lowercased())") {
                infoRow("What it is", info.what)
                infoRow("How your watch measures it", info.measured)
                infoRow("What moves it", info.moves)
                infoRow("How to read it", info.reading)
            }
            Section("Talk to a doctor if") { Text(doctorRule(m)).id("doctor") }
        }
        .listStyle(.insetGrouped)
        .task {
            #if DEBUG
            let a = ProcessInfo.processInfo.arguments
            if a.contains("-deep") { try? await Task.sleep(for: .seconds(2)); proxy.scrollTo("deep", anchor: .top) }
            if a.contains("-info") { try? await Task.sleep(for: .seconds(2)); proxy.scrollTo("doctor", anchor: .bottom) }
            if a.contains("-blanket") { try? await Task.sleep(for: .seconds(2)); proxy.scrollTo("blanket", anchor: .center) }
            if a.contains("-meaning") { try? await Task.sleep(for: .seconds(1)); proxy.scrollTo("meaning", anchor: .center) }
            #endif
        }
        }
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .navigationTitle(m.label)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.vitalExplained[m] == nil { model.vitalExplained[m] = await AI.explainVital(change, allowCloud: model.enhanced) }
        }
    }

    func infoRow(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(title).font(.subheadline.weight(.semibold)); Text(body).font(.subheadline).foregroundStyle(.secondary) }
            .padding(.vertical, 2)
    }

    func dayName(_ iso: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        guard let d = f.date(from: iso) else { return iso }
        let o = DateFormatter(); o.dateFormat = "EEE d MMM"; o.timeZone = TimeZone(identifier: "UTC")
        return o.string(from: d)
    }

    func show(_ v: Double) -> String { change.metric == .sleep ? fmtSleep(v) : "\(fmt(change.metric == .spo2 ? v : v.rounded())) \(change.metric.unit)" }

    /// The same fixed safety rules as the alerts, in plain words.
    func doctorRule(_ m: Metric) -> String {
        switch m {
        case .restingHr: "Your resting heart rate stays above 100, or below 40, for three days, or rises by 10 or more over your usual, especially with tiredness, dizziness or chest pain."
        case .hrv: "A drop lasts more than a couple of weeks, or comes with feeling unwell."
        case .sleep: "Poor sleep lasts for weeks, or you are very sleepy in the day."
        case .spo2: "It averages below 90% for two nights. If you are breathless or your lips look blue, call 112."
        }
    }
}


/// A "blanket": one thin row per day, coloured by how far it sat from the person's usual band (amber worse, green
/// better, grey usual), so five weeks read at a glance.
struct Blanket: View {
    let metric: Metric
    let days: [Day]
    let low: Double
    let high: Double
    var body: some View {
        let rows = Array(days.suffix(35))
        let width = max(high - low, 1e-9)
        Canvas { ctx, size in
            let h = size.height / CGFloat(max(rows.count, 1))
            for (i, d) in rows.enumerated() {
                guard let v = metric.of(d) else { continue }
                let p = metric == .spo2 ? 10.0 : 1.0
                let r = (v * p).rounded() / p
                // How many usual-widths outside the band, signed so that positive is worse.
                let outside = r > high ? (r - high) / width : r < low ? (low - r) / width : 0
                let worse = metric == .restingHr ? r > high : r < low
                let strength = min(1, 0.35 + outside * 0.5)
                let color: Color = outside == 0 ? Color.secondary.opacity(0.16) : worse ? Color.edge.opacity(strength) : Color.teal.opacity(strength)
                let rect = CGRect(x: 0, y: CGFloat(i) * h, width: size.width, height: h - 1.5)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
            }
        }
        .accessibilityLabel("\(rows.count) days, coloured against your usual range")
    }
}
