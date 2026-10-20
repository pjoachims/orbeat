package com.vibecode.orbeat.ui

import android.content.Intent
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.IntrinsicSize
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.painter.Painter
import androidx.compose.ui.graphics.vector.rememberVectorPainter
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.vibecode.orbeat.R
import com.vibecode.orbeat.ble.BleHub
import com.vibecode.orbeat.core.Rider
import com.vibecode.orbeat.model.AppCore
import kotlinx.coroutines.delay

// The iOS settings sheet: grouped list on the elevated sheet greys.
private val SheetBg = Color(0xFF1C1C1E)
private val SheetCell = Color(0xFF2C2C2E)

@Composable
private fun Section(header: String? = null, footer: String? = null, rows: List<@Composable () -> Unit>) =
    Group(header, footer, SheetCell, rows)

/** Everything set once per ride or less: sharing, equipment, rider, alert, notification, debug log. */
@Composable
fun SettingsScreen(core: AppCore, back: () -> Unit, build: () -> Unit) {
    val ctx = LocalContext.current
    val m = core.model
    val ble = core.ble
    // ponytail: 1 s tick re-reads ble.discovered / proxy.enabled (not observable); fine for a settings page
    var tick by remember { mutableIntStateOf(0) }
    LaunchedEffect(Unit) { while (true) { delay(1000); tick++ } }
    var scanAll by remember { mutableStateOf(false) }
    val up = core.upload
    var token by remember { mutableStateOf(up.token) }
    var auto by remember { mutableStateOf(up.auto) }
    var status by remember { mutableStateOf("") }
    fun saveToken() { if (token != up.token) up.token = token }
    DisposableEffect(Unit) { onDispose {
        ble?.setScanAll(false)
        saveToken()
        if (up.auto) up.run(core.store.past)
    } }
    val pickRoute = rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
        if (uri != null) { back(); core.open(ctx, uri) }
    }
    fun rider(r: Rider) = core.setRider(r)

    Column(Modifier.screen(SheetBg).verticalScroll(rememberScrollState()).navigationBarsPadding().imePadding()
        .padding(start = 16.dp, end = 16.dp, top = 24.dp, bottom = 24.dp)) {
        tick   // read: recompose each tick
        Box(Modifier.fillMaxWidth()) {
            LargeTitle("Settings")
            Box(Modifier.align(Alignment.CenterEnd)) { BarButton(back) { Icon(Icons.Filled.Close, "Close", Modifier.size(20.dp)) } }
        }
        if (ble != null) {
            if (ble.proxy.available) {
                Section(footer = "Other devices (Zwift, Apple TV, a Mac) can pair with this phone as a heart-rate/power sensor.", rows = listOf {
                    ToggleCell("Share sensors via Bluetooth", ble.proxy.enabled) { ble.proxy.enabled = it; tick++ }
                })
            }
            val sensors = ble.discovered.filter { it.isSensor }
            Section("Equipment", m.bleStatus, buildList {
                if (sensors.isEmpty()) add { Cell { Text("Scanning for heart-rate straps and power meters…", color = secondary) } }
                sensors.forEach { add { DeviceRow(ble, it, ble.isKnown(it), ble.isConnected(it)) { tick++ } } }
                add { ToggleCell("Show all nearby devices", scanAll) { scanAll = it; ble.setScanAll(it) } }
            })
            if (scanAll) {
                val others = ble.discovered.filter { !it.isSensor }
                Section("All nearby devices", rows = if (others.isEmpty()) listOf { Cell { Text("Searching everything nearby…", color = secondary) } }
                    else others.map { { DeviceRow(ble, it, ble.isKnown(it), ble.isConnected(it)) { tick++ } } })
            }
        }
        Section("Rider", "Sent to the trainer for sim and virtual gears, like Zwift. Trainer Difficulty scales climbs; descents are halved first.", listOf(
            { Cell { Text("Rider ${m.rider.riderKg} kg", Modifier.weight(1f))
                IosStepper({ rider(m.rider.copy(riderKg = maxOf(Rider.riderRange.first, m.rider.riderKg - 1))) },
                    { rider(m.rider.copy(riderKg = minOf(Rider.riderRange.last, m.rider.riderKg + 1))) }) } },
            { Cell { Text("Bike ${m.rider.bikeKg} kg", Modifier.weight(1f))
                IosStepper({ rider(m.rider.copy(bikeKg = maxOf(Rider.bikeRange.first, m.rider.bikeKg - 1))) },
                    { rider(m.rider.copy(bikeKg = minOf(Rider.bikeRange.last, m.rider.bikeKg + 1))) }) } },
            { PickerCell("Trainer Difficulty", Rider.difficulties, m.rider.difficulty, { "$it %" }) { rider(m.rider.copy(difficulty = it)) } },
            { Cell { Text("FTP ${m.ftp} W", Modifier.weight(1f))
                IosStepper({ m.ftp = maxOf(50, m.ftp - 5) }, { m.ftp = minOf(500, m.ftp + 5) }) } },
        ))
        // Three tiles in one row; the two workout ones share a card.
        Section(footer = "GPX rides a track's hills in sim. Workouts (.zwo, .erg, .mrc) run ERG at your FTP. Or build your own right here.", rows = listOf {
            val pick = { pickRoute.launch(arrayOf("*/*")) }
            Row(Modifier.height(IntrinsicSize.Min).background(SheetBg), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                Tile(painterResource(R.drawable.ic_route), "Ride GPX", Modifier.weight(1f).clip(RoundedCornerShape(26.dp)), pick)
                Row(Modifier.weight(2f).clip(RoundedCornerShape(26.dp))) {
                    Tile(painterResource(R.drawable.ic_workout), "Ride Workout", Modifier.weight(1f), pick)
                    Box(Modifier.width(0.5.dp).fillMaxHeight().background(SheetCell).padding(vertical = 12.dp).background(Separator))
                    Tile(rememberVectorPainter(Icons.Filled.Edit), "Build Workout", Modifier.weight(1f), build)
                }
            }
        })
        Section("Heart-rate alert", "Vibrates while you're over the limit; a notification when Orbeat is in the background.", listOf(
            { Cell {
                Text("Alert at", Modifier.weight(1f))
                Box(Modifier.width(60.dp)) {
                    val style = TextStyle(fontSize = 17.sp, textAlign = TextAlign.End, color = Color.White, fontFeatureSettings = "tnum")
                    if (m.threshold == 0) Text("off", Modifier.matchParentSize(), style = style.copy(color = tertiary))
                    BasicTextField(if (m.threshold == 0) "" else "${m.threshold}",
                        { m.threshold = it.filter(Char::isDigit).take(3).toIntOrNull() ?: 0 },
                        singleLine = true, textStyle = style, cursorBrush = SolidColor(Blue),
                        keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number))
                }
                Text("bpm", color = secondary)
            } },
            { PickerCell("Vibrate", listOf(0, 5, 10, 30, 60), core.vibrateEvery, { if (it == 0) "Off" else "Every $it s" }) { core.vibrateEvery = it } },
        ))
        Section(footer = "Live heart rate and power in the notification shade; keeps Bluetooth running in the background.", rows = listOf {
            ToggleCell("Ride notification", core.rideNotification) { core.rideNotification = it }
        })
        Section("Health backend", "Finished rides are sent to your own server (POST <url>/rides).", buildList {
            add { FieldCell("https://…", up.url, KeyboardType.Uri) { up.url = it } }
            add { FieldCell("Token", token, KeyboardType.Password, secret = true) { token = it } }
            add { Cell {
                Text("Test", Modifier.clickable { saveToken(); status = "Testing…"; up.test { status = it } }, color = Blue)
                Text("Upload", Modifier.padding(start = 8.dp).clickable {
                    saveToken(); status = "Uploading…"; up.run(core.store.past) { status = it }
                }, color = Blue)
                Spacer(Modifier.weight(1f))
                Text("Auto")
                IosSwitch(auto) { auto = it; up.auto = it }
            } }
            if (status.isNotEmpty()) add { Cell { Text(status, color = secondary) } }
        })
        // Same JSONL as the Mac app (one line per BLE packet, "t" ISO ms).
        Section("Debug", rows = listOf(
            { ToggleCell("Log ride", core.recorder.recording) { core.recorder.recording = it } },
            { Cell({
                val f = core.recorder.file
                if (!f.exists()) f.createNewFile()
                val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
                ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/json")
                    .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null))
            }) { Icon(Icons.Filled.Share, null, tint = Blue); Text("Share orbeat.jsonl", color = Blue) } },
        ))
        if (ble == null) Text("No Bluetooth on the emulator — showing a simulated ride.", Modifier.padding(16.dp), color = secondary)
    }
}

