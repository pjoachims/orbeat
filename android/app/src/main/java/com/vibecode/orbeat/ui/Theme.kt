package com.vibecode.orbeat.ui

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.Icon
import androidx.compose.material3.LocalContentColor
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Typography
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.produceState
import androidx.compose.runtime.withFrameMillis
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipRect
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.vibecode.orbeat.core.HandlebarInput
import com.vibecode.orbeat.core.Route
import com.vibecode.orbeat.core.Workout
import com.vibecode.orbeat.core.TrainerMode
import com.vibecode.orbeat.model.RideModel
import java.util.Locale
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

// Same look as the Apple apps: one brand red, zone as the only other signal
// color, tight numerals, quiet labels.

val OrbeatRed = Color(0xFFFF375F)
val Background = Color(0xFF0B0B0F)
val Yellow = Color(0xFFFFD60A)

/** Zone palette, cool → hot. Peak is the brand red. */
fun zoneColor(bpm: Int) = when {
    bpm < 60 -> Color(0xFF7FA6FF)    // Resting
    bpm < 100 -> Color(0xFF4DD97B)   // Fat Burn
    bpm < 140 -> Color(0xFFFFB020)   // Cardio
    else -> OrbeatRed                // Peak
}

val Blue = Color(0xFF0A84FF)     // iOS tint
val Green = Color(0xFF30D158)
val Separator = Color(0xFF545458).copy(alpha = 0.6f)

@Composable
fun OrbeatTheme(content: @Composable () -> Unit) = MaterialTheme(
    colorScheme = darkColorScheme(primary = Blue, background = Background, surface = Background,
        onSurface = Color.White, onBackground = Color.White, surfaceContainer = Color(0xFF1C1C1E),
        surfaceContainerHigh = Color(0xFF2C2C2E)),
    // iOS body: 17 pt, no extra tracking (Material's 0.5 sp reads wide).
    typography = Typography(bodyLarge = TextStyle(fontSize = 17.sp, lineHeight = 22.sp, letterSpacing = 0.sp)),
) { CompositionLocalProvider(LocalContentColor provides Color.White, content = content) }

private val LabelGrey = Color(0xFFEBEBF5)   // iOS secondary/tertiary label base
val secondary = LabelGrey.copy(alpha = 0.6f)
val tertiary = LabelGrey.copy(alpha = 0.3f)
val faint = Color.White.copy(alpha = 0.06f)
val Mono = TextStyle(fontFeatureSettings = "tnum")   // tabular digits

fun fmt(f: String, vararg a: Any?) = String.format(Locale.US, f, *a)

fun clock(t: Double): String {
    val s = t.toInt()
    return if (s >= 3600) fmt("%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) else fmt("%d:%02d", s / 60, s % 60)
}

/** Tile background shared by metrics, stepper, route and session bar. */
fun Modifier.tile(padding: Dp = 12.dp) = clip(RoundedCornerShape(12.dp)).background(faint).padding(padding)

/** Small uppercase tracking label above a value. */
@Composable
fun Eyebrow(text: String) = Text(text.uppercase(), fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
    letterSpacing = 1.sp, color = secondary, maxLines = 1)

/** Heart that beats at the actual heart rate (quick systole, slow relax). Still without signal. */
@Composable
fun BeatingHeart(bpm: Int, live: Boolean, size: Dp, color: Color) {
    val mod = Modifier.size(size)
    if (!live || bpm <= 0) { Icon(Icons.Filled.Favorite, null, mod.alpha(0.5f), tint = color); return }
    // Phase from the frame clock, like iOS: a new bpm changes the period without restarting the beat.
    val ms by produceState(0L) { while (true) withFrameMillis { value = it } }
    val period = 60_000f / bpm
    val phase = ms % period / period
    val s = if (phase < 0.12f) phase / 0.12f else max(0f, 1 - (phase - 0.12f) / 0.4f)
    Icon(Icons.Filled.Favorite, null, mod.scale(1 + 0.13f * s), tint = color)
}

/** Pulsing "LIVE" dot; grey static "OFFLINE" when the signal is stale. */
@Composable
fun LiveDot(live: Boolean) {
    val a by rememberInfiniteTransition(label = "live").animateFloat(1f, 0.25f,
        infiniteRepeatable(tween(670), RepeatMode.Reverse), label = "a")
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(5.dp)) {
        Box(Modifier.size(5.dp).alpha(if (live) a else 0.6f).background(if (live) OrbeatRed else secondary, CircleShape))
        Text(if (live) "LIVE" else "OFFLINE", fontSize = 10.sp, fontWeight = FontWeight.SemiBold,
            letterSpacing = 0.8.sp, color = secondary)
    }
}

