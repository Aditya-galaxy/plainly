import Foundation

/*
 The same rules as the web app (src/lib/ranges.ts, parse.ts, guard.ts, deid.ts) and Android (Core.kt), ported line for
 line: numbers are handled by code, models only read and write words.
 */

// MARK: - Regex helper (ICU, same syntax as Kotlin/JS for everything used here)

struct RX: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, ci: Bool = false) {
        re = try! NSRegularExpression(pattern: pattern, options: ci ? [.caseInsensitive] : [])
    }
    /// Capture groups of the first match ("" for a group that didn't take part), or nil.
    func first(_ s: String) -> [String]? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            let r = m.range(at: i); return r.location == NSNotFound ? "" : ns.substring(with: r)
        }
    }
    func matches(_ s: String) -> Bool { re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil }
    func all(_ s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
    func replace(_ s: String, with t: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: t)
    }
}

// MARK: - Types

public struct LabRange: Equatable, Sendable, Codable {
    public var low: Double?
    public var high: Double?
    public var text: String
    public init(low: Double? = nil, high: Double? = nil, text: String = "") { self.low = low; self.high = high; self.text = text }
}

public enum Flag: String, Sendable { case low, high, normal, unknown }

public struct LabTest: Identifiable, Equatable, Sendable, Codable {
    public var id: String { name }
    public var name: String
    public var value: Double
    public var unit: String
    public var range: LabRange
    public var raw: String
    /// True when the value was found in the report's own (OCR) text.
    public var verified: Bool
    public init(name: String, value: Double, unit: String, range: LabRange, raw: String? = nil, verified: Bool = true) {
        self.name = name; self.value = value; self.unit = unit; self.range = range; self.raw = raw ?? fmt(value); self.verified = verified
    }
}

public struct Trend: Equatable, Sendable {
    public var previous: Double
    public var change: Double
    public var direction: String // "up" | "down" | "same"
}

public struct Meta: Equatable, Sendable {
    public var age: Int?
    public var sex: String?
    public var date: String?
    public init(age: Int? = nil, sex: String? = nil, date: String? = nil) { self.age = age; self.sex = sex; self.date = date }
}

// MARK: - Ranges, flags, trends

private let NUM = "-?\\d+(?:[.,]\\d+)?"
private func num(_ s: String) -> Double { Double(s.replacingOccurrences(of: ",", with: "")) ?? .nan }
private let WS = RX("\\s+")

private let RANGE_BOTH = RX("(\(NUM))\\s*(?:-|–|to)\\s*(\(NUM))", ci: true)
private let RANGE_HIGH = RX("(?:<=?|≤|less than|below|up\\s?to|upto)\\s*(\(NUM))", ci: true)
private let RANGE_LOW = RX("(?:>=?|≥|more than|above|greater than)\\s*(\(NUM))", ci: true)

public func parseRange(_ text: String) -> LabRange {
    let t = WS.replace(text, with: " ").trimmingCharacters(in: .whitespaces)
    if let m = RANGE_BOTH.first(t) { return LabRange(low: num(m[1]), high: num(m[2]), text: t) }
    if let m = RANGE_HIGH.first(t) { return LabRange(high: num(m[1]), text: t) }
    if let m = RANGE_LOW.first(t) { return LabRange(low: num(m[1]), text: t) }
    return LabRange(text: t)
}

public func flagOf(_ v: Double, _ r: LabRange) -> Flag {
    if r.low == nil && r.high == nil { return .unknown }
    if let l = r.low, v < l { return .low }
    if let h = r.high, v > h { return .high }
    return .normal
}

public func distance(_ v: Double, _ r: LabRange) -> Double {
    if let l = r.low, v < l { return (l - v) / abs(l == 0 ? 1 : l) }
    if let h = r.high, v > h { return (v - h) / abs(h == 0 ? 1 : h) }
    return 0
}

public func nearEdge(_ v: Double, _ r: LabRange, margin: Double = 0.05) -> Bool {
    guard flagOf(v, r) == .normal else { return false }
    func near(_ l: Double?) -> Bool { guard let l else { return false }; return abs(v - l) <= abs(l) * margin }
    return near(r.low) || near(r.high)
}

