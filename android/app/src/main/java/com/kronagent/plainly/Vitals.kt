package com.kronagent.plainly

import java.time.LocalDate
import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sqrt

/**
 * Vitals from a watch or band, compared with the person's OWN normal and never turned into a diagnosis.
 * A line-for-line port of the web app's src/lib/vitals.ts and src/lib/workout.ts, so both give the same numbers.
 * Recovery weighting (HRV 50%, resting heart rate 30%, sleep 20%, 50 = a normal day) comes from OpenVitals.
 */

data class Day(val date: String, val restingHr: Double? = null, val hrv: Double? = null, val sleepMin: Double? = null, val spo2: Double? = null)

enum class Metric(val label: String, val unit: String, val betterUp: Boolean, val minChange: Double, val relative: Boolean = false) {
    RESTING_HR("Resting heart rate", "bpm", false, 5.0),
    HRV("Heart rate variability", "ms", true, 0.15, relative = true),
    SLEEP("Sleep", "min", true, 45.0),
    SPO2("Blood oxygen (overnight)", "%", true, 2.0);

    fun of(d: Day): Double? = when (this) { RESTING_HR -> d.restingHr; HRV -> d.hrv; SLEEP -> d.sleepMin; SPO2 -> d.spo2 }
}

enum class Direction { BETTER, WORSE, STEADY }

data class Change(val metric: Metric, val baseline: Double, val recent: Double, val delta: Double, val direction: Direction, val text: String)
data class VitalsAlert(val id: String, val urgent: Boolean, val title: String, val advice: String)
data class VitalsReport(val days: Int, val baselineDays: Int, val recentDays: Int, val recovery: Int?, val changes: List<Change>, val alerts: List<VitalsAlert>)

/** JavaScript's Math.round (halves go up), so Kotlin and web agree to the digit. */
internal fun jsRound(x: Double): Double = floor(x + 0.5)
internal fun round(x: Double, d: Int = 0): Double = jsRound(x * 10.0.pow(d)) / 10.0.pow(d)
/** Prints 70.0 as "70" and 96.2 as "96.2", like JavaScript does. */
internal fun num(x: Double): String = if (x == floor(x) && abs(x) < 1e15) x.toLong().toString() else x.toString()

private fun mean(xs: List<Double>) = xs.sum() / xs.size
private fun sd(xs: List<Double>): Double { val m = mean(xs); return sqrt(xs.sumOf { (it - m) * (it - m) } / max(1, xs.size - 1)) }
/** JavaScript's Array.slice for negative indices. */
private fun <T> List<T>.jsSlice(from: Int, to: Int): List<T> {
    val a = (if (from < 0) size + from else from).coerceIn(0, size)
    val b = (if (to < 0) size + to else to).coerceIn(0, size)
    return if (a < b) subList(a, b) else emptyList()
}

internal fun fmtSleep(m: Double) = if (m < 60) "${num(jsRound(m))} min" else "${floor(m / 60).toLong()} h ${num(jsRound(m % 60))} min"

/**
 * Baseline: the 28 days before the recent window. Recent: the last 7 days. A change counts only when it is bigger than
 * the person's usual day-to-day spread AND a minimum that matters (5 bpm, 15% HRV, 45 min sleep, 2 points SpO2).
 */
