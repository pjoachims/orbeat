package com.vibecode.orbeat.drivers

import com.vibecode.orbeat.core.HeartRateReading
import com.vibecode.orbeat.core.PowerReading
import com.vibecode.orbeat.core.Rider
import com.vibecode.orbeat.core.TrainerMode
import com.vibecode.orbeat.core.hex
import com.vibecode.orbeat.core.rounded

private fun ByteArray.u8(i: Int) = this[i].toInt() and 0xFF
private fun ByteArray.u16(i: Int) = u8(i) or (u8(i + 1) shl 8)
private fun ByteArray.s16(i: Int) = u16(i).toShort().toInt()

/** Parses standard BLE Heart Rate Measurement packets (0x2A37). Stateless. */
object HeartRateParser {
    /** byte0 flags; bit0 = u8/u16 bpm, bit1/2 = contact, bit3 = energy, bit4 = RR. null if truncated. */
    fun parse(b: ByteArray, device: String?): HeartRateReading? {
        val flags = b.firstOrNull()?.toInt() ?: return null
        val bpm: Int
        var i: Int
        if (b.size >= 2 && flags and 0x01 == 0) { bpm = b.u8(1); i = 2 }
        else if (b.size >= 3) { bpm = b.u16(1); i = 3 }
        else return null
        val contact = if (flags and 0x04 != 0) flags and 0x02 != 0 else null
        var kj: Int? = null
        if (flags and 0x08 != 0 && b.size >= i + 2) { kj = b.u16(i); i += 2 }
        var rrMs: List<Int>? = null
        if (flags and 0x10 != 0) {   // RR intervals, u16 each, 1/1024 s
            val rr = mutableListOf<Int>()
            while (b.size >= i + 2) { rr.add((b.u16(i) / 1024.0 * 1000).rounded()); i += 2 }
            if (rr.isNotEmpty()) rrMs = rr
        }
        return HeartRateReading(device, bpm, contact, kj, rrMs)
    }

    fun logFields(r: HeartRateReading): Map<String, Any?> =
        mapOf("src" to "hr", "bpm" to r.bpm, "device" to r.device, "contact" to r.contact, "kj" to r.kj, "rr_ms" to r.rrMs)
}

/**
 * Cycling Power Measurement (0x2A63) with speed/cadence from revolution deltas.
 * One per power device (the counters are per-device state); `reset()` on disconnect.
 */
class CyclingPowerParser(private val wheelCircumferenceM: Double = 2.105) {   // ponytail: fixed 700x25c
    data class Packet(
        val device: String?, val watts: Int, val balancePct: Double?, val torqueNm: Double?,
        val kmh: Double?, val rpm: Int?, val wheelRevs: Long?, val wheelEvt: Int?, val crankRevs: Int?, val crankEvt: Int?,
    ) {
        val logFields: Map<String, Any?> get() = mapOf(
            "src" to "pwr", "watts" to watts, "device" to device, "balance_pct" to balancePct, "torque_nm" to torqueNm,
            "wheel_revs" to wheelRevs, "wheel_evt" to wheelEvt, "crank_revs" to crankRevs, "crank_evt" to crankEvt,
            "kmh" to kmh, "rpm" to rpm,
        )
        val reading: PowerReading get() = PowerReading(device, watts, rpm, kmh, balancePct, torqueNm)
    }

    private var lastWheel: Pair<Long, Int>? = null
    private var lastCrank: Pair<Int, Int>? = null

    fun reset() { lastWheel = null; lastCrank = null }

    fun parse(b: ByteArray, device: String?): Packet? {
        if (b.size < 4) return null
        val flags = b.u16(0)
        val watts = b.s16(2)
        var balancePct: Double? = null; var torqueNm: Double? = null
        var kmh: Double? = null; var rpm: Int? = null
        var wheelRevs: Long? = null; var wheelEvt: Int? = null; var crankRevs: Int? = null; var crankEvt: Int? = null
        var i = 4
        if (flags and 0x01 != 0 && b.size >= i + 1) { balancePct = b.u8(i) / 2.0; i += 1 }
        if (flags and 0x04 != 0 && b.size >= i + 2) { torqueNm = b.u16(i) / 32.0; i += 2 }
        if (flags and 0x10 != 0 && b.size >= i + 6) {
            val revs = b.u16(i).toLong() or (b.u16(i + 2).toLong() shl 16)
            val t = b.u16(i + 4)   // 1/2048 s
            lastWheel?.let { (lr, lt) ->
                kmh = if (t == lt) 0.0 else {
                    val dt = ((t - lt) and 0xFFFF) / 2048.0
                    (((revs - lr) and 0xFFFFFFFFL) * wheelCircumferenceM / dt * 3.6).takeIf { it <= MAX_KMH }   // else counter reset
                }
            }
            lastWheel = revs to t
            wheelRevs = revs; wheelEvt = t
            i += 6
        }
        if (flags and 0x20 != 0 && b.size >= i + 4) {
            val revs = b.u16(i)
            val t = b.u16(i + 2)   // 1/1024 s
            lastCrank?.let { (lr, lt) ->
                rpm = if (t == lt) 0 else {
                    val dt = ((t - lt) and 0xFFFF) / 1024.0
                    (((revs - lr) and 0xFFFF) / dt * 60).rounded().takeIf { it <= MAX_RPM }
                }
            }
            lastCrank = revs to t
            crankRevs = revs; crankEvt = t
        }
        return Packet(device, watts, balancePct, torqueNm, kmh, rpm, wheelRevs, wheelEvt, crankRevs, crankEvt)
    }

