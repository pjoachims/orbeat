package com.vibecode.orbeat.ui

import android.content.Context
import android.content.Intent
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.RoundRect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.content.FileProvider
import com.vibecode.orbeat.core.Workout
import com.vibecode.orbeat.core.WorkoutPlan
import com.vibecode.orbeat.core.WorkoutPlan.Block
import com.vibecode.orbeat.core.WorkoutPlan.Kind
import java.io.File
import kotlin.math.max
import kotlin.math.min
import kotlin.math.roundToInt

/**
 * Build a workout on the phone: zone-coloured profile on top (tap it to pick a
 * block), one card below editing that block. The draft is kept between
 * visits; Ride hands it to ERG, Share exports a .zwo.
 */
@Composable
fun WorkoutBuilder(riderFtp: Int, back: () -> Unit, ride: (Workout) -> Unit) {
    val ctx = LocalContext.current
    val prefs = remember { ctx.getSharedPreferences("orbeat", Context.MODE_PRIVATE) }
    // An override Settings has caught up with is no override.
    var plan by remember { mutableStateOf((prefs.getString("workoutPlan", null)?.let(WorkoutPlan::decode) ?: WorkoutPlan.sample)
        .let { if (it.ftp == riderFtp) it.copy(ftp = null) else it }) }
    var sel by remember { mutableIntStateOf(0) }
    fun set(p: WorkoutPlan) { plan = p; prefs.edit().putString("workoutPlan", p.json).apply() }
    LaunchedEffect(Unit) { set(plan) }   // keeps a dropped override dropped if Settings moves on
    fun edit(i: Int, f: (Block) -> Block) = set(plan.copy(blocks = plan.blocks.toMutableList().also { it[i] = f(it[i]) }))
    val ftp = plan.ftp ?: riderFtp
    fun watts(f: Double) = (f * ftp).roundToInt()
    /** Back at the rider's FTP drops the override. */
    fun setFtp(w: Int) { val c = min(500, max(50, w)); set(plan.copy(ftp = if (c == riderFtp) null else c)) }
    val empty = plan.blocks.isEmpty()

    Column(Modifier.screen(Background).navigationBarsPadding().imePadding()) {
        Row(Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            BarButton(back) { GlyphIcon(ChevronLeft, Color.White, 20.dp, 2.4.dp) }
            Text("Build Workout", Modifier.weight(1f).padding(start = 4.dp), fontWeight = FontWeight.SemiBold, maxLines = 1)
            Templates(!empty) { set(it); sel = 0 }
            Box(Modifier.alpha(if (empty) 0.3f else 1f)) {
                BarButton({ if (!empty) share(ctx, plan) }) { Icon(Icons.Filled.Share, "Share .zwo", Modifier.size(20.dp)) }
            }
            Box(Modifier.height(44.dp).alpha(if (empty) 0.3f else 1f).clip(CircleShape).background(Color.White.copy(alpha = 0.1f))
                .clickable(!empty) { ride(plan.workout(ftp)) }.padding(horizontal = 16.dp), contentAlignment = Alignment.Center) {
                Text("Ride", color = OrbeatRed, fontWeight = FontWeight.SemiBold)
            }
        }
        Column(Modifier.verticalScroll(rememberScrollState()).padding(horizontal = 16.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(10.dp)) {
            Column(Modifier.fillMaxWidth().tile(14.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                Box {
                    val style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold, color = Color.White)
                    if (plan.name.isEmpty()) Text("Name", style = style.copy(color = tertiary))
                    BasicTextField(plan.name, { set(plan.copy(name = it)) }, Modifier.fillMaxWidth(), singleLine = true,
                        textStyle = style, cursorBrush = SolidColor(Blue))
                }
                Row {
                    Text(clock(plan.length.toDouble()), Modifier.weight(1f), fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
                    Text("${watts(plan.intensity)} W avg · ${plan.tss} TSS", fontSize = 15.sp, fontWeight = FontWeight.SemiBold, style = Mono)
                }
                ZoneProfile(plan, sel, Modifier.fillMaxWidth().padding(top = 4.dp).height(128.dp)) { sel = it }
                Row(Modifier.alpha(if (empty) 0f else 1f)) {
                    for (k in 0..4) {
                        if (k > 0) Spacer(Modifier.weight(1f))
                        Text(clock((plan.length * k / 4 / 60 * 60).toDouble()), fontSize = 10.sp, color = tertiary, style = Mono)
                    }
                }
                Divider(Modifier.padding(top = 4.dp))
                ValueRow("FTP · ±5 W", "$ftp W", if (plan.ftp == null) "from Settings" else "this workout",
                    { setFtp(ftp - 5) }, { setFtp(ftp + 5) }, bottom = 0)
            }
            if (sel in plan.blocks.indices) Editor(plan, sel, ftp, { sel = it }, ::set, ::edit)
            else Column(Modifier.fillMaxWidth().tile(14.dp).padding(vertical = 12.dp),
                horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(12.dp)) {
                Text("No blocks yet", color = secondary)
                Text("Add a block", Modifier.clickable { set(plan.copy(blocks = listOf(Block(Kind.Steady)))); sel = 0 },
                    color = OrbeatRed, fontWeight = FontWeight.SemiBold)
            }
        }
    }
}

@Composable
private fun Editor(plan: WorkoutPlan, i: Int, ftp: Int, select: (Int) -> Unit, set: (WorkoutPlan) -> Unit, edit: (Int, (Block) -> Block) -> Unit) {
    val b = plan.blocks[i]
    fun upd(f: (Block) -> Block) = edit(i, f)
    fun blocks(f: (MutableList<Block>) -> Unit) = set(plan.copy(blocks = plan.blocks.toMutableList().also(f)))
    /** Finer steps for short times: 15 s under 2 min, 30 s under 10, then minutes. */
    fun step(s: Int) = if (s < 120) 15 else if (s < 600) 30 else 60
    @Composable fun TimeRow(label: String, s: Int, put: (Block, Int) -> Block) {
        val st = step(s)
        ValueRow("$label · ±${if (st < 60) "$st s" else "1 min"}", clock(s.toDouble()), null,
            { upd { put(it, max(15, s - st)) } }, { upd { put(it, min(max(7200, s), s + st)) } })
    }
    /** ±5 W at the effective FTP, stored as an FTP fraction. */
    @Composable fun PowerRow(label: String, v: Double, put: (Block, Double) -> Block) {
        val d = 5.0 / ftp
        ValueRow("$label · ±5 W", "${(v * ftp).roundToInt()} W", "${(v * 100).roundToInt()} %",
            { upd { put(it, max(0.25, v - d)) } }, { upd { put(it, min(3.0, v + d)) } })
    }
    Column(Modifier.fillMaxWidth().tile(14.dp)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Box(Modifier.weight(1f)) { Eyebrow("Block ${i + 1} of ${plan.blocks.size} · ${title(plan, i)}") }
            StepButton(i > 0, { select(i - 1) }) { GlyphIcon(ChevronLeft, Color.White, 13.dp, 2.dp) }
            StepButton(i < plan.blocks.size - 1, { select(i + 1) }) { GlyphIcon(ChevronRight, Color.White, 13.dp, 2.dp) }
        }
        Box(Modifier.padding(vertical = 10.dp)) {
            Segmented(Kind.entries.map { it.name }, b.kind.ordinal) { k -> upd { it.asKind(Kind.entries[k]) } }
        }
        when (b.kind) {
            Kind.Steady -> {
                TimeRow("Time", b.seconds) { x, v -> x.copy(seconds = v) }; Divider()
                PowerRow("Power", b.power) { x, v -> x.copy(power = v) }
            }
            Kind.Ramp -> {
                TimeRow("Time", b.seconds) { x, v -> x.copy(seconds = v) }; Divider()
                PowerRow("Start", b.power) { x, v -> x.copy(power = v) }; Divider()
                PowerRow("End", b.powerEnd) { x, v -> x.copy(powerEnd = v) }
            }
            Kind.Intervals -> {
                ValueRow("Repeat", "${b.repeats} ×", null,
                    { upd { it.copy(repeats = max(1, it.repeats - 1)) } }, { upd { it.copy(repeats = min(30, it.repeats + 1)) } })
                Divider(); TimeRow("Work", b.on) { x, v -> x.copy(on = v) }
                Divider(); PowerRow("Work power", b.onPower) { x, v -> x.copy(onPower = v) }
                Divider(); TimeRow("Rest", b.off) { x, v -> x.copy(off = v) }
                Divider(); PowerRow("Rest power", b.offPower) { x, v -> x.copy(offPower = v) }
            }
        }
        Divider()
        Row(Modifier.padding(top = 12.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
            Text("Duplicate", Modifier.clickable { blocks { it.add(i + 1, b) }; select(i + 1) }, fontSize = 14.sp, color = secondary)
            Text("Add after", Modifier.clickable { blocks { it.add(i + 1, Block(Kind.Steady)) }; select(i + 1) }, fontSize = 14.sp, color = secondary)
            Spacer(Modifier.weight(1f))
            Text("Delete", Modifier.clickable { blocks { it.removeAt(i) }; select(max(0, i - 1)) }, fontSize = 14.sp, color = OrbeatRed)
        }
    }
}

private fun title(plan: WorkoutPlan, i: Int): String {
    val b = plan.blocks[i]
    return when {
        b.kind == Kind.Steady -> "Steady"
        b.kind == Kind.Intervals -> "${b.repeats} × Intervals"
        i == 0 && b.power < b.powerEnd -> "Warm-up"
        i == plan.blocks.size - 1 && b.power > b.powerEnd -> "Cool-down"
        else -> "Ramp"
    }
}

/** Templates menu: picking one replaces the plan (and drops an FTP override), asking first unless it's empty. */
@Composable
private fun Templates(ask: Boolean, pick: (WorkoutPlan) -> Unit) {
    var open by remember { mutableStateOf(false) }
    var pending by remember { mutableStateOf<WorkoutPlan?>(null) }
    Box {
        BarButton({ open = true }) { Icon(Icons.Filled.Menu, "Templates", Modifier.size(20.dp)) }
        DropdownMenu(open, { open = false }, shape = RoundedCornerShape(14.dp)) {
            WorkoutPlan.templates.forEach { t -> DropdownMenuItem({ Text(t.name) }, { open = false; if (ask) pending = t else pick(t) }) }
        }
    }
    pending?.let { t ->
        AlertDialog({ pending = null }, title = { Text("Replace this workout?") }, containerColor = Color(0xFF2C2C2E),
            confirmButton = { TextButton({ pick(t); pending = null }) { Text("Replace with ${t.name}", color = OrbeatRed) } },
            dismissButton = { TextButton({ pending = null }) { Text("Cancel", color = Blue) } })
    }
}

/** Write the .zwo to app files and hand it to the share sheet. */
private fun share(ctx: Context, plan: WorkoutPlan) {
    val f = File(File(ctx.filesDir, "share").apply { mkdirs() }, plan.fileName)
    f.writeText(plan.zwo)
    val uri = FileProvider.getUriForFile(ctx, "${ctx.packageName}.files", f)
    ctx.startActivity(Intent.createChooser(Intent(Intent.ACTION_SEND).setType("application/xml")
        .putExtra(Intent.EXTRA_STREAM, uri).addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION), null))
}

@Composable
private fun Divider(modifier: Modifier = Modifier) = Box(modifier.fillMaxWidth().height(0.5.dp).background(Separator))

@Composable
private fun ValueRow(label: String, value: String, sub: String?, minus: () -> Unit, plus: () -> Unit, bottom: Int = 10) =
    Row(Modifier.padding(top = 10.dp, bottom = bottom.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(3.dp)) {
            Eyebrow(label)
            Row(verticalAlignment = Alignment.Bottom, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(value, fontSize = 17.sp, fontWeight = FontWeight.SemiBold, style = Mono)
                if (sub != null) Text(sub, Modifier.padding(bottom = 1.dp), fontSize = 13.sp, fontWeight = FontWeight.Medium, color = secondary, style = Mono)
            }
        }
        StepButton("−", minus)
        StepButton("+", plus)
    }

/** Zwift's power-zone colours: what anyone who rides structured workouts reads. */
fun powerZoneColor(f: Double) = when {
    f < 0.60 -> Color(0xFF8F8F8F)
    f < 0.76 -> Blue
    f < 0.90 -> Green
    f < 1.05 -> Yellow
    f < 1.19 -> Color(0xFFFF9F0A)
    else -> OrbeatRed
}

/**
 * Bars per step in zone colours, ramps as stairs; the picked block at full
 * strength with a bar underneath, the rest dimmed. Tap picks a block.
 */
@Composable
private fun ZoneProfile(plan: WorkoutPlan, selected: Int, modifier: Modifier, onPick: (Int) -> Unit) {
    val text = rememberTextMeasurer()
    val p by rememberUpdatedState(plan)
    val label = TextStyle(fontSize = 9.sp, letterSpacing = 1.sp, color = tertiary)
    Canvas(modifier.pointerInput(Unit) {
        detectTapGestures { o ->
            val t = o.x / size.width * p.length
            var end = 0
            p.blocks.forEachIndexed { i, b -> end += b.length; if (t < end) return@detectTapGestures onPick(i) }
            if (p.blocks.isNotEmpty()) onPick(p.blocks.size - 1)
        }
    }) {
        val total = max(1, plan.length).toFloat()
        val h = size.height - 8.dp.toPx()
        val gap = 1.5.dp.toPx()
        val top = max(1.2, plan.blocks.flatMap { it.steps }.maxOfOrNull { max(it.second, it.third) } ?: 1.0) / 0.92
        fun y(f: Double) = (h - f / top * h).toFloat()
        var x = 0f
        var mark: Pair<Float, Float>? = null
        plan.blocks.forEachIndexed { i, b ->
            val x0 = x
            for ((s, a, e) in b.steps) {
                val w = s / total * size.width
                val n = if (a == e) 1 else min(12, max(2, s / 60))
                for (k in 0 until n) {
                    val q = k.toFloat() / n; val dq = 1f / n
                    val f = a + (e - a) * (q + dq / 2)
                    val u = x + w * q
                    val u1 = x + w * (q + dq) - (if (k == n - 1) gap else 0f)
                    if (u1 <= u) continue
                    val r = CornerRadius(min(3.dp.toPx(), (u1 - u) / 2))
                    drawPath(Path().apply { addRoundRect(RoundRect(u, y(f), u1, h, topLeftCornerRadius = r, topRightCornerRadius = r)) },
                        powerZoneColor(f).copy(alpha = if (i == selected) 1f else 0.35f))
                }
                x += w
            }
            if (i == selected) mark = x0 to x
        }
        drawLine(secondary.copy(alpha = secondary.alpha * 0.5f), Offset(0f, y(1.0)), Offset(size.width, y(1.0)), 1.dp.toPx(),
            pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 4.dp.toPx())))
        val ftp = text.measure("FTP", label)
        drawText(ftp, topLeft = Offset(size.width - ftp.size.width, y(1.0) - 3.dp.toPx() - ftp.size.height))
        mark?.let { (a, b) ->
            drawRoundRect(Color.White, Offset(a, size.height - 3.dp.toPx()), Size(max(0f, b - a - gap), 3.dp.toPx()),
                CornerRadius(1.5.dp.toPx()))
        }
    }
}
