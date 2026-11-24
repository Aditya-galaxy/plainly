import Foundation
import Testing
@testable import PlainlyCore

/// The same cases as the web tests (test/core.test.ts) and Android (CoreTest.kt), so all three platforms agree.
@Suite struct CoreTests {
    @Test func rangesAsLabsPrintThem() {
        #expect(parseRange("12.0 - 15.0") == LabRange(low: 12, high: 15, text: "12.0 - 15.0"))
        #expect(parseRange("< 100").high == 100)
        #expect(parseRange("Upto 40").high == 40)
        #expect(parseRange(">= 50").low == 50)
        #expect(parseRange("See note").low == nil)
    }

    @Test func flagsAndNearEdge() {
        let r = parseRange("12.0 - 15.0")
        #expect(flagOf(10.9, r) == .low); #expect(flagOf(15.5, r) == .high); #expect(flagOf(13, r) == .normal)
        #expect(nearEdge(12.3, r)); #expect(!nearEdge(13.5, r))
    }

    @Test func readerHandlesOneTestPerLine() {
        let lines = [
            "Patient: Rhea Sharma Age / Sex: 52 Y / Female Ref. by: Dr. A. Kulkarni",
            "Report ID: FD-88213 Collected: 18 Nov 2026, 08:12",
            "Haemoglobin 10.9 L g/dL 12.0 - 15.0",
            "HbA1c (Glycated Haemoglobin) 6.1 H % 4.0 - 5.6",
            "LDL Cholesterol 148 H mg/dL < 100",
        ]
        let tests = parseRows(lines)
        #expect(tests.map(\.name) == ["Haemoglobin", "HbA1c (Glycated Haemoglobin)", "LDL Cholesterol"])
        #expect(tests[2].range.high == 100)
        #expect(parseMeta(lines) == Meta(age: 52, sex: "female", date: "18 Nov 2026"))
    }

    @Test func valuesMustAppearInTheText() {
        let out = verifyAgainstText([
            LabTest(name: "Haemoglobin", value: 10.9, unit: "g/dL", range: parseRange("12.0 - 15.0")),
            LabTest(name: "TSH", value: 6.8, unit: "uIU/mL", range: parseRange("0.40 - 4.00"), raw: "6.80"),
            LabTest(name: "Vitamin D", value: 41, unit: "ng/mL", range: parseRange("30 - 100")),
        ], "Haemoglobin 10.9 g/dL 12.0 - 15.0   TSH 6.80 uIU/mL")
        #expect(out.map(\.verified) == [true, true, false])
    }

    @Test func guardExplainsNeverDiagnoses() {
        let allowed = [6.1, 4.0, 5.6, 5.8]
        #expect(checkExplanation("Your HbA1c is 6.1%, above the 5.6% upper limit and up from 5.8% last time. HbA1c reflects average blood sugar over about three months. Ask your doctor what this means for you.", allowed: allowed) == nil)
        #expect(checkExplanation("You have diabetes. Ask your doctor.", allowed: allowed) != nil)
        #expect(checkExplanation("Your HbA1c is 6.1%. Start metformin 500 mg daily and see your doctor.", allowed: allowed) != nil)
        #expect(checkExplanation("Your HbA1c is 6.5%, above the limit. Ask your doctor.", allowed: allowed) != nil)
        #expect(checkExplanation("Your HbA1c is 6.1%, a little above the 5.6% upper limit of the range.", allowed: allowed) != nil)
    }

    @Test func deidentifiedKeepsOnlyTheFacts() throws {
        let s = deidentified(LabTest(name: "TSH • Rhea Sharma", value: 6.8, unit: "uIU/mL", range: parseRange("0.40 - 4.00")),
                             Meta(age: 52, sex: "female", date: "18 Nov 2026"), nil)
        let j = try #require(try JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any])
        #expect(Set(j.keys) == ["test", "value", "unit", "range", "flag", "ageBand", "sex"])
        #expect(j["ageBand"] as? String == "50s")
        #expect(!(j["test"] as? String ?? "").contains("•"))
    }

