package com.kronagent.plainly

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.ImageDecoder
import android.net.Uri
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.PickVisualMediaRequest
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.google.firebase.ai.ondevice.OnDeviceModelStatus
import kotlinx.coroutines.launch
import org.json.JSONArray
import org.json.JSONObject
import java.io.File

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        // Health Connect opens Plainly with this action to show why it asks for health data.
        val rationale = intent?.action == "androidx.health.ACTION_SHOW_PERMISSIONS_RATIONALE" || intent?.action == "android.intent.action.VIEW_PERMISSION_USAGE"
        setContent { PlainlyTheme { PlainlyScreen(rationale) } }
    }
}

// ── theme: calm and clinical, matching the web app ──
private val Teal = Color(0xFF0F6E66)
private val High = Color(0xFFC2410C)
private val Low = Color(0xFF1D5FBF)
private val Edge = Color(0xFFB7791F)
private val Cloud = Color(0xFF6A55B5)

@Composable
fun PlainlyTheme(content: @Composable () -> Unit) {
    val dark = isSystemInDarkTheme()
    val scheme = if (dark) darkColorScheme(primary = Color(0xFF5CC7B8), background = Color(0xFF0F1514), surface = Color(0xFF161E1C))
    else lightColorScheme(primary = Teal, background = Color(0xFFF7F8F6), surface = Color.White)
    MaterialTheme(colorScheme = scheme, content = content)
}

// ── local history (results only: no images, names or IDs), for trends ──
private object History {
    fun load(ctx: Context): List<Pair<String?, List<LabTest>>> {
        val raw = ctx.getSharedPreferences("plainly", 0).getString("reports", "[]") ?: "[]"
        val arr = JSONArray(raw)
        return (0 until arr.length()).map { i ->
            val o = arr.getJSONObject(i)
            val ts = o.getJSONArray("tests")
            o.optString("date").ifBlank { null } to (0 until ts.length()).map { j ->
                val t = ts.getJSONObject(j)
                LabTest(t.getString("name"), t.getDouble("value"), t.getString("unit"), parseRange(t.getString("range")))
            }
        }
    }
    fun save(ctx: Context, date: String?, tests: List<LabTest>) {
        val all = load(ctx).filter { it.first != date || date == null } + (date to tests)
        val arr = JSONArray(all.takeLast(12).map { (d, ts) ->
            JSONObject().put("date", d ?: "").put("tests", JSONArray(ts.map { JSONObject().put("name", it.name).put("value", it.value).put("unit", it.unit).put("range", it.range.text) }))
        })
        ctx.getSharedPreferences("plainly", 0).edit().putString("reports", arr.toString()).apply()
    }
    fun clear(ctx: Context) = ctx.getSharedPreferences("plainly", 0).edit().remove("reports").apply()
}

/** The earlier sample report (16 May 2026), so the sample photo shows trends. Same values as the web sample. */
private val SAMPLE_MAY = listOf(
    "Haemoglobin" to listOf(11.6, "g/dL", "12.0 - 15.0"), "Total Leucocyte Count" to listOf(7.1, "x10^3/uL", "4.0 - 10.0"),
    "Platelet Count" to listOf(262.0, "x10^3/uL", "150 - 410"), "MCV" to listOf(79.4, "fL", "83.0 - 101.0"),
    "Glucose, Fasting" to listOf(101.0, "mg/dL", "70 - 100"), "HbA1c (Glycated Haemoglobin)" to listOf(5.8, "%", "4.0 - 5.6"),
    "Cholesterol, Total" to listOf(214.0, "mg/dL", "< 200"), "LDL Cholesterol" to listOf(139.0, "mg/dL", "< 100"),
    "HDL Cholesterol" to listOf(45.0, "mg/dL", "> 50"), "Triglycerides" to listOf(151.0, "mg/dL", "< 150"),
    "TSH (Thyroid Stimulating Hormone)" to listOf(5.1, "uIU/mL", "0.40 - 4.00"), "Free T4" to listOf(1.01, "ng/dL", "0.80 - 1.80"),
    "Vitamin D, 25-Hydroxy" to listOf(17.6, "ng/mL", "30 - 100"), "Vitamin B12" to listOf(240.0, "pg/mL", "200 - 900"),
    "Creatinine" to listOf(0.81, "mg/dL", "0.50 - 1.10"), "ALT (SGPT)" to listOf(28.0, "U/L", "7 - 35"),
).map { (n, v) -> LabTest(n, v[0] as Double, v[1] as String, parseRange(v[2] as String)) }