/** Recent BPM: area + line + leading dot, auto-ranged so a hard ride never clips. */
@Composable
fun Sparkline(history: List<RideModel.Sample>, tint: Color, modifier: Modifier) = Canvas(modifier) {
    if (history.isEmpty()) return@Canvas
    val n = max(history.size - 1, 1)
    val vals = history.map { it.bpm.toFloat() }
    val minV = vals.min(); val maxV = vals.max()
    val span = max(maxV - minV, 16f)
    val lo = (minV + maxV) / 2 - span / 2 - 2
    val hi = (minV + maxV) / 2 + span / 2 + 2
    val pts = vals.mapIndexed { i, v -> Offset(i.toFloat() / n * size.width, size.height - (v - lo) / (hi - lo) * size.height) }
    val line = Path().apply { moveTo(pts[0].x, pts[0].y); pts.drop(1).forEach { lineTo(it.x, it.y) } }
    val area = Path().apply { addPath(line); lineTo(size.width, size.height); lineTo(0f, size.height); close() }
    drawPath(area, Brush.verticalGradient(listOf(tint.copy(alpha = 0.22f), Color.Transparent)))
    drawPath(line, tint, style = Stroke(1.75.dp.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    drawCircle(tint.copy(alpha = 0.22f), 6.5.dp.toPx(), pts.last())
    drawCircle(tint, 2.75.dp.toPx(), pts.last())
}

/** Label-over-value metric. Units live in the label so the number stays clean. */
@Composable
fun MetricTile(label: String, value: String, modifier: Modifier = Modifier, valueSize: Int = 22, padding: Dp = 12.dp) =
    Column(modifier.tile(padding), verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Eyebrow(label)
        Text(value, fontSize = valueSize.sp, fontWeight = FontWeight.SemiBold, style = Mono,
            letterSpacing = (-0.5).sp, maxLines = 1)
    }

/** Equal-width segmented choice. selected = -1: none. */
@Composable
fun Segmented(labels: List<String>, selected: Int, onSelect: (Int) -> Unit) =
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(faint).padding(2.dp)) {
        labels.forEachIndexed { i, l ->
            Box(Modifier.weight(1f).clip(RoundedCornerShape(7.dp))
                .background(if (i == selected) Color.White.copy(alpha = 0.16f) else Color.Transparent)
                .clickable { onSelect(i) }.padding(vertical = 6.dp), contentAlignment = Alignment.Center) {
                Text(l, fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
            }
        }
    }

@Composable
fun StepButton(symbol: String, action: () -> Unit) = StepButton(true, action) { Text(symbol, fontSize = 17.sp, fontWeight = FontWeight.Bold) }

@Composable
fun StepButton(enabled: Boolean, action: () -> Unit, content: @Composable () -> Unit) =
    Box(Modifier.size(width = 36.dp, height = 30.dp).alpha(if (enabled) 1f else 0.3f).clip(RoundedCornerShape(8.dp))
        .background(Color.White.copy(alpha = 0.1f)).clickable(enabled, onClick = action), contentAlignment = Alignment.Center) { content() }

@Composable
private fun StepRow(eyebrow: String, value: String, onMinus: () -> Unit, onPlus: () -> Unit) =
    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Eyebrow(eyebrow)
            Text(value, fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
        }
        StepButton("−", onMinus)
        StepButton("+", onPlus)
    }

/** Kind markers only: the trainer owner resumes each kind's last target. */
private val kinds = listOf("Sim" to TrainerMode.Sim(0), "ERG" to TrainerMode.Erg(120))

/** Trainer target with − / + (same policy as the paddles), a hill stepper in sim, Sim / ERG switch. */
@Composable
fun TrainerStepper(mode: TrainerMode?, onStep: (HandlebarInput) -> Unit, onSet: (TrainerMode) -> Unit, hill: Boolean) =
    Column(Modifier.fillMaxWidth().tile(14.dp), verticalArrangement = Arrangement.spacedBy(10.dp)) {
        StepRow("Trainer · ±${mode?.stepLabel?.drop(1) ?: ""}",
            mode?.let { if (it is TrainerMode.Sim) "Gear ${it.gear}" else it.label } ?: "Ready",
            { onStep(HandlebarInput.ShiftDown) }, { onStep(HandlebarInput.ShiftUp) })
        if (hill && mode is TrainerMode.Sim) {
            StepRow("Hill · ±0.5 %", fmt("%.1f %%", mode.grade / 100.0),
                { onSet(TrainerMode.Sim(mode.grade - 50, mode.gear).clamped) },
                { onSet(TrainerMode.Sim(mode.grade + 50, mode.gear).clamped) })
        }
        Segmented(kinds.map { it.first }, kinds.indexOfFirst { it.second.sameKind(mode) }) { onSet(kinds[it].second) }
    }

/** "Mac" capsule while the peer link is up. */
@Composable
fun PeerBadge(label: String) = Text("⇄ $label", fontSize = 10.sp, fontWeight = FontWeight.SemiBold, color = secondary,
    modifier = Modifier.clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).padding(horizontal = 7.dp, vertical = 3.dp))