    companion object {
        /** Trainers reset counters without dropping the link: past these it's a reset, not motion. */
        const val MAX_RPM = 250
        const val MAX_KMH = 120.0
    }
}

/** FTMS Indoor Bike Data (0x2AD2): trainers without a Cycling Power Service. Stateless. */
object FtmsIndoorBikeParser {
    data class Packet(val device: String?, val watts: Int?, val kmh: Double?, val rpm: Int?) {
        val logFields: Map<String, Any?> get() = mapOf("src" to "pwr", "device" to device, "watts" to watts, "kmh" to kmh, "rpm" to rpm)
        val reading: PowerReading? get() = watts?.let { PowerReading(device, it, rpm, kmh) }
    }

    fun parse(b: ByteArray, device: String?): Packet? {
        if (b.size < 2) return null
        val flags = b.u16(0)
        var i = 2
        fun u16(res: Double = 1.0): Double? {
            if (b.size < i + 2) return null
            return (b.u16(i) * res).also { i += 2 }
        }
        var kmh: Double? = null; var rpm: Int? = null; var watts: Int? = null
        if (flags and 0x01 == 0) kmh = u16(0.01)            // instantaneous speed
        if (flags and 0x02 != 0) u16()                       // average speed
        if (flags and 0x04 != 0) rpm = u16(0.5)?.rounded()  // instantaneous cadence
        if (flags and 0x08 != 0) u16()                       // average cadence
        if (flags and 0x10 != 0) { if (b.size < i + 3) return null; i += 3 }   // total distance u24
        if (flags and 0x20 != 0) u16()                       // resistance level
        if (flags and 0x40 != 0) { if (b.size < i + 2) return null; watts = b.s16(i); i += 2 }
        return Packet(device, watts, kmh, rpm)
    }
}

/** FTMS Fitness Machine Status (0x2ADA) → the trainer's current target. */
object FtmsMachineStatus {
    fun parse(b: ByteArray): TrainerMode? {
        if (b.size < 2) return null
        return when (b.u8(0)) {
            0x07 -> TrainerMode.Resistance((if (b.size >= 3) b.s16(1) else b.u8(1)) / 10)
            0x08 -> if (b.size >= 3) TrainerMode.Erg(b.s16(1)) else null
            0x12 -> if (b.size >= 5) TrainerMode.Sim(b.s16(3)) else null
            else -> null
        }
    }

    /** Status frame a trainer would notify for `m` (a KICKR doesn't notify the central that wrote). */
    fun encode(m: TrainerMode, rider: Rider): ByteArray {
        fun le(v: Int) = byteArrayOf(v.toByte(), (v shr 8).toByte())
        return when (m) {
            is TrainerMode.Erg -> byteArrayOf(0x08) + le(m.targetWatts)
            is TrainerMode.Resistance -> byteArrayOf(0x07) + le(m.percent * 10)
            is TrainerMode.Sim -> byteArrayOf(0x12) + m.simParams(rider)!!.bytes
        }
    }
}

/** FTMS Control Point (0x2AD9) write → the target it sets. Inverse of Trainer.set. */
object FtmsControlFrame {
    fun parse(b: ByteArray): TrainerMode? {
        if (b.size < 3) return null
        return when (b.u8(0)) {
            0x04 -> TrainerMode.Resistance(b.s16(1) / 10)
            0x05 -> TrainerMode.Erg(b.s16(1))
            0x11 -> if (b.size >= 5) TrainerMode.Sim(b.s16(3)) else null
            else -> null
        }
    }
}

/** One decoded Zwift Ride / Play button-frame state change. */
data class ZwiftButtonFrame(val raw: String, val pressed: List<String>, val newlyPressed: Set<Long>) {
    companion object {
        const val SHIFT_UP = 0x0100L or 0x1000L
        const val SHIFT_DOWN = 0x0200L or 0x2000L
    }
}

/** Decodes Zwift Ride / Play handlebar button frames: rising-edge detection, no transport. */
class ZwiftRideController {
    private var lastMap = 0xFFFFFFFFL

    fun reset() { lastMap = 0xFFFFFFFFL }

