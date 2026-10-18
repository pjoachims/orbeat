package com.vibecode.orbeat.core

import org.json.JSONObject

/**
 * What one Orbeat tells the other over the peer link: only readings from
 * sensors it is connected to DIRECTLY, never what it learned from the peer.
 */
data class PeerState(
    val bpm: Int? = null,
    val hrSource: String? = null,
    val watts: Int? = null,
    val cadence: Int? = null,
    val kmh: Double? = null,
    val powerSource: String? = null,
    /** Trainer target, set only while this device controls a trainer. */
    val trainer: TrainerMode? = null,
    /** Session this device is recording, if any. */
    val recording: SessionClock? = null,
    /** Rider settings of the trainer owner. */
    val rider: Rider? = null,
)

/** A session's clock. Running counts from a virtual start (shifted by paused time); paused holds elapsed seconds. */
sealed class SessionClock {
    data class Running(val since: Double) : SessionClock()
    data class Paused(val elapsed: Double) : SessionClock()

    fun elapsed(at: Double = now()): Double = when (this) {
        is Running -> at - since
        is Paused -> elapsed
    }
    val isPaused: Boolean get() = this is Paused
    fun pausing(at: Double = now()): SessionClock = Paused(elapsed(at))
    fun resuming(at: Double = now()): SessionClock = Running(at - elapsed(at))
}

/** Remote control: sent to the device that owns the trainer / the session. */
sealed class PeerCommand {
    data class Step(val input: HandlebarInput) : PeerCommand()
    data class SetTrainer(val mode: TrainerMode) : PeerCommand()
    data class SetRider(val rider: Rider) : PeerCommand()
    /** New terrain grade (route mode); the owner keeps its own gear. */
    data class SetGrade(val grade: Int) : PeerCommand()
    data object StopSession : PeerCommand()
    data class PauseSession(val paused: Boolean) : PeerCommand()
}

sealed class PeerMessage {
    data class State(val state: PeerState) : PeerMessage()
    data class Command(val command: PeerCommand) : PeerMessage()
}

/** One message per characteristic value, compact JSON, wire-compatible with the Swift app. ≤ 180 bytes. */
object PeerWire {
    fun encode(m: PeerMessage): ByteArray {
        val e = JSONObject()
        when (m) {
            is PeerMessage.State -> e.put("s", state(m.state))
            is PeerMessage.Command -> when (val c = m.command) {
                is PeerCommand.Step -> e.put("step", if (c.input == HandlebarInput.ShiftUp) 1 else -1)
                is PeerCommand.SetTrainer -> e.put("set", mode(c.mode))
                is PeerCommand.SetRider -> e.put("rider", rider(c.rider))
                is PeerCommand.SetGrade -> e.put("grade", c.grade)
                PeerCommand.StopSession -> e.put("stop", true)
                is PeerCommand.PauseSession -> e.put("pause", c.paused)
            }
        }
        return e.toString().toByteArray()
    }

    fun decode(data: ByteArray): PeerMessage? = try {
        val e = JSONObject(String(data))
        when {
            e.has("s") -> PeerMessage.State(state(e.getJSONObject("s")))
            e.has("step") -> PeerMessage.Command(PeerCommand.Step(if (e.getInt("step") > 0) HandlebarInput.ShiftUp else HandlebarInput.ShiftDown))
            e.has("set") -> PeerMessage.Command(PeerCommand.SetTrainer(mode(e.getJSONObject("set"))))
            e.has("rider") -> PeerMessage.Command(PeerCommand.SetRider(rider(e.getJSONObject("rider"))))
            e.has("grade") -> PeerMessage.Command(PeerCommand.SetGrade(e.getInt("grade")))
            e.optBoolean("stop") -> PeerMessage.Command(PeerCommand.StopSession)
            e.has("pause") -> PeerMessage.Command(PeerCommand.PauseSession(e.getBoolean("pause")))
            else -> null
        }
    } catch (e: Exception) { null }

    private fun state(s: PeerState) = JSONObject().apply {
        s.bpm?.let { put("b", it) }
        s.hrSource?.let { put("hs", it) }
        s.watts?.let { put("w", it) }
        s.cadence?.let { put("c", it) }
        s.kmh?.let { put("k", it) }
        s.powerSource?.let { put("ps", it) }
        s.trainer?.let { put("t", mode(it)) }
        when (val r = s.recording) {
            is SessionClock.Running -> put("r", r.since)
            is SessionClock.Paused -> put("rp", r.elapsed)
            null -> {}
        }
        s.rider?.let { put("rd", rider(it)) }
    }

    private fun state(o: JSONObject): PeerState {
        fun int(k: String) = if (o.has(k)) o.getInt(k) else null
        fun dbl(k: String) = if (o.has(k)) o.getDouble(k) else null
        fun str(k: String) = if (o.has(k)) o.getString(k) else null
        return PeerState(
            bpm = int("b"), hrSource = str("hs"), watts = int("w"), cadence = int("c"), kmh = dbl("k"),
            powerSource = str("ps"),
            trainer = if (o.has("t")) mode(o.getJSONObject("t")) else null,
            recording = dbl("rp")?.let { SessionClock.Paused(it) } ?: dbl("r")?.let { SessionClock.Running(it) },
            rider = if (o.has("rd")) rider(o.getJSONObject("rd")) else null,
        )
    }

    /** {"erg":200} / {"res":40} / {"sim":150,"g":12} */
    fun mode(m: TrainerMode) = JSONObject().apply {
        when (m) {
            is TrainerMode.Erg -> put("erg", m.targetWatts)
            is TrainerMode.Resistance -> put("res", m.percent)
            is TrainerMode.Sim -> { put("sim", m.grade); put("g", m.gear) }
        }
    }

    fun mode(o: JSONObject): TrainerMode = when {
        o.has("erg") -> TrainerMode.Erg(o.getInt("erg"))
        o.has("res") -> TrainerMode.Resistance(o.getInt("res"))
        else -> TrainerMode.Sim(o.getInt("sim"), o.optInt("g", TrainerMode.NEUTRAL_GEAR))
    }

    fun rider(r: Rider) = JSONObject().put("r", r.riderKg).put("b", r.bikeKg).put("d", r.difficulty)
    fun rider(o: JSONObject) = Rider(o.getInt("r"), o.getInt("b"), o.getInt("d"))
}
