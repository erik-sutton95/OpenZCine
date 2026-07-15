package com.opencapture.openzcine

import android.content.Context
import android.content.SharedPreferences
import androidx.annotation.StringRes
import androidx.activity.compose.BackHandler
import androidx.core.content.edit
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.defaultMinSize
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.Stable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.isTraversalGroup
import androidx.compose.ui.semantics.paneTitle
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.opencapture.openzcine.bridge.MonitorZones
import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.diagnostics.AndroidDiagnosticEvent

/** The replayable three-step live monitor introduction, matching iOS concepts. */
internal enum class LiveViewGuideStep(
    @StringRes val titleResource: Int,
) {
    CAMERA_CONTROLS(R.string.guide_title_camera_controls),
    VIEW_ASSIST(R.string.guide_title_view_assist),
    SYSTEM_CONTROLS(R.string.guide_title_system_controls),
    ;

    val number: Int
        get() = ordinal + 1

    val next: LiveViewGuideStep?
        get() = entries.getOrNull(ordinal + 1)

    @StringRes
    fun messageResource(isPortrait: Boolean, usesVerticalAssistRail: Boolean): Int =
        when (this) {
            CAMERA_CONTROLS ->
                if (isPortrait) {
                    R.string.guide_camera_portrait
                } else {
                    R.string.guide_camera_landscape
                }
            VIEW_ASSIST ->
                if (usesVerticalAssistRail) {
                    R.string.guide_assist_rail
                } else {
                    R.string.guide_assist_toolbar
                }
            SYSTEM_CONTROLS -> R.string.guide_system_controls
        }

    companion object {
        fun debugValue(value: String?): LiveViewGuideStep? =
            when (value) {
                "camera" -> CAMERA_CONTROLS
                "assist" -> VIEW_ASSIST
                "system" -> SYSTEM_CONTROLS
                else -> null
            }
    }
}

/** Truthful Settings presentation for the persisted guide state. */
internal enum class LiveViewGuideStatus(@StringRes val labelResource: Int) {
    SHOWING(R.string.guide_status_showing),
    SCHEDULED(R.string.guide_status_scheduled),
    FIRST_FRAME_PENDING(R.string.guide_status_first_frame),
    COMPLETED(R.string.guide_status_completed),
}

/** Closed real-frame gate shared by the monitor callback and JVM tests. */
internal fun realDecodedFrameCanTriggerGuide(
    isDemoSession: Boolean,
    hasExplicitFrameSource: Boolean,
    monitorUsesSwiftCameraSource: Boolean,
    cameraConnected: Boolean,
): Boolean =
    !isDemoSession &&
        !hasExplicitFrameSource &&
        monitorUsesSwiftCameraSource &&
        cameraConnected

/**
 * Persisted guide state. Every transition is synchronous at the app-private
 * preference seam so an active card survives recomposition, configuration
 * rotation, and process recreation.
 */