/** One-line text entry, placeholder while empty. */
@Composable
private fun FieldCell(placeholder: String, value: String, type: KeyboardType, secret: Boolean = false, set: (String) -> Unit) = Cell {
    var text by remember { mutableStateOf(value) }
    Box(Modifier.weight(1f)) {
        val style = TextStyle(fontSize = 17.sp, color = Color.White)
        if (text.isEmpty()) Text(placeholder, style = style.copy(color = tertiary))
        BasicTextField(text, { text = it; set(it) }, Modifier.fillMaxWidth(), singleLine = true, textStyle = style,
            cursorBrush = SolidColor(Blue), keyboardOptions = KeyboardOptions(keyboardType = type, autoCorrectEnabled = false),
            visualTransformation = if (secret) PasswordVisualTransformation() else VisualTransformation.None)
    }
}

@Composable
private fun Tile(icon: Painter, label: String, modifier: Modifier, onClick: () -> Unit) =
    Column(modifier.fillMaxHeight().background(SheetCell).clickable(onClick = onClick).padding(horizontal = 4.dp, vertical = 12.dp),
        horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Icon(icon, null, Modifier.size(24.dp), tint = Blue)
        Text(label, color = Blue, fontSize = 13.sp, maxLines = 1)
    }

// known/connected passed in: BleHub isn't snapshot state, so the row would skip the 1 s tick.
@Composable
private fun DeviceRow(ble: BleHub, d: BleHub.Device, known: Boolean, connected: Boolean, changed: () -> Unit) = key(d.bt.address) {
    val row = @Composable {
        Cell({ ble.connect(d); changed() }) {
            when {
                d.isRide -> Text("🎮", Modifier.width(22.dp), textAlign = TextAlign.Center)
                !d.isSensor -> Text("?", Modifier.width(22.dp), color = secondary, textAlign = TextAlign.Center)
                d.isPower -> GlyphIcon(BoltGlyph, Yellow, 20.dp)
                else -> Icon(Icons.Filled.Favorite, null, tint = Color(0xFFFF453A))
            }
            Column(Modifier.weight(1f)) {
                Text(d.name)
                if (known) Text("Auto-connects", fontSize = 12.sp, color = secondary)
            }
            if (connected) Icon(Icons.Filled.CheckCircle, "Connected", tint = Green)
        }
    }
    if (known) Swipe("Forget", { ble.forget(d); changed() }) { row() } else row()
}
