package com.vibecode.orbeat.ui

import android.content.Context
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vibecode.orbeat.core.Curve
import com.vibecode.orbeat.core.now
import com.vibecode.orbeat.model.AppCore
import com.vibecode.orbeat.model.Session
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

private fun date(t: Double, pattern: String) = SimpleDateFormat(pattern, Locale.getDefault()).format(Date((t * 1000).toLong()))

/** Sessions tab: week totals, the live session bar, then history. */
@Composable
fun SessionsTab(core: AppCore, open: (String) -> Unit) {
    val store = core.store
    val week = store.past.filter { it.start > now() - 7 * 86400 }
    val weekBPM = week.mapNotNull { it.avgBPM }
    // A continued session shows as the live one, not also as history.
    val saved = store.past.filter { it.id != store.active?.id }
    // ponytail: plain scroll, not lazy; history is a few dozen rows
    Column(Modifier.screen(Color.Black).verticalScroll(rememberScrollState()).navigationBarsPadding()
        .padding(start = 16.dp, end = 16.dp, bottom = TabBarSpace + 16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        LargeTitle("Sessions")
        Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            MetricTile("This week", clock(week.sumOf { it.duration }), Modifier.weight(1f))
            MetricTile("Sessions", "${week.size}", Modifier.weight(1f))
            MetricTile("Avg bpm", if (weekBPM.isEmpty()) "––" else "${weekBPM.sum() / weekBPM.size}", Modifier.weight(1f))
        }
        SessionBar(core)
        store.active?.let { a ->
            Group(rows = listOf {
                Cell({ open(a.id) }) { GlyphIcon(EcgGlyph, Blue, 22.dp); Text("Live charts", Modifier.weight(1f)); Chevron() }
            })
        }
        Group("History", rows = if (saved.isEmpty()) listOf { Cell { Text("No sessions yet.", color = secondary) } }
            else saved.map { s -> {
                key(s.id) {
                    Swipe("Delete", { store.delete(s) }) {
                        Cell({ open(s.id) }) {
                            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(4.dp)) {
                                Text(date(s.start, "EEEE d MMM, HH:mm"))
                                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                                    Text(clock(s.duration), fontSize = 13.sp, color = secondary, style = Mono)
                                    s.avgBPM?.let {
                                        Spacer(Modifier.width(8.dp))
                                        Icon(Icons.Filled.Favorite, null, Modifier.size(12.dp), tint = secondary)
                                        Text("$it", fontSize = 13.sp, color = secondary, style = Mono)
                                    }
                                    s.avgWatts?.let {
                                        Spacer(Modifier.width(8.dp))
                                        GlyphIcon(BoltGlyph, secondary, 12.dp)
                                        Text("$it", fontSize = 13.sp, color = secondary, style = Mono)
                                    }
                                }
                            }
                            Chevron()
                        }
                    }
                }
            } })
    }
}

/** One session: live charts while it records, else the saved one with Continue. */
@Composable
fun SessionPage(core: AppCore, id: String, back: () -> Unit) {
    val store = core.store
    val active = store.active?.takeIf { it.id == id }
    val s = active ?: store.past.firstOrNull { it.id == id }
    if (s == null) { LaunchedEffect(id) { back() }; return }   // stopped without samples, or deleted
    // Like iOS: the live page closes when its session stops, rather than turning into the saved one.
    var wasActive by remember { mutableStateOf(false) }
    if (active != null) wasActive = true else if (wasActive) { LaunchedEffect(Unit) { back() }; return }
    Column(Modifier.screen(Color.Black).navigationBarsPadding()) {
        Box(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp)) {
            Box(Modifier.align(Alignment.CenterStart)) { BarButton(back) { GlyphIcon(ChevronLeft, Color.White, 20.dp, 2.4.dp) } }
            Text(if (active != null) "Recording · ${clock(store.elapsed)}" else date(s.start, "d MMM yyyy, HH:mm"),
                Modifier.align(Alignment.Center), fontWeight = FontWeight.SemiBold, maxLines = 1)
            if (active == null && core.recording == null)
                Box(Modifier.align(Alignment.CenterEnd)) { BarButton({ core.continueSession(s) }) { RecordIcon(size = 20.dp) } }
        }
        SessionDetail(s)
    }
}

