package com.opencapture.openzcine

import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.ui.text.PlatformTextStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

// Compose mirrors of the iOS monitor chrome primitives (ios/Runner/
// MonitorControls.swift + MonitorExperience.swift). Layout frames come from the
// shared core's zone map; these components only mirror the DRAWING — pill
// shapes, type hierarchy, and LiveDesign colors. SF Symbols are approximated
// with small Canvas glyphs; SF→Roboto type differences are accepted.

/** Rounded chrome shape (iOS `LiveDesign.cornerRadius`). */
val ChromeShape = RoundedCornerShape(LiveDesign.CORNER_RADIUS_DP.dp)

/** Text style matching iOS `.system(size:weight:design:)` closely enough. */
fun chromeStyle(size: Float, weight: FontWeight, mono: Boolean = false): TextStyle =
    TextStyle(
        fontSize = size.sp,
        lineHeight = size.sp,
        fontWeight = weight,
        fontFamily = if (mono) FontFamily.Monospace else FontFamily.SansSerif,
        platformStyle = PlatformTextStyle(includeFontPadding = false),
    )
