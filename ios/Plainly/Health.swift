import Foundation
import HealthKit
import PlainlyCore

/// Apple Health: where Apple Watch (and apps that sync to Health) store vitals. Plainly reads it on this iPhone and works
/// out everything locally; nothing is uploaded. For people without a watch (and for judges), "Put sample in Apple Health"
/// writes the same fictional 35 days and workout as the web sample, tagged with Plainly's metadata key, then reads them
/// back through HealthKit.
@MainActor
final class Health {
    static let shared = Health()
    let store = HKHealthStore()
    static let tag = "PlainlySample"

    private let rhr = HKQuantityType(.restingHeartRate)
    // Apple Watch reports heart rate variability as SDNN (Health Connect's watches report RMSSD); both are compared only
    // with the person's own usual, so the method doesn't change the reading.
    private let hrv = HKQuantityType(.heartRateVariabilitySDNN)
    private let spo2 = HKQuantityType(.oxygenSaturation)
    private let hr = HKQuantityType(.heartRate)
    private let sleep = HKCategoryType(.sleepAnalysis)
    private let workout = HKObjectType.workoutType()

    var available: Bool { HKHealthStore.isHealthDataAvailable() }
    private var types: Set<HKSampleType> { [rhr, hrv, spo2, hr, sleep, workout] }

    func requestAccess() async throws {
        try await store.requestAuthorization(toShare: types, read: types)
    }

    struct Loaded { var days: [Day]; var workout: PlainlyCore.Session?; var sampleOnly: Bool; var sources: Set<String> }

    private func samples(_ type: HKSampleType, from: Date, to: Date) async throws -> [HKSample] {
        let pred = HKQuery.predicateForSamples(withStart: from, end: to)
        let desc = HKSampleQueryDescriptor(predicates: [.sample(type: type, predicate: pred)], sortDescriptors: [SortDescriptor(\.startDate)])
        return try await desc.result(for: store)
    }

    /// The last 35 days, one value per day (averages; sleep is the total asleep for nights ending that day), and the latest workout.
    func load() async throws -> Loaded {
        let to = Date(), from = to.addingTimeInterval(-35 * 86400)
        let cal = Calendar.current
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        var tags: [Bool] = [], sources = Set<String>()
        func note(_ s: HKSample) { tags.append(s.metadata?[Self.tag] != nil); sources.insert(s.sourceRevision.source.name) }
        func byDay(_ ss: [HKSample], _ unit: HKUnit, scale: Double = 1) -> [String: [Double]] {
            Dictionary(grouping: ss.compactMap { $0 as? HKQuantitySample }.map { s -> (String, Double) in note(s); return (f.string(from: s.startDate), s.quantity.doubleValue(for: unit) * scale) }, by: \.0).mapValues { $0.map(\.1) }
        }
        let rhrD = byDay(try await samples(rhr, from: from, to: to), .count().unitDivided(by: .minute()))
        let hrvD = byDay(try await samples(hrv, from: from, to: to), .secondUnit(with: .milli))
        let oxD = byDay(try await samples(spo2, from: from, to: to), .percent(), scale: 100)
        var sleepD: [String: Double] = [:]
        let asleep: Set<Int> = [HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue, HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                HKCategoryValueSleepAnalysis.asleepDeep.rawValue, HKCategoryValueSleepAnalysis.asleepREM.rawValue]
        for s in try await samples(sleep, from: from, to: to).compactMap({ $0 as? HKCategorySample }) where asleep.contains(s.value) {
            note(s); sleepD[f.string(from: s.endDate), default: 0] += s.endDate.timeIntervalSince(s.startDate) / 60
        }
        let dates = Set(rhrD.keys).union(hrvD.keys).union(oxD.keys).union(sleepD.keys).sorted()
        func avg(_ xs: [Double]?) -> Double? { xs.flatMap { $0.isEmpty ? nil : $0.reduce(0, +) / Double($0.count) } }
        let days = dates.map { d in
            Day(date: d, restingHr: avg(rhrD[d]).map { ($0 + 0.5).rounded(.down) }, hrv: avg(hrvD[d]).map { ($0 + 0.5).rounded(.down) },
                sleepMin: sleepD[d], spo2: avg(oxD[d]).map { (($0 * 10) + 0.5).rounded(.down) / 10 })
        }

        var session: PlainlyCore.Session?
        if let w = try await samples(workout, from: from, to: to).compactMap({ $0 as? HKWorkout }).last {
            note(w)
            let beats = try await samples(hr, from: w.startDate, to: w.endDate.addingTimeInterval(240)).compactMap { $0 as? HKQuantitySample }
            var seen = Set<Int>()
            let pts = beats.map { Sample(t: Int($0.startDate.timeIntervalSince(w.startDate)), bpm: Int($0.quantity.doubleValue(for: .count().unitDivided(by: .minute())).rounded())) }
                .filter { $0.t >= 0 && seen.insert($0.t).inserted }
            if pts.count >= 20 {
                session = PlainlyCore.Session(name: (w.metadata?[HKMetadataKeyWorkoutBrandName] as? String) ?? "Workout", samples: pts,
                                              endT: Int(w.endDate.timeIntervalSince(w.startDate)))
            }
        }
        _ = cal
        sources.remove("Plainly")
        return Loaded(days: days, workout: session, sampleOnly: !tags.isEmpty && tags.allSatisfy { $0 }, sources: sources)
    }

