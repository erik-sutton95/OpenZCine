package com.opencapture.openzcine.pairing

import android.content.Intent
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.net.toUri
import com.opencapture.openzcine.diagnostics.AndroidSupportLinks
import com.opencapture.openzcine.diagnostics.AndroidSystemSettingsActions

/**
 * Startup/pairing design tokens — a 1:1 port of the iOS shell's
 * `StartupColors` (ios/Runner/StartupDesign.swift). Same float components so
 * the two shells render identical startup chrome. Keep the lists in sync.
 * These are the warm connection-screen accents, distinct from the monitor
 * chrome's [com.opencapture.openzcine.LiveDesign].
 */
public object StartupColors {
    public val surface: Color = Color(0.086f, 0.075f, 0.059f)
    public val tile: Color = Color(0.141f, 0.122f, 0.102f)
    public val control: Color = Color(0.173f, 0.149f, 0.125f)
    public val ink: Color = Color(0.949f, 0.925f, 0.886f)
    public val muted: Color = Color(0.655f, 0.612f, 0.553f)
    public val dim: Color = Color(0.490f, 0.447f, 0.392f)
    public val border: Color = Color.White
    public val card: Color = surface.copy(alpha = 0.58f)
    public val accent: Color = Color(0.878f, 0.655f, 0.227f)
    public val ready: Color = Color(0.247f, 0.710f, 0.416f)
    public val destructive: Color = Color(0.930f, 0.267f, 0.267f)
    public val darkText: Color = Color(0.110f, 0.086f, 0.047f)

    /** Warm near-black backdrop base (iOS `StartupColors.backdrop`). */
    public val backdropBase: Color = Color(0.055f, 0.045f, 0.034f)

    /** Soft glow color at the backdrop's radial center. */
    public val backdropGlow: Color = Color(0.132f, 0.108f, 0.082f)
}

/**
 * Cinematic page backdrop for the connection screens: warm near-black with a
 * soft glow falling off from the upper area — iOS `StartupColors.backdrop`.
 */
public fun Modifier.startupBackdrop(): Modifier = drawBehind {
    drawRect(StartupColors.backdropBase)
    drawRect(
        Brush.radialGradient(
            colors = listOf(StartupColors.backdropGlow, StartupColors.backdropGlow.copy(alpha = 0f)),
            center = Offset(size.width * 0.5f, size.height * 0.24f),
            radius = 760.dp.toPx(),
        )
    )
}

/** Rounded card surface for the two-column startup screens (iOS `StartupCardBackground`). */
public fun Modifier.startupCard(): Modifier =
    clip(RoundedCornerShape(20.dp))
        .background(StartupColors.card)
        .border(1.dp, StartupColors.border.copy(alpha = 0.08f), RoundedCornerShape(20.dp))

/** Inner tile/row surface (iOS 14pt-radius tile). */
public fun Modifier.startupTile(borderColor: Color = StartupColors.border.copy(alpha = 0.10f)): Modifier =
    clip(RoundedCornerShape(14.dp))
        .background(StartupColors.tile.copy(alpha = 0.45f))
        .border(1.dp, borderColor, RoundedCornerShape(14.dp))

/** Instruction-card surface (iOS `StartupColors.card` on 16pt radius). */
public fun Modifier.startupInstructionCard(): Modifier =
    clip(RoundedCornerShape(16.dp))
        .background(StartupColors.card)
        .border(1.dp, StartupColors.border.copy(alpha = 0.10f), RoundedCornerShape(16.dp))

/**
 * Startup header row: the OPENZCINE wordmark over a contextual title, with a
 * live status pill on the trailing edge (iOS `StartupHeader`). When supplied,
 * [onOpenSettings] exposes app-local setup before a camera is connected.
 */
