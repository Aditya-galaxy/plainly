package com.kronagent.plainly

import android.content.Intent
import android.net.Uri
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.health.connect.client.PermissionController
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

private val Teal = Color(0xFF0F6E66)
private val Warn = Color(0xFFB7791F)
private val Red = Color(0xFFC2410C)
private val Blue = Color(0xFF1D5FBF)
private val ZoneColors = mapOf(1 to Color(0xFFD6DDE0), 2 to Color(0xFF7FD1B2), 3 to Color(0xFFF1D18F), 4 to Color(0xFFEC9F74), 5 to Color(0xFFD9534F))

private sealed interface Source {
    data object InApp : Source
    data class FromHealth(val loaded: Health.Loaded) : Source
}

/**
 * Vitals against the person's own usual, from Health Connect (any watch that syncs to it) or the built-in sample.
 * Everything is worked out on the phone; nothing is uploaded.
 */
@Composable
fun VitalsPanel(age: Int?, added: Boolean, onAddToSheet: (List<String>) -> Unit) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var hcStatus by remember { mutableStateOf(Health.status(ctx)) }
    var granted by remember { mutableStateOf<Set<String>>(emptySet()) }
    var source by remember { mutableStateOf<Source>(Source.InApp) }
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    suspend fun refresh() {
        if (hcStatus != Health.Status.READY) return
        granted = Health.granted(ctx)
        if (granted.containsAll(Health.readPermissions)) {
            val l = Health.load(ctx)
            if (l.days.isNotEmpty() || l.workout != null) source = Source.FromHealth(l)
        }
    }
    LaunchedEffect(Unit) { try { refresh() } catch (e: Exception) { error = e.message } }

    val ask = rememberLauncherForActivityResult(PermissionController.createRequestPermissionResultContract()) { g ->
        granted = g
        scope.launch { try { refresh() } catch (e: Exception) { error = e.message } }
    }

    val days: List<Day>
    val session: Session?
    val workoutAge: Int?
    val label: String
    when (val s = source) {
        Source.InApp -> { days = sampleDays(); session = sampleWorkout(); workoutAge = 52; label = "Sample data (fictional), 35 days from a watch, plus one workout" }
        is Source.FromHealth -> {
            days = s.loaded.days; session = s.loaded.workout; workoutAge = age
            label = "From Health Connect, ${s.loaded.days.size} days" + when {
                s.loaded.sampleOnly -> ", Plainly's fictional sample"
                s.loaded.sources.isNotEmpty() -> ", " + s.loaded.sources.joinToString { it.substringAfterLast('.') }
                else -> ""
            }
        }
    }
    val report = remember(days) { analyse(days) }
    val workout = remember(session, workoutAge) { session?.let { analyseWorkout(it, workoutAge) } }

    Column(Modifier.padding(top = 22.dp)) {
        Text(label, fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = Color.Gray)
        val off = report.changes.count { it.direction == Direction.WORSE }
        Text(when {
            report.alerts.isNotEmpty() -> "Something needs attention"
            report.changes.isEmpty() -> "Not enough days yet"
            off == 0 -> "Your week looks like your usual"
            else -> "$off of your vitals ${if (off == 1) "is" else "are"} off your usual this week"
        }, fontFamily = FontFamily.Serif, fontSize = 30.sp, lineHeight = 34.sp, modifier = Modifier.padding(top = 4.dp))
        Text(if (report.changes.isEmpty()) "Plainly compares your last 7 days with the 28 before. It needs at least 10 days of data."
            else "Compared with your own last ${report.baselineDays} days, not with anyone else.",
            fontSize = 15.sp, lineHeight = 22.sp, color = MaterialTheme.colorScheme.onBackground.copy(alpha = .8f), modifier = Modifier.padding(top = 6.dp))

        // ── where the data comes from ──
        Card(Modifier.fillMaxWidth().padding(top = 16.dp)) {
            Column(Modifier.padding(16.dp)) {
                Text("Your watch, through Health Connect", fontWeight = FontWeight.SemiBold, fontSize = 15.sp)
                Text("Fitbit, Galaxy Watch, Pixel Watch, Garmin, Zepp, Oura and others sync to Health Connect. Plainly reads it on this phone.",
                    fontSize = 13.sp, color = Color.Gray, modifier = Modifier.padding(top = 4.dp))
                when (hcStatus) {
                    Health.Status.NOT_INSTALLED, Health.Status.NEEDS_UPDATE -> Button({
                        ctx.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.google.android.apps.healthdata")).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                    }, Modifier.padding(top = 10.dp)) { Text(if (hcStatus == Health.Status.NEEDS_UPDATE) "Update Health Connect" else "Install Health Connect") }
                    Health.Status.READY -> {
                        if (!granted.containsAll(Health.readPermissions)) Button({ ask.launch(Health.allPermissions(ctx)) }, Modifier.padding(top = 10.dp)) { Text("Connect Health Connect") }
                        else {
                            if (source == Source.InApp) Text("Connected, but there are no vitals in Health Connect from the last 35 days yet.", fontSize = 13.sp, modifier = Modifier.padding(top = 8.dp))
                            FlowRow(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                                OutlinedButton({
                                    scope.launch {
                                        error = null; busy = "Writing the sample to Health Connect…"
                                        try { Health.writeSample(ctx); busy = "Reading it back…"; refresh() } catch (e: Exception) { error = e.message }
                                        busy = null
                                    }
                                }, enabled = busy == null && granted.containsAll(Health.writePermissions)) { Text("Put sample in Health Connect") }
                                if (source is Source.FromHealth) TextButton({
                                    scope.launch {
                                        error = null; busy = "Removing Plainly's sample…"
                                        try { Health.deleteSample(ctx); source = Source.InApp; refresh() } catch (e: Exception) { error = e.message }
                                        busy = null
                                    }
                                }, enabled = busy == null) { Text("Remove Plainly's sample") }
                            }
                        }
                    }
                }
                busy?.let { Text(it, fontSize = 13.sp, color = Teal, modifier = Modifier.padding(top = 6.dp)) }
                error?.let { Text(it, fontSize = 13.sp, color = Red, modifier = Modifier.padding(top = 6.dp)) }
                if (source is Source.FromHealth) TextButton({ source = Source.InApp }) { Text("Show the built-in sample instead") }
            }
        }

        if (report.alerts.isNotEmpty()) Card(Modifier.fillMaxWidth().padding(top = 14.dp), colors = CardDefaults.cardColors(containerColor = Red.copy(alpha = .12f))) {
            Column(Modifier.padding(16.dp)) {
                Text(if (report.alerts.any { it.urgent }) "Get care now" else "Contact a doctor", fontFamily = FontFamily.Serif, fontSize = 22.sp, color = Red)
                report.alerts.forEach { Text("${it.title}. ${it.advice}", fontSize = 14.sp, modifier = Modifier.padding(top = 6.dp)) }
                Text("Fixed safety rules, not AI. Wearable sensors can be wrong; how you feel matters most.", fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 6.dp))
            }
        }

        report.recovery?.let { rec ->
            Row(Modifier.padding(top = 18.dp), verticalAlignment = Alignment.CenterVertically) {
                Gauge(rec)
                Column(Modifier.padding(start = 14.dp)) {
                    Text("Recovery today", fontFamily = FontFamily.Serif, fontSize = 22.sp)
                    Text("50 is a normal day for you. From heart rate variability (50%), resting heart rate (30%) and sleep (20%), as in OpenVitals.", fontSize = 13.sp, color = Color.Gray)
                }
            }
        }

        report.changes.forEach { c ->
            Column(Modifier.padding(top = 18.dp)) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(c.metric.label, fontWeight = FontWeight.SemiBold, fontSize = 15.sp, modifier = Modifier.weight(1f))
                    val (t, col) = when (c.direction) { Direction.STEADY -> "USUAL" to Color.Gray; Direction.WORSE -> "OFF YOUR USUAL" to Warn; Direction.BETTER -> "BETTER" to Teal }
                    Text(t, color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold, modifier = Modifier.background(col, RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 3.dp))
                }
                Spark(days, c.metric, report, if (c.direction == Direction.WORSE) Warn else MaterialTheme.colorScheme.onBackground.copy(alpha = .6f))
                Text(c.text, fontSize = 13.sp, color = Color.Gray)
            }
        }

        if (session != null && workout != null) WorkoutCard(session, workout)

        val lines = report.changes.filter { it.direction != Direction.STEADY }.map { it.text } +
            listOfNotNull(workout?.recovery1min?.let { "After a ${workout.durationMin}-minute workout, heart rate fell $it bpm in the first minute." }) +
            report.alerts.map { "${it.title}." }
        Button({ onAddToSheet(lines) }, Modifier.padding(top = 20.dp), enabled = !added && lines.isNotEmpty()) {
            Text(if (added) "Added to my doctor sheet" else "Add to my doctor sheet")
        }
        Text("Plainly describes changes in your own numbers and never diagnoses. Talk to your doctor about anything that worries you.",
            fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 14.dp))
    }
}