    /// Writes the fictional sample ending today, each record tagged so Plainly can find and remove only its own data.
    func writeSample() async throws {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = TimeZone(identifier: "UTC")
        let meta: [String: Any] = [Self.tag: true]
        var objects: [HKObject] = []
        for (i, d) in sampleDays(end: f.date(from: f.string(from: today))!).enumerated() {
            let day = cal.date(byAdding: .day, value: i - 34, to: today)!
            let wake = cal.date(bySettingHour: 6, minute: 30, second: 0, of: day)!
            if wake > Date() { continue }
            func q(_ t: HKQuantityType, _ u: HKUnit, _ v: Double, _ at: Date) -> HKQuantitySample {
                HKQuantitySample(type: t, quantity: HKQuantity(unit: u, doubleValue: v), start: at, end: at, metadata: meta)
            }
            objects.append(q(rhr, .count().unitDivided(by: .minute()), d.restingHr!, wake.addingTimeInterval(1800)))
            objects.append(q(hrv, .secondUnit(with: .milli), d.hrv!, wake.addingTimeInterval(-1800)))
            objects.append(q(spo2, .percent(), d.spo2! / 100, wake.addingTimeInterval(-3600)))
            objects.append(HKCategorySample(type: sleep, value: HKCategoryValueSleepAnalysis.asleepCore.rawValue,
                                            start: wake.addingTimeInterval(-d.sleepMin! * 60), end: wake, metadata: meta))
        }
        try await store.save(objects)

        // The workout, two days ago at 6:30, with three minutes of recovery recorded after stopping.
        let w = sampleWorkout()
        let start = cal.date(bySettingHour: 6, minute: 30, second: 0, of: cal.date(byAdding: .day, value: -2, to: today)!)!
        let cfg = HKWorkoutConfiguration(); cfg.activityType = .running
        let builder = HKWorkoutBuilder(healthStore: store, configuration: cfg, device: nil)
        try await builder.beginCollection(at: start)
        let beats = w.samples.map { HKQuantitySample(type: hr, quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: Double($0.bpm)),
                                                     start: start.addingTimeInterval(Double($0.t)), end: start.addingTimeInterval(Double($0.t)), metadata: meta) }
        try await builder.addMetadata(meta.merging([HKMetadataKeyWorkoutBrandName: w.name]) { a, _ in a })
        try await builder.endCollection(at: start.addingTimeInterval(Double(w.endT)))
        _ = try await builder.finishWorkout()
        try await store.save(beats) // recovery after stopping is kept, as a watch records it
    }

    /// Removes only what Plainly wrote (its tagged sample), never anything from a watch.
    func deleteSample() async throws {
        let pred = HKQuery.predicateForObjects(withMetadataKey: Self.tag)
        for t in types { _ = try? await store.deleteObjects(of: t, predicate: pred) }
    }
}
