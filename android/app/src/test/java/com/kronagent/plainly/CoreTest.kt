package com.kronagent.plainly

import org.junit.Assert.*
import org.junit.Test

/** The same cases as the web app's test/core.test.ts, so both platforms follow identical rules. */
class CoreTest {
    @Test fun rangesAsLabsPrintThem() {
        assertEquals(Range(12.0, 15.0, "12.0 - 15.0"), parseRange("12.0 - 15.0"))
        assertEquals(100.0, parseRange("< 100").high)
        assertEquals(40.0, parseRange("Upto 40").high)
        assertEquals(50.0, parseRange(">= 50").low)
        assertNull(parseRange("See note").low)
    }
    @Test fun flagsAndNearEdge() {
        val r = parseRange("12.0 - 15.0")
        assertEquals(Flag.LOW, flagOf(10.9, r)); assertEquals(Flag.HIGH, flagOf(15.5, r)); assertEquals(Flag.NORMAL, flagOf(13.0, r))
        assertTrue(nearEdge(12.3, r)); assertFalse(nearEdge(13.5, r))
    }
    @Test fun readerHandlesOneTestPerLine() {
        val lines = listOf(
            "Patient: Rhea Sharma Age / Sex: 52 Y / Female Ref. by: Dr. A. Kulkarni",
            "Report ID: FD-88213 Collected: 18 Nov 2026, 08:12",
            "Haemoglobin 10.9 L g/dL 12.0 - 15.0",
            "HbA1c (Glycated Haemoglobin) 6.1 H % 4.0 - 5.6",
            "LDL Cholesterol 148 H mg/dL < 100",
            "HDL Cholesterol 42 L mg/dL > 50",
            "Free T4 0.92 ng/dL 0.80 - 1.80",
            "Vitamin B12 212 pg/mL 200 - 900",
        )
        val rows = parseRows(lines)
        assertEquals(listOf("Haemoglobin", "HbA1c (Glycated Haemoglobin)", "LDL Cholesterol", "HDL Cholesterol", "Free T4", "Vitamin B12"), rows.map { it.name })
        assertEquals(listOf(10.9, 6.1, 148.0, 42.0, 0.92, 212.0), rows.map { it.value })
        assertEquals(Meta(52, "female", "18 Nov 2026"), parseMeta(lines))
    }
    @Test fun valuesMustAppearInTheText() {
        val src = "Haemoglobin 10.9 g/dL 12.0 - 15.0   TSH 6.80 uIU/mL"
        val out = verifyAgainstText(listOf(
            LabTest("Haemoglobin", 10.9, "g/dL", parseRange("12.0 - 15.0")),
            LabTest("TSH", 6.8, "uIU/mL", parseRange("0.40 - 4.00"), raw = "6.80"),
            LabTest("Vitamin D", 41.0, "ng/mL", parseRange("30 - 100")),
        ), src)
        assertEquals(listOf(true, true, false), out.map { it.verified })
    }
    @Test fun guardExplainsNeverDiagnoses() {
        val allowed = listOf(6.1, 4.0, 5.6, 5.8)
        assertNull(checkExplanation("Your HbA1c is 6.1%, above the 5.6% upper limit and up from 5.8% last time. HbA1c reflects average blood sugar over about three months. Ask your doctor what this means for you.", allowed))
        assertNotNull(checkExplanation("You have diabetes. Ask your doctor.", allowed))
        assertNotNull(checkExplanation("Your HbA1c is 6.1%. Start metformin 500 mg daily and see your doctor.", allowed))
        assertNotNull(checkExplanation("Your HbA1c is 6.5%, above the limit. Ask your doctor.", allowed))
        assertNotNull(checkExplanation("Your HbA1c is 6.1%, a little above the 5.6% upper limit of the range.", allowed))
    }
    @Test fun deidentifiedKeepsOnlyTheFacts() {
        val j = org.json.JSONObject(deidentified(LabTest("TSH • Rhea Sharma", 6.8, "uIU/mL", parseRange("0.40 - 4.00")), Meta(52, "female", "18 Nov 2026"), null))
        assertEquals(setOf("test", "value", "unit", "range", "flag", "ageBand", "sex"), j.keys().asSequence().toSet())
        assertEquals("50s", j.getString("ageBand"))
        assertFalse(j.getString("test").contains("•"))
    }
}

class PhotoTest {
    /** Real OCR output (Apple Vision, same line-and-corners shape as ML Kit) for the tilted sample photo. */
    private fun fixture(): List<OcrLine> {
        val text = javaClass.classLoader!!.getResource("sample-photo-ocr.json")!!.readText()
        val lines = org.json.JSONObject(text).getJSONArray("lines")
        return (0 until lines.length()).map { i ->
            val o = lines.getJSONObject(i)
            val c = o.getJSONArray("corners")
            OcrLine(o.getString("text"), (0 until 4).map { j -> c.getJSONArray(j).getDouble(0) to c.getJSONArray(j).getDouble(1) })
        }
    }

