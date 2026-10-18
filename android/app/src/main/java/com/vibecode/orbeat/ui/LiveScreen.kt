package com.vibecode.orbeat.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vibecode.orbeat.ble.PeerClient
import com.vibecode.orbeat.core.now
import com.vibecode.orbeat.model.AppCore
import kotlinx.coroutines.delay

@Composable
fun LiveScreen(core: AppCore, openSettings: () -> Unit) {
    val m = core.model
    val live = m.hasData && m.isFresh
    val zone = if (live) zoneColor(m.bpm) else secondary
    // ponytail: no scroll, like iOS; the two flexible spacers absorb the height (route + hill stepper fit a Pixel 9)
    Column(Modifier.screen(Background).navigationBarsPadding().padding(start = 22.dp, end = 22.dp, top = 8.dp, bottom = TabBarSpace)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Text("ORBEAT", Modifier.weight(1f), fontSize = 12.sp, fontWeight = FontWeight.Bold, letterSpacing = 2.2.sp)
            if (m.peerConnected) PeerBadge(PeerClient.PEER_LABEL)
            LiveDot(m.isFresh)
            Icon(Icons.Filled.Settings, "Settings", Modifier.padding(start = 8.dp).size(24.dp).clickable(onClick = openSettings), tint = secondary)
        }
        Text(if (m.hasData) m.sourceName else m.bleStatus, Modifier.padding(top = 3.dp), fontSize = 13.sp,
            color = tertiary, maxLines = 1)
        Spacer(Modifier.weight(1f).heightIn(min = 12.dp))

        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
            Box(Modifier.padding(top = 8.dp)) { BeatingHeart(m.bpm, live, 34.dp, zone) }
            Row(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                Text(m.bpmText, Modifier.alignByBaseline(), fontSize = 116.sp, fontWeight = FontWeight.SemiBold, style = Mono,
                    letterSpacing = (-6).sp, maxLines = 1)
                Text("BPM", Modifier.alignByBaseline(), fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
                    letterSpacing = 0.5.sp, color = secondary)
            }
        }
        ZoneChip(m)
        Sparkline(m.history, zone, Modifier.fillMaxWidth().padding(top = 18.dp).height(84.dp).alpha(if (live) 1f else 0.35f))
        Spacer(Modifier.weight(1f).heightIn(min = 16.dp))

        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MetricTile("Watts", m.displayWatts?.toString() ?: "––", Modifier.weight(1f), 26, 14.dp)
            MetricTile("RPM", m.displayCadence?.toString() ?: "––", Modifier.weight(1f), 26, 14.dp)
            MetricTile("km/h", m.displaySpeedKmh?.let { fmt("%.1f", it) } ?: "––", Modifier.weight(1f), 26, 14.dp)
        }
        m.route?.let { r ->
            Spacer(Modifier.height(8.dp))
            RouteCard(r, m.routeMeters) { core.ride(null) }
        }
        if (m.trainerControllable) {
            Spacer(Modifier.height(8.dp))
            TrainerStepper(m.trainerMode, core::step, core::setTrainer, hill = m.route == null)
        }
        Spacer(Modifier.height(8.dp))
        SessionBar(core)
    }
    m.routeError?.let { err ->
        AlertDialog(onDismissRequest = { m.routeError = null }, title = { Text("Route") }, text = { Text(err) },
            confirmButton = { TextButton({ m.routeError = null }) { Text("OK") } })
    }
}

/** Elapsed clock while a session records here or on the peer (stop works for both); start otherwise. */
@Composable
fun SessionBar(core: AppCore) {
    val rec = core.recording
    var confirmStop by remember { mutableStateOf(false) }
    if (rec == null) {
        Box(Modifier.fillMaxWidth().clip(RoundedCornerShape(12.dp)).background(Color.White.copy(alpha = 0.08f))
            .clickable { core.startSession() }.padding(vertical = 13.dp), contentAlignment = Alignment.Center) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                RecordIcon(); Text("Start session", fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
        return
    }
    var t by remember { mutableDoubleStateOf(now()) }
    LaunchedEffect(Unit) { while (true) { t = now(); delay(1000) } }
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f).tile(14.dp), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Eyebrow(if (rec.isPaused) "Paused"
                else core.store.active?.let { "Session · ${it.samples.size} samples" } ?: "Recording on ${PeerClient.PEER_LABEL}")
            Text(clock(rec.elapsed(t)), fontSize = 22.sp, fontWeight = FontWeight.SemiBold, style = Mono)
        }
        val button = Modifier.clip(RoundedCornerShape(12.dp)).height(64.dp)
        Box(button.background(Color.White.copy(alpha = 0.08f)).clickable { core.setPaused(!rec.isPaused) }
            .padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
            if (rec.isPaused) Icon(Icons.Filled.PlayArrow, "Resume")
            else Text("❚❚", fontSize = 14.sp, fontWeight = FontWeight.Bold)
        }
        Box(button.background(OrbeatRed.copy(alpha = 0.2f)).clickable { confirmStop = true }
            .padding(horizontal = 18.dp), contentAlignment = Alignment.Center) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                Box(Modifier.size(11.dp).clip(RoundedCornerShape(2.dp)).background(OrbeatRed))
                Text("Stop", color = OrbeatRed, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }
    if (confirmStop) AlertDialog(onDismissRequest = { confirmStop = false },
        text = { Text("Stop and save this session?") },
        confirmButton = { TextButton({ confirmStop = false; core.stopSession() }) { Text("Stop session", color = OrbeatRed) } },
        dismissButton = { TextButton({ confirmStop = false }) { Text("Cancel") } })
}
