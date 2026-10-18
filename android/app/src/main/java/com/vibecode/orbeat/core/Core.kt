package com.vibecode.orbeat.core

/** A decoded heart-rate measurement (standard BLE 0x2A37 packet). */
data class HeartRateReading(
    val device: String?,
    val bpm: Int,
    val contact: Boolean? = null,
    val kj: Int? = null,
    val rrMs: List<Int>? = null,
)

/** One power telemetry sample from any equipment source. */
data class PowerReading(
    val device: String?,
    val watts: Int,
    val cadence: Int?,
    val kmh: Double?,
    val balancePct: Double? = null,
    val torqueNm: Double? = null,
)

/** Any sink for structured diagnostics (the JSONL Recorder). */
fun interface LogWriting {
    fun log(fields: Map<String, Any?>)
}

/** Everything the BLE hub reports upward. */
sealed class SensorEvent {
    data class Status(val text: String) : SensorEvent()
    data class HeartLinkUp(val device: String) : SensorEvent()
    data object HeartLinkDown : SensorEvent()
    data class PowerLinkUp(val device: String) : SensorEvent()
    data object PowerLinkDown : SensorEvent()
    data class HeartRate(val reading: HeartRateReading) : SensorEvent()
    data class Power(val reading: PowerReading) : SensorEvent()
    data class Handlebar(val inputs: List<HandlebarInput>) : SensorEvent()
    data object TrainerReady : SensorEvent()
    data object TrainerLost : SensorEvent()
    data class Mode(val mode: TrainerMode) : SensorEvent()
}

/**
 * Chart curves from 1 Hz samples: a centered moving average over a TIME
 * window (not a sample count), then thinned to a drawable number of points.
 */
object Curve {
    data class Point(val t: Double, val v: Double)

    /** Mean of all points within ±window/2 of each point; window ≤ 0 = raw. */
    fun smooth(pts: List<Point>, window: Double): List<Point> {
        if (window <= 0) return pts
        val half = window / 2
        var lo = 0; var hi = 0; var sum = 0.0
        return pts.map { p ->
            while (hi < pts.size && pts[hi].t <= p.t + half) { sum += pts[hi].v; hi++ }
            while (pts[lo].t < p.t - half) { sum -= pts[lo].v; lo++ }
            Point(p.t, sum / (hi - lo))
        }
    }

    /** Every n-th point so at most `max` remain (always keeps the last one). */
    fun thin(pts: List<Point>, max: Int = 600): List<Point> {
        val n = maxOf(1, (pts.size + max - 1) / max)
        if (n <= 1) return pts
        val out = (pts.indices step n).map { pts[it] }.toMutableList()
        if (out.last() != pts.last()) out.add(pts.last())
        return out
    }
}

/**
 * Virtual road speed from power, like Zwift: the trainer's own wheel speed is
 * meaningless in ERG. ponytail: fixed CdA 0.32 / Crr 0.004; settings if speeds read off.
 */
object RoadSpeed {
    const val massKg = 85.0
    private const val cdA = 0.32
    private const val crr = 0.004
    private const val rho = 1.2
    private const val g = 9.81

    /** km/h holding `watts` on `gradePercent`; 0 when not pedalling. */
    fun kmh(watts: Int, gradePercent: Double = 0.0, massKg: Double = RoadSpeed.massKg): Double {
        if (watts <= 0) return 0.0
        val a = 0.5 * rho * cdA
        val b = massKg * g * (crr + gradePercent / 100)
        // P(v) = v·(b + a·v²): one crossing above P > 0 even when b < 0 (downhill).
        var lo = 0.0; var hi = 40.0   // m/s
        repeat(50) {
            val v = (lo + hi) / 2
            if (v * (b + a * v * v) < watts) lo = v else hi = v
        }
        return lo * 3.6
    }
}

fun ByteArray.hex(): String = joinToString("") { "%02x".format(it.toInt() and 0xFF) }