@Composable
private fun Gauge(v: Int) {
    val track = MaterialTheme.colorScheme.onBackground.copy(alpha = .12f)
    val col = if (v < 35) Warn else if (v > 65) Teal else MaterialTheme.colorScheme.primary
    Box(Modifier.size(84.dp), contentAlignment = Alignment.Center) {
        Canvas(Modifier.fillMaxSize().padding(6.dp)) {
            val st = Stroke(width = 8.dp.toPx(), cap = StrokeCap.Round)
            drawArc(track, 135f, 270f, false, style = st)
            drawArc(col, 135f, 270f * v / 100f, false, style = st)
        }
        Text("$v", fontFamily = FontFamily.Serif, fontSize = 24.sp)
    }
}

@Composable
private fun Spark(days: List<Day>, metric: Metric, r: VitalsReport, line: Color) {
    val vals = days.mapNotNull { metric.of(it) }
    if (vals.size < 2) return
    val base = days.dropLast(r.recentDays).takeLast(r.baselineDays).mapNotNull { metric.of(it) }
    val mean = base.average()
    val sd = kotlin.math.sqrt(base.sumOf { (it - mean) * (it - mean) } / maxOf(1, base.size - 1))
    val lo = minOf(vals.min(), mean - sd); val hi = maxOf(vals.max(), mean + sd)
    val usual = Teal.copy(alpha = .16f)
    val week = MaterialTheme.colorScheme.onBackground.copy(alpha = .06f)
    Canvas(Modifier.fillMaxWidth().height(48.dp).padding(vertical = 6.dp)) {
        fun x(i: Int) = i / (vals.size - 1f) * size.width
        fun y(v: Double) = (size.height - ((v - lo) / (hi - lo).coerceAtLeast(1e-9)) * size.height).toFloat()
        drawRect(usual, Offset(0f, y(mean + sd)), Size(size.width, y(mean - sd) - y(mean + sd)))
        val rs = x(vals.size - r.recentDays)
        drawRect(week, Offset(rs, 0f), Size(size.width - rs, size.height))
        val p = Path().apply { vals.forEachIndexed { i, v -> if (i == 0) moveTo(x(i), y(v)) else lineTo(x(i), y(v)) } }
        drawPath(p, line, style = Stroke(width = 2.dp.toPx()))
    }
}

