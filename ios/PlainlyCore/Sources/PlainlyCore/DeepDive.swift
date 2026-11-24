import Foundation

// MARK: - Deep dive: arithmetic on the person's own data, nothing generated

public struct WeekAverage: Sendable { public let label: String; public let value: Double }

public struct DeepDive: Sendable {
    /// Days this week that fell outside the usual band on the worse side.
    public let offDays: Int
    public let recentCount: Int
    /// The longest run of consecutive off-usual days, ending at any point in the last 35 days.
    public let longestRun: Int
    public let bestDay: (date: String, value: Double)?
    public let worstDay: (date: String, value: Double)?
    /// Average per week, oldest first (5 weeks).
    public let weeks: [WeekAverage]
    /// This week's day-to-day spread compared with the usual spread (1.0 = same).
    public let steadiness: Double?
    public let usualLow: Double
    public let usualHigh: Double
}

public func deepDive(_ m: Metric, days input: [Day], recentDays: Int = 7, baselineDays: Int = 28) -> DeepDive {
    let days = input.sorted { $0.date < $1.date }
    let base = Array(days.dropLast(recentDays).suffix(baselineDays)).compactMap(m.of)
    let recent = Array(days.suffix(recentDays))
    let mean = base.isEmpty ? 0 : base.reduce(0, +) / Double(base.count)
    let sd = base.count > 1 ? (base.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(base.count - 1)).squareRoot() : 0
    // The band is compared at the precision the screen shows (whole bpm, ms and minutes; 0.1 for blood oxygen), so a
    // day shown as 64 bpm is never called "off" a usual range shown as 61 to 64.
    let p = m == .spo2 ? 10.0 : 1.0
    func r(_ v: Double) -> Double { (v * p).rounded() / p }
    let lo = r(mean - sd), hi = r(mean + sd)
    func worse(_ v: Double) -> Bool { m.betterUp ? r(v) < lo : r(v) > hi }
    func better(_ a: Double, _ b: Double) -> Bool { m.betterUp ? a > b : a < b }

    let recentVals = recent.compactMap { d in m.of(d).map { (d.date, $0) } }
    let offDays = recentVals.filter { worse($0.1) }.count
    var run = 0, longest = 0
    for d in days { if let v = m.of(d), worse(v) { run += 1; longest = max(longest, run) } else { run = 0 } }
    let best = recentVals.max { better($1.1, $0.1) }
    let worst = recentVals.max { better($0.1, $1.1) }

    var weeks: [WeekAverage] = []
    let n = days.count
    for w in (0..<5).reversed() {
        let slice = days[max(0, n - (w + 1) * 7)..<max(0, n - w * 7)].compactMap(m.of)
        if slice.isEmpty { continue }
        weeks.append(WeekAverage(label: w == 0 ? "This week" : w == 1 ? "Last week" : "\(w) weeks ago", value: slice.reduce(0, +) / Double(slice.count)))
    }
    let rv = recentVals.map(\.1)
    let rMean = rv.isEmpty ? 0 : rv.reduce(0, +) / Double(rv.count)
    let rSd = rv.count > 1 ? (rv.reduce(0) { $0 + ($1 - rMean) * ($1 - rMean) } / Double(rv.count - 1)).squareRoot() : 0
    return DeepDive(offDays: offDays, recentCount: recentVals.count, longestRun: longest,
                    bestDay: best.map { ($0.0, $0.1) }, worstDay: worst.map { ($0.0, $0.1) }, weeks: weeks,
                    steadiness: sd > 0 && rv.count > 2 ? rSd / sd : nil, usualLow: lo, usualHigh: hi)
}

// MARK: - Info packs: fixed, reviewed text (not generated), general education only

public struct InfoPack: Sendable {
    public let what: String
    public let measured: String
    public let moves: String
    public let reading: String
}

