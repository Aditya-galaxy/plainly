import PhotosUI
import PlainlyCore
import SwiftUI

extension Color {
    static let teal = Color(red: 0.059, green: 0.431, blue: 0.4)
    static let high = Color(red: 0.761, green: 0.255, blue: 0.047)
    static let low = Color(red: 0.114, green: 0.373, blue: 0.749)
    static let edge = Color(red: 0.718, green: 0.475, blue: 0.122)
}

/// The earlier sample report (16 May 2026), so the sample shows trends. Same values as the web and Android samples.
let sampleMay: [LabTest] = [
    ("Haemoglobin", 11.6, "g/dL", "12.0 - 15.0"), ("Total Leucocyte Count", 7.1, "x10^3/uL", "4.0 - 10.0"),
    ("Platelet Count", 262, "x10^3/uL", "150 - 410"), ("MCV", 79.4, "fL", "83.0 - 101.0"),
    ("Glucose, Fasting", 101, "mg/dL", "70 - 100"), ("HbA1c (Glycated Haemoglobin)", 5.8, "%", "4.0 - 5.6"),
    ("Cholesterol, Total", 214, "mg/dL", "< 200"), ("LDL Cholesterol", 139, "mg/dL", "< 100"),
    ("HDL Cholesterol", 45, "mg/dL", "> 50"), ("Triglycerides", 151, "mg/dL", "< 150"),
    ("TSH (Thyroid Stimulating Hormone)", 5.1, "uIU/mL", "0.40 - 4.00"), ("Free T4", 1.01, "ng/dL", "0.80 - 1.80"),
    ("Vitamin D, 25-Hydroxy", 17.6, "ng/mL", "30 - 100"), ("Vitamin B12", 240, "pg/mL", "200 - 900"),
    ("Creatinine", 0.81, "mg/dL", "0.50 - 1.10"), ("ALT (SGPT)", 28, "U/L", "7 - 35"),
].map { LabTest(name: $0.0, value: $0.1, unit: $0.2, range: parseRange($0.3)) }

struct Report {
    var tests: [LabTest]
    var meta: Meta
    var earlier: [[LabTest]]
    var rows: [String]
    func trend(_ t: LabTest) -> Trend? { trendOf(t, earlier) }
}

/// Earlier results only (no images, names or IDs), kept on this iPhone for trends.
enum History {
    static let key = "plainly.reports"
    struct Saved: Codable { var date: String; var tests: [LabTest] }
    static func load() -> [Saved] {
        guard let d = UserDefaults.standard.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([Saved].self, from: d)) ?? []
    }
    static func save(date: String?, tests: [LabTest]) {
        var all = load().filter { date == nil || $0.date != date }
        all.append(Saved(date: date ?? "", tests: tests))
        if let d = try? JSONEncoder().encode(Array(all.suffix(12))) { UserDefaults.standard.set(d, forKey: key) }
    }
    static func clear() { UserDefaults.standard.removeObject(forKey: key) }
}

/// App state shared by both tabs.
@MainActor @Observable
final class AppModel {
    var report: Report?
    var explained: [String: Explained] = [:]
    var vitalExplained: [Metric: Explained] = [:]
    var notes = ""
    var vitalsLines: [String] = []
    var busy = false
    var error: String?
    var enhanced: Bool = UserDefaults.standard.string(forKey: "plainly.mode") == "enhanced" {
        didSet { UserDefaults.standard.set(enhanced ? "enhanced" : "private", forKey: "plainly.mode"); explained = [:]; vitalExplained = [:] }
    }

    func read(_ body: () async throws -> Reader.Result) async {
        error = nil; explained = [:]; busy = true
        defer { busy = false }
        do {
            var res = try await body()
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-log") { print("PLAINLY_ROWS\n" + res.rows.joined(separator: "\n") + "\nPLAINLY_END") }
            #endif
            if res.tests.count < 3, AI.local.isAvailable { res.tests = await AI.readOnDevice(res.rows.joined(separator: "\n")) }
            guard !res.tests.isEmpty else { throw Reader.ReadError.noResults }
            let earlier = History.load().filter { $0.date != (res.meta.date ?? "") }.map(\.tests)
            History.save(date: res.meta.date, tests: res.tests)
            report = Report(tests: res.tests, meta: res.meta, earlier: earlier, rows: res.rows)
        } catch { self.error = error.localizedDescription }
    }

    func trySample() async {
        History.save(date: "16 May 2026", tests: sampleMay)
        guard let url = Bundle.main.url(forResource: "report-nov-2026", withExtension: "pdf") else { return }
        await read { try await Reader.read(pdf: url) }
    }

