package com.kronagent.plainly

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Same expectations as the web app's tests and screen, so Android and web agree to the digit. */
class VitalsTest {
    @Test fun sampleWeekIsOffUsual() {
        val r = analyse(sampleDays())
        assertEquals(35, r.days); assertEquals(28, r.baselineDays); assertEquals(7, r.recentDays)
        assertEquals(20, r.recovery)
        val dir = r.changes.associate { it.metric to it.direction }
        assertEquals(Direction.WORSE, dir[Metric.RESTING_HR]); assertEquals(Direction.WORSE, dir[Metric.HRV])
        assertEquals(Direction.WORSE, dir[Metric.SLEEP]); assertEquals(Direction.STEADY, dir[Metric.SPO2])
        val text = r.changes.map { it.text }
        assertTrue(text.toString(), "Resting heart rate is 7 bpm higher than your usual (70 bpm this week vs 63 bpm)." in text)
        assertTrue(text.toString(), "Heart rate variability is 8 ms lower than your usual (36 ms this week vs 44 ms)." in text)
        assertTrue(text.toString(), "Sleep is 53 min shorter than your usual (6 h 4 min this week vs 6 h 57 min)." in text)
        assertTrue(text.toString(), "Blood oxygen (overnight) is in your usual range (96.2 % this week, 96.1 % usually)." in text)
        assertTrue(r.alerts.isEmpty())
    }

    @Test fun safetyRulesFire() {
        val base = sampleDays()
        val bad = base.dropLast(3) + base.takeLast(3).map { it.copy(restingHr = 104.0, spo2 = 88.0) }
        val ids = analyse(bad).alerts.map { it.id }
        assertTrue(ids.toString(), "hr-high" in ids); assertTrue("spo2-low" in ids)
        assertTrue(analyse(bad).alerts.first { it.id == "spo2-low" }.urgent)
    }

    @Test fun tooLittleDataSaysNothing() {
        val r = analyse(sampleDays().takeLast(5))
        assertTrue(r.changes.isEmpty()); assertNull(r.recovery)
    }

    @Test fun workoutSummaryMatchesWeb() {
        val w = analyseWorkout(sampleWorkout(), 52)
        assertEquals(36, w.durationMin); assertEquals(168, w.maxEstimate)
        assertEquals(123, w.avg); assertEquals(147, w.peak.bpm); assertEquals("27:30", clock(w.peak.t))
        assertEquals(21, w.recovery1min)
        assertEquals(listOf(139, 141, 143, 146), w.highs.map { it.bpm })
        assertEquals(listOf("8:55", "15:25", "20:30", "27:35"), w.highs.map { clock(it.t) })
        assertEquals(listOf(115, 115, 115), w.lows.map { it.bpm })
        assertEquals(listOf(2.3, 11.4, 11.6, 10.4, 0.0), w.zoneMin.map { it.minutes })
        assertEquals("You spent 10 min hard or harder, and 23 min steady to moderate.", w.notes[0])
    }
}
