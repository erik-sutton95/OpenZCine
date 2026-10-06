package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorIcon
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.layout.layout
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.foundation.clickable
import androidx.compose.material3.Text
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.onClick as semanticsOnClick
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.toggleableState
import androidx.compose.ui.state.ToggleableState
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntSize
import androidx.compose.ui.unit.offset
import com.opencapture.opencine.appkit.LocalOperatorHaptics

// Compose mirrors of the iOS monitor chrome primitives (ios/Runner/
// MonitorControls.swift + MonitorExperience.swift). Layout frames come from the
// shared core's zone map; these components only mirror the DRAWING — pill
// shapes, type hierarchy, and LiveDesign colors. SF Symbols are approximated
// with small Canvas glyphs; SF→Roboto type differences are accepted.

/** Rounded chrome shape (iOS `LiveDesign.cornerRadius`). */
val ChromeShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

// The glass treatment itself (Modifier.glass / Modifier.chipGlass and the
// tiered GPU backdrop pipeline behind it) lives in GlassChrome.kt.

/**
 * Apple's HIG minimum touch target, which iOS puts under every chrome button through
 * `ZCTapTargetButtonStyle` → `minTapTarget` (ios/Runner/DesignShared.swift:30-42, 61-67).
 * Material's own floor is 48dp; 44 is the parity number and still fits the 46dp top deck band.
 */
internal const val MIN_TAP_TARGET_DP = 44f

/**
 * Grows a control's touch area to [MIN_TAP_TARGET_DP] without moving anything drawn — the Compose
 * transcription of the positive-then-negative padding iOS uses (`MinTapTargetModifier`,
 * ios/Runner/DesignShared.swift:114-137). It lives inside [chromeClickable] so
 * every chrome control inherits the floor from one place, the way iOS inherits it from one button
 * style instead of from its 131 call sites.
 *
 * Deliberately NOT `Modifier.minimumInteractiveComponentSize()`: that one reports the floored size
 * to the parent. The top deck's readout pills are ~27dp tall inside a 46dp band whose glass capsule
 * is drawn by the deck Row itself (`InfoPill`), so a pill that measured 44dp would inflate that
 * capsule past the band — moving drawn chrome is the one thing a tap-target fix must not do.
 */
@Composable
private fun Modifier.tapTargetFloor(click: Modifier.() -> Modifier): Modifier {
    val floorPx = with(LocalDensity.current) { MIN_TAP_TARGET_DP.dp.roundToPx() }
    // The drawn size is only knowable by measuring it, so the pad lands on the pass after — the
    // same one-frame settle as the iOS preference-key version.
    var drawn by remember { mutableStateOf(IntSize.Zero) }
    val padX = if (drawn.width <= 0) 0 else ((floorPx - drawn.width) / 2).coerceAtLeast(0)
    val padY = if (drawn.height <= 0) 0 else ((floorPx - drawn.height) / 2).coerceAtLeast(0)
    val expands = padX > 0 || padY > 0
    return this.then(if (expands) Modifier.tapTargetInset(padX, padY) else Modifier)
        .click()
        .then(if (expands) Modifier.tapTargetExpand(padX, padY) else Modifier)
        .onSizeChanged { size ->
            // Only a control that could still be under the floor is worth recording. Every scrim,
            // full-width row and media-grid cell clears it already, and publishing their size would
            // cost each of them a recomposition to compute a pad of zero.
            val next = if (size.width < floorPx || size.height < floorPx) size else IntSize.Zero
            if (next != drawn) drawn = next
        }
}

/** Pads the click node out around the drawn content — the half of the pair that is felt. */
private fun Modifier.tapTargetExpand(padX: Int, padY: Int): Modifier =
    layout { measurable, constraints ->
        val placeable = measurable.measure(constraints.offset(-2 * padX, -2 * padY))
        layout(placeable.width + 2 * padX, placeable.height + 2 * padY) {
            placeable.place(padX, padY)
        }
    }