public func infoPack(_ m: Metric) -> InfoPack {
    switch m {
    case .restingHr:
        InfoPack(
            what: "How many times your heart beats in a minute while you are fully at rest, usually measured during sleep or quiet moments.",
            measured: "Your watch shines light into the skin and counts each pulse in the blood flow. It picks the calmest stretches of the day.",
            moves: "It tends to rise with illness or fever, poor sleep, alcohol, dehydration, stress, heat and some medicines, and after very hard training. Regular exercise tends to lower it over months.",
            reading: "For adults it is often between 60 and 100 beats a minute, and fitter people can be lower. What matters most is your own usual: a rise of several beats that lasts days is worth noticing.")
    case .hrv:
        InfoPack(
            what: "Heart rate variability is the tiny variation in time between heartbeats. More variation usually means your body is rested and recovering well.",
            measured: "Measured overnight from the pulse. Apple Watch reports it as SDNN and most other watches as RMSSD, so numbers from different brands aren't comparable.",
            moves: "It tends to drop with illness, poor or short sleep, alcohol, stress, hard training and travel, and to recover with rest.",
            reading: "It is very personal: two healthy people can differ by a factor of three. Compare only with your own usual, and look at the trend over days rather than one night.")
    case .sleep:
        InfoPack(
            what: "The time you actually spent asleep, not just time in bed.",
            measured: "Your watch estimates sleep from movement and heart rate. It is good at total sleep time and less precise about sleep stages.",
            moves: "Late caffeine or alcohol, screens and stress before bed, a changing bedtime, pain, a new baby and shift work all shorten sleep.",
            reading: "Most adults need about 7 to 9 hours. A short night now and then is normal; a week of shorter sleep adds up, and shows in heart rate and variability too.")
    case .spo2:
        InfoPack(
            what: "Blood oxygen is how much of your blood is carrying oxygen, as a percentage.",
            measured: "Your watch estimates it overnight by shining red and infrared light into the skin. Wrist readings are less accurate than a finger clip at the doctor's.",
            moves: "It can dip with a cold or chest infection, at altitude, and with breathing pauses during sleep. A loose strap or cold hands can also give low readings.",
            reading: "It is usually between 95% and 100% in healthy adults at sea level. A reading below 90% that repeats is a reason to contact a doctor.")
    }
}

/// General, fixed descriptions of common lab tests, matched by name. Nil when Plainly has no reviewed text for a test.
public func testInfo(_ name: String) -> String? {
    // Match the short name first ("HbA1c (Glycated Haemoglobin)" is HbA1c, not haemoglobin), then the full name.
    let short = (name.split(separator: "(").first.map(String.init) ?? name).lowercased()
    let table: [(String, String)] = [
        ("hba1c", "HbA1c shows your average blood sugar over roughly the last two to three months."),
        ("haemoglobin", "Haemoglobin is the protein in red blood cells that carries oxygen around the body. It is part of a complete blood count."),
        ("hemoglobin", "Haemoglobin is the protein in red blood cells that carries oxygen around the body. It is part of a complete blood count."),
        ("leucocyte", "White blood cells are part of the immune system. The count can change with infection, inflammation and some medicines."),
        ("platelet", "Platelets help blood to clot. The count is part of a complete blood count."),
        ("mcv", "MCV is the average size of your red blood cells. It helps doctors understand changes in haemoglobin."),
        ("hba1c", "HbA1c shows your average blood sugar over roughly the last two to three months."),
        ("glucose", "Fasting glucose is the sugar level in your blood after not eating, usually for 8 hours or more."),
        ("ldl", "LDL cholesterol is often called the bad cholesterol, because higher levels are linked to fatty build-up in arteries."),
        ("hdl", "HDL cholesterol is often called the good cholesterol, because it helps carry cholesterol away from the arteries."),
        ("cholesterol", "Total cholesterol is the overall amount of cholesterol in your blood, including LDL and HDL."),
        ("triglycerides", "Triglycerides are a type of fat in the blood. They are affected by recent meals, alcohol and activity."),
        ("tsh", "TSH is a hormone from the pituitary gland that tells the thyroid how hard to work. It is the usual first test of thyroid function."),
        ("free t4", "Free T4 is the main hormone made by the thyroid gland. It is usually read together with TSH."),
        ("vitamin d", "Vitamin D helps the body use calcium for bones and muscles. Levels depend a lot on sunlight and diet."),
        ("b12", "Vitamin B12 is needed for healthy nerves and red blood cells. It comes mainly from animal foods."),
        ("creatinine", "Creatinine is a waste product cleared by the kidneys. It is used to check how well the kidneys are filtering."),
        ("alt", "ALT is an enzyme found mainly in the liver. It is one of the tests used to check the liver."),
    ]
    return (table.first { short.contains($0.0) } ?? table.first { name.lowercased().contains($0.0) })?.1
}
