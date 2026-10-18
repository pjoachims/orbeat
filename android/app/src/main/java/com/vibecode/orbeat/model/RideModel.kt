package com.vibecode.orbeat.model

import android.content.SharedPreferences
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.vibecode.orbeat.ble.BleHub
import com.vibecode.orbeat.ble.PeerClient
import com.vibecode.orbeat.core.HandlebarInput
import com.vibecode.orbeat.core.PeerState
import com.vibecode.orbeat.core.PeerWire
import com.vibecode.orbeat.core.PowerReading
import com.vibecode.orbeat.core.Rider
import com.vibecode.orbeat.core.RoadSpeed
import com.vibecode.orbeat.core.Route
import com.vibecode.orbeat.core.SensorEvent
import com.vibecode.orbeat.core.SessionClock
import com.vibecode.orbeat.core.TrainerMode
import com.vibecode.orbeat.core.now
import org.json.JSONArray
import org.json.JSONObject

/**
 * Ride model: the single observable UI state — heart rate plus power,
 * cadence, speed and trainer target. Components never write into it; the
 * app layer maps SensorEvents and peer states onto it (`apply`).
 */
class RideModel(private val prefs: SharedPreferences) {
    data class Sample(val time: Double, val bpm: Int)

    var bpm by mutableIntStateOf(0); private set
    var history by mutableStateOf(listOf<Sample>()); private set
    var lastSync by mutableDoubleStateOf(0.0); private set
    /** True while the newest reading (any metric) is < 60 s old. Refreshed by `checkFresh`. */
    var isFresh by mutableStateOf(false); private set
    var sourceName by mutableStateOf("Simulated")
    var bleStatus by mutableStateOf("Starting…")
    /** Alert threshold in BPM; 0 = off. Persisted. */
    var threshold by pref(prefs.getInt("threshold", 0)) { prefs.edit().putInt("threshold", it).apply() }
    val overThreshold: Boolean get() = threshold > 0 && hasData && isFresh && bpm >= threshold
    var watts by mutableStateOf<Int?>(null)
    var cadence by mutableStateOf<Int?>(null)
    var speedKmh by mutableStateOf<Double?>(null)
    var powerSource by mutableStateOf("")
    /** Last ERG target, resumed when switching back to ERG. Persisted. */
    var ergWatts by pref(prefs.getInt("ergWatts", 120)) { prefs.edit().putInt("ergWatts", it).apply() }
    /** Sim grade in 0.01 % units. Persisted. */
    var grade by pref(prefs.getInt("grade", 0)) { prefs.edit().putInt("grade", it).apply() }
    var gear by pref(prefs.getInt("gear", TrainerMode.NEUTRAL_GEAR)) { prefs.edit().putInt("gear", it).apply() }
    var rider by pref(prefs.getString("rider", null)?.let { runCatching { PeerWire.rider(JSONObject(it)) }.getOrNull() } ?: Rider()) {
        prefs.edit().putString("rider", PeerWire.rider(it).toString()).apply()
    }
    /** Route being ridden, persisted with the distance along it so a relaunch resumes mid-ride. */
    // ponytail: whole route as JSON in prefs (~100 KB for a long ride); a file if it grows
    var route by pref(prefs.getString("route", null)?.let(::decodeRoute)) {
        prefs.edit().putString("route", it?.let(::encodeRoute)).apply()
    }
    /** Why the last route couldn't be opened; the UI shows it once and clears it. */
    var routeError by mutableStateOf<String?>(null)
    var routeMeters by pref(prefs.getFloat("routeMeters", 0f).toDouble()) { prefs.edit().putFloat("routeMeters", it.toFloat()).apply() }
    var trainerControllable by mutableStateOf(false)
    var trainerMode by mutableStateOf<TrainerMode?>(null)
    private var isLive = false

    // Peer link
    var peerConnected by mutableStateOf(false)
    var peer by mutableStateOf<PeerState?>(null); private set
    /** THIS device drives the trainer (vs. controlling it through the peer). */
    var localTrainer by mutableStateOf(false)
    private var trainerAttached = false
    private var trainerAttach = 0
    private var directBPM: Int? = null
    private var directBPMAt = 0.0
    private var directHRSource = ""
    private var directPower: PowerReading? = null
    private var directPowerAt = 0.0
    private var directPowerSource = ""
    /** Last power reading from anywhere: route mode only advances while it is fresh. */
    var powerAt = 0.0; private set