/**
 * Hands the parent back the size it would have had — the half of the pair that is invisible.
 *
 * It inflates the constraints by exactly what [tapTargetExpand] subtracts again, so the drawn
 * content still measures against the caller's own constraints: a fixed-size caller (every
 * `Modifier.zone(...)` rail button) can't be squeezed by the pad and feed a smaller size back in.
 */
private fun Modifier.tapTargetInset(padX: Int, padY: Int): Modifier =
    layout { measurable, constraints ->
        val placeable = measurable.measure(constraints.offset(2 * padX, 2 * padY))
        layout(
            (placeable.width - 2 * padX).coerceAtLeast(0),
            (placeable.height - 2 * padY).coerceAtLeast(0),
        ) {
            placeable.place(-padX, -padY)
        }
    }

/**
 * Click without the Material ripple (chrome buttons highlight by state, not ripple), on a hit area
 * floored at [MIN_TAP_TARGET_DP] — see [tapTargetFloor].
 */
@Composable
fun Modifier.chromeClickable(onClick: () -> Unit): Modifier =
    chromeClickable(enabled = true, onClick = onClick)

/** Disabled chrome controls keep their visual state but reject touch input. */
@Composable
fun Modifier.chromeClickable(enabled: Boolean, onClick: () -> Unit): Modifier {
    val haptics = LocalOperatorHaptics.current
    val interaction = remember { MutableInteractionSource() }
    return tapTargetFloor {
        clickable(
            enabled = enabled,
            interactionSource = interaction,
            indication = null,
            onClick = {
                haptics.selection()
                onClick()
            },
        )
    }
}

/** Text style matching iOS `.system(size:weight:design:)` closely enough. */
fun chromeStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    TextStyle(
        fontSize = size.sp,
        lineHeight = size.sp,
        fontWeight = weight,
        fontFamily = if (mono) FontFamily.Monospace else FontFamily.SansSerif,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )

/** Signal bars + FPS readout capsule (iOS `FPSChip`). */
@Composable
fun FpsChip(signalBars: Int, fps: String, modifier: Modifier = Modifier) {
    val tint =
        when {
            signalBars >= 3 -> LiveDesign.good
            signalBars == 2 -> LiveDesign.accent
            signalBars == 1 -> LiveDesign.rec
            else -> LiveDesign.faint
        }
    Row(
        modifier = modifier.chipGlass(CircleShape).padding(horizontal = 11.dp, vertical = 7.dp),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        SignalBarsGlyph(bars = signalBars, tint = tint)
        Text(
            stringResource(R.string.monitor_fps),
            style = chromeStyle(8f, FontWeight.Bold, mono = true),
            color = LiveDesign.faint,
            maxLines = 1,
        )
        // Mirror iOS: two-decimal FPS must never wrap to "25.0" / "0".
        Text(
            fps,
            style = chromeStyle(12f, FontWeight.Medium, mono = true),
            color = LiveDesign.text,
            maxLines = 1,
            softWrap = false,
        )
    }
}

/**
 * Measures its single child unbounded and scales it down (top-start anchored)
 * to fit [maxWidth] — the shell-level analog of iOS `minimumScaleFactor`, so
 * chrome pills compress instead of wrapping when a band runs tight.
 */
@Composable
fun FitScale(maxWidth: Dp, content: @Composable () -> Unit) {
    Layout(content) { measurables, _ ->
        val placeable = measurables.first().measure(Constraints())
        val maxPx = maxWidth.roundToPx()
        val scale = if (placeable.width > maxPx) maxPx / placeable.width.toFloat() else 1f
        val width = (placeable.width * scale).toInt()
        val height = (placeable.height * scale).toInt()
        layout(width, height) {
            placeable.placeWithLayer(0, 0) {
                scaleX = scale
                scaleY = scale
                transformOrigin = TransformOrigin(0f, 0f)
            }
        }
    }
}