/** Zone chip: dot + name, tinted by zone; neutral without signal. */
@Composable
fun ZoneChip(m: RideModel) {
    val live = m.hasData && m.isFresh
    val color = if (live) zoneColor(m.bpm) else secondary
    Row(Modifier.clip(CircleShape).background(color.copy(alpha = if (live) 0.14f else 0.08f))
        .padding(horizontal = 10.dp, vertical = 5.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
        Box(Modifier.size(6.dp).background(color, CircleShape))
        Text(if (m.hasData) (if (live) m.zone else "Signal lost") else "No device",
            fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = color)
    }
}

/** Route mode: name, progress, current grade, elevation profile with the ridden part filled. */
@Composable
fun RouteCard(route: Route, meters: Double, onStop: () -> Unit) =
    Column(Modifier.fillMaxWidth().tile(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { Eyebrow("Route · ${route.name}") }
            Icon(Icons.Filled.Close, "Stop riding this route", Modifier.size(18.dp).clickable(onClick = onStop), tint = secondary)
        }
        Row {
            Text(fmt("%.1f / %.1f km", meters / 1000, route.length / 1000), Modifier.weight(1f),
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
            Text(if (meters >= route.length) "Finished" else fmt("%.1f %%", route.grade(meters) / 100.0),
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
        }
        val base = Color.White.copy(alpha = 0.12f)
        Canvas(Modifier.fillMaxWidth().height(44.dp)) {
            val n = 160
            val samples = (0..n).map { route.elevation(route.length * it / n) }
            val lo = samples.min(); val span = max(20.0, samples.max() - lo)   // ≥ 20 m: flat stays flat
            fun point(i: Int) = Offset(size.width * i / n, size.height * (1 - ((samples[i] - lo) / span).toFloat() * 0.9f))
            fun area(end: Int) = Path().apply {
                moveTo(0f, size.height)
                for (i in 0..end) point(i).let { lineTo(it.x, it.y) }
                lineTo(point(end).x, size.height); close()
            }
            val at = min(n, (meters / max(1.0, route.length) * n).roundToInt())
            drawPath(area(n), base)
            drawPath(area(at), OrbeatRed.copy(alpha = 0.55f))
            drawCircle(OrbeatRed, 4.dp.toPx(), point(at))
        }
        Text(fmt("%.0f m climbing", route.climb), fontSize = 11.sp, color = tertiary)
    }

/** Workout mode: name, time, current target and the power profile with the ridden part filled in. */
@Composable
fun WorkoutCard(workout: Workout, seconds: Double, onStop: () -> Unit) =
    Column(Modifier.fillMaxWidth().tile(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.weight(1f)) { Eyebrow("Workout · ${workout.name}") }
            Icon(Icons.Filled.Close, "Stop this workout", Modifier.size(18.dp).clickable(onClick = onStop), tint = secondary)
        }
        Row {
            Text("${clock(seconds)} / ${clock(workout.length)}", Modifier.weight(1f),
                fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
            Text(workout.watts(seconds)?.let { "$it W" } ?: "Finished", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
        }
        val base = Color.White.copy(alpha = 0.12f)
        Canvas(Modifier.fillMaxWidth().height(44.dp)) {
            val total = max(1.0, workout.length)
            val top = max(1, workout.steps.maxOf { max(it.from, it.to) }).toFloat()
            fun y(w: Int) = size.height * (1 - w / top * 0.9f)
            var t = 0.0
            val p = Path().apply {
                moveTo(0f, size.height)
                for (s in workout.steps) {
                    lineTo((size.width * t / total).toFloat(), y(s.from))
                    t += s.seconds
                    lineTo((size.width * t / total).toFloat(), y(s.to))
                }
                lineTo(size.width, size.height); close()
            }
            drawPath(p, base)
            clipRect(right = (size.width * min(1.0, seconds / total)).toFloat()) { drawPath(p, OrbeatRed.copy(alpha = 0.55f)) }
        }
    }