    private val main = Handler(Looper.getMainLooper())

    val hasData: Boolean get() = history.isNotEmpty()
    val bpmText: String get() = if (hasData && isFresh) "$bpm" else "––"
    val displayWatts: Int? get() = if (isFresh) watts else null
    val displayCadence: Int? get() = if (isFresh) cadence else null
    val displaySpeedKmh: Double? get() = if (isFresh) speedKmh else null
    val zone: String get() = zoneName(bpm)

    fun checkFresh() { isFresh = now() - lastSync < 60 }
    private fun touch() { isFresh = true; lastSync = now() }

    fun setLive(live: Boolean, source: String) { isLive = live; sourceName = source }

    fun ingest(b: Int) {
        bpm = b
        history = (history + Sample(now(), b)).takeLast(60)
        touch()
    }

    // MARK: Events (port of RideModel+Events.swift)

    fun apply(event: SensorEvent, ble: BleHub?) {
        val t = now()
        when (event) {
            is SensorEvent.Status -> bleStatus = event.text
            is SensorEvent.HeartLinkUp -> { directHRSource = event.device; setLive(true, event.device) }
            SensorEvent.HeartLinkDown -> { directBPM = null; directBPMAt = 0.0; setLive(false, "Disconnected") }
            is SensorEvent.PowerLinkUp -> { directPowerSource = event.device; powerSource = event.device }
            SensorEvent.PowerLinkDown -> {
                directPower = null; directPowerAt = 0.0
                watts = null; cadence = null; speedKmh = null; powerSource = ""
            }
            is SensorEvent.HeartRate -> {
                if (event.reading.bpm <= 0) return
                directBPM = event.reading.bpm
                directBPMAt = t
                if (directHRSource.isNotEmpty()) sourceName = directHRSource
                ingest(event.reading.bpm)
            }
            is SensorEvent.Power -> {
                directPower = event.reading
                directPowerAt = t
                powerSource = directPowerSource
                showPower(event.reading.watts, event.reading.cadence)
            }
            is SensorEvent.Handlebar -> {}   // routed by AppCore: the trainer may live on the peer
            SensorEvent.TrainerReady -> {
                trainerAttached = true
                updateOwner()
                if (!localTrainer) return   // the peer drives it; we mirror
                trainerControllable = true
                // The peer may already ride this trainer: keep its target. Else
                // start in sim at the persisted grade — after a grace period, so
                // a peer link still coming up can report its target first.
                val attach = ++trainerAttach
                trainerMode = peer?.trainer
                if (trainerMode != null) return
                main.postDelayed({
                    if (attach == trainerAttach && localTrainer && trainerMode == null) {
                        trainerMode = ble?.setTrainerMode(TrainerMode.Sim(grade, gear), rider)
                    }
                }, 5000)
            }
            SensorEvent.TrainerLost -> {
                trainerAttached = false
                localTrainer = false
                trainerControllable = peer?.trainer != null
                trainerMode = peer?.trainer
            }
            is SensorEvent.Mode -> {
                if (!localTrainer) return   // mirroring the peer: its state is the truth
                // A sim frame only carries the grade the trainer got (terrain,
                // difficulty and gear can't be split back out), so sim follows
                // the kind only and keeps our terrain + gear.
                val m = event.mode
                if (m is TrainerMode.Sim) {
                    if (trainerMode !is TrainerMode.Sim) trainerMode = TrainerMode.Sim(grade, gear)
                    return
                }
                trainerMode = m
                remember(m)
            }
        }
    }

    /** Peer state arrived (null = link dropped). Local sensors win while fresh. */
    fun apply(peer: PeerState?) {
        this.peer = peer
        updateOwner()
        val t = now()
        val label = PeerClient.PEER_LABEL
        val b = peer?.bpm
        if (b != null && t - directBPMAt > DIRECT_WINDOW) {
            sourceName = "${peer.hrSource ?: "Heart rate"} · via $label"
            setLive(true, sourceName)
            ingest(b)
        }
        val w = peer?.watts
        if (w != null && t - directPowerAt > DIRECT_WINDOW) {
            powerSource = "${peer.powerSource ?: "Power"} · via $label"
            showPower(w, peer.cadence)
        }
        val r = peer?.rider?.clamped
        if (!localTrainer && r != null && r != rider) rider = r   // owner's settings win
        if (!localTrainer && trainerMode != peer?.trainer) {
            trainerControllable = peer?.trainer != null
            trainerMode = peer?.trainer
            remember(peer?.trainer)
        } else if (localTrainer && trainerMode == null && peer?.trainer != null) {
            trainerMode = peer.trainer   // both on one trainer: adopt the peer's target, no write
            remember(peer.trainer)
        }
    }