/** Lock toggle: glass rounded square, gold when engaged (iOS `lockButton`). */
@Composable
fun LockButton(locked: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    // While Live View shows a lent multicam member, the lock slot returns to the stage instead
    // (iOS `returnToMulticamButton`); the member keeps its session.
    com.opencapture.openzcine.multicam.LocalMulticamReturn.current?.let { returnToMulticam ->
        Box(
            modifier = modifier.glass(ChromeShape).chromeClickable(returnToMulticam)
                .semantics { contentDescription = "Return to Multicam" },
            contentAlignment = Alignment.Center,
        ) {
            MonitorIcon(
                MonitorIcon.LAYOUT_GRID, null,
                Modifier.size(17.dp), tint = LiveDesign.accent,
            )
        }
        return
    }
    val tint = if (locked) LiveDesign.accent else LiveDesign.text.copy(alpha = 0.86f)
    // iOS says the same two things about this button — a label and an accessibilityHint
    // (MonitorUnified.swift:1092-1093). Compose has no hint slot, so both ride the description and
    // TalkBack speaks the identical words; the engaged state rides `toggleableState`, which the
    // system localises, rather than a pair of strings this app would have to keep in step.
    val lockLabel = stringResource(R.string.a11y_monitor_lock)
    val lockHint = stringResource(R.string.a11y_monitor_lock_hint)
    Box(
        modifier =
            modifier
                .glass(ChromeShape)
                .then(
                    if (locked) {
                        Modifier.border(
                            1.5.dp,
                            LiveDesign.accent.copy(alpha = 0.75f),
                            ChromeShape,
                        )
                    } else {
                        Modifier
                    },
                )
                .chromeClickable(onClick)
                .semantics {
                    contentDescription = "$lockLabel. $lockHint"
                    role = Role.Switch
                    toggleableState = ToggleableState(locked)
                },
        contentAlignment = Alignment.Center,
    ) {
        MonitorIcon(MonitorIcon.LOCK, null, Modifier.size(17.dp), tint)
    }
}

/** DISP pill: label over mode dashes, the active dash lit (iOS `displayButton`). */
@Composable
fun DispButton(
    activeIndex: Int,
    modeCount: Int,
    isLiveActive: Boolean = activeIndex == 0,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    // The operator can reorder modes, so live tint follows typed mode state
    // rather than assuming indicator position zero is always Live.
    val labelColor = if (isLiveActive) LiveDesign.info else LiveDesign.text
    // "DISP" plus dashes says nothing out loud — iOS labels the same button "Change display mode"
    // (MonitorUnified.swift:1170).
    val dispLabel = stringResource(R.string.a11y_monitor_disp)
    Column(
        modifier =
            modifier
                .glass(ChromeShape)
                .chromeClickable(onClick)
                .semantics {
                    contentDescription = dispLabel
                    role = Role.Button
                },
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center,
    ) {
        Text(
            stringResource(R.string.monitor_disp),
            style = chromeStyle(12f, FontWeight.Bold),
            color = labelColor,
        )
        Row(
            Modifier.padding(top = 3.dp),
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            repeat(modeCount) { index ->
                Box(
                    Modifier.size(width = 14.dp, height = 3.dp)
                        .background(
                            if (index == activeIndex) LiveDesign.info
                            else LiveDesign.hairlineStrong,
                            CircleShape,
                        ),
                )
            }
        }
    }
}

/**
 * Round glass auxiliary button (iOS `AssetCircleButton`).
 *
 * [contentDescription] is what the glyph means — iOS labels each of these at the call site
 * ("Open Operator Setup" / "Open Media", MonitorUnified.swift:1109, :1138), because a gear and a
 * film roll are silent to TalkBack.
 */
@Composable
fun AuxCircleButton(
    modifier: Modifier = Modifier,
    onClick: () -> Unit = {},
    contentDescription: String? = null,
    glyph: @Composable (Modifier, Color) -> Unit,
) {
    // Held in a local the semantics block can't confuse with its own write-only property.
    val description = contentDescription
    Box(
        modifier =
            modifier
                .glass(CircleShape)
                .chromeClickable(onClick)
                .then(
                    if (description != null) {
                        Modifier.semantics {
                            this.contentDescription = description
                            role = Role.Button
                        }
                    } else {
                        Modifier
                    },
                ),
        contentAlignment = Alignment.Center,
    ) {
        // iOS sizes the asset glyph at 44% of the circle diameter.
        glyph(Modifier.fillMaxSize(0.44f), LiveDesign.text.copy(alpha = 0.86f))
    }
}