    /** A frame on a real state change; null for non-button frames or unchanged repeats. */
    fun handle(b: ByteArray): ZwiftButtonFrame? {
        val map = bitmap(b) ?: return null
        if (map == lastMap) return null
        val newly = buttons.map { it.second }.filter { map and it == 0L && lastMap and it != 0L }.toSet()
        val pressed = buttons.filter { map and it.second == 0L }.map { it.first }
        lastMap = map
        return ZwiftButtonFrame(b.hex(), pressed, newly)
    }

    private fun readVarint(b: ByteArray, start: Int): Pair<Long, Int>? {
        var result = 0L; var shift = 0; var j = start
        while (j < b.size) {
            val byte = b.u8(j); j++
            result = result or ((byte and 0x7F).toLong() shl shift)
            if (byte and 0x80 == 0) return result to j
            shift += 7
            if (shift >= 64) return null
        }
        return null
    }

    /** Field-1 bitmap from a 0x23 frame (bit CLEAR = pressed). */
    private fun bitmap(b: ByteArray): Long? {
        if (b.firstOrNull() != 0x23.toByte()) return null
        var i = 1
        while (i < b.size) {
            val (tag, ni) = readVarint(b, i) ?: return null
            i = ni
            val field = tag ushr 3; val wire = (tag and 7).toInt()
            if (field == 1L && wire == 0) return (readVarint(b, i) ?: return null).first and 0xFFFFFFFFL
            i = when (wire) {
                0 -> (readVarint(b, i) ?: return null).second
                2 -> (readVarint(b, i) ?: return null).let { (len, n) -> n + len.toInt() }
                5 -> i + 4
                1 -> i + 8
                else -> return null
            }
        }
        return null
    }

    companion object {
        private val buttons = listOf(
            "leftLeft" to 0x00001L, "leftUp" to 0x00002L, "leftRight" to 0x00004L, "leftDown" to 0x00008L,
            "rightA" to 0x00010L, "rightB" to 0x00020L, "rightY" to 0x00040L, "rightZ" to 0x00080L,
            "leftShiftUp" to 0x00100L, "leftShiftDown" to 0x00200L, "leftPowerUp" to 0x00400L,
            "leftPower" to 0x00800L, "rightShiftUp" to 0x01000L, "rightShiftDown" to 0x02000L,
            "rightPowerUp" to 0x04000L, "rightPower" to 0x08000L, "rightOnOff" to 0x20000L,
        )
    }
}

/**
 * Zwift Protocol trainer commands (KICKR CORE Zwift One, Zwift Hub): 0x04 +
 * HubCommand protobuf on the sync RX char. From qdomyos-zwift.
 */
object ZwiftHub {
    /** Sent once after RideOn. ponytail: copied from qdomyos-zwift, not understood. */
    val initFrames = listOf(byteArrayOf(0x41, 0x08, 0x05), byteArrayOf(0x00, 0x08, 0x00), byteArrayOf(0x00, 0x08, 0x88.toByte(), 0x04))

    /** HubCommand.Simulation: wind 0, grade (0.01 %), CWa × 10000, Crr × 100000. */
    fun simulation(grade: Int): ByteArray = byteArrayOf(0x04) + message(4,
        varint(1, 0) + varint(2, zigzag(grade)) + varint(3, (TrainerMode.zwiftCWa * 10_000).toLong())
            + varint(4, (TrainerMode.zwiftCrr * 100_000).rounded().toLong()))

    /** HubCommand.Physical: gear ratio × 10000, bike and rider weight × 100 (kg). */
    fun physical(gearRatio: Double, rider: Rider): ByteArray = byteArrayOf(0x04) + message(5,
        varint(2, (gearRatio * 10_000).rounded().toLong()) + varint(4, rider.bikeKg * 100L) + varint(5, rider.riderKg * 100L))

    /** Simulation first: qdomyos-zwift found gear commands ignored until a grade was sent. */
    fun frames(m: TrainerMode, rider: Rider): List<ByteArray>? {
        val g = m.sentGrade(rider.difficulty) ?: return null
        val r = m.gearRatio ?: return null
        return listOf(simulation(g), physical(r, rider))
    }

    private fun zigzag(v: Int): Long = (v.toLong() shl 1) xor (v.toLong() shr 63)
    private fun varint(field: Int, v: Long) = byteArrayOf((field shl 3).toByte()) + raw(v)
    private fun message(field: Int, body: ByteArray) = byteArrayOf((field shl 3 or 2).toByte()) + raw(body.size.toLong()) + body
    private fun raw(value: Long): ByteArray {
        var v = value
        val out = mutableListOf<Byte>()
        do {
            out.add(((v and 0x7F) or (if (v.toULong() > 0x7FUL) 0x80 else 0)).toByte())
            v = v ushr 7
        } while (v != 0L)
        return out.toByteArray()
    }
}