    func fixture(_ name: String) throws -> URL {
        try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures"))
    }

    /// Apple Vision OCR of the tilted sample photo (made with android/tools/vision-ocr.swift): the same engine the iOS
    /// app uses, so this is the iOS reading path end to end, minus the camera.
    @Test func visionOcrOfTheTiltedPhotoReadsAllSixteen() throws {
        let obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture("sample-photo-ocr.json"))) as? [String: Any])
        let lines = (obj["lines"] as? [[String: Any]] ?? []).map { o in
            OcrLine(text: o["text"] as? String ?? "", corners: (o["corners"] as? [[Double]] ?? []).map { ($0[0], $0[1]) })
        }
        let tests = parseRows(rowsFromLines(lines))
        let got = Dictionary(uniqueKeysWithValues: tests.map { ($0.name, $0.value) })
        #expect(tests.count == 16)
        #expect(got["Haemoglobin"] == 10.9); #expect(got["TSH (Thyroid Stimulating Hormone)"] == 6.8); #expect(got["Free T4"] == 0.92)
        #expect(tests.filter { [.high, .low].contains(flagOf($0.value, $0.range)) }.count == 10)
    }

    @Test(arguments: ["redmi-mlkit-rows.txt", "emulator-mlkit-rows.txt"])
    func phoneOcrStillFindsTenFlagged(_ file: String) throws {
        let rows = parseRows(try String(contentsOf: fixture(file), encoding: .utf8).components(separatedBy: "\n"))
        let by = Dictionary(uniqueKeysWithValues: rows.map { ($0.name, $0) })
        #expect(by["LDL Cholesterol"]?.range.high == 100)
        #expect(rows.filter { [.high, .low].contains(flagOf($0.value, $0.range)) }.count == 10)
    }

    @Test func redFlagsMatchTheWebRules() {
        func ids(_ s: String) -> [String] { redFlags(s).map(\.id) }
        #expect(ids("tired for 3 weeks, cold hands") == [])
        #expect(ids("mild headache in the evenings") == [])
        #expect(ids("tightness in my chest when climbing stairs") == ["chest"])
        #expect(ids("I get short of breath lying down") == ["breath"])
        #expect(ids("her face is drooping and speech is slurred") == ["stroke"])
        #expect(ids("I fainted at work yesterday") == ["faint"])
        #expect(redFlags("I don't want to live").first?.advice.contains("14416") == true)
    }
}

/// Same expectations as the web app and Android's VitalsTest, so all three platforms agree to the digit.
@Suite struct VitalsTests {
    @Test func sampleWeekIsOffUsual() {
        let r = analyse(sampleDays())
        #expect(r.days == 35 && r.baselineDays == 28 && r.recentDays == 7)
        #expect(r.recovery == 20)
        let text = r.changes.map(\.text)
        #expect(text.contains("Resting heart rate is 7 bpm higher than your usual (70 bpm this week vs 63 bpm)."))
        #expect(text.contains("Sleep is 53 min shorter than your usual (6 h 4 min this week vs 6 h 57 min)."))
        #expect(text.contains("Blood oxygen (overnight) is in your usual range (96.2 % this week, 96.1 % usually)."))
        #expect(r.alerts.isEmpty)
    }

    @Test func workoutSummaryMatchesWeb() {
        let w = analyseWorkout(sampleWorkout(), age: 52)
        #expect(w.avg == 123 && w.peak.bpm == 147 && clock(w.peak.t) == "27:30" && w.recovery1min == 21)
        #expect(w.highs.map(\.bpm) == [139, 141, 143, 146])
        #expect(w.lows.map(\.bpm) == [115, 115, 115])
        #expect(w.zoneMin.map(\.minutes) == [2.3, 11.4, 11.6, 10.4, 0.0])
    }
}

