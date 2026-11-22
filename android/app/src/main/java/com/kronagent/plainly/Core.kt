package com.kronagent.plainly

import kotlin.math.abs

/**
 * The same rules as the web app (src/lib/ranges.ts, parse.ts, guard.ts, deid.ts), ported line for line:
 * numbers are handled by code, models only read and write words.
 */

data class Range(val low: Double? = null, val high: Double? = null, val text: String = "")
enum class Flag { LOW, HIGH, NORMAL, UNKNOWN }
data class LabTest(
    val name: String,
    val value: Double,
    val unit: String,
    val range: Range,
    val raw: String = value.toString(),
    /** True when the value was found in the report's own (OCR) text. */
    val verified: Boolean = true,
)
data class Trend(val previous: Double, val change: Double, val direction: String)

private fun num(s: String) = s.replace(",", "").toDouble()
private val NUM = "-?\\d+(?:[.,]\\d+)?"

fun parseRange(text: String): Range {
    val t = text.replace(Regex("\\s+"), " ").trim()
    Regex("($NUM)\\s*(?:-|–|to)\\s*($NUM)", RegexOption.IGNORE_CASE).find(t)?.let { return Range(num(it.groupValues[1]), num(it.groupValues[2]), t) }
    Regex("(?:<=?|≤|less than|below|up\\s?to|upto)\\s*($NUM)", RegexOption.IGNORE_CASE).find(t)?.let { return Range(high = num(it.groupValues[1]), text = t) }
    Regex("(?:>=?|≥|more than|above|greater than)\\s*($NUM)", RegexOption.IGNORE_CASE).find(t)?.let { return Range(low = num(it.groupValues[1]), text = t) }
    return Range(text = t)
}

fun flagOf(v: Double, r: Range): Flag = when {
    r.low == null && r.high == null -> Flag.UNKNOWN
    r.low != null && v < r.low -> Flag.LOW
    r.high != null && v > r.high -> Flag.HIGH
    else -> Flag.NORMAL
}

fun distance(v: Double, r: Range): Double = when {
    r.low != null && v < r.low -> (r.low - v) / abs(if (r.low == 0.0) 1.0 else r.low)
    r.high != null && v > r.high -> (v - r.high) / abs(if (r.high == 0.0) 1.0 else r.high)
    else -> 0.0
}

fun nearEdge(v: Double, r: Range, margin: Double = 0.05): Boolean {
    if (flagOf(v, r) != Flag.NORMAL) return false
    fun near(l: Double?) = l != null && abs(v - l) <= abs(l) * margin
    return near(r.low) || near(r.high)
}

private fun key(name: String) = name.lowercase().replace(Regex("\\(.*?\\)"), "").replace(Regex("[^a-z0-9]+"), " ").trim()

fun trendOf(t: LabTest, earlier: List<List<LabTest>>): Trend? {
    for (report in earlier) {
        val p = report.firstOrNull { key(it.name) == key(t.name) && it.unit.equals(t.unit, ignoreCase = true) } ?: continue
        val change = t.value - p.value
        val same = abs(change) <= abs(p.value) * 0.02
        return Trend(p.value, change, if (same) "same" else if (change > 0) "up" else "down")
    }
    return null
}

// ── reading report text: one test per line, "Name  Value [H|L]  Unit  Reference interval" ──
private val ROW = Regex("^([A-Za-z][A-Za-z0-9 ,()/.'+\\-]*?[A-Za-z0-9)])\\s+(-?\\d+(?:\\.\\d+)?)\\s*(?:([HL])\\b)?\\s+([A-Za-zµ%^/\\d.]+(?:/[A-Za-z0-9.]+)?)\\s+(.*\\d.*)$")
private val SKIP = Regex("^(test|result|unit|biological|reference|report|collected|reported|patient|age|sample|phone|ref\\.?\\s*by|checked|results relate)", RegexOption.IGNORE_CASE)

data class Meta(val age: Int? = null, val sex: String? = null, val date: String? = null)

fun parseMeta(lines: List<String>): Meta {
    val text = lines.joinToString("\n")
    val asx = Regex("Age\\s*/\\s*Sex\\s*:?\\s*(\\d{1,3})\\s*(?:Y|Yrs?|Years?)?\\s*/\\s*(Male|Female|M|F)\\b", RegexOption.IGNORE_CASE).find(text)
    val age = asx?.groupValues?.get(1)?.toIntOrNull()
    val sex = asx?.groupValues?.get(2)?.let { if (it.startsWith("f", true)) "female" else "male" }
    val date = Regex("(?:Collected|Collection|Date)\\s*:?\\s*(\\d{1,2}\\s+[A-Za-z]{3,9}\\s+\\d{4})", RegexOption.IGNORE_CASE).find(text)?.groupValues?.get(1)
    return Meta(age, sex, date)
}