fun analyse(input: List<Day>, recentDays: Int = 7, baselineDays: Int = 28): VitalsReport {
    val days = input.sortedBy { it.date }
    val recent = days.jsSlice(-recentDays, days.size)
    val base = days.jsSlice(-(recentDays + baselineDays), -recentDays)
    val changes = mutableListOf<Change>()
    for (m in Metric.entries) {
        val b = base.mapNotNull { m.of(it) }
        val r = recent.mapNotNull { m.of(it) }
        if (b.size < 7 || r.size < 3) continue
        val bm = mean(b); val rm = mean(r)
        val spread = max(sd(b), 1e-9)
        val delta = rm - bm
        val threshold = max(spread, if (m.relative) abs(bm) * m.minChange else m.minChange)
        val moved = abs(delta) >= threshold
        val good = (delta > 0) == m.betterUp
        val dir = if (!moved) Direction.STEADY else if (good) Direction.BETTER else Direction.WORSE
        val digits = if (m == Metric.SPO2) 1 else 0
        fun show(v: Double) = if (m == Metric.SLEEP) fmtSleep(v) else "${num(round(v, digits))} ${m.unit}"
        val diff = if (m == Metric.SLEEP) fmtSleep(abs(delta)) else "${num(round(abs(delta), digits))} ${m.unit}"
        val word = if (m == Metric.SLEEP) (if (delta > 0) "longer" else "shorter") else if (delta > 0) "higher" else "lower"
        val text = if (dir == Direction.STEADY) "${m.label} is in your usual range (${show(rm)} this week, ${show(bm)} usually)."
            else "${m.label} is $diff $word than your usual (${show(rm)} this week vs ${show(bm)})."
        changes += Change(m, round(bm, 1), round(rm, 1), round(delta, 1), dir, text)
    }

    var recovery: Int? = null
    val last = days.lastOrNull()
    if (last != null && base.size >= 7) {
        fun zLast(m: Metric): Double? {
            val b = base.mapNotNull { m.of(it) }
            val v = m.of(last)
            if (b.size < 7 || v == null) return null
            return (v - mean(b)) / max(sd(b), 1e-9) * (if (m.betterUp) 1 else -1)
        }
        val have = listOf(zLast(Metric.HRV) to 0.5, zLast(Metric.RESTING_HR) to 0.3, zLast(Metric.SLEEP) to 0.2).filter { it.first != null }
        if (have.isNotEmpty()) {
            val w = have.sumOf { it.second }
            val s = have.sumOf { min(3.0, max(-3.0, it.first!!)) * it.second } / w
            recovery = jsRound(max(0.0, min(100.0, 50 + s * 10))).toInt()
        }
    }

    val alerts = mutableListOf<VitalsAlert>()
    fun lastN(m: Metric, n: Int) = days.takeLast(n).mapNotNull { m.of(it) }
    val hr3 = lastN(Metric.RESTING_HR, 3)
    if (hr3.size == 3 && hr3.all { it > 100 }) alerts += VitalsAlert("hr-high", false, "Resting heart rate above 100 for 3 days",
        "Contact a doctor today. If you have chest pain, feel faint or breathless, call 112.")
    if (hr3.size == 3 && hr3.all { it < 40 }) alerts += VitalsAlert("hr-low", false, "Resting heart rate below 40 for 3 days",
        "Contact a doctor, unless a doctor already knows your heart rate runs this low. If you feel dizzy or faint, call 112.")
    val ox2 = lastN(Metric.SPO2, 2)
    if (ox2.size == 2 && ox2.all { it < 90 }) alerts += VitalsAlert("spo2-low", true, "Blood oxygen averaged below 90% for 2 nights",
        "Wrist sensors can be wrong, but don't ignore this. If you are breathless, confused or your lips look blue, call 112 now; otherwise contact a doctor today.")
    val rhr = changes.find { it.metric == Metric.RESTING_HR }
    if (rhr != null && rhr.delta >= 10) alerts += VitalsAlert("hr-rise", false, "Resting heart rate ${num(rhr.delta)} bpm above your usual this week",
        "A sustained rise is worth mentioning to your doctor, especially with tiredness or other symptoms.")

    return VitalsReport(days.size, base.size, recent.size, recovery, changes, alerts)
}

/** The same Park–Miller generator as the web sample, so both produce identical fictional data. */
private class Rand(var seed: Long) { fun next(): Double { seed = (seed * 16807) % 2147483647; return seed / 2147483647.0 - 0.5 } }

/** A deterministic 35-day sample (fictional): a usual month, then a tired week. Values don't depend on [end]. */
fun sampleDays(end: LocalDate = LocalDate.parse("2026-11-18")): List<Day> {
    val r = Rand(7)
    return (34 downTo 0).map { i ->
        val tired = if (i < 7) (7 - i) / 7.0 else 0.0
        Day(
            date = end.minusDays(i.toLong()).toString(),
            restingHr = jsRound(62 + r.next() * 4 + tired * 14),
            hrv = jsRound(44 + r.next() * 10 - tired * 14),
            sleepMin = jsRound(420 + r.next() * 60 - tired * 75),
            spo2 = round(96.2 + r.next() * 1.2 - tired * 0.6, 1),
        )
    }
}

// ── workouts ──

data class Sample(val t: Int, val bpm: Int) // t = seconds from the start
data class Session(val name: String, val startIso: String, val samples: List<Sample>, val endT: Int) // endT = when exercise stopped
data class Zone(val id: Int, val name: String, val from: Double, val to: Double)
data class Moment(val t: Int, val bpm: Int)
data class ZoneTime(val zone: Zone, val minutes: Double)
data class WorkoutSummary(val durationMin: Int, val avg: Int, val peak: Moment, val low: Moment, val maxEstimate: Int, val zoneMin: List<ZoneTime>,
                          val highs: List<Moment>, val lows: List<Moment>, val recovery1min: Int?, val notes: List<String>)

val ZONES = listOf(Zone(1, "Easy", 0.5, 0.6), Zone(2, "Steady", 0.6, 0.7), Zone(3, "Moderate", 0.7, 0.8), Zone(4, "Hard", 0.8, 0.9), Zone(5, "Maximum", 0.9, 1.2))

fun clock(t: Int) = "${t / 60}:${(t % 60).toString().padStart(2, '0')}"

