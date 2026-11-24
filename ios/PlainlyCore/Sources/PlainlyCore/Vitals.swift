import Foundation

/*
 Vitals from a watch, compared with the person's OWN normal and never turned into a diagnosis. A line-for-line port of
 the web app's src/lib/vitals.ts + workout.ts and Android's Vitals.kt, so all three give the same numbers.
 Recovery weighting (HRV 50%, resting heart rate 30%, sleep 20%, 50 = a normal day) comes from OpenVitals.
 */

public struct Day: Equatable, Sendable {
    public var date: String
    public var restingHr: Double?
    public var hrv: Double?
    public var sleepMin: Double?
    public var spo2: Double?
    public init(date: String, restingHr: Double? = nil, hrv: Double? = nil, sleepMin: Double? = nil, spo2: Double? = nil) {
        self.date = date; self.restingHr = restingHr; self.hrv = hrv; self.sleepMin = sleepMin; self.spo2 = spo2
    }
}

public enum Metric: String, CaseIterable, Sendable {
    case restingHr, hrv, sleep, spo2
    public var label: String {
        switch self { case .restingHr: "Resting heart rate"; case .hrv: "Heart rate variability"; case .sleep: "Sleep"; case .spo2: "Blood oxygen (overnight)" }
    }
    public var unit: String { switch self { case .restingHr: "bpm"; case .hrv: "ms"; case .sleep: "min"; case .spo2: "%" } }
    var betterUp: Bool { self != .restingHr }
    var minChange: Double { switch self { case .restingHr: 5; case .hrv: 0.15; case .sleep: 45; case .spo2: 2 } }
    var relative: Bool { self == .hrv }
    public func of(_ d: Day) -> Double? {
        switch self { case .restingHr: d.restingHr; case .hrv: d.hrv; case .sleep: d.sleepMin; case .spo2: d.spo2 }
    }
}

public enum Direction: Sendable { case better, worse, steady }

public struct Change: Sendable {
    public let metric: Metric
    public let baseline: Double, recent: Double, delta: Double
    public let direction: Direction
    public let text: String
}

public struct VitalsAlert: Identifiable, Sendable {
    public let id: String
    public let urgent: Bool
    public let title: String
    public let advice: String
}

public struct VitalsReport: Sendable {
    public let days: Int, baselineDays: Int, recentDays: Int
    public let recovery: Int?
    public let changes: [Change]
    public let alerts: [VitalsAlert]
}

/// JavaScript's Math.round (halves go up), so Swift, Kotlin and web agree to the digit.
func jsRound(_ x: Double) -> Double { (x + 0.5).rounded(.down) }
func round(_ x: Double, _ d: Int = 0) -> Double { let p = pow(10, Double(d)); return jsRound(x * p) / p }
public func num(_ x: Double) -> String { fmt(x) }

private func mean(_ xs: [Double]) -> Double { xs.reduce(0, +) / Double(xs.count) }
private func sd(_ xs: [Double]) -> Double {
    let m = mean(xs); return (xs.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(max(1, xs.count - 1))).squareRoot()
}
/// JavaScript's Array.slice for negative indices.
private func jsSlice<T>(_ a: [T], _ from: Int, _ to: Int) -> [T] {
    let s = min(max(from < 0 ? a.count + from : from, 0), a.count), e = min(max(to < 0 ? a.count + to : to, 0), a.count)
    return s < e ? Array(a[s..<e]) : []
}

public func fmtSleep(_ m: Double) -> String {
    m < 60 ? "\(fmt(jsRound(m))) min" : "\(Int((m / 60).rounded(.down))) h \(fmt(jsRound(m.truncatingRemainder(dividingBy: 60)))) min"
}

