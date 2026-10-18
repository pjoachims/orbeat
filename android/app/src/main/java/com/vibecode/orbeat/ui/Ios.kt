package com.vibecode.orbeat.ui

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.RowScope
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.Icon
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.SwipeToDismissBox
import androidx.compose.material3.SwipeToDismissBoxValue
import androidx.compose.material3.Text
import androidx.compose.material3.rememberSwipeToDismissBoxState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.CompositionLocalProvider
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.staticCompositionLocalOf
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// iOS look-alikes: SF Symbol stand-ins, inset-grouped list, switch, stepper,
// menu picker, swipe action, floating tab bar.

/** Polylines in a unit box (0..1), stroked; `fill` closes and fills the first one. */
class Glyph(val fill: Boolean = false, vararg val lines: List<Pair<Float, Float>>)

val ChartGlyph = Glyph(false, listOf(.12f to .1f, .12f to .88f, .95f to .88f),
    listOf(.28f to .62f, .48f to .38f, .66f to .55f, .9f to .3f))
val EcgGlyph = Glyph(false, listOf(0f to .5f, .3f to .5f, .4f to .2f, .52f to .82f, .62f to .5f, 1f to .5f))
val BoltGlyph = Glyph(true, listOf(.62f to 0f, .15f to .58f, .46f to .58f, .36f to 1f, .85f to .4f, .54f to .4f))
val ChevronRight = Glyph(false, listOf(.38f to .2f, .66f to .5f, .38f to .8f))
val ChevronLeft = Glyph(false, listOf(.62f to .2f, .34f to .5f, .62f to .8f))
val ChevronUpDown = Glyph(false, listOf(.3f to .38f, .5f to .2f, .7f to .38f), listOf(.3f to .62f, .5f to .8f, .7f to .62f))