/// What the iOS 27 simulator's text recognition read from the sample photo (no Neural Engine, so weaker than a phone):
/// "248" became "148". The lab printed no L mark there, so that value must be held back for checking, not flagged.
@Suite struct MarksTests {
    @Test func misreadValueDisagreeingWithTheLabIsHeldBack() throws {
        let url = try #require(Bundle.module.url(forResource: "ios-sim-vision-rows", withExtension: "txt", subdirectory: "Fixtures"))
        let rows = parseRows(try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n"))
        let platelets = try #require(rows.first { $0.name == "Platelet Count" })
        #expect(platelets.value == 148 && !platelets.verified)
        let confident = rows.filter { $0.verified && [.high, .low].contains(flagOf($0.value, $0.range)) }
        #expect(confident.count == 10)
    }

    @Test func marksAgreeingKeepEveryValue() {
        let rows = parseRows(["Haemoglobin 10.9 L g/dL 12.0 - 15.0", "Platelet Count 248 x10^3/uL 150 - 410", "LDL Cholesterol 148 H mg/dL < 100"])
        #expect(rows.filter { !$0.verified }.isEmpty)
    }
}

@Suite struct DeepDiveTests {
    @Test func tiredWeekIsMostlyOffUsualAndWeeksTrend() {
        let d = deepDive(.restingHr, days: sampleDays())
        #expect(d.weeks.count == 5 && d.weeks.last?.label == "This week")
        #expect(d.weeks.last!.value > d.weeks.first!.value + 5)
        #expect(d.offDays >= 5 && d.offDays <= d.recentCount)
        // A day shown inside the usual range is never counted as off it.
        if let b = d.bestDay { #expect(!(b.value.rounded() > d.usualHigh) || d.offDays == d.recentCount) }
        #expect(infoPack(.spo2).reading.contains("90%"))
        #expect(testInfo("HbA1c (Glycated Haemoglobin)")?.contains("two to three months") == true)
    }
}

@Suite struct InfoTests {
    @Test func everySampleTestGetsItsOwnInfo() {
        let names = ["Haemoglobin", "Total Leucocyte Count", "Platelet Count", "MCV", "Glucose, Fasting", "HbA1c (Glycated Haemoglobin)",
                     "Cholesterol, Total", "LDL Cholesterol", "HDL Cholesterol", "Triglycerides", "TSH (Thyroid Stimulating Hormone)",
                     "Free T4", "Vitamin D, 25-Hydroxy", "Vitamin B12", "Creatinine", "ALT (SGPT)"]
        let infos = names.map { testInfo($0) }
        #expect(infos.allSatisfy { $0 != nil })
        #expect(Set(infos.compactMap { $0 }).count == 16) // no test borrows another's text
        #expect(testInfo("LDL Cholesterol")!.hasPrefix("LDL") && testInfo("HDL Cholesterol")!.hasPrefix("HDL"))
    }
}

@Suite struct NameTests {
    @Test func misreadNamesSnapToTheRealTest() {
        #expect(canonicalTestName("Haemoalobin") == "Haemoglobin")
        #expect(canonicalTestName("Trialvcendes") == "Triglycerides")
        #expect(canonicalTestName("HDl Cholestero") == "HDL Cholesterol")
        #expect(canonicalTestName("Chueose. Fasting") == "Glucose, Fasting")
        #expect(canonicalTestName("MeV") == "MCV")
        #expect(canonicalTestName("Vitamin D, co-nydruny") == "Vitamin D, 25-Hydroxy")
        // Different tests are never merged.
        #expect(canonicalTestName("LDL Cholesterol") == "LDL Cholesterol")
        #expect(canonicalTestName("Vitamin B12") == "Vitamin B12")
        #expect(canonicalTestName("Lipase") == "Lipase")
        #expect(canonicalTestName("ALP") == "ALP")   // never ALT
        #expect(canonicalTestName("LDH") == "LDH")
    }
}