/// Baseline: the 28 days before the recent window. Recent: the last 7 days. A change counts only when it is bigger than
/// the person's usual day-to-day spread AND a minimum that matters (5 bpm, 15% HRV, 45 min sleep, 2 points SpO2).
public func analyse(_ input: [Day], recentDays: Int = 7, baselineDays: Int = 28) -> VitalsReport {
    let days = input.sorted { $0.date < $1.date }
    let recent = jsSlice(days, -recentDays, days.count)
    let base = jsSlice(days, -(recentDays + baselineDays), -recentDays)
    var changes: [Change] = []
    for m in Metric.allCases {
        let b = base.compactMap(m.of), r = recent.compactMap(m.of)
        if b.count < 7 || r.count < 3 { continue }
        let bm = mean(b), rm = mean(r)
        let spread = max(sd(b), 1e-9)
        let delta = rm - bm
        let threshold = max(spread, m.relative ? abs(bm) * m.minChange : m.minChange)
        let moved = abs(delta) >= threshold
        let good = (delta > 0) == m.betterUp
        let dir: Direction = !moved ? .steady : good ? .better : .worse
        let digits = m == .spo2 ? 1 : 0
        func show(_ v: Double) -> String { m == .sleep ? fmtSleep(v) : "\(fmt(round(v, digits))) \(m.unit)" }
        let diff = m == .sleep ? fmtSleep(abs(delta)) : "\(fmt(round(abs(delta), digits))) \(m.unit)"
        let word = m == .sleep ? (delta > 0 ? "longer" : "shorter") : (delta > 0 ? "higher" : "lower")
        let text = dir == .steady ? "\(m.label) is in your usual range (\(show(rm)) this week, \(show(bm)) usually)."
            : "\(m.label) is \(diff) \(word) than your usual (\(show(rm)) this week vs \(show(bm)))."
        changes.append(Change(metric: m, baseline: round(bm, 1), recent: round(rm, 1), delta: round(delta, 1), direction: dir, text: text))
    }

    var recovery: Int?
    if let last = days.last, base.count >= 7 {
        func zLast(_ m: Metric) -> Double? {
            let b = base.compactMap(m.of)
            guard b.count >= 7, let v = m.of(last) else { return nil }
            return (v - mean(b)) / max(sd(b), 1e-9) * (m.betterUp ? 1 : -1)
        }
        let have = [(zLast(.hrv), 0.5), (zLast(.restingHr), 0.3), (zLast(.sleep), 0.2)].compactMap { z, w in z.map { ($0, w) } }
        if !have.isEmpty {
            let w = have.reduce(0) { $0 + $1.1 }
            let s = have.reduce(0) { $0 + min(3, max(-3, $1.0)) * $1.1 } / w
            recovery = Int(jsRound(max(0, min(100, 50 + s * 10))))
        }
    }

    var alerts: [VitalsAlert] = []
    func lastN(_ m: Metric, _ n: Int) -> [Double] { days.suffix(n).compactMap(m.of) }
    let hr3 = lastN(.restingHr, 3)
    if hr3.count == 3 && hr3.allSatisfy({ $0 > 100 }) {
        alerts.append(VitalsAlert(id: "hr-high", urgent: false, title: "Resting heart rate above 100 for 3 days",
                                  advice: "Contact a doctor today. If you have chest pain, feel faint or breathless, call 112."))
    }
    if hr3.count == 3 && hr3.allSatisfy({ $0 < 40 }) {
        alerts.append(VitalsAlert(id: "hr-low", urgent: false, title: "Resting heart rate below 40 for 3 days",
                                  advice: "Contact a doctor, unless a doctor already knows your heart rate runs this low. If you feel dizzy or faint, call 112."))
    }
    let ox2 = lastN(.spo2, 2)
    if ox2.count == 2 && ox2.allSatisfy({ $0 < 90 }) {
        alerts.append(VitalsAlert(id: "spo2-low", urgent: true, title: "Blood oxygen averaged below 90% for 2 nights",
                                  advice: "Wrist sensors can be wrong, but don't ignore this. If you are breathless, confused or your lips look blue, call 112 now; otherwise contact a doctor today."))
    }
    if let rhr = changes.first(where: { $0.metric == .restingHr }), rhr.delta >= 10 {
        alerts.append(VitalsAlert(id: "hr-rise", urgent: false, title: "Resting heart rate \(fmt(rhr.delta)) bpm above your usual this week",
                                  advice: "A sustained rise is worth mentioning to your doctor, especially with tiredness or other symptoms."))
    }
    return VitalsReport(days: days.count, baselineDays: base.count, recentDays: recent.count, recovery: recovery, changes: changes, alerts: alerts)
}