@Composable
public fun StartupHeader(
    title: String,
    statusTitle: String,
    isBusy: Boolean,
    onOpenSettings: (() -> Unit)? = null,
    onOpenPrivacy: (() -> Unit)? = null,
    onOpenTerms: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val openPrivacy: () -> Unit =
        onOpenPrivacy ?: {
            AndroidSystemSettingsActions.safeLaunch(
                context,
                Intent(Intent.ACTION_VIEW, AndroidSupportLinks.PRIVACY.toUri()),
            )
        }
    val openTerms: () -> Unit =
        onOpenTerms ?: {
            AndroidSystemSettingsActions.safeLaunch(
                context,
                Intent(Intent.ACTION_VIEW, AndroidSupportLinks.TERMS.toUri()),
            )
        }
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val compact = maxWidth < 600.dp
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text(
                    "OPENZCINE",
                    color = StartupColors.muted,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.SemiBold,
                    letterSpacing = 1.3.sp,
                )
                if (compact) {
                    StartupHeaderTitle(title)
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        StartupLegalLink("Privacy", openPrivacy)
                        StartupLegalLink("Terms", openTerms)
                    }
                } else {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        StartupHeaderTitle(title, Modifier.weight(1f, fill = false))
                        StartupLegalLink("Privacy", openPrivacy)
                        StartupLegalLink("Terms", openTerms)
                    }
                }
            }
            Spacer(Modifier.width(8.dp))
            onOpenSettings?.let { openSettings ->
                StartupOutlineButton(
                    text = "Settings",
                    onClick = openSettings,
                    modifier = Modifier.width(92.dp),
                )
                Spacer(Modifier.width(8.dp))
            }
            val statusColor = if (isBusy) StartupColors.accent else StartupColors.ready
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                modifier =
                    Modifier.clip(CircleShape)
                        .background(StartupColors.surface.copy(alpha = 0.50f))
                        .border(1.dp, statusColor.copy(alpha = 0.40f), CircleShape)
                        .padding(horizontal = 14.dp, vertical = 7.dp),
            ) {
                Box(Modifier.size(7.dp).background(statusColor, CircleShape))
                Text(
                    statusTitle,
                    color = statusColor,
                    fontSize = 12.sp,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                )
            }
        }
    }
}

@Composable
private fun StartupHeaderTitle(title: String, modifier: Modifier = Modifier) {
    Text(
        title,
        color = StartupColors.ink,
        fontSize = 17.sp,
        fontWeight = FontWeight.Bold,
        maxLines = 1,
        modifier = modifier,
    )
}

/** Quiet policy link matching the iOS startup header without competing with its title. */
@Composable
private fun StartupLegalLink(label: String, onClick: () -> Unit) {
    Text(
        label,
        color = StartupColors.dim,
        fontSize = 11.sp,
        fontWeight = FontWeight.Medium,
        maxLines = 1,
        modifier =
            Modifier.semantics {
                    contentDescription = "Open the OpenZCine $label page"
                }
                .clickable(role = Role.Button, onClick = onClick)
                .padding(horizontal = 3.dp, vertical = 5.dp),
    )
}

/** Wizard progress capsules with the step counter (iOS `StartupWizardProgress`, compact). */
@Composable
public fun StartupWizardProgress(currentStep: Int, totalSteps: Int) {
    Column(verticalArrangement = Arrangement.spacedBy(10.dp)) {
        Row {
            Text(
                "Setup",
                color = StartupColors.muted,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
            Spacer(Modifier.weight(1f))
            Text(
                "Step $currentStep of $totalSteps",
                color = StartupColors.dim,
                fontSize = 10.sp,
                fontWeight = FontWeight.Medium,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
            for (step in 1..totalSteps) {
                val filled = step <= currentStep
                Box(
                    Modifier.weight(1f)
                        .height(3.dp)
                        .clip(CircleShape)
                        .background(
                            if (filled) StartupColors.accent
                            else StartupColors.control.copy(alpha = 0.55f)
                        )
                )
            }
        }
    }
}

/**
 * A thin accent line whose segment slides back and forth — the indeterminate
 * "working" indicator (iOS `StartupIndeterminateBar`).
 */
@Composable
public fun StartupIndeterminateBar(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "startup-indeterminate")
    val progress by
        transition.animateFloat(
            initialValue = 0f,
            targetValue = 1f,
            animationSpec =
                infiniteRepeatable(tween(durationMillis = 850), repeatMode = RepeatMode.Reverse),
            label = "startup-indeterminate-offset",
        )
    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .height(3.dp)
            .clip(CircleShape)
            .background(StartupColors.control.copy(alpha = 0.45f))
    ) {
        val segment: Dp = maxOf(44.dp, maxWidth * 0.32f)
        Box(
            Modifier.width(segment)
                .height(3.dp)
                .offset(x = (maxWidth - segment) * progress)
                .clip(CircleShape)
                .background(StartupColors.accent)
        )
    }
}
