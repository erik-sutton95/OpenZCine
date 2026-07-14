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
