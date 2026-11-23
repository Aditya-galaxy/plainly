package com.kronagent.plainly

import android.content.Context
import androidx.health.connect.client.HealthConnectClient
import androidx.health.connect.client.HealthConnectFeatures
import androidx.health.connect.client.permission.HealthPermission
import androidx.health.connect.client.records.ExerciseSessionRecord
import androidx.health.connect.client.records.HeartRateRecord
import androidx.health.connect.client.records.HeartRateVariabilityRmssdRecord
import androidx.health.connect.client.records.OxygenSaturationRecord
import androidx.health.connect.client.records.Record
import androidx.health.connect.client.records.RestingHeartRateRecord
import androidx.health.connect.client.records.SleepSessionRecord
import androidx.health.connect.client.records.metadata.Metadata
import androidx.health.connect.client.request.ReadRecordsRequest
import androidx.health.connect.client.time.TimeRangeFilter
import androidx.health.connect.client.units.Percentage
import java.time.Duration
import java.time.Instant
import java.time.LocalDate
import java.time.LocalTime
import java.time.ZoneId
import java.time.ZonedDateTime
import kotlin.reflect.KClass

/**
 * Health Connect: the on-phone store that Fitbit, Galaxy Watch, Pixel Watch, Garmin, Zepp, Oura and others sync to.
 * Plainly reads it on the phone and works out everything locally; nothing is uploaded.
 *
 * For people without a watch (and for judges), "Put sample data in Health Connect" writes the same fictional 35 days and
 * workout as the web sample, tagged with a "plainly-sample-" record id, then reads them back through the real API.
 */
object Health {
    private val types: List<KClass<out Record>> = listOf(
        RestingHeartRateRecord::class, HeartRateVariabilityRmssdRecord::class, SleepSessionRecord::class,
        OxygenSaturationRecord::class, HeartRateRecord::class, ExerciseSessionRecord::class,
    )
    val readPermissions = types.map { HealthPermission.getReadPermission(it) }.toSet()
    val writePermissions = types.map { HealthPermission.getWritePermission(it) }.toSet()

    enum class Status { READY, NEEDS_UPDATE, NOT_INSTALLED }

    fun status(ctx: Context): Status = when (HealthConnectClient.getSdkStatus(ctx)) {
        HealthConnectClient.SDK_AVAILABLE -> Status.READY
        HealthConnectClient.SDK_UNAVAILABLE_PROVIDER_UPDATE_REQUIRED -> Status.NEEDS_UPDATE
        else -> Status.NOT_INSTALLED
    }

    private fun client(ctx: Context) = HealthConnectClient.getOrCreate(ctx)

    /** Read and write, plus reading history older than 30 days where the phone's Health Connect supports it. */
    fun allPermissions(ctx: Context): Set<String> {
        val history = try {
            client(ctx).features.getFeatureStatus(HealthConnectFeatures.FEATURE_READ_HEALTH_DATA_HISTORY) == HealthConnectFeatures.FEATURE_STATUS_AVAILABLE
        } catch (_: Throwable) { false }
        return readPermissions + writePermissions + if (history) setOf(HealthPermission.PERMISSION_READ_HEALTH_DATA_HISTORY) else emptySet()
    }

    suspend fun granted(ctx: Context): Set<String> = client(ctx).permissionController.getGrantedPermissions()

    private suspend fun <T : Record> readAll(ctx: Context, type: KClass<T>, from: Instant, to: Instant): List<T> {
        val out = mutableListOf<T>()
        var token: String? = null
        do {
            val res = client(ctx).readRecords(ReadRecordsRequest(type, TimeRangeFilter.between(from, to), pageToken = token))
            out += res.records
            token = res.pageToken
        } while (token != null)
        return out
    }

    data class Loaded(val days: List<Day>, val workout: Session?, val sources: Set<String>, val sampleOnly: Boolean)