    @Test fun tiltedSamplePhotoReadsAllSixteenTests() {
        val rows = rowsFromLines(fixture())
        val tests = parseRows(rows)
        val got = tests.associate { it.name to it.value }
        assertEquals(rows.joinToString("\n"), 16, tests.size)
        assertEquals(10.9, got["Haemoglobin"]); assertEquals(6.1, got["HbA1c (Glycated Haemoglobin)"]); assertEquals(6.8, got["TSH (Thyroid Stimulating Hormone)"])
        assertEquals(0.92, got["Free T4"]); assertEquals(14.2, got["Vitamin D, 25-Hydroxy"]); assertEquals(28.0, got["ALT (SGPT)"])
        assertEquals(10, tests.count { flagOf(it.value, it.range) == Flag.HIGH || flagOf(it.value, it.range) == Flag.LOW })
        assertEquals(Meta(52, "female", "18 Nov 2026"), parseMeta(rows))
    }
}

class PhoneOcrTest {
    /** What ML Kit on a Redmi Note 11T 5G actually produced for the sample photo, pasted from the app. */
    @Test fun redmiOcrOfTheSamplePhoto() {
        val lines = javaClass.classLoader!!.getResource("redmi-mlkit-rows.txt")!!.readText().lines()
        val rows = parseRows(lines)
        val by = rows.associateBy { it.name }
        assertEquals(rows.joinToString("\n") { "${it.name} ${it.value} ${it.unit} ${it.range.text}" }, 15, rows.size) // Free T4's value was lost by the OCR
        assertEquals(10, rows.count { flagOf(it.value, it.range) == Flag.HIGH || flagOf(it.value, it.range) == Flag.LOW })
        assertEquals(200.0, by["Cholesterol, Total"]!!.range.high)
        assertEquals(100.0, by["LDL Cholesterol"]!!.range.high)
        assertEquals(6.8, by["TSH (Thyroid Stimulating Hormone)"]!!.value, 1e-9)
        assertEquals(listOf("g/dL", "mg/dL", "ng/mL", "mg/dL", "U/L", "x10^3/uL", "uIU/mL"),
            listOf("Haemoglobin", "Glucose, Fasting", "Vitamin D, 25-Hydroxy", "Creatinine", "ALT (SGPT)", "Total Leucocyte Count", "TSH (Thyroid Stimulating Hormone)").map { by[it]!!.unit })
        assertEquals(Meta(52, "female", "18 Nov 2026"), parseMeta(lines))
    }
}

class SymptomsTest {
    private fun ids(t: String) = redFlags(t).map { it.id }
    @Test fun redFlagsMatchTheWebRules() {
        assertEquals(emptyList<String>(), ids("tired for 3 weeks, cold hands"))
        assertEquals(emptyList<String>(), ids("mild headache in the evenings"))
        assertEquals(listOf("chest"), ids("tightness in my chest when climbing stairs"))
        assertEquals(listOf("breath"), ids("I get short of breath lying down"))
        assertEquals(listOf("stroke"), ids("her face is drooping and speech is slurred"))
        assertEquals(listOf("faint"), ids("I fainted at work yesterday"))
        assertEquals(listOf("bleed"), ids("vomited blood this morning"))
        assertEquals(listOf("selfharm"), ids("sometimes I don't want to live"))
        assertTrue(redFlags("sometimes I don't want to live")[0].advice.contains("14416"))
    }

    /** What ML Kit produced on the Android 16 emulator: "< 100" came out as ":100". */
    @Test fun emulatorOcrOfTheSamplePhoto() {
        val rows = parseRows(javaClass.classLoader!!.getResource("emulator-mlkit-rows.txt")!!.readText().lines())
        val by = rows.associateBy { it.name }
        assertEquals(100.0, by["LDL Cholesterol"]!!.range.high)
        assertEquals(10, rows.count { flagOf(it.value, it.range) == Flag.HIGH || flagOf(it.value, it.range) == Flag.LOW })
    }

    /** iOS-simulator text recognition read Platelets 248 as 148; the lab printed no L, so it's held back. */
    @Test fun misreadValueDisagreeingWithTheLabIsHeldBack() {
        val rows = parseRows(javaClass.classLoader!!.getResource("ios-sim-vision-rows.txt")!!.readText().lines())
        val p = rows.first { it.name == "Platelet Count" }
        assertEquals(148.0, p.value, 1e-9); assertFalse(p.verified)
        assertEquals(10, rows.count { it.verified && (flagOf(it.value, it.range) == Flag.HIGH || flagOf(it.value, it.range) == Flag.LOW) })
    }
}
