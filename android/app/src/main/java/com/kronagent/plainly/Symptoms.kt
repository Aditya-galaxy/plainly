package com.kronagent.plainly

/**
 * Same rules as the web app (src/lib/symptoms.ts): what the person notices goes on the doctor sheet, and fixed
 * rules (no AI) say "get care now" when notes mention a standard emergency warning sign.
 */
data class RedFlag(val id: String, val label: String, val advice: String)

private const val CALL = "Call 112 (emergency) or go to the nearest emergency department now."
private val I = RegexOption.IGNORE_CASE

private val RULES = listOf(
    Triple("chest", "Chest pain or pressure", Regex("\\b(chest|heart)\\b[^.]{0,30}\\b(pain|pressure|tight|tightness|squeez|heavy|ache|hurt)|\\b(pain|pressure|tightness)\\b[^.]{0,20}\\bchest\\b", I)),
    Triple("breath", "Trouble breathing", Regex("\\b(can'?t|cannot|hard to|difficult(y)? (in )?|trouble|struggl\\w*|short(ness)? of)\\s*(breath|breathe|breathing)|\\bbreathless\\w*|\\bgasping\\b", I)),
    Triple("stroke", "Signs of a stroke (face, arm, speech)", Regex("\\b(face|mouth)\\b[^.]{0,20}\\b(droop|drooping|numb|weak|uneven)|\\b(arm|leg|one side)\\b[^.]{0,20}\\b(weak|weakness|numb|can'?t move|paraly)|\\b(slurred|garbled|trouble)\\s*(speech|speaking|talking)|\\bsudden(ly)?\\b[^.]{0,25}\\b(confus|vision|blind|severe headache|worst headache)", I)),
    Triple("faint", "Fainting or passing out", Regex("\\b(faint(ed|ing)?|pass(ed|ing)? out|blacked out|lost consciousness|unconscious|collapsed)\\b", I)),
    Triple("bleed", "Heavy bleeding, or vomiting or coughing blood", Regex("\\b(vomit\\w*|cough\\w*|throw\\w* up)\\b[^.]{0,20}\\bblood|\\bblood\\b[^.]{0,20}\\b(vomit|stool|poo|cough)|\\bblack (tarry )?stools?\\b|\\b(heavy|severe|won'?t stop)\\b[^.]{0,15}\\bbleed", I)),
    Triple("seizure", "A seizure or fit", Regex("\\b(seizure|convulsion|fitting)\\b", I)),
    Triple("selfharm", "Thoughts of harming yourself", Regex("\\b(suicid\\w*|kill (myself|me)|end (my|it all)|self[- ]?harm|hurt(ing)? myself|don'?t want to (live|be alive))\\b", I)),
)

fun redFlags(text: String): List<RedFlag> = RULES.filter { it.third.containsMatchIn(text) }.map { (id, label, _) ->
    RedFlag(id, label, if (id == "selfharm")
        "You don't have to face this alone. Call Tele-MANAS on 14416 (free, 24×7, India) or 112 in an emergency. If you can, tell someone near you now."
    else CALL)
}