    func explain(_ t: LabTest) async {
        guard explained[t.name] == nil, let r = report else { return }
        let e = await AI.explain(t, meta: r.meta, trend: r.trend(t), allowCloud: enhanced)
        explained[t.name] = e
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-log") { print("PLAINLY_EXPLAIN \(t.name) [\(e.source)] \(e.text) | note: \(e.note ?? "-")") }
        #endif
    }
}

struct ContentView: View {
    @State private var model = AppModel()
    @State private var tab = 0
    var body: some View {
        TabView(selection: $tab) {
            VitalsView().tabItem { Label("Vitals", systemImage: "heart") }.tag(0)
            ReportsTab().tabItem { Label("Reports", systemImage: "doc.text") }.tag(1)
        }
        .tint(.teal)
        .environment(model)
        // Demo flags for filming and automated checks: -sample, -explain, -enhanced, -notes, -vitals.
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-enhanced") { model.enhanced = true }
            if args.contains("-private") { model.enhanced = false }
            if args.contains("-sample") { tab = 1; await model.trySample() }
            if args.contains("-photo") {
                tab = 1; History.save(date: "16 May 2026", tests: sampleMay)
                if let url = Bundle.main.url(forResource: "sample-report", withExtension: "jpg"), let img = UIImage(contentsOfFile: url.path) {
                    await model.read { try await Reader.read(image: img) }
                }
            }
            if args.contains("-notes") { model.notes = "Tired for three weeks, and chest pain on the stairs" }
            if args.contains("-explain"), let r = model.report {
                for t in r.tests where t.verified && (flagOf(t.value, t.range) != .normal || nearEdge(t.value, t.range)) { await model.explain(t) }
            }
        }
    }
}

// MARK: - Reports

struct ReportsTab: View {
    @Environment(AppModel.self) private var model
    @State private var photo: PhotosPickerItem?
    @State private var pickingPDF = false
    @State private var showSettings = false
    @State private var showSheet = false
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if model.busy { ProgressView("Reading your report").frame(maxWidth: .infinity, maxHeight: .infinity) }
                else if let r = model.report { ReportList(report: r, showSheet: $showSheet) }
                else { empty }
            }
            .navigationDestination(for: String.self) { name in
                if let r = model.report, let t = r.tests.first(where: { $0.name == name }) { ResultDetail(test: t, trend: r.trend(t)) }
            }
            .onChange(of: model.report?.tests.count) { _, n in
                #if DEBUG
                let a = ProcessInfo.processInfo.arguments
                guard n != nil else { return }
                if let i = a.firstIndex(of: "-result"), i + 1 < a.count, let t = model.report?.tests.first(where: { $0.name.hasPrefix(a[i + 1]) }) { path = [t.name] }
                if a.contains("-sheet") { showSheet = true }
                #endif
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("-settings") { showSettings = true }
                #endif
            }
            .navigationTitle(model.report == nil ? "" : "Your Report")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if model.report != nil {
                            Button("For My Doctor", systemImage: "stethoscope") { showSheet = true }
                            Button("New Report", systemImage: "plus") { model.report = nil }
                        }
                        Button("Settings", systemImage: "gearshape") { showSettings = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .sheet(isPresented: $showSheet) { DoctorSheet() }
        }
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) {
                    await model.read { try await Reader.read(image: img) }
                }
                photo = nil
            }
        }
        .fileImporter(isPresented: $pickingPDF, allowedContentTypes: [.pdf]) { result in
            if case .success(let url) = result { Task { await model.read { try await Reader.read(pdf: url) } } }
        }
    }

    var empty: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass").font(.system(size: 52, weight: .light)).foregroundStyle(Color.teal)
            Text("Understand your lab report").font(.title2.weight(.semibold))
            Text("Open your report and Plainly explains each result in plain words, then helps you prepare for your doctor.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary).padding(.horizontal, 24)
            if let e = model.error { Text(e).font(.footnote).foregroundStyle(Color.high).multilineTextAlignment(.center).padding(.horizontal) }
            Spacer()
            VStack(spacing: 10) {
                Button { pickingPDF = true } label: { Text("Open PDF").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                PhotosPicker(selection: $photo, matching: .images) { Text("Choose Photo").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
                Button("Try a Sample") { Task { await model.trySample() } }.padding(.top, 4)
            }
            .padding(.horizontal, 24)
            Text("Your report stays on this iPhone.").font(.footnote).foregroundStyle(.secondary).padding(.bottom, 12)
        }
    }
}

struct ReportList: View {
    let report: Report
    @Binding var showSheet: Bool
    @State private var showNormal = false

