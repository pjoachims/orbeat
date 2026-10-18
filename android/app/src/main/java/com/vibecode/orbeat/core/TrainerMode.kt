package com.vibecode.orbeat.core

import kotlin.math.pow

/** Seconds since 1970, the app's one clock unit (Swift's Date). */
fun now(): Double = System.currentTimeMillis() / 1000.0

/** Swift's `.rounded()`: half away from zero (Kotlin's roundToInt rounds half up). */
fun Double.rounded(): Int = (if (this < 0) -Math.round(-this) else Math.round(this)).toInt()

private fun Int.clamp(r: IntRange) = coerceIn(r.first, r.last)

/** Neutral handlebar-controller input, whichever brand decoded it. */
enum class HandlebarInput { ShiftUp, ShiftDown }

/**
 * Trainer control target — one type for every FTMS mode the app supports.
 * App policy steps modes with `steppedUp/steppedDown`; the Trainer component
 * clamps and encodes them onto the FTMS control point.
 */
sealed class TrainerMode {
    /** ERG: trainer holds a constant power regardless of cadence. */
    data class Erg(val targetWatts: Int) : TrainerMode()
    /** Resistance level as a percentage of the trainer's range. */
    data class Resistance(val percent: Int) : TrainerMode()
    /**
     * Simulation: resistance scales with speed like a real hill. Grade is the
     * terrain in 0.01 % units; gear is the virtual gear (1…24, Zwift's table).
     */
    data class Sim(val grade: Int, val gear: Int = NEUTRAL_GEAR) : TrainerMode()

    companion object {
        val wattRange = 30..600
        val percentRange = 0..100
        val gradeRange = -500..1500   // terrain: -5 % … +15 %
        val gearRange = 1..24
        const val NEUTRAL_GEAR = 12

        /** Zwift's virtual gear ratios (chainring/cog, gear 1…24). */
        val gearRatios = doubleArrayOf(0.75, 0.87, 0.99, 1.11, 1.23, 1.38, 1.53, 1.68, 1.86, 2.04, 2.22, 2.40,
            2.61, 2.82, 3.03, 3.24, 3.49, 3.74, 3.99, 4.24, 4.54, 4.84, 5.14, 5.49)

        /** Ratio the trainer is assumed to be ridden in: 34×14, the Zwift Cog (gear 12). */
        const val trainerRatio = 34.0 / 14

        /** Road Zwift sends the trainer, on FTMS and Zwift Protocol alike. */
        const val zwiftCrr = 0.004
        const val zwiftCWa = 0.51
    }

    /** Grade the trainer gets, Zwift's Trainer Difficulty: descents halved first. 0.01 % units. */
    fun sentGrade(difficulty: Int): Int? {
        if (this !is Sim) return null
        return (grade * (if (grade < 0) 0.5 else 1.0) * difficulty / 100).rounded()
    }

    /** Gear ratio of the current sim gear (chainring/cog). */
    val gearRatio: Double? get() = (this as? Sim)?.let { gearRatios[it.gear - 1] }

    /**
     * FTMS fallback for trainers without Zwift Protocol: Zwift's road scaled for
     * the virtual gear, k = r / trainerRatio: grade × k, crr × k, cw × k³.
     * cw saturates at 2.55 from about gear 18 on.
     */
    fun simParams(rider: Rider): SimParams? {
        val sent = sentGrade(rider.difficulty) ?: return null
        val r = gearRatio ?: return null
        val k = r / trainerRatio
        fun clamp(x: Double, range: IntRange) = x.rounded().clamp(range)
        // Downhill, grade pushes and cw brakes: once cw saturates, cap k there.
        val kCw = (2.55 / zwiftCWa).pow(1.0 / 3)
        return SimParams(
            grade = clamp(sent * (if (sent < 0) minOf(k, kCw) else k), -4000..4000),
            crr = clamp(zwiftCrr * k * 10_000, 0..255),
            cw = clamp(zwiftCWa * k * k * k * 100, 0..255),
        )
    }

    val clamped: TrainerMode get() = when (this) {
        is Erg -> Erg(targetWatts.clamp(wattRange))
        is Resistance -> Resistance(percent.clamp(percentRange))
        is Sim -> Sim(grade.clamp(gradeRange), gear.clamp(gearRange))
    }

    val steppedUp: TrainerMode get() = when (this) {
        is Erg -> Erg(targetWatts + 5).clamped
        is Resistance -> Resistance(percent + 10).clamped
        is Sim -> Sim(grade, gear + 1).clamped
    }

    val steppedDown: TrainerMode get() = when (this) {
        is Erg -> Erg(targetWatts - 5).clamped
        is Resistance -> Resistance(percent - 10).clamped
        is Sim -> Sim(grade, gear - 1).clamped
    }

    fun sameKind(other: TrainerMode?): Boolean = other != null && this::class == other::class

    /** This kind at its last-used target. Resistance has no memory. */
    fun resumed(ergWatts: Int, grade: Int, gear: Int): TrainerMode = when (this) {
        is Erg -> Erg(ergWatts)
        is Sim -> Sim(grade, gear)
        is Resistance -> this
    }

    val label: String get() = when (this) {
        is Erg -> "ERG · $targetWatts W"
        is Resistance -> "Resistance · $percent %"
        is Sim -> String.format(java.util.Locale.US, "%.1f %% · Gear %d", grade / 100.0, gear)
    }

    /** Label for one step in this mode, e.g. "+5 W". */
    val stepLabel: String get() = when (this) {
        is Erg -> "+5 W"
        is Resistance -> "+10 %"
        is Sim -> "+1 gear"
    }
}

/** FTMS Indoor Bike Simulation Parameters (control 0x11 / status 0x12 payload). */
data class SimParams(val grade: Int, val crr: Int, val cw: Int) {
    /** wind(sint16, mm/s)=0, grade(sint16), crr(uint8), cw(uint8). */
    val bytes: ByteArray get() = byteArrayOf(0, 0, grade.toByte(), (grade shr 8).toByte(), crr.toByte(), cw.toByte())
}

/** Rider settings the trainer needs for Zwift-style sim. Persisted; the owner's copy wins. */
data class Rider(val riderKg: Int = 80, val bikeKg: Int = 8, val difficulty: Int = 50) {
    val massKg: Double get() = (riderKg + bikeKg).toDouble()

    /** Within the settings' ranges: values also arrive from the peer link. */
    val clamped: Rider get() = Rider(riderKg.clamp(riderRange), bikeKg.clamp(bikeRange), difficulty.clamp(0..100))

    companion object {
        val riderRange = 40..150
        val bikeRange = 5..25
        val difficulties = listOf(0, 25, 50, 75, 100)
    }
}