/// The same Park–Miller generator as the web and Android samples, so all produce identical fictional data.
private struct Rand {
    var seed: Int64
    mutating func next() -> Double { seed = (seed * 16807) % 2147483647; return Double(seed) / 2147483647 - 0.5 }
}

/// A deterministic 35-day sample (fictional): a usual month, then a tired week. Values don't depend on `end`.
public func sampleDays(end: Date = ISO8601DateFormatter().date(from: "2026-11-18T00:00:00Z")!) -> [Day] {
    var r = Rand(seed: 7)
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
    return (0...34).reversed().map { i in
        let tired = i < 7 ? Double(7 - i) / 7 : 0
        let date = f.string(from: end.addingTimeInterval(-Double(i) * 86400))
        let rhr = jsRound(62 + r.next() * 4 + tired * 14)
        let hrv = jsRound(44 + r.next() * 10 - tired * 14)
        let sleep = jsRound(420 + r.next() * 60 - tired * 75)
        let spo2 = round(96.2 + r.next() * 1.2 - tired * 0.6, 1)
        return Day(date: date, restingHr: rhr, hrv: hrv, sleepMin: sleep, spo2: spo2)
    }
}

// MARK: - Workouts

public struct Sample: Sendable { public let t: Int; public let bpm: Int; public init(t: Int, bpm: Int) { self.t = t; self.bpm = bpm } }
public struct Session: Sendable {
    public let name: String, samples: [Sample], endT: Int
    public init(name: String, samples: [Sample], endT: Int) { self.name = name; self.samples = samples; self.endT = endT }
}
public struct Zone: Sendable { public let id: Int, name: String, from: Double, to: Double }
public struct Moment: Sendable { public let t: Int, bpm: Int }
public struct ZoneTime: Sendable { public let zone: Zone, minutes: Double }
public struct WorkoutSummary: Sendable {
    public let durationMin: Int, avg: Int, peak: Moment, low: Moment, maxEstimate: Int
    public let zoneMin: [ZoneTime], highs: [Moment], lows: [Moment], recovery1min: Int?, notes: [String]
}

public let ZONES = [Zone(id: 1, name: "Easy", from: 0.5, to: 0.6), Zone(id: 2, name: "Steady", from: 0.6, to: 0.7),
                    Zone(id: 3, name: "Moderate", from: 0.7, to: 0.8), Zone(id: 4, name: "Hard", from: 0.8, to: 0.9),
                    Zone(id: 5, name: "Maximum", from: 0.9, to: 1.2)]

public func clock(_ t: Int) -> String { "\(t / 60):" + String(format: "%02d", t % 60) }

/// Highs (or lows): local extremes of the 30-second average, at least 3 minutes apart, most extreme first.
private func extremes(_ s: [Sample], high: Bool, n: Int) -> [Moment] {
    let smooth = s.indices.map { i -> (Int, Double) in
        let w = jsSlice(s, max(0, i - 3), i + 4); return (s[i].t, Double(w.reduce(0) { $0 + $1.bpm }) / Double(w.count))
    }
    let sign: Double = high ? 1 : -1
    let cand = smooth.indices.filter { i in
        i > 0 && i < smooth.count - 1 && sign * (smooth[i].1 - smooth[i - 1].1) >= 0 && sign * (smooth[i].1 - smooth[i + 1].1) >= 0
    }.map { smooth[$0] }
    var out: [Moment] = []
    // Stable sort, most extreme first (Kotlin's sortedByDescending and JS sort are stable too).
    for c in cand.enumerated().sorted(by: { sign * $0.element.1 != sign * $1.element.1 ? sign * $0.element.1 > sign * $1.element.1 : $0.offset < $1.offset }).map(\.element) {
        if out.allSatisfy({ abs($0.t - c.0) >= 180 }) { out.append(Moment(t: c.0, bpm: Int(jsRound(c.1)))) }
        if out.count == n { break }
    }
    return out.sorted { $0.t < $1.t }
}