private let PAREN = RX("\\(.*?\\)")
private let NONALNUM = RX("[^a-z0-9]+")
private func key(_ name: String) -> String {
    NONALNUM.replace(PAREN.replace(name.lowercased(), with: ""), with: " ").trimmingCharacters(in: .whitespaces)
}

public func trendOf(_ t: LabTest, _ earlier: [[LabTest]]) -> Trend? {
    for report in earlier {
        // Units must match, unless OCR dropped one of them; then the test name alone decides.
        guard let p = report.first(where: { key($0.name) == key(t.name) &&
            ($0.unit.isEmpty || t.unit.isEmpty || $0.unit.caseInsensitiveCompare(t.unit) == .orderedSame) }) else { continue }
        let change = t.value - p.value
        let same = abs(change) <= abs(p.value) * 0.02
        return Trend(previous: p.value, change: change, direction: same ? "same" : change > 0 ? "up" : "down")
    }
    return nil
}

// MARK: - Reading report text: one test per line, "Name  Value [H|L]  Unit  Reference interval"

// The unit is optional (OCR sometimes drops a short unit like "fL" or "%"), but must contain a letter or % so a
// range's first number is never mistaken for it.
private let ROW = RX("^([A-Za-z][A-Za-z0-9 ,()/.'+\\-]*?[A-Za-z0-9)])\\s+(-?\\d+(?:\\.\\d+)?)\\s*(?:([HL])\\b)?(?:\\s+((?=[^\\s]*[A-Za-zµ%])[A-Za-zµ%^/\\d.]+(?:/[A-Za-z0-9.]+)?))?\\s+(.*\\d.*)$")
private let SKIP = RX("^(test|result|unit|biological|reference|report|collected|reported|patient|age|sample|phone|ref\\.?\\s*by|checked|results relate)", ci: true)

// OCR often reads the "/" between age and sex as "I", "l" or "|".
private let AGE_SEX = RX("Age\\s*[/Il|]\\s*Sex\\s*:?\\s*(\\d{1,3})\\s*(?:Y|Yrs?|Years?)?\\s*[/Il|]\\s*(Male|Female|M|F)\\b", ci: true)
private let DATE = RX("(?:Collected|Collection|Date)\\s*:?\\s*(\\d{1,2}\\s+[A-Za-z]{3,9}\\s+\\d{4})", ci: true)

public func parseMeta(_ lines: [String]) -> Meta {
    let text = lines.joined(separator: "\n")
    var meta = Meta()
    if let m = AGE_SEX.first(text) {
        meta.age = Int(m[1])
        meta.sex = m[2].lowercased().hasPrefix("f") ? "female" : "male"
    }
    if let m = DATE.first(text) { meta.date = m[1] }
    return meta
}

/// Units labs actually print. OCR misreads "/" as "l", "i" or "1" ("gldL", "ngimL"), so a printed unit is snapped to the
/// nearest of these when it is at most two characters away. Same list as the web app.
let UNITS = ["g/dL", "mg/dL", "ng/mL", "pg/mL", "ng/dL", "uIU/mL", "mIU/L", "U/L", "IU/L", "fL", "pg", "%", "x10^3/uL", "x10^6/uL",
             "mmol/L", "umol/L", "mEq/L", "g/L", "mm/hr", "ratio"]

private func edits(_ a: String, _ b: String) -> Int {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return b.count }; if b.isEmpty { return a.count }
    var prev = Array(0...b.count)
    for i in 1...a.count {
        var cur = [i] + Array(repeating: 0, count: b.count)
        for j in 1...b.count { cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)) }
        prev = cur
    }
    return prev[b.count]
}

public func canonicalUnit(_ u: String) -> String {
    var t = u.trimmingCharacters(in: .whitespaces)
    if t.hasSuffix(".") { t.removeLast() }
    if t.isEmpty { return "" }
    var best = t, bestD = 3
    for c in UNITS { let d = edits(t.lowercased(), c.lowercased()); if d < bestD { best = c; bestD = d } }
    return bestD <= 2 && (bestD == 0 || t.count >= 2) ? best : t
}