@Composable
private fun WorkoutCard(s: Session, w: WorkoutSummary) {
    var playing by remember(s) { mutableStateOf(false) }
    var t by remember(s) { mutableStateOf<Float?>(null) }
    val endT = s.samples.last().t.toFloat()
    // Replay at 60× speed: a 39-minute recording plays in about 40 seconds.
    LaunchedEffect(playing) {
        if (!playing) return@LaunchedEffect
        val from = t ?: 0f
        val started = withFrameNanos { it }
        while (isActive) {
            val now = withFrameNanos { it }
            val cur = from + (now - started) / 1e9f * 60f
            if (cur >= endT) { t = endT; playing = false; break }
            t = cur
        }
    }
    val live = t?.let { tt -> s.samples.minBy { kotlin.math.abs(it.t - tt) } }
    val ink = MaterialTheme.colorScheme.onBackground
    Card(Modifier.fillMaxWidth().padding(top = 22.dp)) {
        Column(Modifier.padding(16.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(s.name, fontFamily = FontFamily.Serif, fontSize = 21.sp, modifier = Modifier.weight(1f))
                OutlinedButton({ if (t != null && t!! >= endT) t = 0f; playing = !playing }) {
                    Text(if (playing) "Pause" else if (t != null && t!! < endT) "Resume" else "Replay live")
                }
            }
            Text("${w.durationMin} min, zones from an estimated maximum of ${w.maxEstimate} bpm (220 − age; real maximums vary)", fontSize = 12.sp, color = Color.Gray)
            live?.let { l ->
                val zone = ZONES.find { l.bpm.toDouble() / w.maxEstimate >= it.from && l.bpm.toDouble() / w.maxEstimate < it.to }
                Row(Modifier.padding(top = 8.dp), verticalAlignment = Alignment.Bottom) {
                    Text("♥ ", color = Red, fontSize = 24.sp)
                    Text("${l.bpm}", fontFamily = FontFamily.Serif, fontSize = 32.sp)
                    Text(" bpm", fontSize = 13.sp, color = Color.Gray, modifier = Modifier.weight(1f).padding(bottom = 6.dp))
                    Text("${if (l.t > s.endT) "stopped, recovering" else zone?.name ?: "Resting"}, ${clock(l.t)}", fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = Color.Gray, modifier = Modifier.padding(bottom = 6.dp))
                }
            }
            val minB = 60f
            val maxB = maxOf(w.maxEstimate, s.samples.maxOf { it.bpm }) + 5f
            Canvas(Modifier.fillMaxWidth().height(170.dp).padding(top = 10.dp)) {
                fun x(tt: Float) = tt / endT * size.width
                fun y(b: Float) = (1 - (b - minB) / (maxB - minB)) * size.height
                ZONES.drop(1).forEach { z ->
                    val top = y(minOf(maxB, (z.to * w.maxEstimate).toFloat())); val bot = y((z.from * w.maxEstimate).toFloat())
                    if (bot > top) drawRect(ZoneColors.getValue(z.id).copy(alpha = .22f), Offset(0f, top), Size(size.width, bot - top))
                }
                drawLine(ink.copy(alpha = .4f), Offset(x(s.endT.toFloat()), 0f), Offset(x(s.endT.toFloat()), size.height), 1.5f, pathEffect = PathEffect.dashPathEffect(floatArrayOf(8f, 8f)))
                val shown = t?.let { tt -> s.samples.filter { it.t <= tt } } ?: s.samples
                if (shown.size > 1) drawPath(Path().apply { shown.forEachIndexed { i, p -> if (i == 0) moveTo(x(p.t.toFloat()), y(p.bpm.toFloat())) else lineTo(x(p.t.toFloat()), y(p.bpm.toFloat())) } },
                    ink, style = Stroke(width = 2.dp.toPx()))
                if (t == null) {
                    w.highs.forEach { drawCircle(Red, 4.dp.toPx(), Offset(x(it.t.toFloat()), y(it.bpm.toFloat()))) }
                    w.lows.forEach { drawCircle(Blue, 4.dp.toPx(), Offset(x(it.t.toFloat()), y(it.bpm.toFloat()))) }
                }
                live?.let { drawCircle(Red, 6.dp.toPx(), Offset(x(it.t.toFloat()), y(it.bpm.toFloat()))) }
            }
            Row(Modifier.fillMaxWidth().padding(top = 4.dp)) {
                Text("start", fontFamily = FontFamily.Monospace, fontSize = 10.sp, color = Color.Gray, modifier = Modifier.weight(1f))
                Text("stop ${clock(s.endT)}", fontFamily = FontFamily.Monospace, fontSize = 10.sp, color = Color.Gray)
            }
            Row(Modifier.fillMaxWidth().padding(top = 12.dp)) {
                Stat("${w.avg}", "average bpm"); Stat("${w.peak.bpm}", "peak at ${clock(w.peak.t)}")
            }
            Row(Modifier.fillMaxWidth().padding(top = 8.dp)) {
                Stat("${w.lows.minOfOrNull { it.bpm } ?: w.low.bpm}", "lowest between efforts"); Stat(w.recovery1min?.toString() ?: "–", "bpm drop 1 min after stopping")
            }
            Column(Modifier.padding(top = 12.dp)) {
                w.zoneMin.forEach { z ->
                    Row(Modifier.padding(vertical = 3.dp), verticalAlignment = Alignment.CenterVertically) {
                        Box(Modifier.size(10.dp).background(ZoneColors.getValue(z.zone.id), RoundedCornerShape(50)))
                        Text(z.zone.name, fontSize = 13.sp, modifier = Modifier.width(90.dp).padding(start = 8.dp))
                        Canvas(Modifier.weight(1f).height(8.dp)) {
                            drawRoundRect(ink.copy(alpha = .1f), cornerRadius = CornerRadius(size.height / 2))
                            drawRoundRect(ZoneColors.getValue(z.zone.id), size = Size(size.width * (z.minutes / w.durationMin).toFloat().coerceIn(0f, 1f), size.height), cornerRadius = CornerRadius(size.height / 2))
                        }
                        Text("${num(z.minutes)} min", fontSize = 13.sp, modifier = Modifier.width(64.dp).padding(start = 8.dp))
                    }
                }
            }
            val bullets = buildList {
                if (w.highs.isNotEmpty()) add("Highs at ${w.highs.joinToString { "${clock(it.t)} (${it.bpm})" }}.")
                if (w.lows.isNotEmpty()) add("Lows at ${w.lows.joinToString { "${clock(it.t)} (${it.bpm})" }}: the easy stretches between efforts.")
                addAll(w.notes)
            }
            bullets.forEach { Text("• $it", fontSize = 13.sp, lineHeight = 19.sp, modifier = Modifier.padding(top = 6.dp)) }
        }
    }
}

@Composable
private fun RowScope.Stat(big: String, small: String) {
    Column(Modifier.weight(1f)) {
        Text(big, fontFamily = FontFamily.Serif, fontSize = 26.sp)
        Text(small, fontSize = 12.sp, color = Color.Gray)
    }
}