data class Report(val tests: List<LabTest>, val meta: Meta, val readBy: String, val earlier: List<List<LabTest>>, val text: List<String> = emptyList())

@Composable
fun PlainlyScreen(rationale: Boolean = false) {
    val ctx = LocalContext.current
    val scope = rememberCoroutineScope()
    var allowCloud by remember { mutableStateOf(ctx.getSharedPreferences("plainly", 0).getBoolean("cloud", false)) }
    var nano by remember { mutableStateOf<OnDeviceModelStatus?>(null) }
    var progress by remember { mutableStateOf<Double?>(null) }
    var report by remember { mutableStateOf<Report?>(null) }
    var busy by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }
    val explained = remember { mutableStateMapOf<String, Ai.Explained?>() }
    var tab by remember { mutableStateOf(if (rationale) 1 else 0) } // 0 = lab report, 1 = vitals
    var vitalsLines by remember { mutableStateOf(listOf<String>()) }

    LaunchedEffect(Unit) { nano = Ai.nanoStatus() }

    fun read(bitmap: Bitmap) {
        scope.launch {
            error = null; explained.clear(); busy = "Reading your report on this phone…"
            try {
                val rows = Reader.ocrRows(bitmap)
                val meta = parseMeta(rows)
                var tests = parseRows(rows)
                var by = "on-device OCR + rules (no AI)"
                if (tests.size < 3 && nano == OnDeviceModelStatus.AVAILABLE) {
                    tests = Ai.readWithNano(rows.joinToString("\n")); by = "Gemini Nano on this phone"
                }
                if (tests.isEmpty()) throw IllegalStateException("No results were found. Try a clear, flat photo in good light.")
                val earlier = History.load(ctx).filter { it.first != meta.date }.map { it.second }
                History.save(ctx, meta.date, tests)
                android.util.Log.d("Plainly", "OCR rows:\n" + rows.joinToString("\n"))
                report = Report(tests, meta, by, earlier, rows)
            } catch (e: Exception) { error = e.message }
            busy = null
        }
    }

    val photoFile = remember { File(ctx.cacheDir, "report.jpg") }
    val photoUri = remember { FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", photoFile) }
    fun decode(uri: Uri): Bitmap = ImageDecoder.decodeBitmap(ImageDecoder.createSource(ctx.contentResolver, uri)) { d, _, _ ->
        d.allocator = ImageDecoder.ALLOCATOR_SOFTWARE
        d.isMutableRequired = false
    }
    val camera = rememberLauncherForActivityResult(ActivityResultContracts.TakePicture()) { ok -> if (ok) read(decode(photoUri)) }
    val picker = rememberLauncherForActivityResult(ActivityResultContracts.PickVisualMedia()) { uri -> uri?.let { read(decode(it)) } }

    Scaffold { pad ->
        LazyColumn(Modifier.padding(pad).padding(horizontal = 20.dp).fillMaxSize(), contentPadding = PaddingValues(bottom = 48.dp)) {
            item {
                Row(Modifier.fillMaxWidth().padding(top = 12.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("Plainly", fontFamily = FontFamily.Serif, fontSize = 26.sp, modifier = Modifier.weight(1f))
                    Text("Enhanced explanations", fontSize = 13.sp, color = MaterialTheme.colorScheme.onBackground.copy(alpha = .7f))
                    Spacer(Modifier.width(8.dp))
                    Switch(allowCloud, { allowCloud = it; ctx.getSharedPreferences("plainly", 0).edit().putBoolean("cloud", it).apply() })
                }
                val nanoText = when {
                    progress != null && progress!! < 1 -> "Private explanations: getting ready, ${((progress ?: 0.0) * 100).toInt()}%"
                    nano == OnDeviceModelStatus.AVAILABLE -> "Private explanations: ready"
                    nano == OnDeviceModelStatus.DOWNLOADABLE -> "Private explanations: not set up"
                    nano == OnDeviceModelStatus.DOWNLOADING -> "Private explanations: getting ready"
                    nano == null -> "Private explanations: checking"
                    else -> "Private explanations: not available on this phone"
                }
                Row(Modifier.padding(top = 6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text(nanoText, fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = if (nano == OnDeviceModelStatus.AVAILABLE) Teal else Color.Gray)
                    if (nano == OnDeviceModelStatus.DOWNLOADABLE) TextButton({
                        scope.launch {
                            try { Ai.downloadNano { progress = it }; nano = Ai.nanoStatus() } catch (e: Exception) { error = e.message }
                        }
                    }) { Text("Download") }
                }
                Text(if (allowCloud) "Your report stays on this phone. Enhanced explanations send only the numbers." else "Your report stays on this phone.",
                    fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = Color.Gray)
                HorizontalDivider(Modifier.padding(top = 12.dp))
                Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    FilterChip(tab == 0, { tab = 0 }, { Text("Lab report") })
                    FilterChip(tab == 1, { tab = 1 }, { Text("Vitals") })
                }
                error?.let { Text(it, color = High, modifier = Modifier.padding(top = 12.dp)) }
                busy?.let { Text(it, fontFamily = FontFamily.Serif, fontSize = 22.sp, modifier = Modifier.padding(top = 40.dp)) }
            }

            if (tab == 1) item {
                if (rationale) Card(Modifier.fillMaxWidth().padding(top = 16.dp)) {
                    Text("Plainly reads resting heart rate, heart rate variability, sleep, blood oxygen, heart rate and workouts from Health Connect to compare this week with your own usual. It works it all out on this phone and never uploads it. It writes to Health Connect only when you ask it to add its fictional sample, and can remove that sample again.",
                        fontSize = 14.sp, lineHeight = 20.sp, modifier = Modifier.padding(16.dp))
                }
                VitalsPanel(report?.meta?.age, vitalsLines.isNotEmpty()) { vitalsLines = it; tab = 0 }
            }

            val r = if (tab == 0) report else null
            if (tab == 0 && r == null && busy == null) item {
                Column(Modifier.padding(top = 48.dp)) {
                    Text("Your lab report,", fontFamily = FontFamily.Serif, fontSize = 40.sp, lineHeight = 44.sp)
                    Text("in plain words.", fontFamily = FontFamily.Serif, fontStyle = FontStyle.Italic, fontSize = 40.sp, lineHeight = 44.sp, color = MaterialTheme.colorScheme.primary)
                    Text("Take a photo of a blood test report. Plainly reads it on this phone, shows what's outside the range and what changed, and helps you prepare questions for your doctor.",
                        fontSize = 17.sp, lineHeight = 25.sp, modifier = Modifier.padding(top = 18.dp, bottom = 26.dp), color = MaterialTheme.colorScheme.onBackground.copy(alpha = .8f))
                    Button({ camera.launch(photoUri) }, Modifier.fillMaxWidth().height(52.dp)) { Text("Take a photo") }
                    Spacer(Modifier.height(10.dp))
                    OutlinedButton({ picker.launch(PickVisualMediaRequest(ActivityResultContracts.PickVisualMedia.ImageOnly)) }, Modifier.fillMaxWidth().height(52.dp)) { Text("Choose a photo") }
                    TextButton({
                        History.save(ctx, "16 May 2026", SAMPLE_MAY)
                        read(ctx.assets.open("sample-report.jpg").use { BitmapFactory.decodeStream(it) })
                    }, Modifier.align(Alignment.CenterHorizontally)) { Text("Try the sample report") }
                    Text("Read on your phone. Explains, never diagnoses.", fontSize = 13.sp, color = Color.Gray, modifier = Modifier.padding(top = 24.dp))
                    if (vitalsLines.isNotEmpty()) DoctorSheet("", emptyList(), vitalsLines, "Open a report to add your results and questions to this sheet.")
                }
            }

            if (r != null) {
                val rows = r.tests.map { t -> t to trendOf(t, r.earlier) }
                val outside = rows.filter { flagOf(it.first.value, it.first.range) in setOf(Flag.HIGH, Flag.LOW) }.sortedByDescending { distance(it.first.value, it.first.range) }
                val edge = rows.filter { nearEdge(it.first.value, it.first.range) }
                val normal = rows.filter { flagOf(it.first.value, it.first.range) == Flag.NORMAL && !nearEdge(it.first.value, it.first.range) }
                item {
                    Column(Modifier.padding(top = 26.dp)) {
                        Text(listOfNotNull(r.meta.date?.let { "Report from $it" }, r.meta.age?.let { "$it y" }, r.meta.sex).joinToString(", "), fontFamily = FontFamily.Monospace, fontSize = 12.sp, color = Color.Gray)
                        Text(if (outside.isEmpty()) "Everything is within range" else "${outside.size} results outside the range", fontFamily = FontFamily.Serif, fontSize = 30.sp, lineHeight = 34.sp, modifier = Modifier.padding(top = 4.dp))
                        Text("${outside.count { flagOf(it.first.value, it.first.range) == Flag.HIGH }} high, ${outside.count { flagOf(it.first.value, it.first.range) == Flag.LOW }} low, ${edge.size} near a limit, ${normal.size} in range", fontSize = 14.sp, modifier = Modifier.padding(top = 6.dp))
                        Text(if (r.earlier.isNotEmpty()) "Compared with your earlier report." else "", fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = Color.Gray, modifier = Modifier.padding(top = 6.dp))
                        Row(Modifier.padding(top = 16.dp)) {
                            Button({
                                scope.launch {
                                    for ((t, tr) in outside + edge) {
                                        val k = t.name
                                        if (explained[k] != null) continue
                                        explained[k] = null
                                        explained[k] = try { Ai.explain(t, r.meta, tr, allowCloud) } catch (e: Exception) {
                                            Ai.plain(t, tr).copy(note = if (allowCloud) "A full explanation isn't available right now, so a summary is shown." else "Private explanations aren't available on this phone. Turn on Enhanced explanations for a fuller explanation.")
                                        }
                                    }
                                }
                            }) { Text("Explain my results") }
                            Spacer(Modifier.width(8.dp))
                            OutlinedButton({ report = null; explained.clear() }) { Text("New") }
                        }
                        val done = explained.values.filterNotNull()
                        if (done.isNotEmpty()) Text("${done.count { it.source == Ai.Source.ON_DEVICE }} written privately, ${done.count { it.source == Ai.Source.IN_CLOUD }} with Enhanced explanations",
                            fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
                    }
                }
                items(outside + edge, key = { it.first.name }) { (t, tr) -> ResultCard(t, tr, explained[t.name], explained.containsKey(t.name)) }
                item {
                    var show by remember { mutableStateOf(false) }
                    TextButton({ show = !show }) { Text("${if (show) "Hide" else "Show"} the ${normal.size} results within range") }
                    if (show) Column { normal.forEach { (t, tr) -> ResultCard(t, tr, null, false) } }
                    // What the person noticed: kept on this phone, put on the doctor sheet; fixed rules flag emergencies.
                    var notes by remember { mutableStateOf("") }
                    Text("Anything you've noticed?", fontFamily = FontFamily.Serif, fontSize = 22.sp, modifier = Modifier.padding(top = 22.dp))
                    Text("Symptoms, how long, how often. They go on the sheet for your doctor and never leave this phone.", fontSize = 13.sp, color = Color.Gray)
                    OutlinedTextField(notes, { notes = it }, Modifier.fillMaxWidth().padding(top = 8.dp), minLines = 3,
                        placeholder = { Text("For example: tired for 3 weeks, cold hands") })
                    val flags = redFlags(notes)
                    if (flags.isNotEmpty()) Card(Modifier.fillMaxWidth().padding(top = 14.dp), colors = CardDefaults.cardColors(containerColor = High.copy(alpha = .12f))) {
                        Column(Modifier.padding(16.dp)) {
                            Text("Get care now", fontFamily = FontFamily.Serif, fontSize = 22.sp, color = High)
                            flags.forEach { Text("${it.label}. ${it.advice}", fontSize = 14.sp, modifier = Modifier.padding(top = 6.dp)) }
                            Text("Plainly can't assess symptoms. These are standard warning signs that need a doctor straight away, not a result from AI.", fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 6.dp))
                        }
                    }
                    val qs = (outside + edge).flatMap { (t, _) -> explained[t.name]?.questions?.map { t.name to it }.orEmpty() }
                    if (qs.isNotEmpty() || notes.isNotBlank() || vitalsLines.isNotEmpty()) DoctorSheet(notes, qs, vitalsLines, null)
                    Text("Plainly explains lab values and never diagnoses. Reference ranges are the ones printed on your report. Talk to your doctor before making any health decision.",
                        fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 20.dp))
                    // Transparency: exactly what was read from the photo, so anyone can check the reading.
                    var showText by remember { mutableStateOf(false) }
                    TextButton({ showText = !showText }) { Text(if (showText) "Hide the text Plainly read" else "See the text Plainly read") }
                    if (showText) {
                        val clip = androidx.compose.ui.platform.LocalClipboardManager.current
                        Text(r.text.joinToString("\n"), fontFamily = FontFamily.Monospace, fontSize = 11.sp, lineHeight = 15.sp,
                            modifier = Modifier.fillMaxWidth().background(MaterialTheme.colorScheme.onBackground.copy(alpha = .05f), RoundedCornerShape(8.dp)).padding(12.dp))
                        TextButton({ clip.setText(androidx.compose.ui.text.AnnotatedString(r.text.joinToString("\n"))) }) { Text("Copy") }
                    }
                    TextButton({ History.clear(ctx) }) { Text("Forget saved reports on this phone") }
                }
            }
        }
    }
}

