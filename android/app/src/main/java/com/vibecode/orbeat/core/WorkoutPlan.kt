package com.vibecode.orbeat.core

import org.json.JSONArray
import org.json.JSONObject
import java.util.Locale
import kotlin.math.max
import kotlin.math.pow
import kotlin.math.roundToInt

/**
 * The workout builder's editable shape: blocks with power as a fraction of
 * FTP, so a plan survives FTP changes. Expanded to `Workout` steps to ride,
 * written as Zwift .zwo to share.
 */
data class WorkoutPlan(val name: String, val blocks: List<Block>, /** Rides at this FTP instead of the rider's; null = the rider's. */ val ftp: Int? = null) {
    enum class Kind { Steady, Ramp, Intervals }

    /** One shape for all kinds; fields a kind doesn't use are ignored. */
    data class Block(
        val kind: Kind,
        val seconds: Int = 300,        // steady, ramp
        val power: Double = 0.75,      // steady; ramp start
        val powerEnd: Double = 0.75,   // ramp end
        val repeats: Int = 3,          // intervals
        val on: Int = 60, val onPower: Double = 1.2,
        val off: Int = 60, val offPower: Double = 0.5,
    ) {
        val length: Int get() = if (kind == Kind.Intervals) repeats * (on + off) else seconds

        /** (seconds, from, to) as FTP fractions. */
        val steps: List<Triple<Int, Double, Double>> get() = when (kind) {
            Kind.Steady -> listOf(Triple(seconds, power, power))
            Kind.Ramp -> listOf(Triple(seconds, power, powerEnd))
            Kind.Intervals -> List(repeats) { listOf(Triple(on, onPower, onPower), Triple(off, offPower, offPower)) }.flatten()
        }

        /** Same block as another kind, keeping its effort (and its time, except as intervals). */
        fun asKind(k: Kind): Block {
            val top = if (kind == Kind.Intervals) onPower else max(power, powerEnd)
            return when (k) {
                Kind.Steady -> Block(k, seconds = length, power = top)
                Kind.Ramp -> Block(k, seconds = length, power = max(0.25, top - 0.25), powerEnd = top)
                Kind.Intervals -> max(60, length / 6 / 60 * 60).let { Block(k, on = it, off = it, onPower = max(top, 0.9), offPower = 0.55) }
            }
        }
    }

    val length: Int get() = blocks.sumOf { it.length }

    fun workout(ftp: Int): Workout {
        fun w(f: Double) = (f * ftp).roundToInt()
        return Workout(name, blocks.flatMap { it.steps }.map { Workout.Step(it.first.toDouble(), w(it.second), w(it.third)) })
    }

    /** Mean power as an FTP fraction (ramps at their midpoint). */
    val intensity: Double get() {
        val st = blocks.flatMap { it.steps }
        val t = st.sumOf { it.first }
        return if (t == 0) 0.0 else st.sumOf { it.first * (it.second + it.third) / 2 } / t
    }

    /** Normalised power as an FTP fraction: 30 s rolling mean, fourth-power average. */
    val intensityFactor: Double get() {
        val p = blocks.flatMap { it.steps }.flatMap { (s, a, e) -> List(s) { a + (e - a) * (it + 0.5) / s } }
        if (p.size < 30) return intensity
        var sum = p.subList(0, 30).sum()
        var acc = 0.0
        for (i in 30..p.size) {
            acc += (sum / 30).pow(4)
            if (i < p.size) sum += p[i] - p[i - 30]
        }
        return (acc / (p.size - 29)).pow(0.25)
    }

    val tss: Int get() = (length / 3600.0 * intensityFactor * intensityFactor * 100).roundToInt()