/// Test names labs commonly print. A name misread by OCR ("Haemoalobin", "Trialvcendes") is snapped to the nearest of
/// these when it is close enough, the same way units are, so explanations and trends use the real name.
let TEST_NAMES = ["Haemoglobin", "Total Leucocyte Count", "Platelet Count", "MCV", "MCH", "MCHC", "RBC Count", "Haematocrit",
                  "Glucose, Fasting", "Glucose, Post Prandial", "HbA1c (Glycated Haemoglobin)", "Cholesterol, Total", "LDL Cholesterol",
                  "HDL Cholesterol", "VLDL Cholesterol", "Triglycerides", "TSH (Thyroid Stimulating Hormone)", "Free T4", "Free T3",
                  "Vitamin D, 25-Hydroxy", "Vitamin B12", "Creatinine", "Urea", "Uric Acid", "Sodium", "Potassium", "Calcium",
                  "ALT (SGPT)", "AST (SGOT)", "Alkaline Phosphatase", "Bilirubin, Total", "Albumin", "Ferritin", "Iron", "ESR", "CRP"]

private func letters(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }

/// Characters OCR commonly swaps; swapping them costs half an edit.
private let LOOKALIKE: Set<String> = ["ce", "ag", "ao", "vy", "nr", "li", "l1", "i1", "oq", "gq", "hb", "un", "rn", "il"]
private func ocrEdits(_ a: String, _ b: String) -> Double {
    let a = Array(a), b = Array(b)
    if a.isEmpty { return Double(b.count) }; if b.isEmpty { return Double(a.count) }
    var prev = (0...b.count).map(Double.init)
    for i in 1...a.count {
        var cur = [Double(i)] + Array(repeating: 0, count: b.count)
        for j in 1...b.count {
            let x = a[i - 1], y = b[j - 1]
            let sub = x == y ? 0 : (LOOKALIKE.contains(String([x, y])) || LOOKALIKE.contains(String([y, x]))) ? 0.5 : 1
            cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + sub)
        }
        prev = cur
    }
    return prev[b.count]
}

public func canonicalTestName(_ name: String) -> String {
    let n = letters(name.split(separator: "(").first.map(String.init) ?? name)
    if n.count < 3 { return name }
    var best = name, bestScore = 1.0
    for c in TEST_NAMES {
        let short = letters(c.split(separator: "(").first.map(String.init) ?? c)
        if n == short { return c }
        let score = ocrEdits(n, short) / Double(max(n.count, short.count))
        if score < bestScore { best = c; bestScore = score }
    }
    // Close enough to be the same word misread, never a different test: short names ("MCV", "ALT") may differ only by
    // one look-alike character, longer ones by about one character in five.
    let limit = n.count <= 4 ? 0.17 : 0.22
    if bestScore <= limit { return best }
    // "Vitamin D, co-nydruny": a known name's first words, followed by garbled text.
    for c in TEST_NAMES where c.contains(",") {
        let head = letters(String(c.split(separator: ",")[0]) + String(c.split(separator: ",")[1].prefix(2)))
        if n.hasPrefix(letters(String(c.split(separator: ",")[0]))) && n.count >= head.count && c.hasPrefix("Vitamin") { return c }
    }
    return name
}

/// "6,80" → "6.80" (a comma read for a decimal point); "1,200" (thousands) is left alone.
private let DEC_COMMA = RX("(\\d),(\\d{1,2})(?!\\d)")
// A lone number (OCR lost the "<" or ">", or read it as ":" or ";") is resolved by the lab's own H/L mark.
private let LONE = RX("^[:;.,'`\"]?\\s*(\\d+(?:\\.\\d+)?)$")

public func parseRows(_ lines: [String]) -> [LabTest] {
    let read: [(LabTest, String)] = lines.compactMap { line in
        let l = DEC_COMMA.replace(WS.replace(line, with: " ").trimmingCharacters(in: .whitespaces), with: "$1.$2")
        if l.isEmpty || SKIP.matches(l) { return nil }
        guard let m = ROW.first(l), let value = Double(m[2]) else { return nil }
        var range = parseRange(m[5])
        if range.low == nil && range.high == nil {
            guard let lone = LONE.first(m[5].trimmingCharacters(in: .whitespaces)).flatMap({ Double($0[1]) }) else { return nil }
            if m[3] == "H" && value > lone { range = LabRange(high: lone, text: "< \(fmt(lone))") }
            else if m[3] == "L" && value < lone { range = LabRange(low: lone, text: "> \(fmt(lone))") }
            else { return nil }
        }
        // Sanity: a broken OCR line can look like a row ("ng/dL 0 80-1.80"). A test name is never a unit, and a range's
        // low end is never above its high end; such rows are dropped rather than shown to a patient.
        let name = canonicalTestName(m[1].trimmingCharacters(in: .whitespaces))
        if UNITS.contains(canonicalUnit(name)) || name.filter(\.isLetter).count < 2 { return nil }
        if let lo = range.low, let hi = range.high, lo > hi { return nil }
        return (LabTest(name: name, value: value, unit: canonicalUnit(m[4]), range: range, raw: m[2], verified: true), m[3])
    }
    return crossCheckMarks(read)
}