    /** The last 35 days, one value per day (averages; sleep is the total of sessions ending that day), and the latest workout. */
    suspend fun load(ctx: Context, zone: ZoneId = ZoneId.systemDefault()): Loaded {
        val to = Instant.now()
        val from = to.minus(Duration.ofDays(35))
        val sources = mutableSetOf<String>()
        val ids = mutableListOf<String?>()
        fun note(r: Record) { sources += r.metadata.dataOrigin.packageName; ids += r.metadata.clientRecordId }
        fun day(i: Instant) = i.atZone(zone).toLocalDate().toString()

        val rhr = readAll(ctx, RestingHeartRateRecord::class, from, to).onEach(::note).groupBy({ day(it.time) }, { it.beatsPerMinute.toDouble() })
        val hrv = readAll(ctx, HeartRateVariabilityRmssdRecord::class, from, to).onEach(::note).groupBy({ day(it.time) }, { it.heartRateVariabilityMillis })
        val ox = readAll(ctx, OxygenSaturationRecord::class, from, to).onEach(::note).groupBy({ day(it.time) }, { it.percentage.value })
        val sleep = readAll(ctx, SleepSessionRecord::class, from, to).onEach(::note)
            .groupBy({ day(it.endTime) }, { Duration.between(it.startTime, it.endTime).toMinutes().toDouble() })
        val dates = (rhr.keys + hrv.keys + ox.keys + sleep.keys).sorted()
        val days = dates.map { d ->
            Day(d, rhr[d]?.average()?.let { jsRound(it) }, hrv[d]?.average()?.let { jsRound(it) }, sleep[d]?.sum(), ox[d]?.average()?.let { round(it, 1) })
        }

        val ex = readAll(ctx, ExerciseSessionRecord::class, from, to).onEach(::note).maxByOrNull { it.startTime }
        val workout = ex?.let { s ->
            val hr = readAll(ctx, HeartRateRecord::class, s.startTime, s.endTime.plus(Duration.ofMinutes(4)))
            val samples = hr.flatMap { it.samples }.filter { !it.time.isBefore(s.startTime) }.sortedBy { it.time }
                .map { Sample(Duration.between(s.startTime, it.time).seconds.toInt(), it.beatsPerMinute.toInt()) }
                .distinctBy { it.t }
            if (samples.size < 20) null
            else Session(s.title ?: "Workout", s.startTime.atZone(zone).toOffsetDateTime().toString(), samples, Duration.between(s.startTime, s.endTime).seconds.toInt())
        }
        sources.remove(ctx.packageName)
        return Loaded(days, workout, sources, sampleOnly = ids.isNotEmpty() && ids.all { it?.startsWith("plainly-sample-") == true })
    }

    private fun meta(id: String) = Metadata.manualEntry(clientRecordId = "plainly-sample-$id", clientRecordVersion = 1)

    /** Writes the fictional sample, ending today. Record ids make this idempotent: writing twice updates, never duplicates. */
    suspend fun writeSample(ctx: Context, zone: ZoneId = ZoneId.systemDefault()) {
        val today = LocalDate.now(zone)
        val records = mutableListOf<Record>()
        for (d in sampleDays(today)) {
            val date = LocalDate.parse(d.date)
            fun at(h: Int, m: Int): ZonedDateTime = ZonedDateTime.of(date, LocalTime.of(h, m), zone)
            val wake = at(6, 30)
            val off = wake.offset
            if (wake.toInstant().isAfter(Instant.now())) continue // nothing in the future
            records += RestingHeartRateRecord(at(7, 0).toInstant().coerceAtMost(Instant.now()), off, d.restingHr!!.toLong(), meta("rhr-${d.date}"))
            records += HeartRateVariabilityRmssdRecord(wake.minusMinutes(30).toInstant(), off, d.hrv!!, meta("hrv-${d.date}"))
            records += OxygenSaturationRecord(wake.minusMinutes(60).toInstant(), off, Percentage(d.spo2!!), meta("spo2-${d.date}"))
            records += SleepSessionRecord(wake.minusMinutes(d.sleepMin!!.toLong()).toInstant(), off, wake.toInstant(), off, meta("sleep-${d.date}"), title = "Sleep (Plainly sample)")
        }
        // The workout: two days ago at 6:30, with three minutes of recovery recorded after stopping.
        val w = sampleWorkout()
        val start = ZonedDateTime.of(today.minusDays(2), LocalTime.of(6, 30), zone)
        val s0 = start.toInstant()
        records += ExerciseSessionRecord(s0, start.offset, s0.plusSeconds(w.endT.toLong()), start.offset, meta("workout"),
            ExerciseSessionRecord.EXERCISE_TYPE_RUNNING, title = w.name)
        records += HeartRateRecord(s0, start.offset, s0.plusSeconds(w.samples.last().t + 1L), start.offset,
            w.samples.map { HeartRateRecord.Sample(s0.plusSeconds(it.t.toLong()), it.bpm.toLong()) }, meta("workout-hr"))
        records.chunked(500).forEach { client(ctx).insertRecords(it) }
    }

    /** Removes only what Plainly wrote (its own sample), never anything from a watch. */
    suspend fun deleteSample(ctx: Context) {
        val c = client(ctx)
        val far = TimeRangeFilter.between(Instant.now().minus(Duration.ofDays(60)), Instant.now().plus(Duration.ofDays(1)))
        for (t in types) {
            val mine = readAll(ctx, t, far.startTime!!, far.endTime!!).filter { it.metadata.clientRecordId?.startsWith("plainly-sample-") == true }
            if (mine.isNotEmpty()) c.deleteRecords(t, mine.map { it.metadata.id }, emptyList())
        }
    }
}

private fun Instant.coerceAtMost(o: Instant) = if (isAfter(o)) o else this
