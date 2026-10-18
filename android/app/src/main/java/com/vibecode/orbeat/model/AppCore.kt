package com.vibecode.orbeat.model

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.VibrationEffect
import android.os.VibratorManager
import android.provider.OpenableColumns
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import com.vibecode.orbeat.R
import com.vibecode.orbeat.RideService
import com.vibecode.orbeat.ble.BleHub
import com.vibecode.orbeat.ble.PeerClient
import com.vibecode.orbeat.core.HandlebarInput
import com.vibecode.orbeat.core.PeerCommand
import com.vibecode.orbeat.core.PeerMessage
import com.vibecode.orbeat.core.PeerState
import com.vibecode.orbeat.core.Rider
import com.vibecode.orbeat.core.Route
import com.vibecode.orbeat.core.SensorEvent
import com.vibecode.orbeat.core.SessionClock
import com.vibecode.orbeat.core.TrainerMode
import com.vibecode.orbeat.core.Workout
import com.vibecode.orbeat.core.now
import java.io.File
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread
import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min
import kotlin.random.Random

/**
 * Composition root: sensors, peer link, model, sessions. The UI calls the
 * intent methods; each routes to whichever device owns the trainer or the
 * running session. Lives as long as the process (OrbeatApp).
 */
class AppCore(ctx: Context) {
    private val app = ctx.applicationContext
    private val prefs = ctx.getSharedPreferences("orbeat", Context.MODE_PRIVATE)
    val model = RideModel(prefs)
    val store = SessionStore(File(ctx.filesDir, "sessions.json"))
    val recorder = Recorder(File(ctx.getExternalFilesDir(null) ?: ctx.filesDir, "orbeat.jsonl"), prefs)
    var ble: BleHub? = null; private set
    var peer: PeerClient? = null; private set
    private val main = Handler(Looper.getMainLooper())
    private var lastPush = 0.0
    private var routeAt: Double? = null
    private var lastGradeAt = 0.0
    private var workoutAt: Double? = null
    private var lastTarget: Int? = null
    private var lastTargetAt = 0.0
    private var lastBuzz = 0.0
    /** An activity is on screen: alerts vibrate instead of notifying. */
    var foreground = false

    /** Vibrate/notify every N seconds while over threshold; 0 = off. */
    var vibrateEvery by pref(prefs.getInt("vibrateEvery", 10)) { prefs.edit().putInt("vibrateEvery", it).apply() }
    /** Ongoing ride notification (RideService), the Live Activity stand-in. */
    var rideNotification by pref(prefs.getBoolean("rideNotification", true)) {
        prefs.edit().putBoolean("rideNotification", it).apply()
        startRideNotification()
    }

    /** Start or stop RideService to match the toggle. Call from the foreground only. */
    fun startRideNotification() {
        val i = Intent(app, RideService::class.java)
        if (rideNotification) runCatching { app.startForegroundService(i) } else app.stopService(i)
    }

    init {
        if (isEmulator) simulate() else {
            val ble = BleHub(ctx, recorder)
            ble.onEvent = ::handle
            val peer = PeerClient(ctx)
            peer.onLog = recorder::log
            peer.onMessage = ::handle
            peer.onConnected = { up ->
                recorder.log(mapOf("src" to "peer", "ev" to if (up) "linkUp" else "linkDown"))
                model.peerConnected = up
                if (up) pushState(force = true) else applyPeer(null)
            }
            ble.peerStateListener = peer::bluetooth
            this.ble = ble
            this.peer = peer
        }
        main.post(object : Runnable {
            override fun run() { tick(); main.postDelayed(this, 1000) }
        })
    }

    /** Bluetooth permissions granted: start scanning, sharing and the peer link. */
    fun startBluetooth() { ble?.start() }

    // MARK: Intents (UI, paddles)

    fun step(input: HandlebarInput) {
        if (model.localTrainer) { model.press(listOf(input), ble); pushState(force = true) }
        else if (model.peer?.trainer != null) peer?.send(PeerMessage.Command(PeerCommand.Step(input)))
    }

    fun setTrainer(mode: TrainerMode) {
        if (model.localTrainer) { model.setTrainer(mode, ble); pushState(force = true) }
        else if (model.peer?.trainer != null) peer?.send(PeerMessage.Command(PeerCommand.SetTrainer(mode)))
    }

    /** New rider settings: kept here, applied where the trainer is. */
    fun setRider(r: Rider) {
        val c = r.clamped
        model.rider = c
        val m = model.trainerMode
        if (model.localTrainer && m is TrainerMode.Sim) setTrainer(m)
        else if (model.peer?.trainer != null) peer?.send(PeerMessage.Command(PeerCommand.SetRider(c)))
    }

    /** Terrain grade for sim, keeping the gear. No-op outside sim. */
    fun setGrade(g: Int) {
        val m = model.trainerMode
        if (model.localTrainer && m is TrainerMode.Sim) setTrainer(TrainerMode.Sim(g, m.gear).clamped)
        else if (!model.localTrainer && model.peer?.trainer != null) peer?.send(PeerMessage.Command(PeerCommand.SetGrade(g)))
    }

