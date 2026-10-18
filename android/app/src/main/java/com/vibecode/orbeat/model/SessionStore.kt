package com.vibecode.orbeat.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.vibecode.orbeat.core.SessionClock
import com.vibecode.orbeat.core.now
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.UUID

/**
 * One recorded session of anything — ride, run, gym set. Sampled once a
 * second from what the model shows; unconnected metrics stay null.
 */
data class Session(
    val id: String = UUID.randomUUID().toString(),
    val start: Double,
    val end: Double? = null,
    val samples: List<Sample> = emptyList(),
) {
    data class Sample(val t: Double, val bpm: Int?, val watts: Int?, val rpm: Int?, val kmh: Double?)

    /** Recorded (moving) time: pauses don't count. */
    val duration: Double get() = samples.lastOrNull()?.t ?: 0.0
    val bpms: List<Int> get() = samples.mapNotNull { it.bpm }
    val wattsAll: List<Int> get() = samples.mapNotNull { it.watts }
    val avgBPM: Int? get() = bpms.takeIf { it.isNotEmpty() }?.let { it.sum() / it.size }
    val maxBPM: Int? get() = bpms.maxOrNull()
    val avgWatts: Int? get() = wattsAll.takeIf { it.isNotEmpty() }?.let { it.sum() / it.size }
    val maxWatts: Int? get() = wattsAll.maxOrNull()
    val distanceKm: Double get() = samples.mapNotNull { it.kmh }.sumOf { it / 3600 }
    /** Seconds per zone, in display order. */
    val zoneSeconds: List<Pair<String, Int>> get() {
        val counts = bpms.groupingBy { RideModel.zoneName(it) }.eachCount()
        return ZONES.map { it to (counts[it] ?: 0) }
    }

    companion object {
        val ZONES = listOf("Resting", "Fat Burn", "Cardio", "Peak")
    }
}

/**
 * Start/stop a session and keep the finished ones, as one JSON file in the
 * app's private storage. The Apple build syncs via iCloud; Android stays local.
 * ponytail: rewrites the whole file per save; fine to a few hundred sessions.
 */
class SessionStore(private val file: File) {
    var active by mutableStateOf<Session?>(null); private set
    var past by mutableStateOf(load()); private set
    var elapsed by mutableDoubleStateOf(0.0); private set
    var clock by mutableStateOf<SessionClock?>(null); private set

    fun start() { active = Session(start = now()); elapsed = 0.0; clock = SessionClock.Running(now()) }

    /** Reopen a saved session: new samples continue its clock. */
    fun resume(s: Session) {
        active = s.copy(end = null)
        elapsed = s.duration
        clock = SessionClock.Paused(s.duration).resuming()
    }

    fun setPaused(paused: Boolean) {
        val c = clock ?: return
        if (c.isPaused == paused) return
        clock = if (paused) c.pausing() else c.resuming()
        elapsed = clock!!.elapsed()
    }

    fun stop() {
        val s = active?.copy(end = now()) ?: return
        active = null
        clock = null
        if (s.samples.isEmpty()) return   // accidental tap, no sensors: nothing to keep
        // A resumed session replaces its record.
        past = (listOf(s) + past.filter { it.id != s.id }).sortedByDescending { it.start }
        save()
    }

    fun delete(s: Session) {
        past = past.filter { it.id != s.id }
        save()
    }

    /** Call on every reading and once a second; samples at most 1 Hz, fresh readings only. */
    fun tick(m: RideModel) {
        val a = active ?: return
        val c = clock as? SessionClock.Running ?: return
        elapsed = c.elapsed()
        val last = a.samples.lastOrNull()
        if (last != null && elapsed - last.t < 0.95) return
        val live = m.hasData && m.isFresh
        val s = Session.Sample(elapsed, if (live) m.bpm else null, m.displayWatts, m.displayCadence, m.displaySpeedKmh)
        if (s.bpm != null || s.watts != null) active = a.copy(samples = a.samples + s)
    }

    private fun save() {
        val tmp = File(file.path + ".tmp")
        tmp.writeText(JSONArray(past.map(::encode)).toString())
        tmp.renameTo(file)   // atomic: a crash mid-write never loses history
    }

    private fun load(): List<Session> = runCatching {
        val a = JSONArray(file.readText())
        List(a.length()) { decode(a.getJSONObject(it)) }.sortedByDescending { it.start }
    }.getOrDefault(emptyList())

    companion object {
        fun encode(s: Session): JSONObject = JSONObject().put("id", s.id).put("start", s.start).put("end", s.end)
            .put("samples", JSONArray(s.samples.map {
                JSONObject().put("t", it.t).put("bpm", it.bpm).put("watts", it.watts).put("rpm", it.rpm).put("kmh", it.kmh)
            }))

        fun decode(o: JSONObject): Session {
            fun JSONObject.int(k: String) = if (isNull(k)) null else getInt(k)
            fun JSONObject.dbl(k: String) = if (isNull(k)) null else getDouble(k)
            val a = o.getJSONArray("samples")
            return Session(o.getString("id"), o.getDouble("start"), o.dbl("end"), List(a.length()) {
                val s = a.getJSONObject(it)
                Session.Sample(s.getDouble("t"), s.int("bpm"), s.int("watts"), s.int("rpm"), s.dbl("kmh"))
            })
        }
    }
}