/// Labs print their own H and L marks. When a report uses them, every reading must agree with the lab: a value read as
/// outside the range with no mark (or the wrong mark), or a mark on a value read as normal, means the photo was misread
/// ("248" read as "148"), so that value is marked to check against the report instead of being shown as a finding.
public func crossCheckMarks(_ read: [(LabTest, String)]) -> [LabTest] {
    guard read.contains(where: { !$0.1.isEmpty }) else { return read.map(\.0) }
    return read.map { t, mark in
        let f = flagOf(t.value, t.range)
        let expected = f == .high ? "H" : f == .low ? "L" : ""
        var c = t
        if f != .unknown && mark != expected { c.verified = false }
        return c
    }
}

/// A model reading report text can misread a number; each value must appear in the OCR text as printed.
public func verifyAgainstText(_ tests: [LabTest], _ source: String) -> [LabTest] {
    let hay = WS.replace(source, with: " ")
    return tests.map { t in
        let variants: Set<String> = [t.raw.trimmingCharacters(in: .whitespaces), fmt(t.value),
                                     String(format: "%.1f", t.value), String(format: "%.2f", t.value)]
        var copy = t
        copy.verified = variants.contains { v in RX("(^|[^0-9.])\(NSRegularExpression.escapedPattern(for: v))([^0-9]|$)").matches(hay) }
        return copy
    }
}

public func fmt(_ v: Double) -> String {
    if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
    return String(v)
}

// MARK: - What the cloud may see

public func ageBand(_ age: Int?) -> String? {
    guard let age, age > 0, age <= 120 else { return nil }
    return age < 18 ? "under 18" : "\(age / 10 * 10)s"
}

private let NAME_CLEAN = RX("[^A-Za-z0-9 ()%,.+\\-/]")

/// The only facts that may leave the device to explain a result: never a name, lab, date, ID, doctor or image.
public func deidentified(_ t: LabTest, _ meta: Meta, _ trend: Trend?) -> String {
    let name = String(WS.replace(NAME_CLEAN.replace(t.name, with: " "), with: " ").trimmingCharacters(in: .whitespaces).prefix(60))
    var parts = ["\"test\":\"\(name)\"", "\"value\":\(fmt(t.value))", "\"unit\":\"\(t.unit.prefix(16))\"",
                 "\"range\":\"\(t.range.text.prefix(40))\"", "\"flag\":\"\(flagOf(t.value, t.range).rawValue)\""]
    if let trend { parts.append("\"previous\":\(fmt(trend.previous))") }
    if let band = ageBand(meta.age) { parts.append("\"ageBand\":\"\(band)\"") }
    if let sex = meta.sex { parts.append("\"sex\":\"\(sex)\"") }
    return "{" + parts.joined(separator: ",") + "}"
}

// MARK: - The guard: explains, never diagnoses or prescribes; numbers must be the test's own

private let DIAGNOSE = [
    RX("\\byou (?:have|are suffering from|are diagnosed|definitely|certainly)\\b", ci: true),
    RX("\\b(?:this|it) (?:means|confirms|proves) (?:that )?you\\b", ci: true),
    RX("\\bdiagnos(?:is|ed|e)\\b(?! is not| isn't)", ci: true),
    RX("\\byou(?:'re| are) (?:diabetic|anaemic|anemic|hypothyroid|hyperthyroid)\\b", ci: true),
]
private let PRESCRIBE = [
    RX("\\b(?:take|start|stop|increase|reduce|double)\\s+(?:a |an |your |the )?(?:dose|tablet|pill|medicine|medication|supplement|insulin|metformin|levothyroxine|thyroxine|statin)", ci: true),
    RX("\\b\\d+(?:\\.\\d+)?\\s?(?:mg|mcg|µg|iu|units)\\b(?! ?/)", ci: true),
]
private let DOCTOR = RX("\\b(?:doctor|physician|clinician|gp|healthcare provider)\\b", ci: true)
private let NUMBERS = RX(NUM)