// Battery row-stack footprint, in dp: each row is a 12dp device-glyph slot,
// a 5dp gap, and the 28dp outline — 45dp across, so the whole stack stays
// inside the leading rail lane and never reaches the feed edge.
internal const val BATTERY_ROW_HEIGHT_DP = 16f
internal const val BATTERY_ROW_GAP_DP = 5f
internal const val BATTERY_OUTLINE_WIDTH_DP = 28f

/**
 * Stacked phone + camera battery rows for the leading rail (iOS combined
 * indicator): two bare rows — muted device glyph beside a battery-shaped
 * outline carrying the percent — no glass, sized to the rail lane.
 */
@Composable
fun BatteryRowStack(
    phonePercent: Int?,
    cameraPercent: Int?,
    modifier: Modifier = Modifier,
    phoneExternalPower: Boolean? = null,
    cameraExternalPower: Boolean? = null,
) {
    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(BATTERY_ROW_GAP_DP.dp),
    ) {
        BatteryOutlineRow(
            percent = phonePercent,
            isCamera = false,
            externalPower = phoneExternalPower,
        )
        BatteryOutlineRow(
            percent = cameraPercent,
            isCamera = true,
            externalPower = cameraExternalPower,
        )
    }
}

/** One bare battery row: device glyph, then the readout inside the outline. */
@Composable
private fun BatteryOutlineRow(percent: Int?, isCamera: Boolean, externalPower: Boolean?) {
    val presentation = monitorBatteryPresentation(percent, externalPower)
    val batteryPercent = presentation.percent
    // Charge reads as colour before it reads as a count. The camera's thresholds come from the
    // shared gauge (`CameraBatteryUrgency`, mirroring core `CameraBatteryGauge.Urgency`) so the
    // two platforms cannot warn at different charges; the phone keeps its own percentage rule.
    val tint =
        when {
            batteryPercent == null && externalPower != true -> LiveDesign.faint
            isCamera ->
                when (presentation.urgency) {
                    // Muted, not a signal green: a healthy battery must not compete with the
                    // record tally for attention.
                    CameraBatteryUrgency.NOMINAL -> Color(0xFF6BCC87)
                    CameraBatteryUrgency.LOW -> Color(0xFFE59A3C)
                    CameraBatteryUrgency.DEPLETED -> Color.Red
                }
            batteryPercent != null && batteryPercent <= 15 -> Color.Red
            else -> LiveDesign.text.copy(alpha = 0.85f)
        }
    // Only the body's blinking exhaustion step pulses. A steady red bar is "nearly out"; a
    // pulsing one is the body reporting the shutter is already disabled.
    val pulseAlpha =
        if (presentation.pulses) {
            val transition = rememberInfiniteTransition(label = "batteryPulse")
            transition.animateFloat(
                initialValue = 1f,
                targetValue = 0.35f,
                animationSpec =
                    infiniteRepeatable(tween(600), repeatMode = RepeatMode.Reverse),
                label = "batteryPulseAlpha",
            ).value
        } else {
            1f
        }
    val source =
        stringResource(if (isCamera) R.string.battery_source_camera else R.string.battery_source_phone)
    val description =
        when {
            batteryPercent != null && externalPower == true ->
                stringResource(R.string.battery_description_power, source, batteryPercent)
            batteryPercent != null ->
                stringResource(R.string.battery_description_percent, source, batteryPercent)
            externalPower == true -> stringResource(R.string.battery_description_external, source)
            else -> stringResource(R.string.battery_description_unavailable, source)
        }
    Row(
        modifier = Modifier.semantics { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(5.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.width(12.dp), contentAlignment = Alignment.Center) {
            if (isCamera) {
                MonitorIcon(MonitorIcon.CAMERA, null, Modifier.size(12.dp), LiveDesign.muted)
            } else {
                MonitorIcon(MonitorIcon.SMARTPHONE, null, Modifier.size(11.dp), LiveDesign.muted)
            }
        }
        BatteryOutlineReadout(
            label = presentation.label.removeSuffix("%"),
            tint = tint.copy(alpha = tint.alpha * pulseAlpha),
            charging = presentation.externalPower,
        )
    }
}

/**
 * Battery-shaped outline (rounded body + trailing terminal nub) with the bare
 * readout inside — the number is the fill. Stroke and text share the state
 * tint; a small bolt precedes the number on external power.
 */
@Composable
private fun BatteryOutlineReadout(label: String, tint: Color, charging: Boolean) {
    Box(
        Modifier.size(BATTERY_OUTLINE_WIDTH_DP.dp, BATTERY_ROW_HEIGHT_DP.dp),
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val stroke = 1.2.dp.toPx()
            val bodyWidth = size.width - 3.dp.toPx()
            drawRoundRect(
                tint.copy(alpha = 0.85f),
                topLeft = Offset(0f, 0f),
                size = Size(bodyWidth, size.height),
                cornerRadius = CornerRadius(3.5.dp.toPx()),
                style = Stroke(stroke),
            )
            // Terminal nub.
            drawRoundRect(
                tint.copy(alpha = 0.85f),
                topLeft = Offset(bodyWidth + stroke, size.height * 0.3f),
                size = Size(size.width - bodyWidth - stroke, size.height * 0.4f),
                cornerRadius = CornerRadius(1.dp.toPx()),
            )
        }
        Row(
            // Center the readout in the body span, not body + nub.
            Modifier.padding(end = 3.dp),
            horizontalArrangement = Arrangement.spacedBy(1.5.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            if (charging) MonitorIcon(MonitorIcon.ZAP, null, Modifier.size(8.dp), tint)
            val gaugeBars = label.count { it == FILLED_BAR || it == EMPTY_BAR }
            if (gaugeBars > 0) {
                // DRAWN segments, not the block characters this used to print. Glyphs carry the
                // font's own metrics, weight and side bearings, so the gauge never matched the
                // iOS one no matter how the size was tuned — which is what "looks nothing like
                // the baseline" was. These are the same rounded segments iOS fills.
                val filled = label.count { it == FILLED_BAR }
                Row(horizontalArrangement = Arrangement.spacedBy(1.dp)) {
                    repeat(gaugeBars) { index ->
                        Canvas(Modifier.size(2.dp, 7.dp)) {
                            drawRoundRect(
                                if (index < filled) tint else tint.copy(alpha = 0.22f),
                                cornerRadius = CornerRadius(0.8.dp.toPx()),
                            )
                        }
                    }
                }
            } else {
                // The phone's own charge stays a numeral: it IS a true percentage, and the two
                // readings must not look like the same kind of measurement.
                val fits = !(charging && label.length >= 3)
                Text(
                    label,
                    style =
                        chromeStyle(if (fits) 10.5f else 8.5f, FontWeight.SemiBold, mono = true),
                    color = tint,
                    maxLines = 1,
                    softWrap = false,
                )
            }
        }
    }
}

// MARK: - Canvas glyphs (SF Symbol approximations)

/** SF `cellularbars` with `variableValue` (filled bars vs dim bars). */
@Composable
fun SignalBarsGlyph(bars: Int, tint: Color, modifier: Modifier = Modifier.size(16.dp, 12.dp)) {
    Canvas(modifier) {
        val barWidth = size.width / 4f * 0.68f
        val gap = size.width / 4f * 0.32f
        for (index in 0 until 4) {
            val height = size.height * (0.35f + 0.65f * index / 3f)
            drawRoundRect(
                if (index < bars) tint else tint.copy(alpha = 0.3f),
                topLeft = Offset(index * (barWidth + gap), size.height - height),
                size = Size(barWidth, height),
                cornerRadius = CornerRadius(barWidth * 0.35f),
            )
        }
    }
}