@Stable
@Suppress("ApplySharedPref", "UseKtx") // Tiny synchronous writes make each active step process-durable.
internal class LiveViewGuideController(
    private val preferences: SharedPreferences,
    private val onDiagnosticEvent: (AndroidDiagnosticEvent) -> Unit = {},
) {
    constructor(
        context: Context,
        onDiagnosticEvent: (AndroidDiagnosticEvent) -> Unit = {},
    ) : this(
        context.getSharedPreferences(STORE_NAME, Context.MODE_PRIVATE),
        onDiagnosticEvent,
    )

    private var hasRealDecodedFrame by mutableStateOf(false)
    private var activeState by
        mutableStateOf(
            preferences.getString(ACTIVE_STEP_KEY, null)?.let { stored ->
                LiveViewGuideStep.entries.firstOrNull { it.name == stored }
            },
        )
    private var pendingNextFrame by mutableStateOf(preferences.getBoolean(PENDING_KEY, false))

    val activeStep: LiveViewGuideStep?
        get() = activeState.takeIf { hasRealDecodedFrame }

    val blocksCameraCommands: Boolean
        get() = activeStep != null

    val needsRealDecodedFrame: Boolean
        get() =
            !hasRealDecodedFrame || pendingNextFrame ||
                (activeState == null && completedVersion < CURRENT_VERSION)

    val canReplayNow: Boolean
        get() = hasRealDecodedFrame

    val status: LiveViewGuideStatus
        get() =
            when {
                activeStep != null -> LiveViewGuideStatus.SHOWING
                pendingNextFrame -> LiveViewGuideStatus.SCHEDULED
                completedVersion < CURRENT_VERSION -> LiveViewGuideStatus.FIRST_FRAME_PENDING
                else -> LiveViewGuideStatus.COMPLETED
            }

    fun onRealDecodedFrame() {
        val firstRealFrame = !hasRealDecodedFrame
        hasRealDecodedFrame = true
        if (firstRealFrame) onDiagnosticEvent(AndroidDiagnosticEvent.LIVE_VIEW_STARTED)
        if (activeState != null) return
        if (!pendingNextFrame && completedVersion >= CURRENT_VERSION) return
        pendingNextFrame = false
        activeState = LiveViewGuideStep.CAMERA_CONTROLS
        persistActiveState()
        onDiagnosticEvent(AndroidDiagnosticEvent.GUIDE_PRESENTED)
    }

    fun onRealFrameUnavailable() {
        hasRealDecodedFrame = false
    }

    fun advance() {
        val current = activeStep ?: return
        val next = current.next
        if (next != null) {
            activeState = next
            persistActiveState()
            return
        }
        complete(AndroidDiagnosticEvent.GUIDE_COMPLETED)
    }

    fun skip() {
        if (activeStep == null) return
        complete(AndroidDiagnosticEvent.GUIDE_SKIPPED)
    }

    fun replayNow() {
        if (!hasRealDecodedFrame) {
            replayOnNextRealFrame()
            return
        }
        preferences.edit(commit = true) { remove(COMPLETED_VERSION_KEY) }
        pendingNextFrame = false
        activeState = LiveViewGuideStep.CAMERA_CONTROLS
        persistActiveState()
        onDiagnosticEvent(AndroidDiagnosticEvent.GUIDE_PRESENTED)
    }

    fun replayOnNextRealFrame() {
        activeState = null
        pendingNextFrame = true
        preferences.edit(commit = true) {
            remove(COMPLETED_VERSION_KEY)
            remove(ACTIVE_STEP_KEY)
            putBoolean(PENDING_KEY, true)
        }
    }

    fun forceForDebug(step: LiveViewGuideStep) {
        hasRealDecodedFrame = true
        pendingNextFrame = false
        activeState = step
    }

    private fun complete(event: AndroidDiagnosticEvent) {
        activeState = null
        pendingNextFrame = false
        preferences.edit(commit = true) {
            putInt(COMPLETED_VERSION_KEY, CURRENT_VERSION)
            remove(ACTIVE_STEP_KEY)
            remove(PENDING_KEY)
        }
        onDiagnosticEvent(event)
    }

    private fun persistActiveState() {
        preferences.edit(commit = true) {
            putString(ACTIVE_STEP_KEY, activeState?.name)
            putBoolean(PENDING_KEY, pendingNextFrame)
        }
    }

    private val completedVersion: Int
        get() = preferences.getInt(COMPLETED_VERSION_KEY, 0)

    internal companion object {
        const val CURRENT_VERSION: Int = 1
        const val STORE_NAME: String = "live-view-guide"
        private const val COMPLETED_VERSION_KEY = "completedVersion"
        private const val ACTIVE_STEP_KEY = "activeStep"
        private const val PENDING_KEY = "pendingNextRealFrame"
    }
}

/** Full-screen modal guide. The hit-testable scrim owns every non-card tap. */
@Composable
internal fun LiveViewGuideOverlay(
    controller: LiveViewGuideController,
    zones: MonitorZones,
    isPortrait: Boolean,
    usesVerticalAssistRail: Boolean,
    assistTarget: ZoneFrame? = zones.assistStrip,
) {
    val step = controller.activeStep ?: return
    val paneTitleText = stringResource(R.string.guide_pane_title)
    val backgroundDescription = stringResource(R.string.guide_modal_background_description)
    BackHandler { controller.skip() }
    BoxWithConstraints(
        Modifier.fillMaxSize()
            .zIndex(100f)
            .semantics {
                paneTitle = paneTitleText
                isTraversalGroup = true
            },
    ) {
        val interactionSource = remember { MutableInteractionSource() }
        Box(
            Modifier.fillMaxSize()
                .background(Color.Black.copy(alpha = 0.28f))
                .clickable(
                    interactionSource = interactionSource,
                    indication = null,
                    role = Role.Button,
                    onClick = {},
                )
                .semantics { contentDescription = backgroundDescription },
        )
        guideTargetFrames(step, zones, assistTarget).forEach { frame ->
            val highlight =
                frame.expanded(5f).clampedInside(
                    viewportWidth = maxWidth.value,
                    viewportHeight = maxHeight.value,
                    strokeInset = 1.dp.value,
                )
            Box(
                Modifier.zone(highlight)
                    .shadow(4.dp, ChromeShape)
                    .border(2.dp, LiveDesign.accent, ChromeShape),
            )
        }
        val maximumCardWidth = if (isPortrait) 390.dp else 430.dp
        val availableCardWidth = (maxWidth - 36.dp).coerceAtLeast(240.dp)
        val cardWidth = minOf(maximumCardWidth, availableCardWidth)
        val cardAlignment =
            if (step == LiveViewGuideStep.VIEW_ASSIST) Alignment.TopCenter else Alignment.Center
        Box(
            Modifier.fillMaxSize()
                .padding(
                    start = if (isPortrait) 18.dp else 70.dp,
                    top =
                        if (step == LiveViewGuideStep.VIEW_ASSIST) {
                            if (isPortrait) 92.dp else 76.dp
                        } else {
                            18.dp
                        },
                    end = if (isPortrait) 18.dp else 70.dp,
                    bottom = 18.dp,
                ),
            contentAlignment = cardAlignment,
        ) {
            LiveViewGuideCard(
                step = step,
                isPortrait = isPortrait,
                usesVerticalAssistRail = usesVerticalAssistRail,
                onSkip = controller::skip,
                onAdvance = controller::advance,
                modifier = Modifier.width(cardWidth),
            )
        }
    }
}