/// nil when the text passes; otherwise the reason it was rejected.
public func checkExplanation(_ text: String, allowed: [Double]) -> String? {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count < 20 { return "The explanation was too short to be useful." }
    if t.count > 900 { return "The explanation ran too long." }
    if DIAGNOSE.contains(where: { $0.matches(t) }) { return "It read like a diagnosis, which Plainly never gives." }
    if PRESCRIBE.contains(where: { $0.matches(t) }) { return "It suggested a medicine or dose, which only a doctor should." }
    func isAllowed(_ n: Double) -> Bool {
        for a in allowed where abs(a - n) <= max(1e-9, abs(a) * 0.001) { return true }
        let smallWhole: Bool = n == n.rounded() && n >= 0 && n <= 3 // "two questions", "three months"
        return smallWhole
    }
    let stray: Double? = NUMBERS.all(t).map(num).first { !isAllowed($0) }
    if let stray { return "It mentioned a number that isn't on your report (\(fmt(stray)))." }
    if !DOCTOR.matches(t) { return "It didn't point you back to your doctor." }
    return nil
}

// MARK: - Rebuilding table rows from OCR lines

/// One recognised line of text and its four corners (top-left, top-right, bottom-right, bottom-left), y pointing down.
public struct OcrLine: Sendable {
    public var text: String
    public var corners: [(Double, Double)]
    public init(text: String, corners: [(Double, Double)]) { self.text = text; self.corners = corners }
}

/// OCR returns each table column as separate lines, and photos are rarely straight. The tilt is found from the table
/// itself: the page is levelled at each candidate slope within ±4.5° and the slope that rebuilds the most rows wins.
public func rowsFromLines(_ lines: [OcrLine]) -> [String] {
    let usable = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty && $0.corners.count == 4 }
    if usable.isEmpty { return [] }
    let slopes = usable.compactMap { l -> Double? in
        let (x0, y0) = l.corners[0], (x1, y1) = l.corners[1]
        return x1 - x0 > 20 ? (y1 - y0) / (x1 - x0) : nil
    }.sorted()
    let fromBoxes = slopes.isEmpty ? 0 : slopes[slopes.count / 2]
    let candidates = [fromBoxes, 0] + (-45...45).map { Double($0) / 570 } // ~0.1° steps up to ±4.5°
    var best = rowsAtSlope(usable, fromBoxes)
    var bestScore = parseRows(best).count
    for c in candidates {
        let rows = rowsAtSlope(usable, c)
        let score = parseRows(rows).count
        if score > bestScore { best = rows; bestScore = score }
    }
    return best
}

/// Levels the page by `slope` (y grows by slope per pixel of x) and joins lines whose centres share a row.
public func rowsAtSlope(_ lines: [OcrLine], _ slope: Double) -> [String] {
    struct Item { let x: Double; let y: Double; let h: Double; let text: String }
    let items = lines.map { l -> Item in
        let cx = l.corners.map(\.0).reduce(0, +) / 4
        let cy = l.corners.map(\.1).reduce(0, +) / 4
        let h = ((l.corners[3].1 - l.corners[0].1) + (l.corners[2].1 - l.corners[1].1)) / 2
        return Item(x: cx, y: cy - cx * slope, h: abs(h), text: l.text.trimmingCharacters(in: .whitespaces))
    }.sorted { $0.y < $1.y }
    let hMedian = max(items.map(\.h).sorted()[items.count / 2], 4)
    var rows: [[Item]] = []
    for it in items {
        if let row = rows.last, abs(row.map(\.y).reduce(0, +) / Double(row.count) - it.y) < hMedian * 0.5 {
            rows[rows.count - 1].append(it)
        } else { rows.append([it]) }
    }
    return rows.map { $0.sorted { $0.x < $1.x }.map(\.text).joined(separator: " ") }
}