public func analyseWorkout(_ sess: Session, age: Int?) -> WorkoutSummary {
    let s = sess.samples
    let during = s.filter { $0.t <= sess.endT }
    let maxEstimate = 220 - ((age.map { (11...99).contains($0) } ?? false) ? age! : 35)
    let avg = Int(jsRound(Double(during.reduce(0) { $0 + $1.bpm }) / Double(during.count)))
    let pk = during.reduce(during[0]) { $1.bpm > $0.bpm ? $1 : $0 }
    let lo = during.reduce(during[0]) { $1.bpm < $0.bpm ? $1 : $0 }
    var zoneSec: [Int: Int] = [:]
    for i in 1..<during.count {
        let dt = during[i].t - during[i - 1].t
        let frac = Double(during[i].bpm) / Double(maxEstimate)
        if let z = ZONES.first(where: { frac >= $0.from && frac < $0.to }) { zoneSec[z.id, default: 0] += dt }
    }
    let atStop = during.last
    let oneMin = s.first { $0.t >= sess.endT + 60 }
    let recovery1min = atStop.flatMap { a in oneMin.map { a.bpm - $0.bpm } }

    var notes: [String] = []
    let hard = (zoneSec[4] ?? 0) + (zoneSec[5] ?? 0)
    notes.append("You spent \(fmt(jsRound(Double(hard) / 60))) min hard or harder, and \(fmt(jsRound(Double(zoneSec[2] ?? 0) / 60 + Double(zoneSec[3] ?? 0) / 60))) min steady to moderate.")
    if let r = recovery1min {
        notes.append(r >= 12 ? "Your heart rate fell \(r) bpm in the first minute after stopping, a normal recovery."
            : "Your heart rate fell only \(r) bpm in the first minute after stopping. A slow recovery now and then is common when tired; if it keeps happening, mention it to your doctor.")
    }
    let maxSec = during.enumerated().filter { $0.offset > 0 && Double($0.element.bpm) / Double(maxEstimate) >= 0.95 }.count * 5
    if maxSec >= 120 {
        notes.append("You were at 95% or more of your estimated maximum for about \(fmt(jsRound(Double(maxSec) / 60))) min. If you felt chest pain, dizziness or unusual breathlessness, stop and get checked.")
    }
    return WorkoutSummary(
        durationMin: Int(jsRound(Double(sess.endT) / 60)), avg: avg, peak: Moment(t: pk.t, bpm: pk.bpm), low: Moment(t: lo.t, bpm: lo.bpm),
        maxEstimate: maxEstimate,
        zoneMin: ZONES.map { ZoneTime(zone: $0, minutes: jsRound(Double(zoneSec[$0.id] ?? 0) / 60 * 10) / 10) },
        highs: extremes(during, high: true, n: 4),
        // Lows that matter are the recoveries between efforts, so the warm-up's first 5 minutes are left out.
        lows: extremes(during.filter { $0.t >= 300 }, high: false, n: 3),
        recovery1min: recovery1min, notes: notes)
}

/// A fictional 36-minute brisk walk/jog with 3 minutes recorded after stopping. Samples every 5 seconds.
public func sampleWorkout() -> Session {
    var r = Rand(seed: 11)
    let end = 36.0
    func target(_ t: Int) -> Double {
        let m = Double(t) / 60
        if m < 7 { return 92 + m * 4 }
        if m < 31 { let k = ((m - 7) / 6).rounded(.down); return (m - 7).truncatingRemainder(dividingBy: 6) < 3 ? 138 + k * 2.5 : 116 }
        if m < end { return 128 - (m - 31) * 2 }
        return 72 + (118 - 72) * exp(-(m - end) / 1.1)
    }
    var bpm = 76.0
    let samples = stride(from: 0, through: Int(end + 3) * 60, by: 5).map { t -> Sample in
        bpm += (target(t) - bpm) * 0.18 + r.next() * 2
        return Sample(t: t, bpm: Int(jsRound(bpm)))
    }
    return Session(name: "Brisk walk and jog (sample)", samples: samples, endT: Int(end) * 60)
}