@Composable
fun DoctorSheet(notes: String, qs: List<Pair<String, String>>, vitals: List<String>, hint: String?) {
    Card(Modifier.fillMaxWidth().padding(top = 20.dp)) {
        Column(Modifier.padding(18.dp)) {
            Text("For my doctor", fontFamily = FontFamily.Serif, fontSize = 22.sp)
            @Composable fun head(t: String) = Text(t, fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = Color.Gray, modifier = Modifier.padding(top = 10.dp))
            if (notes.isNotBlank()) { head("WHAT I'VE NOTICED"); Text(notes.trim(), fontSize = 14.sp) }
            if (qs.isNotEmpty()) { head("QUESTIONS ABOUT MY RESULTS"); qs.forEach { (n, q) -> Text("• $n: $q", fontSize = 14.sp, modifier = Modifier.padding(top = 4.dp)) } }
            if (vitals.isNotEmpty()) { head("FROM MY WATCH (LAST WEEK VS MY USUAL)"); vitals.forEach { Text("• $it", fontSize = 14.sp, modifier = Modifier.padding(top = 4.dp)) } }
            hint?.let { Text(it, fontSize = 12.sp, color = Color.Gray, modifier = Modifier.padding(top = 10.dp)) }
        }
    }
}

@Composable
fun ResultCard(t: LabTest, trend: Trend?, e: Ai.Explained?, requested: Boolean) {
    val f = flagOf(t.value, t.range)
    val edge = nearEdge(t.value, t.range)
    val color = when { f == Flag.HIGH -> High; f == Flag.LOW -> Low; edge -> Edge; else -> Color.Gray }
    Column(Modifier.fillMaxWidth().padding(vertical = 16.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(t.name, fontWeight = FontWeight.SemiBold, fontSize = 16.sp, modifier = Modifier.weight(1f))
            Text("${fmt(t.value)} ", fontFamily = FontFamily.Serif, fontSize = 20.sp)
            Text(t.unit, fontSize = 12.sp, color = Color.Gray)
            Spacer(Modifier.width(8.dp))
            Text(when { f == Flag.HIGH -> "HIGH"; f == Flag.LOW -> "LOW"; edge -> "NEAR LIMIT"; else -> "IN RANGE" },
                color = Color.White, fontSize = 10.sp, fontWeight = FontWeight.Bold,
                modifier = Modifier.background(color, RoundedCornerShape(50)).padding(horizontal = 8.dp, vertical = 3.dp))
        }
        RangeBar(t, trend, color)
        Text("Reference ${t.range.text}" + (trend?.let { ". Last time ${fmt(it.previous)} " + when (it.direction) { "up" -> "↑"; "down" -> "↓"; else -> "→" } } ?: "") +
            if (!t.verified) ". Check this value against your report." else "", fontSize = 13.sp, color = Color.Gray)
        if (requested && e == null) Text("Writing an explanation…", fontStyle = FontStyle.Italic, color = Color.Gray, modifier = Modifier.padding(top = 8.dp))
        e?.let {
            Text(it.text, fontSize = 15.sp, lineHeight = 22.sp, modifier = Modifier.padding(top = 8.dp))
            Text(when (it.source) { Ai.Source.ON_DEVICE -> "Written privately on this phone"; Ai.Source.IN_CLOUD -> "Written with Enhanced explanations"; Ai.Source.RULES -> "Summary" },
                fontFamily = FontFamily.Monospace, fontSize = 11.sp, color = when (it.source) { Ai.Source.ON_DEVICE -> Teal; Ai.Source.IN_CLOUD -> Cloud; else -> Color.Gray }, modifier = Modifier.padding(top = 4.dp))
            it.note?.let { n -> Text(n, fontSize = 12.sp, color = Edge) }
        }
        HorizontalDivider(Modifier.padding(top = 14.dp))
    }
}

