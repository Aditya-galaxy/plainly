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
        // Units must match, unless OCR dropped one of them; then the test name alone decides.
        val p = report.firstOrNull { key(it.name) == key(t.name) && (it.unit.isEmpty() || t.unit.isEmpty() || it.unit.equals(t.unit, ignoreCase = true)) } ?: continue
        val change = t.value - p.value
        val same = abs(change) <= abs(p.value) * 0.02
        return Trend(p.value, change, if (same) "same" else if (change > 0) "up" else "down")
    }
    return null
}

// ── reading report text: one test per line, "Name  Value [H|L]  Unit  Reference interval" ──
// The unit is optional (OCR sometimes drops a short unit like "fL" or "%"), but must contain a letter or % so a
// range's first number is never mistaken for it.
private val ROW = Regex("^([A-Za-z][A-Za-z0-9 ,()/.'+\\-]*?[A-Za-z0-9)])\\s+(-?\\d+(?:\\.\\d+)?)\\s*(?:([HL])\\b)?(?:\\s+((?=[^\\s]*[A-Za-zµ%])[A-Za-zµ%^/\\d.]+(?:/[A-Za-z0-9.]+)?))?\\s+(.*\\d.*)$")
private val SKIP = Regex("^(test|result|unit|biological|reference|report|collected|reported|patient|age|sample|phone|ref\\.?\\s*by|checked|results relate)", RegexOption.IGNORE_CASE)

data class Meta(val age: Int? = null, val sex: String? = null, val date: String? = null)

fun parseMeta(lines: List<String>): Meta {
    val text = lines.joinToString("\n")
    // OCR often reads the "/" between age and sex as "I", "l" or "|".
    val asx = Regex("Age\\s*[/Il|]\\s*Sex\\s*:?\\s*(\\d{1,3})\\s*(?:Y|Yrs?|Years?)?\\s*[/Il|]\\s*(Male|Female|M|F)\\b", RegexOption.IGNORE_CASE).find(text)
    val age = asx?.groupValues?.get(1)?.toIntOrNull()
    val sex = asx?.groupValues?.get(2)?.let { if (it.startsWith("f", true)) "female" else "male" }
    val date = Regex("(?:Collected|Collection|Date)\\s*:?\\s*(\\d{1,2}\\s+[A-Za-z]{3,9}\\s+\\d{4})", RegexOption.IGNORE_CASE).find(text)?.groupValues?.get(1)
    return Meta(age, sex, date)
}

/** Units labs actually print. OCR misreads "/" as "l", "i" or "1" ("gldL", "ngimL"), so a printed unit is snapped to
 *  the nearest of these when it is at most two characters away. Same list as the web app. */
private val UNITS = listOf("g/dL", "mg/dL", "ng/mL", "pg/mL", "ng/dL", "uIU/mL", "mIU/L", "U/L", "IU/L", "fL", "pg", "%", "x10^3/uL", "x10^6/uL",
    "mmol/L", "umol/L", "mEq/L", "g/L", "mm/hr", "ratio")

private fun edits(a: String, b: String): Int {
    val d = Array(a.length + 1) { i -> IntArray(b.length + 1) { j -> if (i == 0) j else if (j == 0) i else 0 } }
    for (i in 1..a.length) for (j in 1..b.length)
        d[i][j] = minOf(d[i - 1][j] + 1, d[i][j - 1] + 1, d[i - 1][j - 1] + if (a[i - 1] == b[j - 1]) 0 else 1)
    return d[a.length][b.length]
}

fun canonicalUnit(u: String): String {
    val t = u.trim().removeSuffix(".")
    if (t.isEmpty()) return ""
    var best = t; var bestD = 3
    for (c in UNITS) { val d = edits(t.lowercase(), c.lowercase()); if (d < bestD) { best = c; bestD = d } }
    return if (bestD <= 2 && (bestD == 0 || t.length >= 2)) best else t
}

/** "6,80" → "6.80" (a comma read for a decimal point); "1,200" (thousands) is left alone. */
private fun decimalComma(s: String) = s.replace(Regex("(\\d),(\\d{1,2})(?!\\d)"), "$1.$2")