    /**
     * Who drives the trainer. Attached here: us — the phone is on the bike, so
     * it never yields a shared trainer to the Mac (yieldsSharedTrainer = false).
     */
    private fun updateOwner() {
        val own = trainerAttached
        if (own == localTrainer) return
        localTrainer = own
        trainerControllable = own || peer?.trainer != null
        if (!own) trainerMode = peer?.trainer
    }

    /** What this device publishes to its peer: direct readings only. */
    fun directState(recording: SessionClock?): PeerState {
        val t = now()
        val hr = t - directBPMAt < DIRECT_WINDOW
        val pw = if (t - directPowerAt < DIRECT_WINDOW) directPower else null
        return PeerState(
            bpm = if (hr) directBPM else null, hrSource = if (hr) directHRSource else null,
            watts = pw?.watts, cadence = pw?.cadence, kmh = pw?.kmh,
            powerSource = if (pw != null) directPowerSource else null,
            trainer = if (localTrainer) trainerMode else null,
            recording = recording,
            rider = if (localTrainer) rider else null,
        )
    }

    /** Step the LOCAL trainer: ERG ±5 W, resistance ±10 %, sim ±1 gear. */
    fun press(inputs: List<HandlebarInput>, ble: BleHub?) {
        var mode = trainerMode ?: return   // no trainer target yet
        for (i in inputs) mode = if (i == HandlebarInput.ShiftUp) mode.steppedUp else mode.steppedDown
        setTrainer(mode, ble)
    }

    /** Push a target to the LOCAL trainer. A different kind resumes that kind's last target. */
    fun setTrainer(mode: TrainerMode, ble: BleHub?) {
        val m = if (mode.sameKind(trainerMode)) mode else mode.resumed(ergWatts, grade, gear)
        trainerMode = ble?.setTrainerMode(m, rider) ?: m.clamped
        remember(trainerMode)
    }

    private fun remember(m: TrainerMode?) {
        when (m) {
            is TrainerMode.Erg -> ergWatts = m.targetWatts
            is TrainerMode.Sim -> { grade = m.grade; gear = m.gear }
            else -> {}
        }
    }

    fun showPower(w: Int, c: Int?) {
        watts = w
        cadence = c
        // Road-model speed, not the trainer's wheel speed (bogus in ERG).
        val g = (trainerMode as? TrainerMode.Sim)?.grade ?: 0
        speedKmh = RoadSpeed.kmh(w, g / 100.0, rider.massKg)
        powerAt = now()
        touch()   // power packets count as a sync too
    }

    companion object {
        const val DIRECT_WINDOW = 5.0
        fun zoneName(bpm: Int) = when {
            bpm < 60 -> "Resting"
            bpm < 100 -> "Fat Burn"
            bpm < 140 -> "Cardio"
            else -> "Peak"
        }

        fun encodeRoute(r: Route): String = JSONObject().put("name", r.name)
            .put("dist", JSONArray(r.dist)).put("ele", JSONArray(r.ele)).toString()

        fun decodeRoute(s: String): Route? = runCatching {
            val o = JSONObject(s)
            fun list(k: String) = o.getJSONArray(k).let { a -> List(a.length()) { a.getDouble(it) } }
            Route(o.getString("name"), list("dist"), list("ele"))
        }.getOrNull()
    }
}

/** Compose state that persists on every write. */
internal fun <T> pref(initial: T, save: (T) -> Unit) = object : kotlin.properties.ReadWriteProperty<Any?, T> {
    val state = mutableStateOf(initial)
    override fun getValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>) = state.value
    override fun setValue(thisRef: Any?, property: kotlin.reflect.KProperty<*>, value: T) {
        state.value = value
        save(value)
    }
}