fun parseRows(lines: List<String>): List<LabTest> = lines.mapNotNull { line ->
    val l = line.replace(Regex("\\s+"), " ").trim()
    if (l.isEmpty() || SKIP.containsMatchIn(l)) return@mapNotNull null
    val m = ROW.find(l) ?: return@mapNotNull null
    val range = parseRange(m.groupValues[5])
    if (range.low == null && range.high == null) return@mapNotNull null
    LabTest(m.groupValues[1].trim(), m.groupValues[2].toDouble(), m.groupValues[4], range, m.groupValues[2], true)
}

/** A model reading report text can misread a number; each value must appear in the OCR text as printed. */
fun verifyAgainstText(tests: List<LabTest>, source: String): List<LabTest> {
    val hay = source.replace(Regex("\\s+"), " ")
    return tests.map { t ->
        val variants = setOf(t.raw.trim(), fmt(t.value), "%.1f".format(t.value), "%.2f".format(t.value))
        val found = variants.any { v -> Regex("(^|[^0-9.])${Regex.escape(v)}([^0-9]|$)").containsMatchIn(hay) }
        t.copy(verified = found)
    }
}

fun fmt(v: Double): String = if (v == v.toLong().toDouble()) v.toLong().toString() else v.toString()

// ── what the cloud may see ──
fun ageBand(age: Int?): String? = when {
    age == null || age <= 0 || age > 120 -> null
    age < 18 -> "under 18"
    else -> "${age / 10 * 10}s"
}

fun deidentified(t: LabTest, meta: Meta, trend: Trend?): String {
    val name = t.name.replace(Regex("[^A-Za-z0-9 ()%,.+\\-/]"), " ").replace(Regex("\\s+"), " ").trim().take(60)
    val parts = mutableListOf(
        "\"test\":\"$name\"", "\"value\":${fmt(t.value)}", "\"unit\":\"${t.unit.take(16)}\"",
        "\"range\":\"${t.range.text.take(40)}\"", "\"flag\":\"${flagOf(t.value, t.range).name.lowercase()}\"",
    )
    trend?.let { parts += "\"previous\":${fmt(it.previous)}" }
    ageBand(meta.age)?.let { parts += "\"ageBand\":\"$it\"" }
    meta.sex?.let { parts += "\"sex\":\"$it\"" }
    return parts.joinToString(",", "{", "}")
}

// ── the guard: explains, never diagnoses or prescribes; numbers must be the test's own ──
private val DIAGNOSE = listOf(
    Regex("\\byou (?:have|are suffering from|are diagnosed|definitely|certainly)\\b", RegexOption.IGNORE_CASE),
    Regex("\\b(?:this|it) (?:means|confirms|proves) (?:that )?you\\b", RegexOption.IGNORE_CASE),
    Regex("\\bdiagnos(?:is|ed|e)\\b(?! is not| isn't)", RegexOption.IGNORE_CASE),
    Regex("\\byou(?:'re| are) (?:diabetic|anaemic|anemic|hypothyroid|hyperthyroid)\\b", RegexOption.IGNORE_CASE),
)
private val PRESCRIBE = listOf(
    Regex("\\b(?:take|start|stop|increase|reduce|double)\\s+(?:a |an |your |the )?(?:dose|tablet|pill|medicine|medication|supplement|insulin|metformin|levothyroxine|thyroxine|statin)", RegexOption.IGNORE_CASE),
    Regex("\\b\\d+(?:\\.\\d+)?\\s?(?:mg|mcg|µg|iu|units)\\b(?! ?/)", RegexOption.IGNORE_CASE),
)
private val DOCTOR = Regex("\\b(?:doctor|physician|clinician|gp|healthcare provider)\\b", RegexOption.IGNORE_CASE)

/** Null when the text passes; otherwise the reason it was rejected. */
fun checkExplanation(text: String, allowed: List<Double>): String? {
    val t = text.trim()
    if (t.length < 20) return "The explanation was too short to be useful."
    if (t.length > 900) return "The explanation ran too long."
    if (DIAGNOSE.any { it.containsMatchIn(t) }) return "It read like a diagnosis, which Plainly never gives."
    if (PRESCRIBE.any { it.containsMatchIn(t) }) return "It suggested a medicine or dose, which only a doctor should."
    val stray = Regex(NUM).findAll(t).map { num(it.value) }
        .filter { n -> allowed.none { a -> abs(a - n) <= maxOf(1e-9, abs(a) * 0.001) } && !(n == n.toLong().toDouble() && n in 0.0..3.0) }
        .firstOrNull()
    if (stray != null) return "It mentioned a number that isn't on your report (${fmt(stray)})."
    if (!DOCTOR.containsMatchIn(t)) return "It didn't point you back to your doctor."
    return null
}
