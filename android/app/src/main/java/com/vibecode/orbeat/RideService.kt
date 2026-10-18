package com.vibecode.orbeat

import android.app.Application
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Handler
import android.os.Looper
import com.vibecode.orbeat.model.AppCore
import com.vibecode.orbeat.ui.MainActivity

/** Process-wide core: BLE links must outlive the activity. */
class OrbeatApp : Application() {
    lateinit var core: AppCore; private set

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannels(listOf(
            NotificationChannel(RideService.CHANNEL, "Ride", NotificationManager.IMPORTANCE_LOW),
            NotificationChannel(RideService.ALERTS, "Heart-rate alerts", NotificationManager.IMPORTANCE_HIGH),
        ))
        core = AppCore(this)
    }
}

/**
 * The Live Activity stand-in: an ongoing notification with heart rate and
 * power, which as a connectedDevice foreground service also keeps BLE
 * running while the screen is off.
 */
class RideService : Service() {
    companion object {
        const val CHANNEL = "ride"
        const val ALERTS = "alerts"
        private const val ID = 1
        private const val HIDE = "hide"

        fun openApp(ctx: Context): PendingIntent = PendingIntent.getActivity(ctx, 0,
            Intent(ctx, MainActivity::class.java), PendingIntent.FLAG_IMMUTABLE)
    }

    private val core get() = (application as OrbeatApp).core
    private val main = Handler(Looper.getMainLooper())
    private val update = object : Runnable {
        override fun run() {
            getSystemService(NotificationManager::class.java).notify(ID, build())
            main.postDelayed(this, 2000)
        }
    }

    override fun onBind(i: Intent?) = null

    override fun onStartCommand(i: Intent?, flags: Int, startId: Int): Int {
        if (i?.action == HIDE) { core.rideNotification = false; return START_NOT_STICKY }   // stops us
        // Throws without Bluetooth permission or when started from the background.
        if (runCatching { startForeground(ID, build(), ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE) }.isFailure) {
            stopSelf()
            return START_NOT_STICKY
        }
        main.removeCallbacks(update)
        main.postDelayed(update, 2000)
        return START_NOT_STICKY
    }

    override fun onDestroy() { main.removeCallbacks(update) }

    private fun build(): Notification {
        val m = core.model
        val power = listOfNotNull(m.displayWatts?.let { "$it W" }, m.displayCadence?.let { "$it rpm" }).joinToString(" · ")
        val hide = PendingIntent.getService(this, 0, Intent(this, RideService::class.java).setAction(HIDE), PendingIntent.FLAG_IMMUTABLE)
        return Notification.Builder(this, CHANNEL)
            .setSmallIcon(R.drawable.ic_heart)
            .setContentTitle(if (m.isFresh && m.hasData) "${m.bpm} bpm" + if (m.overThreshold) " — over limit" else "" else "Orbeat")
            .setContentText(power.ifEmpty { m.bleStatus })
            .setContentIntent(openApp(this))
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .addAction(Notification.Action.Builder(null, "Hide", hide).build())
            .build()
    }
}
