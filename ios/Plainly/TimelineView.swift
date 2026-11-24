import Charts
import PlainlyCore
import SwiftUI

/// Earlier fictional reports for the sample, so the timeline has a history: the same patient a year and nine months
/// before November, drifting towards the November values. Like all sample data, made up.
let sampleEarlier: [(String, [LabTest])] = {
    // How far each test sat from its May value at each earlier report (fraction of the May value).
    let drift: [String: (Double, Double)] = [
        "Haemoglobin": (0.07, 0.03), "MCV": (0.05, 0.02), "Glucose, Fasting": (-0.08, -0.04),
        "HbA1c (Glycated Haemoglobin)": (-0.07, -0.03), "Cholesterol, Total": (-0.06, -0.03), "LDL Cholesterol": (-0.10, -0.05),
        "HDL Cholesterol": (0.09, 0.04), "Triglycerides": (-0.09, -0.04), "TSH (Thyroid Stimulating Hormone)": (-0.30, -0.12),
        "Vitamin D, 25-Hydroxy": (0.35, 0.15), "Vitamin B12": (0.10, 0.05),
    ]
    func at(_ k: Int) -> [LabTest] {
        sampleMay.map { t in
            var c = t
            if let d = drift[t.name] {
                let f = k == 0 ? d.0 : d.1
                let digits: Double = t.value < 10 ? 10 : 1
                c.value = ((t.value * (1 + f)) * digits).rounded() / digits
                c.raw = fmt(c.value)
            }
            return c
        }
    }
    return [("12 Aug 2025", at(0)), ("20 Feb 2026", at(1))]
}()

private func reportDate(_ s: String) -> Date? {
    let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; f.locale = Locale(identifier: "en_GB")
    return f.date(from: s)
}

struct TimelineReport: Identifiable {
    let id: String
    let date: Date
    let label: String
    let tests: [LabTest]
    var outside: Int { tests.filter { $0.verified && [.high, .low].contains(flagOf($0.value, $0.range)) }.count }
}

func timelineReports() -> [TimelineReport] {
    History.load().compactMap { s -> TimelineReport? in
        guard let d = reportDate(s.date) else { return nil }
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"; f.locale = Locale(identifier: "en_GB")
        return TimelineReport(id: s.date, date: d, label: f.string(from: d), tests: s.tests)
    }
    .sorted { $0.date < $1.date }
}

/// Every report as a flower, one petal per result (red when high, blue when low), then each test across the years.
struct TimelineView: View {
    let reports: [TimelineReport]

    var body: some View {
        let names = testNames()
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(reports.count) reports").font(.title2.weight(.semibold))
                    if let first = reports.first, let last = reports.last {
                        Text("\(first.label) to \(last.label). Each flower is one report; a petal is one result, coloured when it was outside the range.")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(reports) { r in
                            VStack(spacing: 8) {
                                Flower(tests: r.tests).frame(width: 70, height: 70)
                                Text(r.label).font(.caption.weight(.semibold))
                                Text(r.outside == 0 ? "All in range" : "\(r.outside) outside").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
            }
            Section("Each test over time") {
                ForEach(names, id: \.self) { name in
                    TestHistoryRow(name: name, points: points(name))
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Timeline")
    }

    /// Tests that appear in at least two reports, most often outside the range first.
    func testNames() -> [String] {
        var count: [String: (seen: Int, out: Int)] = [:]
        for r in reports { for t in r.tests where t.verified {
            let out = [.high, .low].contains(flagOf(t.value, t.range)) ? 1 : 0
            count[t.name, default: (0, 0)].seen += 1; count[t.name, default: (0, 0)].out += out
        } }
        return count.filter { $0.value.seen >= 2 }.sorted { ($0.value.out, $1.key) > ($1.value.out, $0.key) }.map(\.key)
    }

    func points(_ name: String) -> [(TimelineReport, LabTest)] {
        reports.compactMap { r in r.tests.first { $0.name == name && $0.verified }.map { (r, $0) } }
    }
}

/// A report drawn as a flower: one petal per result, longer and coloured when the value was outside the range.
struct Flower: View {
    let tests: [LabTest]
    var body: some View {
        Canvas { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let n = max(tests.count, 1)
            for (i, t) in tests.enumerated() {
                let f = flagOf(t.value, t.range)
                let out = t.verified && (f == .high || f == .low)
                let angle = Double(i) / Double(n) * 2 * .pi - .pi / 2
                let len = size.width * (out ? 0.48 : 0.34)
                var petal = Path()
                petal.addEllipse(in: CGRect(x: 0, y: -size.width * 0.055, width: len, height: size.width * 0.11))
                let color: Color = !out ? Color.teal.opacity(0.28) : f == .high ? .high : .low
                ctx.fill(petal.applying(CGAffineTransform(rotationAngle: angle).concatenating(CGAffineTransform(translationX: c.x, y: c.y))),
                         with: .color(color.opacity(out ? 0.85 : 1)))
            }
            ctx.fill(Path(ellipseIn: CGRect(x: c.x - 7, y: c.y - 7, width: 14, height: 14)), with: .color(.primary.opacity(0.75)))
        }
        .accessibilityLabel("\(tests.filter { [.high, .low].contains(flagOf($0.value, $0.range)) }.count) of \(tests.count) results outside the range")
    }
}

struct TestHistoryRow: View {
    let name: String
    let points: [(TimelineReport, LabTest)]
    var body: some View {
        let last = points.last?.1
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(shortName(name))
                Spacer()
                if let last { Text("\(fmt(last.value)) \(last.unit)").foregroundStyle(.secondary).monospacedDigit() }
            }
            Chart {
                if let r = last?.range, let lo = r.low ?? (r.high != nil ? 0 : nil), let hi = r.high ?? r.low.map({ $0 * 2 }) {
                    RectangleMark(xStart: .value("from", points.first!.0.date), xEnd: .value("to", points.last!.0.date),
                                  yStart: .value("lo", lo), yEnd: .value("hi", hi))
                        .foregroundStyle(Color.teal.opacity(0.10))
                }
                ForEach(points, id: \.0.id) { r, t in
                    LineMark(x: .value("date", r.date), y: .value("value", t.value)).foregroundStyle(Color.secondary.opacity(0.5))
                    PointMark(x: .value("date", r.date), y: .value("value", t.value))
                        .foregroundStyle(flagOf(t.value, t.range) == .high ? Color.high : flagOf(t.value, t.range) == .low ? Color.low : Color.teal)
                }
            }
            .chartXAxis(.hidden).chartYAxis(.hidden).chartYScale(domain: .automatic(includesZero: false)).frame(height: 44)
        }
        .padding(.vertical, 4)
    }
}
