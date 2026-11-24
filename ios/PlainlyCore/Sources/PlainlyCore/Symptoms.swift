import Foundation

/// Same rules as the web app (src/lib/symptoms.ts) and Android (Symptoms.kt): what the person notices goes on the
/// doctor sheet, and fixed rules (no AI) say "get care now" when notes mention a standard emergency warning sign.
public struct RedFlag: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let advice: String
}

private let CALL = "Call 112 (emergency) or go to the nearest emergency department now."

private let RULES: [(String, String, RX)] = [
    ("chest", "Chest pain or pressure", RX("\\b(chest|heart)\\b[^.]{0,30}\\b(pain|pressure|tight|tightness|squeez|heavy|ache|hurt)|\\b(pain|pressure|tightness)\\b[^.]{0,20}\\bchest\\b", ci: true)),
    ("breath", "Trouble breathing", RX("\\b(can'?t|cannot|hard to|difficult(y)? (in )?|trouble|struggl\\w*|short(ness)? of)\\s*(breath|breathe|breathing)|\\bbreathless\\w*|\\bgasping\\b", ci: true)),
    ("stroke", "Signs of a stroke (face, arm, speech)", RX("\\b(face|mouth)\\b[^.]{0,20}\\b(droop|drooping|numb|weak|uneven)|\\b(arm|leg|one side)\\b[^.]{0,20}\\b(weak|weakness|numb|can'?t move|paraly)|\\b(slurred|garbled|trouble)\\s*(speech|speaking|talking)|\\bsudden(ly)?\\b[^.]{0,25}\\b(confus|vision|blind|severe headache|worst headache)", ci: true)),
    ("faint", "Fainting or passing out", RX("\\b(faint(ed|ing)?|pass(ed|ing)? out|blacked out|lost consciousness|unconscious|collapsed)\\b", ci: true)),
    ("bleed", "Heavy bleeding, or vomiting or coughing blood", RX("\\b(vomit\\w*|cough\\w*|throw\\w* up)\\b[^.]{0,20}\\bblood|\\bblood\\b[^.]{0,20}\\b(vomit|stool|poo|cough)|\\bblack (tarry )?stools?\\b|\\b(heavy|severe|won'?t stop)\\b[^.]{0,15}\\bbleed", ci: true)),
    ("seizure", "A seizure or fit", RX("\\b(seizure|convulsion|fitting)\\b", ci: true)),
    ("selfharm", "Thoughts of harming yourself", RX("\\b(suicid\\w*|kill (myself|me)|end (my|it all)|self[- ]?harm|hurt(ing)? myself|don'?t want to (live|be alive))\\b", ci: true)),
]

public func redFlags(_ text: String) -> [RedFlag] {
    RULES.filter { $0.2.matches(text) }.map { id, label, _ in
        RedFlag(id: id, label: label, advice: id == "selfharm"
            ? "You don't have to face this alone. Call Tele-MANAS on 14416 (free, 24×7, India) or 112 in an emergency. If you can, tell someone near you now."
            : CALL)
    }
}
