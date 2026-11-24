import FirebaseAILogic
import Foundation
import FoundationModels
import PlainlyCore

/// The answer shape both models fill in, through Apple's Foundation Models guided generation.
@Generable(description: "A plain-English explanation of one lab result, and questions for the doctor")
struct Explanation {
    @Guide(description: "Two or three calm sentences: what the test measures, where the value sits against the printed reference interval, which way it moved if an earlier value is given, and a suggestion to discuss it with their doctor.")
    var explanation: String
    @Guide(description: "Two short questions the person could ask their doctor about this result.", .count(2))
    var questions: [String]
}

/// One test row read from report text, for layouts the rules can't rebuild. Values are copied as printed.
@Generable(description: "One result copied from a lab report")
struct ReadTest {
    @Guide(description: "The test name exactly as printed") var name: String
    @Guide(description: "The result value exactly as printed") var value: String
    @Guide(description: "The unit as printed, or empty") var unit: String
    @Guide(description: "The reference interval as printed, e.g. 12.0 - 15.0 or < 200") var range: String
}

@Generable(description: "Every result on the report")
struct ReadReport {
    var tests: [ReadTest]
}

enum Source: String { case onDevice = "Written privately on this iPhone", inCloud = "Written with Enhanced explanations", rules = "Summary" }

struct Explained: Equatable {
    var text: String
    var questions: [String]
    var source: Source
    var note: String?
}

/**
 Hybrid inference with Apple's Foundation Models framework and Firebase AI Logic:
  - On the device: Apple's on-device model (`SystemLanguageModel`), through `LanguageModelSession`.
  - In the cloud, only when the user allows it: Gemini through Firebase AI Logic's `GeminiLanguageModel`, in the very
    same `LanguageModelSession` API with the same instructions and the same `@Generable` answer type.
 Reading a report never goes to the cloud. Explaining sends only de-identified facts, and every answer passes the guard.
 */
enum AI {
    static let cloudModel = "gemini-3.5-flash-lite"

    static let explainInstructions = """
    You help a person understand one result on their own lab report, in plain, calm English for someone without medical \
    training. Use only the facts given. Do not diagnose, do not name a disease the person has, do not suggest medicines \
    or doses. Only use numbers that appear in the facts. End by suggesting they discuss it with their doctor.
    """

    static let readInstructions = """
    You read the text of a medical laboratory report (from OCR) and copy its results exactly. Copy each value exactly as \
    printed. Never guess a missing value. Do not copy names, IDs, phone numbers, the doctor or the lab.
    """

    static var local: SystemLanguageModel { .default }

    static var localStatus: String {
        switch local.availability {
        case .available: return "Ready"
        case .unavailable(.appleIntelligenceNotEnabled): return "Turn on Apple Intelligence in Settings"
        case .unavailable(.deviceNotEligible): return "Not available on this iPhone"
        case .unavailable(.modelNotReady): return "Getting ready"
        case .unavailable: return "Not available"
        }
    }

    static var cloud: GeminiLanguageModel {
        FirebaseAI.firebaseAI(backend: .agentPlatform(location: "global")).geminiLanguageModel(name: cloudModel)
    }

    static func plain(_ t: LabTest, _ trend: Trend?, note: String? = nil) -> Explained {
        let whereIs: String = switch flagOf(t.value, t.range) {
        case .high: "above"; case .low: "below"; case .normal: "within"; case .unknown: "compared with"
        }
        var moved = ""
        if let trend {
            moved = trend.direction == "same"
                ? " It is about the same as last time (\(fmt(trend.previous)) \(t.unit))."
                : " It has gone \(trend.direction) from \(fmt(trend.previous)) \(t.unit) last time."
        }
        return Explained(
            text: "Your \(t.name) is \(fmt(t.value)) \(t.unit), \(whereIs) the printed reference interval (\(t.range.text)).\(moved) Ask your doctor what this means for you.",
            questions: ["What could be behind my \(t.name) result?", "Should I repeat this test, and when?"],
            source: .rules, note: note)
    }

    static func explain(_ t: LabTest, meta: Meta, trend: Trend?, allowCloud: Bool) async -> Explained {
        let facts = deidentified(t, meta, trend)
        var allowed = [t.value]
        if let l = t.range.low { allowed.append(l) }
        if let h = t.range.high { allowed.append(h) }
        if let trend { allowed += [trend.previous, abs(trend.change)] }
        if let age = meta.age { allowed.append(Double(age)) }

        // On the device first; the cloud only with the user's say-so.
        var attempts: [Source] = []
        if local.isAvailable { attempts.append(.onDevice) }
        if allowCloud { attempts.append(.inCloud) }
        if attempts.isEmpty {
            return plain(t, trend, note: "Private explanations aren't available on this iPhone yet. Turn on Enhanced explanations in Settings for a fuller explanation.")
        }
        var lastError = ""
        for source in attempts {
            do {
                let session = source == .onDevice
                    ? LanguageModelSession(model: local, instructions: explainInstructions)
                    : LanguageModelSession(model: cloud, instructions: explainInstructions)
                let answer = try await session.respond(to: "Facts: \(facts)", generating: Explanation.self).content
                let text = answer.explanation.trimmingCharacters(in: .whitespacesAndNewlines)
                if let reason = checkExplanation(text, allowed: allowed) {
                    return plain(t, trend, note: "A summary is shown instead of the written explanation.").with(source: source)
                }
                let qs = answer.questions.map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && checkExplanation("\($0) Ask your doctor.", allowed: allowed) == nil }
                return Explained(text: text, questions: qs.isEmpty ? plain(t, trend).questions : Array(qs.prefix(2)), source: source)
            } catch {
                lastError = error.localizedDescription
            }
        }
        return plain(t, trend, note: "A full explanation isn't available right now, so a summary is shown.")
    }

    /// For report layouts the rules can't rebuild: the on-device model structures the OCR text. Never the cloud.
    static func readOnDevice(_ text: String) async -> [LabTest] {
        guard local.isAvailable else { return [] }
        do {
            let session = LanguageModelSession(model: local, instructions: readInstructions)
            let report = try await session.respond(to: "Report text:\n\(text.prefix(6000))", generating: ReadReport.self).content
            let tests = report.tests.compactMap { r -> LabTest? in
                let digits = r.value.filter { $0.isNumber || $0 == "." || $0 == "-" }
                guard let v = Double(digits), !r.name.isEmpty else { return nil }
                return LabTest(name: r.name, value: v, unit: r.unit, range: parseRange(r.range), raw: r.value, verified: false)
            }
            return verifyAgainstText(tests, text)
        } catch { return [] }
    }
}

private extension Explained {
    func with(source: Source) -> Explained { var c = self; c.source = source; return c }
}