    /** Ride a route from its start (null = stop). The route only drives sim. */
    fun ride(r: Route?) {
        if (r != null) model.workout = null
        model.route = r
        model.routeMeters = 0.0
        routeAt = null
        lastGradeAt = 0.0
        if (r == null) setGrade(0)   // stopped: flat, like finishing
        else if (model.trainerControllable && !TrainerMode.Sim(0).sameKind(model.trainerMode)) setTrainer(TrainerMode.Sim(0))
    }

    /** Start a workout from its beginning (null = stop, ERG holds its target). A workout only drives ERG. */
    fun train(w: Workout?) {
        if (w != null && model.route != null) ride(null)
        model.workout = w
        model.workoutSeconds = 0.0
        workoutAt = null
        lastTarget = null
        lastTargetAt = 0.0
        if (w != null && model.trainerControllable && !TrainerMode.Erg(0).sameKind(model.trainerMode)) {
            lastTarget = w.watts(0.0)
            setTrainer(TrainerMode.Erg(lastTarget ?: model.ergWatts).clamped)
        }
    }

    /** A GPX route or .zwo/.erg/.mrc workout (content:// from Files / share / picker) or orbeat://ride?gpx=<https URL>. */
    fun open(ctx: Context, uri: Uri) {
        val shown = runCatching {
            ctx.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { if (it.moveToFirst()) it.getString(0) else null }
        }.getOrNull()
        val file = (shown ?: uri.lastPathSegment ?: "Route").substringAfterLast('/')
        val ext = file.substringAfterLast('.', "").lowercase()
        val name = file.removeSuffix(".gpx")
        when {
            (uri.scheme == "content" || uri.scheme == "file") && ext in Workout.extensions -> {
                val data = runCatching { ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull()
                val w = data?.let { Workout.parse(it, ext, file.substringBeforeLast('.'), model.ftp) }
                if (w == null) {
                    recorder.log(mapOf("src" to "workout", "ev" to "rejected", "url" to uri.toString(), "bytes" to (data?.size ?: -1)))
                    model.routeError = if (data == null) "Couldn't read $file." else "$file has no power targets to ride."
                    return
                }
                recorder.log(mapOf("src" to "workout", "ev" to "loaded", "name" to w.name, "min" to w.length / 60, "steps" to w.steps.size))
                train(w)
            }
            uri.scheme == "content" || uri.scheme == "file" ->
                load(runCatching { ctx.contentResolver.openInputStream(uri)?.use { it.readBytes() } }.getOrNull(), name, uri)
            uri.scheme == "orbeat" && uri.host == "ride" -> {
                val remote = uri.getQueryParameter("gpx")?.let(Uri::parse)
                if (remote?.scheme != "https") { model.routeError = "Orbeat can't open $uri."; return }
                thread {
                    val data = runCatching {
                        val c = URL(remote.toString()).openConnection() as HttpURLConnection
                        try {
                            if (c.responseCode != 200 || c.contentLengthLong > MAX_GPX) null
                            else c.inputStream.use { it.readNBytes(MAX_GPX + 1) }.takeIf { it.size <= MAX_GPX }
                        } finally { c.disconnect() }
                    }.getOrNull()
                    val remoteName = (remote.lastPathSegment ?: "Route").removeSuffix(".gpx")
                    main.post { load(data, remoteName, remote) }
                }
            }
            else -> model.routeError = "Orbeat can't open $uri."
        }
    }

    private fun load(data: ByteArray?, name: String, uri: Uri) {
        val r = data?.let { Route.gpx(it, name) }
        if (r == null) {
            recorder.log(mapOf("src" to "route", "ev" to "rejected", "url" to uri.toString(), "bytes" to (data?.size ?: -1)))
            model.routeError = if (data == null) "Couldn't download or read $name." else "$name has no elevation to ride."
            return
        }
        recorder.log(mapOf("src" to "route", "ev" to "loaded", "name" to r.name, "km" to r.length / 1000, "points" to r.dist.size))
        ride(r)
    }

    /** Clock of the session running here or on the peer. */
    val recording: SessionClock? get() = store.clock ?: model.peer?.recording

    fun startSession() {
        if (recording != null) return
        store.start()
        pushState(force = true)
    }

    fun continueSession(s: Session) {
        if (recording != null) return
        store.resume(s)
        pushState(force = true)
    }

    fun setPaused(paused: Boolean) {
        if (store.active != null) { store.setPaused(paused); pushState(force = true) }
        else if (model.peer?.recording != null) peer?.send(PeerMessage.Command(PeerCommand.PauseSession(paused)))
    }

    fun stopSession() {
        if (store.active != null) { store.stop(); pushState(force = true) }
        else if (model.peer?.recording != null) peer?.send(PeerMessage.Command(PeerCommand.StopSession))
    }

    // MARK: Plumbing

    private fun handle(e: SensorEvent) {
        if (e is SensorEvent.Handlebar) e.inputs.forEach(::step) else model.apply(e, ble)
        tick()
    }

    private fun handle(m: PeerMessage) {
        when (m) {
            is PeerMessage.State -> { applyPeer(m.state); store.tick(model) }
            is PeerMessage.Command -> when (val c = m.command) {
                is PeerCommand.Step -> if (model.localTrainer) step(c.input)
                is PeerCommand.SetTrainer -> if (model.localTrainer) setTrainer(c.mode)
                is PeerCommand.SetRider -> setRider(c.rider)
                is PeerCommand.SetGrade -> if (model.localTrainer && model.route == null) setGrade(c.grade)   // own route wins
                PeerCommand.StopSession -> if (store.active != null) stopSession()
                is PeerCommand.PauseSession -> if (store.active != null) setPaused(c.paused)
            }
        }
    }

    /** Peer state in; if that hands us the trainer, hold its last target. */
    private fun applyPeer(s: PeerState?) {
        val drove = model.localTrainer
        model.apply(s)
        val m = model.trainerMode
        if (!drove && model.localTrainer && m != null) setTrainer(m)
    }

    private fun tick() {
        model.checkFresh()
        store.tick(model)
        followRoute()
        followWorkout()
        pushState()
        alert()
    }

    /** While over threshold, buzz every `vibrateEvery` s: vibrate in the foreground, else a notification. */
    private fun alert() {
        if (!model.overThreshold || vibrateEvery <= 0 || now() - lastBuzz < vibrateEvery) return
        lastBuzz = now()
        if (foreground) {
            app.getSystemService(VibratorManager::class.java)?.defaultVibrator
                ?.vibrate(VibrationEffect.createPredefined(VibrationEffect.EFFECT_DOUBLE_CLICK))
        } else {
            app.getSystemService(NotificationManager::class.java).notify(2, Notification.Builder(app, RideService.ALERTS)
                .setSmallIcon(R.drawable.ic_heart)
                .setContentTitle("Heart rate high")
                .setContentText("${model.bpm} bpm — over your ${model.threshold} bpm limit")
                .setContentIntent(RideService.openApp(app))
                .setAutoCancel(true)
                .build())
        }
    }

    /**
     * Route mode: advance at road-model speed, send the grade when it changes
     * by ≥ 0.1 %, at most once a second. Paused outside sim and without fresh
     * power. Flat once finished.
     */
    private fun followRoute() {
        val route = model.route
        val m = model.trainerMode
        if (route == null || m !is TrainerMode.Sim) { routeAt = null; return }
        val t = now()
        val v = model.speedKmh
        val at = routeAt
        if (at != null && v != null && t - model.powerAt < RideModel.DIRECT_WINDOW) {
            model.routeMeters = min(route.length, model.routeMeters + v / 3.6 * min(t - at, 5.0))
        }
        routeAt = t
        val target = if (model.routeMeters < route.length) route.grade(model.routeMeters) else 0
        if (abs(target - m.grade) >= 10 && t - lastGradeAt >= 1) {
            lastGradeAt = t
            setGrade(target)
        }
    }

    /**
     * Workout mode, like a route: the clock runs while fresh power arrives;
     * the ERG target goes out when it changes, at most once a second. A
     * manual ±5 W holds until the next change. Paused outside ERG.
     */
    private fun followWorkout() {
        val w = model.workout
        if (w == null || model.trainerMode !is TrainerMode.Erg) { workoutAt = null; return }
        val t = now()
        val at = workoutAt
        if (at != null && t - model.powerAt < RideModel.DIRECT_WINDOW) {
            model.workoutSeconds = min(w.length, model.workoutSeconds + min(t - at, 5.0))
        }
        workoutAt = t
        val target = w.watts(model.workoutSeconds) ?: return
        if (target == lastTarget || t - lastTargetAt < 1) return
        lastTarget = target
        lastTargetAt = t
        setTrainer(TrainerMode.Erg(target).clamped)
    }

    private fun pushState(force: Boolean = false) {
        val p = peer ?: return
        if (!p.connected || (!force && now() - lastPush < 0.9)) return
        lastPush = now()
        p.send(PeerMessage.State(model.directState(store.clock)))
    }

    /** No Bluetooth on the emulator: fake a ride so every screen has data. */
    private fun simulate() {
        model.setLive(true, "Simulated ride")
        model.localTrainer = true
        model.trainerControllable = true
        model.trainerMode = TrainerMode.Sim(model.grade, model.gear)
        var bpm = 128.0
        var watts = 210.0
        main.post(object : Runnable {
            override fun run() {
                bpm = min(174.0, max(96.0, bpm + Random.nextDouble(-4.0, 5.0)))
                watts = min(340.0, max(140.0, watts + Random.nextDouble(-14.0, 14.0)))
                model.ingest(bpm.toInt())
                model.showPower(watts.toInt(), Random.nextInt(84, 97))
                main.postDelayed(this, 1100)
            }
        })
    }

    companion object {
        const val MAX_GPX = 20_000_000
        val isEmulator: Boolean get() = Build.FINGERPRINT.startsWith("generic") || Build.HARDWARE in setOf("ranchu", "goldfish")
    }
}
