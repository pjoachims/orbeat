package com.vibecode.orbeat.ui

import android.Manifest
import android.content.Intent
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.SystemBarStyle
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.vibecode.orbeat.OrbeatApp
import com.vibecode.orbeat.model.AppCore

class MainActivity : ComponentActivity() {
    private val core get() = (application as OrbeatApp).core

    private val permissions = registerForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) {
        core.startBluetooth()          // no-op if Bluetooth was denied
        core.startRideNotification()   // the connectedDevice service needs those permissions first
    }

    override fun onCreate(saved: Bundle?) {
        super.onCreate(saved)
        enableEdgeToEdge(SystemBarStyle.dark(android.graphics.Color.TRANSPARENT), SystemBarStyle.dark(android.graphics.Color.TRANSPARENT))
        setContent { OrbeatTheme { Root(core) } }
        if (saved != null) return   // rotation: permissions asked and intent handled already
        permissions.launch(arrayOf(Manifest.permission.BLUETOOTH_SCAN, Manifest.permission.BLUETOOTH_CONNECT,
            Manifest.permission.BLUETOOTH_ADVERTISE, Manifest.permission.POST_NOTIFICATIONS))
        open(intent)
    }

    override fun onNewIntent(intent: Intent) { super.onNewIntent(intent); open(intent) }
    override fun onStart() { super.onStart(); core.foreground = true }
    override fun onStop() { super.onStop(); core.foreground = false }

    /** .gpx from Files/share, orbeat://ride?gpx= */
    private fun open(i: Intent) { if (i.action == Intent.ACTION_VIEW) i.data?.let { core.open(this, it) } }
}

/** Two tabs (Live, Sessions); settings and a session page on top, closed with Back. */
@Composable
private fun Root(core: AppCore) {
    var tab by rememberSaveable { mutableIntStateOf(0) }
    var settings by rememberSaveable { mutableStateOf(false) }
    var session by rememberSaveable { mutableStateOf<String?>(null) }
    BackHandler(settings || session != null) { settings = false; session = null }
    Box(Modifier.fillMaxSize().background(Color.Black)) {
        when {
            settings -> SettingsScreen(core) { settings = false }
            session != null -> SessionPage(core, session!!) { session = null }
            tab == 0 -> LiveScreen(core) { settings = true }
            else -> SessionsTab(core) { session = it }
        }
        if (!settings && session == null)
            TabBar(tab, { tab = it }, Modifier.align(Alignment.BottomCenter).navigationBarsPadding().padding(bottom = 4.dp))
    }
}