    var body: some View {
        let confident = report.tests.filter(\.verified)
        let outside = confident.filter { [.high, .low].contains(flagOf($0.value, $0.range)) }
            .sorted { distance($0.value, $0.range) > distance($1.value, $1.range) }
        let edge = confident.filter { nearEdge($0.value, $0.range) }
        let check = report.tests.filter { !$0.verified }
        let normal = confident.filter { flagOf($0.value, $0.range) == .normal && !nearEdge($0.value, $0.range) }

        ScrollViewReader { proxy in
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(outside.isEmpty ? "All results are in range" : "\(outside.count) results outside the range").font(.title2.weight(.semibold))
                    Text(subtitle(high: outside.filter { flagOf($0.value, $0.range) == .high }.count, low: outside.filter { flagOf($0.value, $0.range) == .low }.count))
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            if !check.isEmpty {
                Section {
                    ForEach(check) { row($0).id($0.name == check.first?.name ? "check" : $0.name) }
                } header: { Text("Check against your report") } footer: {
                    Text("These values may have been misread. Compare them with the printed report.")
                }
            }
            if !outside.isEmpty { Section("Outside the range") { ForEach(outside) { row($0) } } }
            if !edge.isEmpty { Section("Close to a limit") { ForEach(edge) { row($0) } } }
            Section {
                DisclosureGroup("In range (\(normal.count))", isExpanded: $showNormal) { ForEach(normal) { row($0) } }
            }
            Section {
                Button { showSheet = true } label: { Label("Prepare for my doctor", systemImage: "stethoscope") }
            } footer: {
                Text("Plainly explains results and never diagnoses. Reference ranges are the ones printed on your report.")
            }
        }
        .listStyle(.insetGrouped)
        .task {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-check") { try? await Task.sleep(for: .seconds(2)); withAnimation(.easeInOut(duration: 1.2)) { proxy.scrollTo("check", anchor: .top) } }
            #endif
        }
        }
    }

    func subtitle(high: Int, low: Int) -> String {
        var parts: [String] = []
        if high > 0 { parts.append("\(high) high") }
        if low > 0 { parts.append("\(low) low") }
        let when = report.meta.date.map { "Report from \($0)" } ?? "Your report"
        let compared = report.earlier.isEmpty ? "" : ", compared with your earlier report"
        return parts.isEmpty ? when + compared : parts.joined(separator: " and ") + ". " + when + compared + "."
    }

    func row(_ t: LabTest) -> some View {
        NavigationLink { ResultDetail(test: t, trend: report.trend(t)) } label: {
            HStack {
                Text(shortName(t.name))
                Spacer()
                Text("\(fmt(t.value)) \(t.unit)").foregroundStyle(.secondary).monospacedDigit()
                FlagBadge(test: t)
            }
        }
    }
}

/// "TSH (Thyroid Stimulating Hormone)" → "TSH": the full name is on the detail screen.
func shortName(_ n: String) -> String {
    guard let i = n.firstIndex(of: "("), i > n.startIndex else { return n }
    return n[..<i].trimmingCharacters(in: .whitespaces)
}

struct FlagBadge: View {
    let test: LabTest
    var body: some View {
        let f = flagOf(test.value, test.range)
        let (text, color): (String, Color) = !test.verified ? ("Check", .secondary)
            : f == .high ? ("High", .high) : f == .low ? ("Low", .low) : nearEdge(test.value, test.range) ? ("Near", .edge) : ("Normal", .secondary)
        Text(text).font(.caption.weight(.semibold)).foregroundStyle(color)
            .padding(.horizontal, 8).padding(.vertical, 3).background(color.opacity(0.12), in: Capsule())
    }
}

struct ResultDetail: View {
    @Environment(AppModel.self) private var model
    let test: LabTest
    let trend: Trend?