@Composable
fun RangeBar(t: LabTest, trend: Trend?, color: Color) {
    val lo = t.range.low ?: if (t.range.high != null) 0.0 else t.value * 0.5
    val hi = t.range.high ?: (t.range.low?.times(2) ?: (t.value * 1.5))
    val span = (hi - lo).takeIf { it > 0 } ?: 1.0
    val min = lo - span * 0.5
    val max = hi + span * 0.5
    fun x(v: Double, w: Float) = (((v - min) / (max - min)).coerceIn(0.0, 1.0) * w).toFloat()
    val track = MaterialTheme.colorScheme.onBackground.copy(alpha = .12f)
    val band = Teal.copy(alpha = .25f)
    Canvas(Modifier.fillMaxWidth().height(22.dp).padding(vertical = 7.dp)) {
        val h = size.height
        drawRoundRect(track, size = Size(size.width, h), cornerRadius = CornerRadius(h / 2))
        drawRoundRect(band, topLeft = Offset(x(lo, size.width), 0f), size = Size(x(hi, size.width) - x(lo, size.width), h), cornerRadius = CornerRadius(h / 2))
        trend?.let { drawCircle(Color.Gray, radius = h * 0.7f, center = Offset(x(it.previous, size.width), h / 2), style = Stroke(width = 3f)) }
        drawCircle(color, radius = h * 0.9f, center = Offset(x(t.value, size.width), h / 2))
    }
}