fun parseRows(lines: List<String>): List<LabTest> = lines.mapNotNull { line ->
    val l = decimalComma(line.replace(Regex("\\s+"), " ").trim())
    if (l.isEmpty() || SKIP.containsMatchIn(l)) return@mapNotNull null
    val m = ROW.find(l) ?: return@mapNotNull null
    val value = m.groupValues[2].toDouble()
    var range = parseRange(m.groupValues[5])
    if (range.low == null && range.high == null) {
        // A "< 200" can lose its "<" in a photo, leaving one number; the lab's own H/L mark says which side it is.
        // A lone number (OCR lost the "<" or ">", or read it as ":" or ";") is resolved by the lab's own H/L mark.
        val lone = Regex("^[:;.,'`\"]?\\s*(\\d+(?:\\.\\d+)?)$").find(m.groupValues[5].trim())?.groupValues?.get(1)?.toDouble()
        range = when {
            lone != null && m.groupValues[3] == "H" && value > lone -> Range(high = lone, text = "< ${fmt(lone)}")
            lone != null && m.groupValues[3] == "L" && value < lone -> Range(low = lone, text = "> ${fmt(lone)}")
            else -> return@mapNotNull null
        }
    }
    // Sanity: a broken OCR line can look like a row ("ng/dL 0 80-1.80"). A test name is never a unit, and a range's
    // low end is never above its high end; such rows are dropped rather than shown to a patient.
    val name = m.groupValues[1].trim()
    if (canonicalUnit(name) in UNITS || name.count { it.isLetter() } < 2) return@mapNotNull null
    if (range.low != null && range.high != null && range.low > range.high) return@mapNotNull null
    LabTest(name, value, canonicalUnit(m.groupValues[4]), range, m.groupValues[2], true)
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

// ── rebuilding table rows from OCR lines ──
/** One recognised line of text and its four corners (top-left, top-right, bottom-right, bottom-left), y pointing down. */
data class OcrLine(val text: String, val corners: List<Pair<Double, Double>>)

/**
 * OCR returns each table column as separate lines, and photos are rarely straight: on a page tilted 2°, a row's cells
 * drift by more than half a row height from left to right. Line boxes don't reliably carry the tilt (many OCR engines
 * return axis-aligned boxes), so the tilt is found from the table itself: the page is levelled at each candidate slope
 * within ±4.5° and the slope that rebuilds the most readable result rows wins.
 */
fun rowsFromLines(lines: List<OcrLine>): List<String> {
    val usable = lines.filter { it.text.isNotBlank() && it.corners.size == 4 }
    if (usable.isEmpty()) return emptyList()
    val fromBoxes = usable.mapNotNull { l ->
        val (x0, y0) = l.corners[0]; val (x1, y1) = l.corners[1]
        if (x1 - x0 > 20) (y1 - y0) / (x1 - x0) else null
    }.sorted().let { if (it.isEmpty()) 0.0 else it[it.size / 2] }
    val candidates = listOf(fromBoxes, 0.0) + (-45..45).map { it / 570.0 } // ~0.1° steps up to ±4.5°
    var best = rowsAtSlope(usable, fromBoxes)
    var bestScore = parseRows(best).size
    for (c in candidates) {
        val rows = rowsAtSlope(usable, c)
        val score = parseRows(rows).size
        if (score > bestScore) { best = rows; bestScore = score }
    }
    return best
}

/** Levels the page by [slope] (y grows by slope per pixel of x) and joins lines whose centres share a row. */
fun rowsAtSlope(lines: List<OcrLine>, slope: Double): List<String> {
    data class Item(val x: Double, val y: Double, val h: Double, val text: String)
    val items = lines.map { l ->
        val cx = l.corners.map { it.first }.average()
        val cy = l.corners.map { it.second }.average()
        val h = ((l.corners[3].second - l.corners[0].second) + (l.corners[2].second - l.corners[1].second)) / 2
        Item(cx, cy - cx * slope, kotlin.math.abs(h), l.text.trim())
    }.sortedBy { it.y }
    val hMedian = items.map { it.h }.sorted()[items.size / 2].coerceAtLeast(4.0)
    val rows = mutableListOf<MutableList<Item>>()
    for (it in items) {
        val row = rows.lastOrNull()
        if (row != null && kotlin.math.abs(row.map { r -> r.y }.average() - it.y) < hMedian * 0.5) row += it else rows += mutableListOf(it)
    }
    return rows.map { r -> r.sortedBy { it.x }.joinToString(" ") { it.text } }
}