@Composable
fun GlyphIcon(g: Glyph, tint: Color, size: Dp, weight: Dp = 1.8.dp) = Canvas(Modifier.size(size)) {
    g.lines.forEachIndexed { i, line ->
        val p = Path().apply {
            line.forEachIndexed { j, (x, y) -> if (j == 0) moveTo(x * this@Canvas.size.width, y * this@Canvas.size.height)
                else lineTo(x * this@Canvas.size.width, y * this@Canvas.size.height) }
        }
        if (g.fill && i == 0) { p.close(); drawPath(p, tint) }
        else drawPath(p, tint, style = Stroke(weight.toPx(), cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
}

/** record.circle */
@Composable
fun RecordIcon(tint: Color = Color.White, size: Dp = 18.dp) = Canvas(Modifier.size(size)) {
    drawCircle(tint, this.size.minDimension / 2 - 1.dp.toPx(), style = Stroke(1.7.dp.toPx()))
    drawCircle(tint, this.size.minDimension * 0.2f)
}

/** Full-screen page background, drawn under the status bar. */
fun Modifier.screen(color: Color) = fillMaxSize().background(color).statusBarsPadding()

@Composable
fun LargeTitle(text: String) = Text(text, Modifier.padding(start = 4.dp, top = 12.dp, bottom = 8.dp),
    fontSize = 34.sp, fontWeight = FontWeight.Bold)

private val LocalCell = staticCompositionLocalOf { Color(0xFF1C1C1E) }

/** Inset-grouped section: header, rounded rows split by hairlines, footer. */
@Composable
fun Group(header: String? = null, footer: String? = null, cell: Color = Color(0xFF1C1C1E),
          rows: List<@Composable () -> Unit>) =
    Column(Modifier.padding(top = if (header == null) 20.dp else 12.dp)) {
        header?.let { Text(it, Modifier.padding(start = 16.dp, bottom = 8.dp), fontSize = 17.sp,
            fontWeight = FontWeight.SemiBold, color = secondary) }
        CompositionLocalProvider(LocalCell provides cell) {
            Column(Modifier.fillMaxWidth().clip(RoundedCornerShape(26.dp))) {
                rows.forEachIndexed { i, row ->
                    if (i > 0) Box(Modifier.fillMaxWidth().background(cell).padding(start = 16.dp)) {
                        Box(Modifier.fillMaxWidth().height(0.5.dp).background(Separator))
                    }
                    row()
                }
            }
        }
        footer?.let { Text(it, Modifier.padding(start = 16.dp, end = 16.dp, top = 8.dp), fontSize = 14.sp,
            lineHeight = 18.sp, color = secondary) }
    }

@Composable
fun Cell(onClick: (() -> Unit)? = null, content: @Composable RowScope.() -> Unit) =
    Row(Modifier.fillMaxWidth().background(LocalCell.current).let { if (onClick != null) it.clickable(onClick = onClick) else it }
        .heightIn(min = 52.dp).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp), content = content)

@Composable
fun Chevron() = GlyphIcon(ChevronRight, tertiary, 14.dp, 2.2.dp)

@Composable
fun IosSwitch(on: Boolean, set: (Boolean) -> Unit) = Switch(on, set, thumbContent = {},   // thumbContent: full-size thumb in both states
    colors = SwitchDefaults.colors(checkedThumbColor = Color.White, checkedTrackColor = Green, checkedBorderColor = Color.Transparent,
        uncheckedThumbColor = Color.White, uncheckedTrackColor = Color(0xFF39393D), uncheckedBorderColor = Color.Transparent))

@Composable
fun ToggleCell(label: String, on: Boolean, set: (Boolean) -> Unit) =
    Cell { Text(label, Modifier.weight(1f)); IosSwitch(on, set) }

/** − | + capsule. */
@Composable
fun IosStepper(minus: () -> Unit, plus: () -> Unit) =
    Row(Modifier.height(32.dp).clip(CircleShape).background(Color(0xFF3A3A3C)), verticalAlignment = Alignment.CenterVertically) {
        Box(Modifier.width(46.dp).fillMaxHeight().clickable(onClick = minus), contentAlignment = Alignment.Center) { Text("−", fontSize = 22.sp) }
        Box(Modifier.width(1.dp).height(18.dp).background(Color.White.copy(alpha = 0.2f)))
        Box(Modifier.width(46.dp).fillMaxHeight().clickable(onClick = plus), contentAlignment = Alignment.Center) { Text("+", fontSize = 22.sp) }
    }

/** Picker in menu style: value + ⌃⌄, tap for the choices. */
@Composable
fun <T> PickerCell(label: String, options: List<T>, selected: T, text: (T) -> String, set: (T) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Cell({ open = true }) {
        Text(label, Modifier.weight(1f))
        Box {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Text(text(selected), color = secondary); GlyphIcon(ChevronUpDown, secondary, 14.dp)
            }
            DropdownMenu(open, { open = false }, shape = RoundedCornerShape(14.dp)) {
                options.forEach { o ->
                    DropdownMenuItem({ Text(text(o)) }, { set(o); open = false },
                        leadingIcon = { Box(Modifier.size(18.dp)) { if (o == selected) Icon(Icons.Filled.Check, null) } })
                }
            }
        }
    }
}

/** Trailing swipe action (Delete, Forget); a full swipe runs it. */
@Composable
fun Swipe(label: String, action: () -> Unit, content: @Composable () -> Unit) {
    // Refusing the dismiss snaps the row back; the action removes it if it should go.
    val act by rememberUpdatedState(action)
    // Full swipe only (60 % of the row), like iOS; a flick must not delete.
    val state = rememberSwipeToDismissBoxState(confirmValueChange = { if (it == SwipeToDismissBoxValue.EndToStart) act(); false },
        positionalThreshold = { it * 0.6f })
    SwipeToDismissBox(state, enableDismissFromStartToEnd = false,
        backgroundContent = {
            // Only while swiping: at rest it would bleed through the group's rounded corners.
            if (state.dismissDirection == SwipeToDismissBoxValue.EndToStart) Box(Modifier.fillMaxSize().background(Color(0xFFFF453A)).padding(end = 20.dp), contentAlignment = Alignment.CenterEnd) {
                Text(label, fontWeight = FontWeight.SemiBold)
            }
        }) { content() }
}

/** Floating capsule tab bar: Live, Sessions. */
@Composable
fun TabBar(tab: Int, select: (Int) -> Unit, modifier: Modifier) =
    Row(modifier.clip(CircleShape).background(Color(0xFF1C1C1E)).border(0.5.dp, Color.White.copy(alpha = 0.12f), CircleShape)
        .padding(4.dp)) {
        listOf("Live", "Sessions").forEachIndexed { i, label ->
            val tint = if (i == tab) Blue else Color.White
            Column(Modifier.width(92.dp).clip(CircleShape).background(if (i == tab) Color.White.copy(alpha = 0.1f) else Color.Transparent)
                .clickable { select(i) }.padding(vertical = 6.dp), horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(2.dp)) {
                if (i == 0) Icon(Icons.Filled.Favorite, null, Modifier.size(26.dp), tint = tint) else GlyphIcon(ChartGlyph, tint, 26.dp)
                Text(label, fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = tint)
            }
        }
    }

/** Room the floating tab bar takes at the bottom of a tab screen. */
val TabBarSpace = 86.dp

/** Circular toolbar button (iOS 26 nav bar). */
@Composable
fun BarButton(onClick: () -> Unit, content: @Composable () -> Unit) =
    Box(Modifier.size(44.dp).clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).clickable(onClick = onClick),
        contentAlignment = Alignment.Center) { content() }