    var body: some View {
        let e = model.explained[test.name]
        List {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(fmt(test.value)).font(.system(size: 40, weight: .semibold)).monospacedDigit()
                        Text(test.unit).foregroundStyle(.secondary)
                        Spacer()
                        FlagBadge(test: test)
                    }
                    RangeBar(t: test, trend: trend)
                    Text(rangeLine).font(.subheadline).foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            if !test.verified {
                Section { Text("This value may have been misread. Check it against your printed report before relying on it.").foregroundStyle(.secondary) }
            } else {
                Section {
                    if let e {
                        Text(e.text)
                        if let note = e.note { Text(note).font(.footnote).foregroundStyle(.secondary) }
                    } else {
                        HStack { ProgressView(); Text("Writing an explanation").foregroundStyle(.secondary) }
                    }
                } header: { Text("What it means") } footer: { if let e, e.source != .rules { Text(e.source.rawValue) } }
                if let e, !e.questions.isEmpty {
                    Section("Questions for your doctor") { ForEach(e.questions, id: \.self) { Text($0) } }
                }
                if let info = testInfo(test.name) {
                    Section("About this test") { Text(info).foregroundStyle(.secondary) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .defaultScrollAnchor(.top, for: .sizeChanges)
        .navigationTitle(test.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { if test.verified { await model.explain(test) } }
    }

    var rangeLine: String {
        var s = "Normal range \(test.range.text) \(test.unit)".trimmingCharacters(in: .whitespaces)
        if let trend {
            s += trend.direction == "same" ? ". About the same as last time (\(fmt(trend.previous)))."
                : ". \(trend.direction == "up" ? "Up" : "Down") from \(fmt(trend.previous)) last time."
        }
        return s
    }
}

struct RangeBar: View {
    let t: LabTest
    let trend: Trend?
    var body: some View {
        let f = flagOf(t.value, t.range)
        let color: Color = !t.verified ? .secondary : f == .high ? .high : f == .low ? .low : .teal
        let lo = t.range.low ?? (t.range.high != nil ? 0 : t.value * 0.5)
        let hi = t.range.high ?? ((t.range.low ?? t.value) * (t.range.low != nil ? 2 : 1.5))
        let span = hi - lo > 0 ? hi - lo : 1
        let mn = lo - span * 0.5, mx = hi + span * 0.5
        GeometryReader { g in
            let w = g.size.width
            let x: (Double) -> CGFloat = { v in CGFloat(min(max((v - mn) / (mx - mn), 0), 1)) * w }
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08)).frame(height: 6)
                Capsule().fill(Color.teal.opacity(0.35)).frame(width: max(x(hi) - x(lo), 2), height: 6).offset(x: x(lo))
                if let trend { Circle().stroke(Color.secondary, lineWidth: 1.5).frame(width: 10, height: 10).offset(x: x(trend.previous) - 5) }
                Circle().fill(color).frame(width: 14, height: 14).offset(x: x(t.value) - 7)
            }
            .frame(height: 16)
        }
        .frame(height: 16)
    }
}

// MARK: - Doctor sheet and settings

struct DoctorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        let questions = (model.report?.tests ?? []).flatMap { t in (model.explained[t.name]?.questions ?? []).map { "\(shortName(t.name)): \($0)" } }
        let flags = redFlags(model.notes)
        NavigationStack {
            Form {
                Section {
                    TextField("For example, tired for three weeks", text: $model.notes, axis: .vertical).lineLimit(3...8)
                } header: { Text("What I've noticed") } footer: { Text("Stays on this iPhone.") }
                if !flags.isEmpty {
                    Section {
                        ForEach(flags) { f in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(f.label).font(.headline).foregroundStyle(Color.high)
                                Text(f.advice)
                            }
                        }
                    } header: { Text("Get care now") } footer: { Text("These are standard warning signs that need a doctor straight away.") }
                }
                if !questions.isEmpty { Section("Questions about my results") { ForEach(questions, id: \.self) { Text($0) } } }
                if !model.vitalsLines.isEmpty { Section("From my watch") { ForEach(model.vitalsLines, id: \.self) { Text($0) } } }
                if questions.isEmpty && model.vitalsLines.isEmpty {
                    Section { Text("Open a result to add questions about it here.").foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("For My Doctor")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { ShareLink(item: summaryText(questions)) }
            }
        }
    }

    func summaryText(_ questions: [String]) -> String {
        var s = "For my doctor\n"
        if !model.notes.isEmpty { s += "\nWhat I've noticed:\n\(model.notes)\n" }
        if !questions.isEmpty { s += "\nQuestions about my results:\n" + questions.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        if !model.vitalsLines.isEmpty { s += "\nFrom my watch:\n" + model.vitalsLines.map { "- \($0)" }.joined(separator: "\n") + "\n" }
        return s
    }
}

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Form {
                Section {
                    Picker("Explanations", selection: $model.enhanced) {
                        Text("Private").tag(false)
                        Text("Enhanced").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("Explanations") } footer: {
                    Text(model.enhanced
                         ? "Enhanced uses Google's Gemini when this iPhone can't write the explanation itself. Only the test name, value, range, an age band and sex are sent. Never your name, your report or your photos."
                         : "Private keeps everything on this iPhone. Explanations are written by Apple Intelligence on the device.")
                }
                Section {
                    LabeledContent("Private explanations", value: AI.localStatus)
                }
                Section {
                    Button("Forget Saved Reports", role: .destructive) { History.clear() }
                } footer: { Text("Plainly keeps earlier results on this iPhone to show what changed. No names or images are kept.") }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
