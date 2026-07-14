package com.opencapture.openzcine

import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.darkColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.ui.graphics.Color

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
 * Live-monitor design tokens — a 1:1 mirror of the iOS shell's `LiveDesign`
 * (ios/Runner/MonitorExperience.swift). Same float components, so the two
 * shells render identical chrome colors. Keep the two lists in sync.
 */
object LiveDesign {
    val background = Color(0.072f, 0.064f, 0.053f)
    val surface = Color(0.145f, 0.128f, 0.102f)
    val glass = Color(0.105f, 0.092f, 0.073f, 0.64f)
    val glassBright = Color(0.178f, 0.155f, 0.122f, 0.68f)
    val hairline = Color(0.968f, 0.937f, 0.882f, 0.14f)
    val hairlineStrong = Color(0.968f, 0.937f, 0.882f, 0.22f)
    val text = Color(0.958f, 0.935f, 0.885f)
    val muted = Color(0.642f, 0.600f, 0.535f)
    val faint = Color(0.455f, 0.420f, 0.365f)
    val accent = Color(0.914f, 0.674f, 0.208f)
    val accentDim = Color(0.914f, 0.674f, 0.208f, 0.16f)
    val good = Color(0.18f, 0.78f, 0.42f)
    val rec = Color(0.82f, 0.20f, 0.23f)
    val info = Color(0.10f, 0.58f, 0.98f)

    /** Corner radius for rounded chrome surfaces (iOS `DesignTokens.cornerRadius`). */
    const val CORNER_RADIUS_DP = 16f

    /** Height of the bottom control bars (iOS `LiveDesign.controlHeight`). */
    const val CONTROL_HEIGHT_DP = 58f
}

/**
 * Dark-only Material 3 theme for the monitor shell. There is no light
 * variant on purpose: a camera monitor is always black-backed.
 */
@Composable
fun OpenZCineTheme(content: @Composable () -> Unit) {
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