@Composable
internal fun LiveViewGuideCard(
    step: LiveViewGuideStep,
    isPortrait: Boolean,
    usesVerticalAssistRail: Boolean,
    onSkip: () -> Unit,
    onAdvance: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val title = stringResource(step.titleResource)
    val cardDescription =
        stringResource(
            R.string.guide_card_description,
            step.number,
            LiveViewGuideStep.entries.size,
            title,
        )
    Column(
        modifier
            .glass(ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .testTag("live_guide_card")
            .semantics {
                contentDescription = cardDescription
            }
            .padding(14.dp),
        verticalArrangement = Arrangement.spacedBy(10.dp),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                stringResource(R.string.guide_heading),
                color = LiveDesign.accent,
                fontSize = 10.sp,
                fontWeight = FontWeight.Bold,
                letterSpacing = 0.8.sp,
            )
            Spacer(Modifier.weight(1f))
            Text(
                stringResource(
                    R.string.guide_step_counter,
                    step.number,
                    LiveViewGuideStep.entries.size,
                ),
                color = LiveDesign.muted,
                fontSize = 10.sp,
                fontWeight = FontWeight.SemiBold,
            )
        }
        Text(
            title,
            style = chromeStyle(21f, FontWeight.SemiBold),
            color = LiveDesign.text,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
        )
        Text(
            stringResource(step.messageResource(isPortrait, usesVerticalAssistRail)),
            style = chromeStyle(13f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
        Row(verticalAlignment = Alignment.CenterVertically) {
            GuideTextButton(
                stringResource(R.string.guide_skip),
                stringResource(R.string.guide_skip_description),
                onSkip,
            )
            Spacer(Modifier.weight(1f))
            GuidePrimaryButton(
                title =
                    stringResource(
                        if (step.next == null) R.string.action_done else R.string.action_next
                    ),
                contentDescription =
                    if (step.next == null) {
                        stringResource(R.string.guide_finish_description)
                    } else {
                        stringResource(R.string.guide_next_description)
                    },
                onClick = onAdvance,
            )
        }
    }
}

@Composable
private fun GuideTextButton(title: String, description: String, onClick: () -> Unit) {
    Box(
        Modifier.defaultMinSize(minWidth = 48.dp, minHeight = 48.dp)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { contentDescription = description },
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = chromeStyle(13f, FontWeight.SemiBold), color = LiveDesign.muted)
    }
}

@Composable
private fun GuidePrimaryButton(title: String, contentDescription: String, onClick: () -> Unit) {
    Box(
        Modifier.defaultMinSize(minWidth = 72.dp, minHeight = 48.dp)
            .background(LiveDesign.accent, CircleShape)
            .clickable(role = Role.Button, onClick = onClick)
            .semantics { this.contentDescription = contentDescription }
            .padding(horizontal = 16.dp),
        contentAlignment = Alignment.Center,
    ) {
        Text(title, style = chromeStyle(13f, FontWeight.Bold), color = LiveDesign.background)
    }
}

internal fun guideTargetFrames(
    step: LiveViewGuideStep,
    zones: MonitorZones,
    assistTarget: ZoneFrame? = zones.assistStrip,
): List<ZoneFrame> =
    when (step) {
        LiveViewGuideStep.CAMERA_CONTROLS ->
            listOfNotNull(zones.infoBar, zones.captureStrip ?: zones.controlsGrid)
        LiveViewGuideStep.VIEW_ASSIST -> listOfNotNull(assistTarget)
        LiveViewGuideStep.SYSTEM_CONTROLS ->
            listOf(zones.lock, zones.disp, zones.record, zones.media, zones.settings)
    }

private fun ZoneFrame.expanded(amount: Float): ZoneFrame =
    copy(
        x = x - amount,
        y = y - amount,
        width = width + amount * 2f,
        height = height + amount * 2f,
    )

private fun ZoneFrame.clampedInside(
    viewportWidth: Float,
    viewportHeight: Float,
    strokeInset: Float,
): ZoneFrame {
    val left = maxOf(x, strokeInset)
    val top = maxOf(y, strokeInset)
    val right = minOf(x + width, viewportWidth - strokeInset).coerceAtLeast(left)
    val bottom = minOf(y + height, viewportHeight - strokeInset).coerceAtLeast(top)
    return ZoneFrame(left, top, right - left, bottom - top)
}