/** Highs (or lows): local extremes of the 30-second average, at least 3 minutes apart, most extreme first. */
private fun extremes(s: List<Sample>, high: Boolean, n: Int): List<Moment> {
    val smooth = s.mapIndexed { i, p -> val w = s.jsSlice(max(0, i - 3), i + 4); p.t to w.sumOf { it.bpm }.toDouble() / w.size }
    val sign = if (high) 1 else -1
    val cand = smooth.filterIndexed { i, p -> i > 0 && i < smooth.size - 1 && sign * (p.second - smooth[i - 1].second) >= 0 && sign * (p.second - smooth[i + 1].second) >= 0 }
    val out = mutableListOf<Moment>()
    for (c in cand.sortedByDescending { sign * it.second }) {
        if (out.all { abs(it.t - c.first) >= 180 }) out += Moment(c.first, jsRound(c.second).toInt())
        if (out.size == n) break
    }
    return out.sortedBy { it.t }
}

fun analyseWorkout(sess: Session, age: Int?): WorkoutSummary {
    val s = sess.samples
    val during = s.filter { it.t <= sess.endT }
    val maxEstimate = 220 - (if (age != null && age in 11..99) age else 35)
    val avg = jsRound(during.sumOf { it.bpm }.toDouble() / during.size).toInt()
    val pk = during.reduce { a, b -> if (b.bpm > a.bpm) b else a }
    val lo = during.reduce { a, b -> if (b.bpm < a.bpm) b else a }
    val zoneSec = mutableMapOf<Int, Int>()
    for (i in 1 until during.size) {
        val dt = during[i].t - during[i - 1].t
        val frac = during[i].bpm.toDouble() / maxEstimate
        ZONES.find { frac >= it.from && frac < it.to }?.let { zoneSec[it.id] = (zoneSec[it.id] ?: 0) + dt }
    }
    val atStop = during.lastOrNull()
    val oneMin = s.find { it.t >= sess.endT + 60 }
    val recovery1min = if (atStop != null && oneMin != null) atStop.bpm - oneMin.bpm else null

    val notes = mutableListOf<String>()
    val hard = (zoneSec[4] ?: 0) + (zoneSec[5] ?: 0)
    notes += "You spent ${num(jsRound(hard / 60.0))} min hard or harder, and ${num(jsRound((zoneSec[2] ?: 0) / 60.0 + (zoneSec[3] ?: 0) / 60.0))} min steady to moderate."
    if (recovery1min != null) notes += if (recovery1min >= 12) "Your heart rate fell $recovery1min bpm in the first minute after stopping, a normal recovery."
        else "Your heart rate fell only $recovery1min bpm in the first minute after stopping. A slow recovery now and then is common when tired; if it keeps happening, mention it to your doctor."
    val maxSec = during.filterIndexed { i, p -> i > 0 && p.bpm.toDouble() / maxEstimate >= 0.95 }.size * 5
    if (maxSec >= 120) notes += "You were at 95% or more of your estimated maximum for about ${num(jsRound(maxSec / 60.0))} min. If you felt chest pain, dizziness or unusual breathlessness, stop and get checked."

    return WorkoutSummary(
        durationMin = jsRound(sess.endT / 60.0).toInt(), avg = avg, peak = Moment(pk.t, pk.bpm), low = Moment(lo.t, lo.bpm), maxEstimate = maxEstimate,
        zoneMin = ZONES.map { ZoneTime(it, jsRound((zoneSec[it.id] ?: 0) / 60.0 * 10) / 10) },
        highs = extremes(during, true, 4),
        // Lows that matter are the recoveries between efforts, so the warm-up's first 5 minutes are left out.
        lows = extremes(during.filter { it.t >= 300 }, false, 3),
        recovery1min = recovery1min, notes = notes,
    )
}

/** A fictional 36-minute brisk walk/jog with 3 minutes recorded after stopping. Samples every 5 seconds. */
fun sampleWorkout(): Session {
    val r = Rand(11)
    val end = 36
    fun target(t: Int): Double {
        val m = t / 60.0
        if (m < 7) return 92 + m * 4
        if (m < 31) { val k = floor((m - 7) / 6); return if ((m - 7) % 6 < 3) 138 + k * 2.5 else 116.0 }
        if (m < end) return 128 - (m - 31) * 2
        return 72 + (118 - 72) * exp(-(m - end) / 1.1)
    }
    var bpm = 76.0
    val samples = (0..(end + 3) * 60 step 5).map { t -> bpm += (target(t) - bpm) * 0.18 + r.next() * 2; Sample(t, jsRound(bpm).toInt()) }
    return Session("Brisk walk and jog (sample)", "2026-11-16T06:30:00+05:30", samples, end * 60)
}
