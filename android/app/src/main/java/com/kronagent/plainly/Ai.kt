package com.kronagent.plainly

import com.google.firebase.Firebase
import com.google.firebase.ai.GenerativeModel
import com.google.firebase.ai.InferenceMode
import com.google.firebase.ai.InferenceSource
import com.google.firebase.ai.OnDeviceConfig
import com.google.firebase.ai.ai
import com.google.firebase.ai.ondevice.DownloadStatus
import com.google.firebase.ai.ondevice.FirebaseAIOnDevice
import com.google.firebase.ai.ondevice.OnDeviceModelStatus
import com.google.firebase.ai.type.GenerativeBackend
import com.google.firebase.ai.type.PublicPreviewAPI
import com.google.firebase.ai.type.content
import com.google.firebase.ai.type.generationConfig
import org.json.JSONObject

/**
 * Same two privacy rules as the web app:
 *  - READING a report is on-device only: OCR (ML Kit) + rules, and Gemini Nano in ONLY_ON_DEVICE mode for
 *    layouts the rules miss. The photo and its text never leave the phone.
 *  - EXPLAINING a value sends the same de-identified facts on-device or to the cloud (only if allowed).
 */
@OptIn(PublicPreviewAPI::class)
object Ai {
    private const val CLOUD_MODEL = "gemini-3.5-flash-lite"

    private const val READ_PROMPT =
        "You read the text of a medical laboratory report (from OCR) and copy its results exactly. " +
            "Return only JSON: {\"tests\":[{\"name\":..., \"value\":..., \"unit\":..., \"range\":...}]}. " +
            "Copy each value exactly as printed. Never guess a missing value. Do not copy names, IDs, phone numbers, the doctor or the lab.\n\nReport text:\n"

    private const val EXPLAIN =
        "You help a person understand one result on their own lab report, in plain, calm English for someone without medical training. " +
            "Use only the facts given. Say what the test measures in one sentence, where the value sits against the printed reference interval, " +
            "and, if an earlier value is given, which way it moved. Do not diagnose, do not name a disease the person has, do not suggest medicines or doses. " +
            "Only use numbers that appear in the facts. End by suggesting they discuss it with their doctor. " +
            "Return only JSON: {\"explanation\": \"...\", \"questions\": [\"...\", \"...\"]} with two short questions they could ask their doctor."

    private val backend = GenerativeBackend.agentPlatform("global")

    private val reader: GenerativeModel by lazy {
        // No cloud fallback for reading: the report is the most private thing in the app.
        Firebase.ai(backend = backend).generativeModel(
            modelName = CLOUD_MODEL,
            onDeviceConfig = OnDeviceConfig(mode = InferenceMode.ONLY_ON_DEVICE, maxOutputTokens = 1500, temperature = 0f),
        )
    }

    private fun explainer(allowCloud: Boolean): GenerativeModel = Firebase.ai(backend = backend).generativeModel(
        modelName = CLOUD_MODEL,
        generationConfig = generationConfig { temperature = 0.2f; maxOutputTokens = 400; responseMimeType = "application/json" },
        systemInstruction = content { text(EXPLAIN) },
        onDeviceConfig = OnDeviceConfig(
            mode = if (allowCloud) InferenceMode.PREFER_ON_DEVICE else InferenceMode.ONLY_ON_DEVICE,
            maxOutputTokens = 400,
            temperature = 0.2f,
        ),
    )

    suspend fun nanoStatus(): OnDeviceModelStatus = runCatching { FirebaseAIOnDevice.checkStatus() }.getOrDefault(OnDeviceModelStatus.UNAVAILABLE)

    /** Downloads Gemini Nano (AICore manages it), reporting progress as a fraction when the size is known. */
    suspend fun downloadNano(onProgress: (Double?) -> Unit) {
        var total = 0L
        FirebaseAIOnDevice.download().collect { s ->
            when (s) {
                is DownloadStatus.DownloadStarted -> { total = s.bytesToDownload; onProgress(0.0) }
                is DownloadStatus.DownloadInProgress -> onProgress(if (total > 0) s.totalBytesDownloaded.toDouble() / total else null)
                is DownloadStatus.DownloadCompleted -> onProgress(1.0)
                is DownloadStatus.DownloadFailed -> throw IllegalStateException("Gemini Nano download failed")
            }
        }
    }

    private fun json(raw: String?): JSONObject? = raw?.let {
        val a = it.indexOf('{'); val b = it.lastIndexOf('}')
        if (a < 0 || b <= a) null else runCatching { JSONObject(it.substring(a, b + 1)) }.getOrNull()
    }

    /** Gemini Nano structures OCR text the rules couldn't; every value is then checked against that text. */
    suspend fun readWithNano(ocrText: String): List<LabTest> {
        val res = reader.generateContent(READ_PROMPT + ocrText.take(6000))
        val arr = json(res.text)?.optJSONArray("tests") ?: return emptyList()
        val out = (0 until arr.length()).mapNotNull { i ->
            val o = arr.optJSONObject(i) ?: return@mapNotNull null
            val raw = o.optString("value")
            val v = raw.replace(Regex("[^\\d.\\-]"), "").toDoubleOrNull() ?: return@mapNotNull null
            LabTest(o.optString("name").trim(), v, o.optString("unit").trim(), parseRange(o.optString("range")), raw, false)
        }.filter { it.name.isNotBlank() }
        return verifyAgainstText(out, ocrText)
    }

    enum class Source { ON_DEVICE, IN_CLOUD, RULES }
    data class Explained(val text: String, val questions: List<String>, val source: Source, val note: String? = null)

    fun plain(t: LabTest, trend: Trend?): Explained {
        val where = when (flagOf(t.value, t.range)) { Flag.HIGH -> "above"; Flag.LOW -> "below"; Flag.NORMAL -> "within"; Flag.UNKNOWN -> "compared with" }
        val moved = trend?.let {
            if (it.direction == "same") " It is about the same as last time (${fmt(it.previous)} ${t.unit})."
            else " It has gone ${it.direction} from ${fmt(it.previous)} ${t.unit} last time."
        } ?: ""
        return Explained(
            "Your ${t.name} is ${fmt(t.value)} ${t.unit}, $where the printed reference interval (${t.range.text}).$moved Ask your doctor what this means for you.",
            listOf("What could be behind my ${t.name} result?", "Should I repeat this test, and when?"),
            Source.RULES,
        )
    }

    suspend fun explain(t: LabTest, meta: Meta, trend: Trend?, allowCloud: Boolean): Explained {
        val allowed = listOfNotNull(t.value, t.range.low, t.range.high, trend?.previous, trend?.let { kotlin.math.abs(it.change) }, meta.age?.toDouble())
        val res = explainer(allowCloud).generateContent("$EXPLAIN\n\nFacts: ${deidentified(t, meta, trend)}")
        val source = if (res.inferenceSource == InferenceSource.ON_DEVICE) Source.ON_DEVICE else Source.IN_CLOUD
        val o = json(res.text)
        val text = o?.optString("explanation").orEmpty().replace(Regex("\\s+"), " ").trim()
        checkExplanation(text, allowed)?.let { reason -> return plain(t, trend).copy(source = source, note = "$reason A plain summary is shown instead.") }
        val qs = o?.optJSONArray("questions")?.let { a -> (0 until a.length()).map { a.optString(it).trim() } }.orEmpty()
            .filter { it.isNotBlank() && checkExplanation("$it Ask your doctor.", allowed) == null }.take(2)
        return Explained(text, qs.ifEmpty { plain(t, trend).questions }, source)
    }
}
