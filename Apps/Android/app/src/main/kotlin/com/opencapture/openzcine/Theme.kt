package com.opencapture.openzcine

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color
import com.opencapture.monitorui.MonitorIosParity
import com.opencapture.monitorui.MonitorPalette

/**
 * OpenZCine brand tokens — gold on black, matching the iOS shell's
 * `BrandColors` (ios/Runner/Branding.swift) and the landing page.
 */
object BrandColors {
    /** Signature gold accent (#FFE100). */
    val accent: Color = Color(0xFFFFE100)

    /** Pure black monitor background — the app is a camera monitor first. */
    val background: Color = Color.Black

    /** Dimmed foreground for secondary/status text on the monitor. */
    val dimmedText: Color = Color(0xFF8A8A8A)
}

/**
 * Live-monitor design tokens. Surfaces, type, and hairlines come from
 * [MonitorPalette], the same tokens Pocket and Insta use. The accent is the
 * OpenZCine gold [OpenZCineTheme] assigns. Assist swatches that are not the
 * brand accent stay on [amber], [info], [good], and [rec]. Keep this list in
 * step with iOS `LiveDesign` in `ios/Runner/MonitorExperience.swift`.
 */
object LiveDesign {
    /** iOS `MonitorTheme.canvas` (`0x08090A`). */
    val background = MonitorPalette.backgroundDeep
    val surface = MonitorPalette.surface
    val glass = surface
    val glassOpaque = surface
    /** iOS `MonitorTheme.raised`. */
    val glassBright = MonitorPalette.tile
    val hairline = MonitorPalette.border
    val hairlineStrong = MonitorPalette.faint.copy(alpha = 0.5f)
    val text = MonitorPalette.text
    val muted = MonitorPalette.muted
    val faint = MonitorPalette.faint
    val accent get() = MonitorPalette.accent
    val accentDim get() = accent.copy(alpha = 0.16f)
    /** Zebra and highlight amber. Stable, so brand gold does not recolor stored paint. */
    val amber = Color(0.914f, 0.674f, 0.208f)
    val good = Color(0.18f, 0.78f, 0.42f)
    val rec = MonitorPalette.recording
    /** Cyan and blue assist previews. Not the brand accent. */
    val info = Color(0.10f, 0.58f, 0.98f)

    /** iOS `MonitorTheme.radius`. */
    const val CORNER_RADIUS_DP = 12f

    /** Height of the bottom control bars (iOS `LiveDesign.controlHeight`). */
    const val CONTROL_HEIGHT_DP = 58f
}

/**
 * Dark-only Material 3 theme for the monitor shell. There is no light
 * variant on purpose: a camera monitor is always black-backed.
 */
@Composable
fun OpenZCineTheme(content: @Composable () -> Unit) {
    // Shared OpenCine monitor UI wears the OpenZCine gold; plain fields, set before any shared
    // chrome in this tree draws.
    MonitorPalette.accent = BrandColors.accent
    // OpenZCine takes the iOS look of the shared Android pieces (engine-port UI-03 learning);
    // Pocket and Insta keep the default until they review it (OpenCine monitor-ui README).
    MonitorIosParity.enabled = true
    MaterialTheme(
        colorScheme =
            darkColorScheme(
                primary = BrandColors.accent,
                background = BrandColors.background,
                surface = BrandColors.background,
                onBackground = Color.White,
                onSurface = Color.White,
            ),
        content = content,
    )
}