    val zwo: String get() {
        fun f(x: Double) = String.format(Locale.US, "%.3f", x)
        val name = name.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
        val body = blocks.joinToString("\n") { b ->
            when (b.kind) {
                Kind.Steady -> "    <SteadyState Duration=\"${b.seconds}\" Power=\"${f(b.power)}\"/>"
                Kind.Ramp -> "    <Ramp Duration=\"${b.seconds}\" PowerLow=\"${f(b.power)}\" PowerHigh=\"${f(b.powerEnd)}\"/>"
                Kind.Intervals -> "    <IntervalsT Repeat=\"${b.repeats}\" OnDuration=\"${b.on}\" OffDuration=\"${b.off}\" OnPower=\"${f(b.onPower)}\" OffPower=\"${f(b.offPower)}\"/>"
            }
        }
        return "<workout_file>\n  <author>Orbeat</author>\n  <name>$name</name>\n  <sportType>bike</sportType>\n  <workout>\n$body\n  </workout>\n</workout_file>\n"
    }

    /** Share name: no "/", no edge spaces or dots (hidden / extension-only files). */
    val fileName: String get() = "${name.replace("/", "-").trim { it.isWhitespace() || it == '.' }.ifEmpty { "Workout" }}.zwo"

    /** Draft JSON, the Swift Codable keys. */
    val json: String get() = JSONObject().put("name", name).put("ftp", ftp).put("blocks", JSONArray(blocks.map {
        JSONObject().put("kind", it.kind.name).put("seconds", it.seconds).put("power", it.power).put("powerEnd", it.powerEnd)
            .put("repeats", it.repeats).put("on", it.on).put("onPower", it.onPower).put("off", it.off).put("offPower", it.offPower)
    })).toString()

    companion object {
        /** null if unreadable; missing fields (older drafts: no ftp) take their defaults. */
        fun decode(s: String): WorkoutPlan? = runCatching {
            val o = JSONObject(s)
            val a = o.getJSONArray("blocks")
            val d = Block(Kind.Steady)
            WorkoutPlan(o.getString("name"), List(a.length()) { a.getJSONObject(it).run {
                Block(Kind.valueOf(getString("kind")), optInt("seconds", d.seconds), optDouble("power", d.power),
                    optDouble("powerEnd", d.powerEnd), optInt("repeats", d.repeats), optInt("on", d.on), optDouble("onPower", d.onPower),
                    optInt("off", d.off), optDouble("offPower", d.offPower))
            } }, if (o.has("ftp") && !o.isNull("ftp")) o.getInt("ftp") else null)
        }.getOrNull()

        val sample = WorkoutPlan("Sweet Spot 3×10", listOf(
            Block(Kind.Ramp, seconds = 600, power = 0.5, powerEnd = 0.75),
            Block(Kind.Steady, seconds = 300, power = 0.75),
            Block(Kind.Intervals, repeats = 3, on = 600, onPower = 0.9, off = 300, offPower = 0.55),
            Block(Kind.Ramp, seconds = 300, power = 0.7, powerEnd = 0.45),
        ))

        /** Starting points for a new plan; the last one is blank. */
        val templates = listOf(
            WorkoutPlan("Endurance 1h", listOf(
                Block(Kind.Ramp, seconds = 300, power = 0.5, powerEnd = 0.65),
                Block(Kind.Steady, seconds = 3000, power = 0.68),
                Block(Kind.Ramp, seconds = 300, power = 0.6, powerEnd = 0.45),
            )),
            sample,
            WorkoutPlan("Threshold 2×20", listOf(
                Block(Kind.Ramp, seconds = 600, power = 0.5, powerEnd = 0.75),
                Block(Kind.Intervals, repeats = 2, on = 1200, onPower = 0.97, off = 300, offPower = 0.55),
                Block(Kind.Ramp, seconds = 300, power = 0.7, powerEnd = 0.45),
            )),
            WorkoutPlan("VO2 Max 5×3", listOf(
                Block(Kind.Ramp, seconds = 600, power = 0.5, powerEnd = 0.8),
                Block(Kind.Steady, seconds = 300, power = 0.6),
                Block(Kind.Intervals, repeats = 5, on = 180, onPower = 1.15, off = 180, offPower = 0.5),
                Block(Kind.Ramp, seconds = 300, power = 0.6, powerEnd = 0.45),
            )),
            WorkoutPlan("New Workout", emptyList()),
        )
    }
}