/** Stats + heart-rate / power over time. */
@Composable
fun SessionDetail(session: Session) {
    val prefs = LocalContext.current.getSharedPreferences("orbeat", Context.MODE_PRIVATE)
    /** Moving-average window in seconds, 0 = raw. */
    var window by remember { mutableFloatStateOf(prefs.getFloat("chartSmoothing", 30f)) }
    val windows = listOf(0f, 10f, 30f, 60f)
    fun curve(metric: (Session.Sample) -> Int?) = Curve.thin(Curve.smooth(
        session.samples.mapNotNull { s -> metric(s)?.let { Curve.Point(s.t, it.toDouble()) } }, window.toDouble()))

    Column(Modifier.verticalScroll(rememberScrollState()).padding(22.dp), verticalArrangement = Arrangement.spacedBy(16.dp)) {
        val tiles = mutableListOf("Time" to clock(session.duration),
            "Avg bpm" to (session.avgBPM?.toString() ?: "––"), "Max bpm" to (session.maxBPM?.toString() ?: "––"))
        if (session.avgWatts != null) tiles += listOf("Avg W" to "${session.avgWatts}", "Max W" to "${session.maxWatts}",
            "km" to fmt("%.1f", session.distanceKm))
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            tiles.chunked(3).forEach { row ->
                Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    row.forEach { (l, v) -> MetricTile(l, v, Modifier.weight(1f)) }
                }
            }
        }
        Segmented(listOf("Raw", "10 s", "30 s", "1 min"), windows.indexOf(window)) {
            window = windows[it]; prefs.edit().putFloat("chartSmoothing", window).apply()
        }
        if (session.bpms.isNotEmpty()) {
            Eyebrow("Heart rate")
            LineChart(remember(session.samples, window) { curve { it.bpm } }, OrbeatRed, includeZero = false)
            Zones(session)
        }
        if (session.wattsAll.isNotEmpty()) {
            Eyebrow("Power")
            LineChart(remember(session.samples, window) { curve { it.watts } }, Yellow, includeZero = true)
        }
    }
}

/** Minutes on x; y auto-ranged, min/max labelled. */
@Composable
private fun LineChart(pts: List<Curve.Point>, color: Color, includeZero: Boolean) {
    if (pts.isEmpty()) return
    val lo = if (includeZero) 0.0 else pts.minOf { it.v }
    val hi = maxOf(pts.maxOf { it.v }, lo + 1)
    val t1 = maxOf(pts.last().t, 1.0)
    Row(Modifier.fillMaxWidth().height(160.dp)) {
        Column(Modifier.fillMaxHeight().padding(end = 6.dp), verticalArrangement = Arrangement.SpaceBetween) {
            Text("${hi.toInt()}", fontSize = 10.sp, color = secondary)
            Text("${lo.toInt()}", fontSize = 10.sp, color = secondary)
        }
        Column(Modifier.weight(1f)) {
            val grid = tertiary
            Canvas(Modifier.weight(1f).fillMaxWidth()) {
                fun at(p: Curve.Point) = Offset((p.t / t1 * size.width).toFloat(), (size.height * (1 - (p.v - lo) / (hi - lo))).toFloat())
                drawLine(grid, Offset(0f, size.height), Offset(size.width, size.height))
                val path = Path().apply { at(pts[0]).let { moveTo(it.x, it.y) }; pts.drop(1).forEach { at(it).let { o -> lineTo(o.x, o.y) } } }
                drawPath(path, color, style = Stroke(2.dp.toPx(), join = StrokeJoin.Round))
            }
            Row { Text("0", Modifier.weight(1f), fontSize = 10.sp, color = secondary); Text("${(t1 / 60).toInt()} min", fontSize = 10.sp, color = secondary) }
        }
    }
}

/** Time-in-zone bar, one segment per zone. */
@Composable
private fun Zones(session: Session) {
    val z = session.zoneSeconds.filter { it.second > 0 }
    fun color(name: String) = zoneColor(when (name) { "Resting" -> 50; "Fat Burn" -> 80; "Cardio" -> 120; else -> 160 })
    Column(verticalArrangement = Arrangement.spacedBy(6.dp)) {
        Row(Modifier.fillMaxWidth().height(10.dp), horizontalArrangement = Arrangement.spacedBy(2.dp)) {
            z.forEach { (name, sec) -> Box(Modifier.weight(sec.toFloat()).fillMaxHeight().clip(RoundedCornerShape(3.dp)).background(color(name))) }
        }
        Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            z.forEach { (name, sec) ->
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    Box(Modifier.size(6.dp).background(color(name), CircleShape))
                    Text("$name ${clock(sec.toDouble())}", fontSize = 12.sp, color = secondary)
                }
            }
        }
    }
}
