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

    var body: some View {
        let days = loaded?.days ?? sampleDays()
        let session = loaded == nil ? sampleWorkout() : loaded?.workout
        let report = analyse(days)
        let workout = session.map { analyseWorkout($0, age: loaded == nil ? 52 : nil) }
        let off = report.changes.filter { $0.direction == .worse }.count
        let lines = report.changes.filter { $0.direction != .steady }.map(\.text)
            + (workout?.recovery1min.map { ["After a \(workout!.durationMin)-minute workout, heart rate fell \($0) bpm in the first minute."] } ?? [])
            + report.alerts.map { "\($0.title)." }

        NavigationStack {
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
                            Text(c.text).font(.footnote).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
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
            .navigationTitle("Vitals")
            .overlay { if busy { ProgressView() } }
        }
        .task { await refresh(ask: false) }
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
