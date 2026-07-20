package com.opencapture.openzcine.settings

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.text.format.Formatter
import android.view.HapticFeedbackConstants
import android.widget.Toast
import androidx.annotation.StringRes
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGesturesAfterLongPress
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.scrollBy
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.selection.toggleable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.ScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Slider
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.key
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalResources
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.res.stringResource
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.CustomAccessibilityAction
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.customActions
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.opencapture.openzcine.AndroidThermalTier
import com.opencapture.openzcine.BuildConfig
import com.opencapture.openzcine.R
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.titleResource
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedPeakingColor
import com.opencapture.openzcine.FeedPeakingSensitivity
import com.opencapture.openzcine.FeedZebraStripeColor
import com.opencapture.openzcine.FeedZebraUnit
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.LiveViewGuideController
import com.opencapture.openzcine.zebraEditorValue
import com.opencapture.openzcine.zebraMonitorPercent
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.bridge.AndroidLinkHealthMonitor
import com.opencapture.openzcine.bridge.LinkHealthPresentation
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreLiveFrameSource
import com.opencapture.openzcine.bridge.SwiftLiveViewPreviewState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.CameraTemperatureStatus
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.labelResource
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.diagnostics.BugReportPathChooser
import com.opencapture.openzcine.diagnostics.BugReportScreen
import com.opencapture.openzcine.diagnostics.BugReportSubmitter
import com.opencapture.openzcine.diagnostics.SystemSettingsActions
import com.opencapture.openzcine.media.MediaCacheClearResult
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.CustomLutImportResult
import com.opencapture.openzcine.lut.RedLutDownloadGate
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutEntry
import com.opencapture.openzcine.lut.StoredLutFailure
import com.opencapture.openzcine.lut.reconciledLutSelectionAfterDeletion
import com.opencapture.openzcine.rememberAndroidThermalTier
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlin.math.floor
import kotlin.math.roundToInt

/**
 * Operator Setup rail tabs — 1:1 with the iOS `OperatorSettingsTab` set
 * (Link / View Assist / Controls / Display / Storage / System). The Link tab
 * binds to the active Android session; every other tab exposes the same
 * operator controls as the iOS baseline.
 */
public enum class OperatorSettingsTab(
    @StringRes public val titleResource: Int,
    @StringRes public val compactTitleResource: Int,
    @StringRes public val railSubtitleResource: Int,
    @StringRes public val subtitleResource: Int,
    @StringRes public val pillResource: Int,
) {
    LINK(R.string.settings_tab_link, R.string.settings_tab_link, R.string.settings_rail_connection, R.string.settings_subtitle_link, R.string.settings_pill_live),
    ASSIST(R.string.settings_tab_assist, R.string.settings_tab_assist_compact, R.string.settings_rail_assist, R.string.settings_subtitle_assist, R.string.settings_pill_assist),
    CONTROLS(R.string.settings_tab_controls, R.string.settings_tab_controls, R.string.settings_rail_controls, R.string.settings_subtitle_controls, R.string.settings_pill_touch),
    DISPLAY(R.string.settings_tab_display, R.string.settings_tab_display, R.string.settings_rail_display, R.string.settings_subtitle_display, R.string.settings_pill_visibility),
    STORAGE(R.string.settings_tab_storage, R.string.settings_tab_storage, R.string.settings_rail_storage, R.string.settings_subtitle_storage, R.string.settings_pill_storage),
    SYSTEM(R.string.settings_tab_system, R.string.settings_tab_system, R.string.settings_rail_system, R.string.settings_subtitle_system, R.string.settings_pill_app),
}

private enum class BugReportDestination {
    CHOOSER,
    ANONYMOUS,
}

/**
 * The full-screen Operator Settings surface — a 1:1 structural port of the
 * iOS `OperatorSettingsPanel` (ios/Runner/MonitorPanels.swift): floating close
 * button, eyebrow/title header with the live tile, vertical tab rail, and a
 * rounded content pane per tab. [assistState] is the monitor toolbar's state,
 * so view-assist changes apply immediately and persist through one seam.
 *
 * [session] is null for standalone startup settings. That state never creates
 * a session or sends a camera command; the live tile instead explains that
 * only app-local setup is available. [mediaCacheStore] is scoped to the
 * app-owned progressive cache, not camera or share-provider storage.
 */
@Composable
internal fun OperatorSettingsScreen(
    session: CameraSession?,
    assistState: AssistState,
    settings: OperatorSettings,
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController? = null,
    lutLibrary: AndroidLutLibrary? = null,
    linkHealth: AndroidLinkHealthMonitor? = null,
    liveViewSource: SwiftCoreLiveFrameSource? = null,
    activeTransportLabel: String? = null,
    onDisconnect: (() -> Unit)? = null,
    onReconnect: (() -> Unit)? = null,
    systemSettingsActions: SystemSettingsActions,
    bugReportSubmitter: BugReportSubmitter,
    bugReportActivityLogProvider: () -> List<String> = { emptyList() },
    liveViewGuideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)? = null,
    onShowGuideOnNextRealFrame: () -> Unit,
    onCompletedMediaCacheCleared: () -> Unit = {},
    initialTab: OperatorSettingsTab = OperatorSettingsTab.LINK,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scopeLimitMessage = stringResource(R.string.settings_scope_limit)
    val isPortrait = LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT
    val cameraProperties = if (session == null) null else session.cameraProperties.collectAsState().value
    val cameraInput =
        remember(cameraProperties?.codec, cameraProperties?.iso, cameraProperties?.baseIso) {
            ExposureAssistCameraInput(
                codec = cameraProperties?.codec,
                iso = cameraProperties?.iso,
                baseIso = cameraProperties?.baseIso,
            )
        }
    val feedbackView = LocalView.current
    val toggleSetting: (OperatorSettings.Toggle) -> Unit = { toggle ->
        val hapticsWereEnabled = settings.hapticsEnabled.value
        toggle.toggle()
        if (hapticsWereEnabled) {
            feedbackView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    val toggleAssist: (AssistTool) -> Unit = { tool ->
        val hapticsEnabled = settings.hapticsEnabled.value
        val maximumScopes = if (session != null && isPortrait) 2 else null
        val changed = assistState.toggle(tool, maximumActiveScopes = maximumScopes)
        if (!changed) {
            Toast.makeText(
                context,
                scopeLimitMessage,
                Toast.LENGTH_SHORT,
            ).show()
        } else if (hapticsEnabled) {
            feedbackView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    val emitHaptic: () -> Unit = {
        if (settings.hapticsEnabled.value) {
            feedbackView.performHapticFeedback(HapticFeedbackConstants.KEYBOARD_TAP)
        }
    }
    var selectedTab by rememberSaveable(initialTab) { mutableStateOf(initialTab) }
    var bugReportDestination by remember { mutableStateOf<BugReportDestination?>(null) }

    when (bugReportDestination) {
        BugReportDestination.CHOOSER ->
            BugReportPathChooser(
                onChooseAnonymous = { bugReportDestination = BugReportDestination.ANONYMOUS },
                onContinueWithGitHub = systemSettingsActions::openGitHubBugReport,
                onClose = { bugReportDestination = null },
            )
        BugReportDestination.ANONYMOUS ->
            BugReportScreen(
                submitter = bugReportSubmitter,
                activityLogProvider = bugReportActivityLogProvider,
                onOpenSecurityAdvisory = systemSettingsActions::openSecurityAdvisory,
                onClose = { bugReportDestination = null },
            )
        null ->
            BoxWithConstraints(
            Modifier.fillMaxSize()
                .background(LiveDesign.background)
                // A hit-testable node at the root keeps every pointer event on
                // this surface — without it, taps between rows would fall through
                // to the monitor chrome's buttons underneath (Compose siblings
                // below stay hit-testable wherever the overlay itself has no
                // pointer node).
                .pointerInput(Unit) { detectTapGestures {} }
                .windowInsetsPadding(WindowInsets.safeDrawing)
        ) {
            val compact = maxWidth < 600.dp
            Column(
                Modifier.fillMaxSize()
                    .padding(start = 16.dp, end = 16.dp, top = 14.dp, bottom = 12.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                // The floating PanelCloseButton overlays this row's leading corner
                // (the iOS iPad clearance fix — `closeButtonClearance`): inset the
                // header to start beside it, (16 + 37 + 8) − 16dp of panel padding.
                SettingsHeader(session, linkHealth, compact)
                if (compact) {
                    SettingsTabStrip(selectedTab, onSelect = { selectedTab = it })
                    SettingsContentPane(
                        selectedTab,
                        session,
                        settings,
                        assistState,
                        mediaCacheStore,
                        frameioController,
                        lutLibrary,
                        cameraInput,
                        linkHealth,
                        liveViewSource,
                        activeTransportLabel,
                        onDisconnect,
                        onReconnect,
                        systemSettingsActions,
                        liveViewGuideController,
                        onShowGuideNow,
                        onShowGuideOnNextRealFrame,
                        onCompletedMediaCacheCleared,
                        onSettingToggle = toggleSetting,
                        onAssistToggle = toggleAssist,
                        onInteraction = emitHaptic,
                        compact = true,
                        onReportProblem = { bugReportDestination = BugReportDestination.CHOOSER },
                        modifier = Modifier.weight(1f),
                    )
                } else {
                    Row(
                        Modifier.fillMaxWidth().weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        SettingsTabRail(selectedTab, onSelect = { selectedTab = it })
                        SettingsContentPane(
                            selectedTab,
                            session,
                            settings,
                            assistState,
                            mediaCacheStore,
                            frameioController,
                            lutLibrary,
                            cameraInput,
                            linkHealth,
                            liveViewSource,
                            activeTransportLabel,
                            onDisconnect,
                            onReconnect,
                            systemSettingsActions,
                            liveViewGuideController,
                            onShowGuideNow,
                            onShowGuideOnNextRealFrame,
                            onCompletedMediaCacheCleared,
                            onSettingToggle = toggleSetting,
                            onAssistToggle = toggleAssist,
                            onInteraction = emitHaptic,
                            compact = false,
                            onReportProblem = { bugReportDestination = BugReportDestination.CHOOSER },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
            // Floats in the very top-left corner, outside the layout flow, at the
            // iOS metrics (leading 16, top 22).
            Box(Modifier.padding(start = 16.dp, top = 22.dp)) { PanelCloseButton(onClick = onClose) }
        }
    }
}

/** Eyebrow + title with the live tile pinned trailing (iOS `settingsTop`). */
@Composable
private fun SettingsHeader(
    session: CameraSession?,
    linkHealth: AndroidLinkHealthMonitor?,
    compact: Boolean,
) {
    if (compact) {
        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SettingsTitle(Modifier.padding(start = 45.dp))
            SettingsLiveTile(session, linkHealth, Modifier.fillMaxWidth(), expanded = true)
        }
    } else {
        Row(
            Modifier.fillMaxWidth().padding(start = 45.dp),
            verticalAlignment = Alignment.Top,
        ) {
            SettingsTitle()
            Spacer(Modifier.weight(1f))
            SettingsLiveTile(session, linkHealth, expanded = false)
        }
    }
}

@Composable
private fun SettingsTitle(modifier: Modifier = Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(3.dp)) {
        Text(
            stringResource(R.string.settings_brand),
            color = LiveDesign.accent,
            fontSize = 9.5.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.8.sp,
        )
        Text(
            stringResource(R.string.settings_title),
            style = chromeStyle(24f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
    }
}

/** Link-state tile: status dot, title/detail, meter bars (iOS `SettingsLiveTile`). */
@Composable
private fun SettingsLiveTile(
    session: CameraSession?,
    linkHealth: AndroidLinkHealthMonitor?,
    modifier: Modifier = Modifier,
    expanded: Boolean,
) {
    val disconnectedState = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
    val state by (session?.state ?: disconnectedState).collectAsState()
    val standalone = session == null
    val linked = state is CameraSessionState.Connected
    val health = linkHealth?.presentation ?: LinkHealthPresentation()
    val tint =
        when {
            !linked -> LiveDesign.faint
            health.signalBars >= 3 -> LiveDesign.good
            health.signalBars == 2 -> LiveDesign.accent
            else -> LiveDesign.rec
        }
    val detail =
        if (standalone) {
            stringResource(R.string.settings_local_only)
        } else {
            when (val current = state) {
                is CameraSessionState.Connected ->
                    health.detail.ifBlank {
                        stringResource(
                            R.string.settings_connected_detail,
                            current.identity.name,
                            "PTP-IP",
                        )
                    }
                CameraSessionState.Connecting -> stringResource(R.string.camera_connecting_short)
                CameraSessionState.Disconnected -> stringResource(R.string.camera_none)
            }
        }
    Row(
        modifier.background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(10.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(Modifier.size(8.dp).background(tint, CircleShape))
        Column(
            if (expanded) Modifier.weight(1f) else Modifier.widthIn(max = 180.dp),
            verticalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            Text(
                stringResource(
                    if (linked) R.string.settings_active_link
                    else if (standalone) R.string.settings_local_setup
                    else R.string.settings_no_link,
                ),
                style = chromeStyle(12f, FontWeight.SemiBold),
                color = LiveDesign.text,
            )
            Text(
                detail,
                style = chromeStyle(10.5f, FontWeight.Medium, mono = true),
                color = LiveDesign.muted,
                maxLines = 1,
                overflow = TextOverflow.Ellipsis,
            )
        }
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
            repeat(4) { index ->
                Box(
                    Modifier.size(width = 3.dp, height = (6 + index * 3).dp)
                        .background(
                            if (index < health.signalBars) tint.copy(alpha = 0.52f + index * 0.12f)
                            else LiveDesign.hairline,
                            CircleShape,
                        )
                )
            }
        }
    }
}

/**
 * Horizontal tab selector used when the landscape rail cannot fit — the same
 * tab buttons as the vertical rail (iOS `settingsTabStrip`), scrolled when the
 * strip is wider than the screen.
 */
@Composable
private fun SettingsTabStrip(
    selected: OperatorSettingsTab,
    onSelect: (OperatorSettingsTab) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth()
            .glass(ChromeShape)
            .horizontalScroll(rememberScrollState())
            .padding(6.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        OperatorSettingsTab.entries.forEach { tab ->
            Box(Modifier.width(146.dp)) {
                SettingsTabButton(tab, active = tab == selected, onClick = { onSelect(tab) })
            }
        }
    }
}

/** Vertical tab rail, 146dp wide on full-height glass (iOS `settingsRail`). */
@Composable
private fun SettingsTabRail(selected: OperatorSettingsTab, onSelect: (OperatorSettingsTab) -> Unit) {
    Column(
        Modifier.width(146.dp).fillMaxHeight().glass(ChromeShape).padding(6.dp),
        verticalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        OperatorSettingsTab.entries.forEach { tab ->
            SettingsTabButton(tab, active = tab == selected, onClick = { onSelect(tab) })
        }
    }
}

/** One rail tab: accent capsule + title over subtitle (iOS `settingsTabButton`). */
@Composable
private fun SettingsTabButton(tab: OperatorSettingsTab, active: Boolean, onClick: () -> Unit) {
    Row(
        Modifier.fillMaxWidth()
            .height(43.dp)
            .background(if (active) LiveDesign.surface else LiveDesign.surface.copy(alpha = 0f), ChromeShape)
            .settingsClickable(role = Role.Tab, onClick = onClick)
            .padding(horizontal = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(9.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Box(
            Modifier.size(width = 6.dp, height = 26.dp)
                .background(
                    if (active) LiveDesign.accent else LiveDesign.accent.copy(alpha = 0f),
                    CircleShape,
                )
        )
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(
                stringResource(tab.titleResource),
                style = chromeStyle(13f, FontWeight.SemiBold),
                color = if (active) LiveDesign.text else LiveDesign.muted,
                maxLines = 1,
            )
            Text(
                stringResource(tab.railSubtitleResource),
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.faint,
                maxLines = 1,
            )
        }
    }
}

/** Rounded content pane: tab title/subtitle + pill header over scrolling rows. */
@Composable
private fun SettingsContentPane(
    tab: OperatorSettingsTab,
    session: CameraSession?,
    settings: OperatorSettings,
    assistState: AssistState,
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController?,
    lutLibrary: AndroidLutLibrary?,
    cameraInput: ExposureAssistCameraInput,
    linkHealth: AndroidLinkHealthMonitor?,
    liveViewSource: SwiftCoreLiveFrameSource?,
    activeTransportLabel: String?,
    onDisconnect: (() -> Unit)?,
    onReconnect: (() -> Unit)?,
    systemSettingsActions: SystemSettingsActions,
    liveViewGuideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)?,
    onShowGuideOnNextRealFrame: () -> Unit,
    onCompletedMediaCacheCleared: () -> Unit,
    onSettingToggle: (OperatorSettings.Toggle) -> Unit,
    onAssistToggle: (AssistTool) -> Unit,
    onInteraction: () -> Unit,
    compact: Boolean,
    onReportProblem: () -> Unit,
    modifier: Modifier = Modifier,
) {
    BoxWithConstraints(
        modifier
            .fillMaxSize()
            .background(LiveDesign.surface, ChromeShape)
            .border(1.dp, LiveDesign.hairline, ChromeShape)
            .padding(12.dp),
    ) {
        // A landscape phone exposes only about 250dp of pane height once the
        // top chrome and safe areas are accounted for. Keep the selected
        // Storage card complete in that window rather than leaving its clear
        // result half-hidden below a scroll edge.
        val condensed = maxHeight < 300.dp
        Column(
            Modifier.fillMaxSize(),
            verticalArrangement = Arrangement.spacedBy(if (condensed) 6.dp else 10.dp),
        ) {
            Row(verticalAlignment = Alignment.Top) {
                Column(verticalArrangement = Arrangement.spacedBy(5.dp)) {
                    Text(
                        stringResource(tab.titleResource),
                        style = chromeStyle(if (condensed) 21f else 24f, FontWeight.SemiBold),
                        color = LiveDesign.text,
                    )
                    if (!condensed) {
                        Text(
                            stringResource(tab.subtitleResource),
                            style = chromeStyle(12.5f, FontWeight.Normal),
                            color = LiveDesign.muted,
                            maxLines = 2,
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                Text(
                    stringResource(tab.pillResource),
                    color = LiveDesign.accent,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Bold,
                    letterSpacing = 0.6.sp,
                    modifier =
                        Modifier.border(1.dp, LiveDesign.accentDim, CircleShape)
                            .padding(horizontal = 10.dp, vertical = 6.dp),
                )
            }
            // Fresh scroll position per tab. ponytail: iOS persists per-tab
            // offsets across panel dismissal; add if the rows ever grow that long.
            key(tab) {
                val scrollState = rememberScrollState()
                var viewportBounds by remember { mutableStateOf<Rect?>(null) }
                Box(
                    Modifier.fillMaxSize()
                        .onGloballyPositioned { viewportBounds = it.boundsInRoot() },
                ) {
                    Column(
                        Modifier.fillMaxSize().verticalScroll(scrollState),
                        verticalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        when (tab) {
                            OperatorSettingsTab.LINK ->
                                LinkRows(
                                    session = session,
                                    settings = settings,
                                    linkHealth = linkHealth,
                                    liveViewSource = liveViewSource,
                                    activeTransportLabel = activeTransportLabel,
                                    onDisconnect = onDisconnect,
                                    onReconnect = onReconnect,
                                    onInteraction = onInteraction,
                                )
                            OperatorSettingsTab.ASSIST ->
                                AssistRows(
                                    settings,
                                    assistState,
                                    lutLibrary,
                                    cameraInput,
                                    onSettingToggle,
                                    onAssistToggle,
                                    onInteraction,
                                )
                            OperatorSettingsTab.CONTROLS -> ControlsRows(settings, onSettingToggle)
                            OperatorSettingsTab.DISPLAY ->
                                DisplayRows(
                                    settings,
                                    compact,
                                    onSettingToggle,
                                    onInteraction,
                                    scrollState,
                                    viewportBounds,
                                )
                            OperatorSettingsTab.STORAGE ->
                                StorageRows(
                                    mediaCacheStore,
                                    frameioController,
                                    condensed,
                                    onCompletedMediaCacheCleared,
                                )
                            OperatorSettingsTab.SYSTEM ->
                                SystemRows(
                                    actions = systemSettingsActions,
                                    onReportProblem = onReportProblem,
                                    guideController = liveViewGuideController,
                                    onShowGuideNow = onShowGuideNow,
                                    onShowGuideOnNextRealFrame = onShowGuideOnNextRealFrame,
                                )
                        }
                    }
                }
            }
        }
    }
}

/**
 * Link tab — 1:1 with iOS `linkRows`: dash-scale health meter, then one row card
 * with transport, stream preset, Size/Quality bias, connection action, and the
 * fixed threshold / reconnect readouts.
 */
@Composable
private fun LinkRows(
    session: CameraSession?,
    settings: OperatorSettings,
    linkHealth: AndroidLinkHealthMonitor?,
    liveViewSource: SwiftCoreLiveFrameSource?,
    activeTransportLabel: String?,
    onDisconnect: (() -> Unit)?,
    onReconnect: (() -> Unit)?,
    onInteraction: () -> Unit,
) {
    // liveViewSource is accepted for call-site parity; iOS Link no longer surfaces
    // preview-apply diagnostics in this tab.
    @Suppress("UNUSED_PARAMETER")
    val unusedLiveViewSource = liveViewSource
    val disconnectedState = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
    val state by (session?.state ?: disconnectedState).collectAsState()
    val linked = state is CameraSessionState.Connected
    val health = linkHealth?.presentation ?: LinkHealthPresentation()
    val scoreBand =
        when {
            health.score >= 80 -> "Stable"
            health.score >= 50 -> "Watch"
            else -> "Poor"
        }
    val healthCaption =
        if (session == null || !linked) {
            health.detail.ifBlank { stringResource(R.string.settings_link_no_camera_caption) }
        } else {
            val detail = health.detail.ifBlank { stringResource(R.string.settings_active_link) }
            "$detail · $scoreBand"
        }
    val transportValue =
        when {
            session == null && activeTransportLabel == null ->
                stringResource(R.string.settings_transport_not_connected)
            !linked -> stringResource(R.string.settings_transport_not_connected)
            else ->
                stringResource(
                    R.string.settings_transport_active,
                    activeTransportLabel ?: "Wi-Fi",
                )
        }
    // iOS collapses the 3-way core bias to the mockup Size / Quality pair.
    val qualityBiasSizeSelected = settings.qualityBias != LiveViewQualityBias.DETAIL
    val connectionTitle =
        if (linked && onDisconnect != null) {
            stringResource(R.string.action_disconnect)
        } else {
            stringResource(R.string.settings_connect_over_wifi)
        }

    SettingsDashScale(
        title = stringResource(R.string.settings_link_health),
        caption = healthCaption,
        score = if (linked) health.score else 0,
    )

    SettingsRowCard {
        SettingsInlineRow(
            title = stringResource(R.string.settings_current_transport),
            showTopDivider = false,
        ) {
            SettingsValueText(transportValue)
        }
        SettingsInlineRow(title = stringResource(R.string.settings_stream_preset)) {
            Row(
                Modifier.selectableGroup(),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                LiveViewStreamPreset.entries.forEach { preset ->
                    AssistChoice(
                        label = preset.label,
                        selected = settings.streamPreset == preset,
                    ) {
                        settings.streamPreset = preset
                        onInteraction()
                    }
                }
            }
        }
        SettingsInlineRow(title = stringResource(R.string.settings_quality_bias)) {
            Row(
                Modifier.selectableGroup(),
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                AssistChoice(
                    label = stringResource(R.string.settings_quality_bias_size),
                    selected = qualityBiasSizeSelected,
                ) {
                    settings.qualityBias = LiveViewQualityBias.LATENCY
                    onInteraction()
                }
                AssistChoice(
                    label = stringResource(R.string.settings_quality_bias_quality),
                    selected = !qualityBiasSizeSelected,
                ) {
                    settings.qualityBias = LiveViewQualityBias.DETAIL
                    onInteraction()
                }
            }
        }
        SettingsInlineRow(title = stringResource(R.string.settings_connection_action)) {
            SettingsActionPill(connectionTitle) {
                if (linked) {
                    onDisconnect?.invoke()
                } else {
                    onReconnect?.invoke()
                }
                onInteraction()
            }
        }
        SettingsInlineRow(title = stringResource(R.string.settings_health_threshold)) {
            SettingsValueText(stringResource(R.string.preview_preset_balanced))
        }
        SettingsInlineRow(title = stringResource(R.string.settings_reconnect_window)) {
            SettingsValueText(stringResource(R.string.settings_reconnect_window_value))
        }
    }
}

/**
 * View Assist tab — 1:1 with iOS `ViewAssistSettingsRows`: eight per-tool cards
 * (False Color, Zebra, Waveform, Parade, Histogram, Vectorscope, Peaking,
 * Traffic Lights). Landscape uses the same two-column masonry reading order;
 * portrait is a single full-width column. Tool on/off and LUT library stay on
 * the monitor toolbar popups, matching iOS.
 */
@Composable
private fun AssistRows(
    settings: OperatorSettings,
    assistState: AssistState,
    lutLibrary: AndroidLutLibrary?,
    cameraInput: ExposureAssistCameraInput,
    onSettingToggle: (OperatorSettings.Toggle) -> Unit,
    onAssistToggle: (AssistTool) -> Unit,
    onInteraction: () -> Unit,
) {
    @Suppress("UNUSED_PARAMETER")
    val unusedLutLibrary = lutLibrary
    @Suppress("UNUSED_PARAMETER")
    val unusedSettingToggle = onSettingToggle
    val imageEffectsAvailable = Build.VERSION.SDK_INT >= 33 && SwiftCore.isAvailable
    val isPortrait = LocalConfiguration.current.orientation == Configuration.ORIENTATION_PORTRAIT

    @Composable
    fun FalseColorCard() {
        if (!imageEffectsAvailable) {
            SettingsRowCard(title = stringResource(R.string.settings_false_color)) {
                SettingsInlineRow(title = stringResource(R.string.settings_image_processing), showTopDivider = false) {
                    SettingsValueText(stringResource(R.string.settings_image_processing_unavailable))
                }
            }
            return
        }
        val configuration = settings.feedEffectsConfiguration
        SettingsRowCard(
            title = stringResource(R.string.settings_false_color),
            onReset = {
                assistState.resetFalseColorSelection()
                settings.resetFalseColorConfiguration()
                onInteraction()
            },
        ) {
            SettingsInlineRow(title = stringResource(R.string.settings_scale), showTopDivider = false) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    FeedFalseColorScale.entries.forEach { scale ->
                        AssistChoice(
                            label = stringResource(scale.labelResource()),
                            selected = assistState.selectedFalseColorScale == scale,
                        ) {
                            assistState.selectFalseColorScale(scale)
                            onInteraction()
                        }
                    }
                }
            }
            SettingsSwitchRow(
                stringResource(R.string.settings_reference_display),
                isOn = configuration.falseColorReferenceEnabled,
            ) {
                val enabled = !configuration.falseColorReferenceEnabled
                settings.feedEffectsConfiguration =
                    configuration.copy(falseColorReferenceEnabled = enabled)
                if (enabled && !assistState.isOn(AssistTool.FALSE)) {
                    onAssistToggle(AssistTool.FALSE)
                } else {
                    onInteraction()
                }
            }
        }
    }

    @Composable
    fun PeakingCard() {
        if (!imageEffectsAvailable) return
        PeakingSettingsRows(settings, onInteraction)
    }

    @Composable
    fun ZebraCard() {
        if (!imageEffectsAvailable) return
        ZebraSettingsRows(settings, cameraInput, onInteraction)
    }

    if (isPortrait) {
        Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
            FalseColorCard()
            ZebraCard()
            WaveformSettingsCard(settings, onInteraction)
            ParadeSettingsCard(settings, onInteraction)
            HistogramSettingsCard(settings, onInteraction)
            VectorscopeSettingsCard(settings, onInteraction)
            PeakingCard()
            TrafficLightsSettingsCard(settings, onInteraction)
        }
    } else {
        // iOS masonry: left = odd cards (FC, Waveform, Histogram, Peaking),
        // right = even (Zebra, Parade, Vectorscope, Traffic Lights).
        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
            verticalAlignment = Alignment.Top,
        ) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                FalseColorCard()
                WaveformSettingsCard(settings, onInteraction)
                HistogramSettingsCard(settings, onInteraction)
                PeakingCard()
            }
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(8.dp)) {
                ZebraCard()
                ParadeSettingsCard(settings, onInteraction)
                VectorscopeSettingsCard(settings, onInteraction)
                TrafficLightsSettingsCard(settings, onInteraction)
            }
        }
    }
}

private val imageEffectTools: Set<AssistTool> =
    setOf(AssistTool.LUT, AssistTool.PEAK, AssistTool.FALSE, AssistTool.ZEBRA)

@Composable
private fun feedLutLabel(lut: FeedLut): String =
    stringResource(
        when (lut) {
            FeedLut.LOG3G10_709 -> R.string.lut_log_709
            FeedLut.NLOG_709 -> R.string.lut_nlog_709
            FeedLut.MONO -> R.string.lut_mono
        },
    )

@Composable
private fun peakingSensitivityLabel(value: FeedPeakingSensitivity): String =
    stringResource(
        when (value) {
            FeedPeakingSensitivity.LOW -> R.string.peaking_low
            FeedPeakingSensitivity.MEDIUM -> R.string.peaking_medium
            FeedPeakingSensitivity.HIGH -> R.string.peaking_high
        },
    )

@Composable
private fun peakingColorLabel(value: FeedPeakingColor): String =
    stringResource(
        when (value) {
            FeedPeakingColor.WHITE -> R.string.color_white
            FeedPeakingColor.BLUE -> R.string.color_blue
            FeedPeakingColor.RED -> R.string.color_red
            FeedPeakingColor.GREEN -> R.string.color_green
        },
    )

@Composable
private fun zebraColorLabel(value: FeedZebraStripeColor): String =
    stringResource(
        when (value) {
            FeedZebraStripeColor.WHITE -> R.string.color_white
            FeedZebraStripeColor.AMBER -> R.string.color_amber
            FeedZebraStripeColor.RED -> R.string.color_red
            FeedZebraStripeColor.CYAN -> R.string.color_cyan
            FeedZebraStripeColor.GREEN -> R.string.color_green
        },
    )

@Composable
private fun framingFamilyLabel(value: LocalFramingGuideFamily): String =
    stringResource(
        if (value == LocalFramingGuideFamily.FILM) R.string.framing_family_film
        else R.string.framing_family_social,
    )

@Composable
private fun framingRatioLabel(value: LocalFramingAspectRatio): String =
    stringResource(
        when (value) {
            LocalFramingAspectRatio.RATIO_276 -> R.string.framing_ratio_276
            LocalFramingAspectRatio.RATIO_239 -> R.string.framing_ratio_239
            LocalFramingAspectRatio.RATIO_235 -> R.string.framing_ratio_235
            LocalFramingAspectRatio.RATIO_200 -> R.string.framing_ratio_200
            LocalFramingAspectRatio.RATIO_185 -> R.string.framing_ratio_185
            LocalFramingAspectRatio.RATIO_16_9 -> R.string.framing_ratio_16_9
            LocalFramingAspectRatio.RATIO_166 -> R.string.framing_ratio_166
            LocalFramingAspectRatio.RATIO_143 -> R.string.framing_ratio_143
            LocalFramingAspectRatio.RATIO_4_3 -> R.string.framing_ratio_4_3
            LocalFramingAspectRatio.RATIO_9_16 -> R.string.framing_ratio_9_16
            LocalFramingAspectRatio.RATIO_4_5 -> R.string.framing_ratio_4_5
            LocalFramingAspectRatio.RATIO_1_1 -> R.string.framing_ratio_1_1
            LocalFramingAspectRatio.RATIO_2_3 -> R.string.framing_ratio_2_3
            LocalFramingAspectRatio.RATIO_191 -> R.string.framing_ratio_191
        },
    )

@Composable
private fun desqueezeRatioLabel(value: LocalDesqueezeRatio): String =
    stringResource(
        when (value) {
            LocalDesqueezeRatio.X100 -> R.string.desqueeze_1
            LocalDesqueezeRatio.X133 -> R.string.desqueeze_133
            LocalDesqueezeRatio.X150 -> R.string.desqueeze_15
            LocalDesqueezeRatio.X165 -> R.string.desqueeze_165
            LocalDesqueezeRatio.X180 -> R.string.desqueeze_18
            LocalDesqueezeRatio.X200 -> R.string.desqueeze_2
        },
    )

/** iOS-matched peaking choices; Swift resolves the actual detector values and RGB. */
@Composable
private fun PeakingSettingsRows(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.feedEffectsConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_peaking),
        onReset = {
            settings.resetPeakingConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = stringResource(R.string.settings_sensitivity), showTopDivider = false) {
            Row(
                Modifier.widthIn(max = 220.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                FeedPeakingSensitivity.entries.forEach { sensitivity ->
                    AssistChoice(
                        label = peakingSensitivityLabel(sensitivity),
                        selected = configuration.peakingSensitivity == sensitivity,
                    ) {
                        settings.feedEffectsConfiguration =
                            configuration.copy(peakingSensitivity = sensitivity)
                        onInteraction()
                    }
                }
            }
        }
        SettingsInlineRow(title = stringResource(R.string.settings_color)) {
            Row(
                Modifier.widthIn(max = 220.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                FeedPeakingColor.entries.forEach { color ->
                    AssistChoice(label = peakingColorLabel(color), selected = configuration.peakingColor == color) {
                        settings.feedEffectsConfiguration = configuration.copy(peakingColor = color)
                        onInteraction()
                    }
                }
            }
        }
    }
}

/** Dual-zone zebra settings retain canonical monitor percentages across unit changes. */
@Composable
private fun ZebraSettingsRows(
    settings: OperatorSettings,
    cameraInput: ExposureAssistCameraInput,
    onInteraction: () -> Unit,
) {
    val configuration = settings.feedEffectsConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_zebra),
        onReset = {
            settings.resetZebraConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = stringResource(R.string.settings_units), showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                FeedZebraUnit.entries.forEach { unit ->
                    AssistChoice(
                        label =
                            stringResource(
                                if (unit == FeedZebraUnit.NATIVE) R.string.zebra_unit_native
                                else R.string.false_color_scale_ire,
                            ),
                        selected = configuration.zebraUnit == unit,
                    ) {
                        settings.feedEffectsConfiguration = configuration.copy(zebraUnit = unit)
                        onInteraction()
                    }
                }
            }
        }
        SettingsSwitchRow(stringResource(R.string.settings_highlight), isOn = configuration.zebraHighlightEnabled) {
            settings.feedEffectsConfiguration =
                configuration.copy(zebraHighlightEnabled = !configuration.zebraHighlightEnabled)
            onInteraction()
        }
        SettingsInlineRow(title = stringResource(R.string.settings_highlight_threshold)) {
            ZebraThresholdStepper(
                cameraInput = cameraInput,
                unit = configuration.zebraUnit,
                monitorPercent = configuration.zebraHighlightIre,
                onChange = { monitorPercent ->
                    settings.feedEffectsConfiguration =
                        configuration.copy(zebraHighlightIre = monitorPercent)
                    onInteraction()
                },
            )
        }
        SettingsInlineRow(title = stringResource(R.string.settings_highlight_color)) {
            ZebraColorChoices(
                selected = configuration.zebraHighlightColor,
                onSelect = { color ->
                    settings.feedEffectsConfiguration = configuration.copy(zebraHighlightColor = color)
                    onInteraction()
                },
            )
        }
        SettingsSwitchRow(stringResource(R.string.settings_midtone), isOn = configuration.zebraMidtoneEnabled) {
            settings.feedEffectsConfiguration =
                configuration.copy(zebraMidtoneEnabled = !configuration.zebraMidtoneEnabled)
            onInteraction()
        }
        SettingsInlineRow(title = stringResource(R.string.settings_midtone_threshold)) {
            ZebraThresholdStepper(
                cameraInput = cameraInput,
                unit = configuration.zebraUnit,
                monitorPercent = configuration.zebraMidtoneIre,
                onChange = { monitorPercent ->
                    settings.feedEffectsConfiguration =
                        configuration.copy(zebraMidtoneIre = monitorPercent)
                    onInteraction()
                },
            )
        }
        SettingsInlineRow(title = stringResource(R.string.settings_midtone_color)) {
            ZebraColorChoices(
                selected = configuration.zebraMidtoneColor,
                onSelect = { color ->
                    settings.feedEffectsConfiguration = configuration.copy(zebraMidtoneColor = color)
                    onInteraction()
                },
            )
        }
    }
}

/** Swift-only native/IRE conversion stepper: no Kotlin exposure conversion is permitted here. */
@Composable
private fun ZebraThresholdStepper(
    cameraInput: ExposureAssistCameraInput,
    unit: FeedZebraUnit,
    monitorPercent: Float,
    onChange: (Float) -> Unit,
) {
    val editorValue =
        remember(cameraInput, unit, monitorPercent) {
            zebraEditorValue(cameraInput, unit, monitorPercent)
        } ?: return
    val maximum = if (unit == FeedZebraUnit.NATIVE) 255f else 100f
    val rounded = editorValue.roundToInt().coerceIn(0, maximum.roundToInt())
    val thresholdDescription =
        stringResource(R.string.settings_zebra_threshold_description, maximum.roundToInt())
    var directEntry by remember(unit, rounded) { mutableStateOf(rounded.toString()) }
    fun adjust(delta: Float) {
        zebraMonitorPercent(cameraInput, unit, (editorValue + delta).coerceIn(0f, maximum))?.let(onChange)
    }
    Row(horizontalArrangement = Arrangement.spacedBy(5.dp), verticalAlignment = Alignment.CenterVertically) {
        AssistChoice(label = "−", selected = false) { adjust(-1f) }
        OutlinedTextField(
            value = directEntry,
            onValueChange = { raw ->
                val digits = raw.filter(Char::isDigit).take(3)
                val normalized = normalizedZebraEntry(digits, maximum.roundToInt())
                directEntry = normalized?.toString() ?: digits
                if (normalized != null) {
                    zebraMonitorPercent(cameraInput, unit, normalized.toFloat())?.let(onChange)
                }
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number),
            textStyle = chromeStyle(12.5f, FontWeight.SemiBold),
            modifier =
                Modifier.width(72.dp).semantics {
                    contentDescription = thresholdDescription
                },
        )
        AssistChoice(label = "+", selected = false) { adjust(1f) }
    }
}

/** Digits-only direct entry with the same closed-range clamp as iOS. */
internal fun normalizedZebraEntry(raw: String, maximum: Int): Int? =
    raw.toIntOrNull()?.coerceIn(0, maximum)

@Composable
private fun ZebraColorChoices(
    selected: FeedZebraStripeColor,
    onSelect: (FeedZebraStripeColor) -> Unit,
) {
    Row(
        Modifier.widthIn(max = 220.dp).horizontalScroll(rememberScrollState()),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        FeedZebraStripeColor.entries.forEach { color ->
            AssistChoice(label = zebraColorLabel(color), selected = selected == color) {
                onSelect(color)
            }
        }
    }
}

/** Canvas-only scope controls. Each option below has a corresponding render/sampler path. */
/** Waveform card — iOS rows only (mode, brightness, guide switches); no panel scale. */
@Composable
private fun WaveformSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_waveform),
        onReset = {
            settings.resetWaveformConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = stringResource(R.string.settings_mode), showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScopeWaveformMode.entries.forEach { mode ->
                    AssistChoice(
                        label =
                            stringResource(
                                if (mode == ScopeWaveformMode.LUMA) R.string.scope_chip_luma
                                else R.string.scope_chip_rgb,
                            ),
                        selected = configuration.waveformMode == mode,
                    ) {
                        settings.scopeAssistConfiguration = configuration.copy(waveformMode = mode)
                        onInteraction()
                    }
                }
            }
        }
        ScopeBrightnessRow(
            brightness = configuration.waveformBrightness,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(waveformBrightness = value)
                onInteraction()
            },
        )
        ScopeGuideRows(
            guides = configuration.waveformGuides,
            onChange = { guides ->
                settings.scopeAssistConfiguration = configuration.copy(waveformGuides = guides)
                onInteraction()
            },
        )
    }
}

/** Parade card — iOS rows only (mode, brightness, guide switches). */
@Composable
private fun ParadeSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_parade),
        onReset = {
            settings.resetParadeConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = stringResource(R.string.settings_mode), showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScopeParadeMode.entries.forEach { mode ->
                    AssistChoice(
                        label =
                            stringResource(
                                if (mode == ScopeParadeMode.RGB) R.string.scope_chip_rgb
                                else R.string.scope_chip_yrgb,
                            ),
                        selected = configuration.paradeMode == mode,
                    ) {
                        settings.scopeAssistConfiguration = configuration.copy(paradeMode = mode)
                        onInteraction()
                    }
                }
            }
        }
        ScopeBrightnessRow(
            brightness = configuration.paradeBrightness,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(paradeBrightness = value)
                onInteraction()
            },
        )
        ScopeGuideRows(
            guides = configuration.paradeGuides,
            onChange = { guides ->
                settings.scopeAssistConfiguration = configuration.copy(paradeGuides = guides)
                onInteraction()
            },
        )
    }
}

/** Vectorscope card — iOS rows only (trace zoom + brightness). */
@Composable
private fun VectorscopeSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsRowCard(
        title = stringResource(R.string.settings_vectorscope),
        onReset = {
            settings.resetVectorscopeConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = stringResource(R.string.settings_trace_zoom), showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScopeVectorscopeZoom.entries.forEach { zoom ->
                    AssistChoice(
                        label =
                            stringResource(
                                when (zoom.wireOrdinal) {
                                    0 -> R.string.scope_zoom_1
                                    1 -> R.string.scope_zoom_2
                                    else -> R.string.scope_zoom_4
                                },
                            ),
                        selected = configuration.vectorscopeZoom == zoom,
                    ) {
                        settings.scopeAssistConfiguration = configuration.copy(vectorscopeZoom = zoom)
                        onInteraction()
                    }
                }
            }
        }
        ScopeBrightnessRow(
            brightness = configuration.vectorscopeBrightness,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(vectorscopeBrightness = value)
                onInteraction()
            },
        )
    }
}

/**
 * Histogram card — iOS: Traffic Lights switch + Crush/Clip Compensation (panel
 * scale is not an operator-setup control on iOS).
 */
@Composable
private fun HistogramSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    SettingsRowCard(
        title = stringResource(R.string.settings_histogram),
        onReset = {
            settings.resetHistogramConfiguration()
            onInteraction()
        },
    ) {
        SettingsSwitchRow(
            stringResource(R.string.settings_traffic_lights),
            isOn = settings.histogramTrafficLightsEnabled.value,
            showTopDivider = false,
        ) {
            settings.histogramTrafficLightsEnabled.toggle()
            onInteraction()
        }
        SettingsInlineRow(title = stringResource(R.string.settings_crush_clip)) {
            ScopeCrushClipCompensationChoices(
                selected = settings.scopeCrushClipCompensation,
                onSelect = { compensation ->
                    settings.scopeCrushClipCompensation = compensation
                    onInteraction()
                },
            )
        }
    }
}

/** Traffic Lights card — iOS: Crush/Clip Compensation only (shared with histogram). */
@Composable
private fun TrafficLightsSettingsCard(settings: OperatorSettings, onInteraction: () -> Unit) {
    SettingsRowCard(
        title = stringResource(R.string.settings_traffic_lights),
        onReset = {
            settings.resetTrafficLightsConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = stringResource(R.string.settings_crush_clip), showTopDivider = false) {
            ScopeCrushClipCompensationChoices(
                selected = settings.scopeCrushClipCompensation,
                onSelect = { compensation ->
                    settings.scopeCrushClipCompensation = compensation
                    onInteraction()
                },
            )
        }
    }
}

@Composable
private fun ScopeBrightnessRow(brightness: Int, onSelect: (Int) -> Unit) {
    SettingsInlineRow(title = stringResource(R.string.settings_brightness)) {
        Row(
            Modifier.widthIn(max = 250.dp),
            horizontalArrangement = Arrangement.spacedBy(7.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Slider(
                value = brightness.toFloat(),
                onValueChange = { onSelect(it.roundToInt()) },
                valueRange =
                    ScopeAssistConfiguration.MIN_BRIGHTNESS.toFloat()..
                        ScopeAssistConfiguration.MAX_BRIGHTNESS.toFloat(),
                steps = ScopeAssistConfiguration.MAX_BRIGHTNESS - ScopeAssistConfiguration.MIN_BRIGHTNESS - 1,
                modifier = Modifier.weight(1f),
            )
            SettingsValueText(stringResource(R.string.settings_percent, brightness))
        }
    }
}

@Composable
private fun ScopeGuideRows(guides: ScopeGuideLines, onChange: (ScopeGuideLines) -> Unit) {
    SettingsSwitchRow(stringResource(R.string.settings_safe_border_clip), isOn = guides.clip) {
        onChange(guides.copy(clip = !guides.clip))
    }
    SettingsSwitchRow(stringResource(R.string.settings_safe_border_crush), isOn = guides.crush) {
        onChange(guides.copy(crush = !guides.crush))
    }
    SettingsSwitchRow(stringResource(R.string.settings_middle_gray), isOn = guides.middle) {
        onChange(guides.copy(middle = !guides.middle))
    }
}

/**
 * Custom LUT manager. `OpenDocument` yields one operator-selected URI only; its bytes are validated
 * by Swift before the app-private copy is made and the URI never enters preferences or metadata.
 */
@Composable
private fun StoredLutLibraryRows(
    library: AndroidLutLibrary,
    assistState: AssistState,
    onInteraction: () -> Unit,
) {
    val resources = LocalResources.current
    val entries by library.entries.collectAsState()
    val failures by library.failures.collectAsState()
    val scope = rememberCoroutineScope()
    var feedback by remember { mutableStateOf<String?>(null) }
    var pendingDeletion by remember { mutableStateOf<StoredLutEntry?>(null) }
    val importLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocument()) { uri ->
            if (uri != null) {
                scope.launch {
                    when (val result = library.importFromDocument(uri)) {
                        is CustomLutImportResult.Imported -> {
                            assistState.selectStoredLut(result.entry.selection)
                            if (!assistState.isOn(AssistTool.LUT)) assistState.toggle(AssistTool.LUT)
                            feedback =
                                resources.getString(R.string.lut_added, result.entry.displayName)
                            onInteraction()
                        }
                        is CustomLutImportResult.Rejected -> feedback = result.message
                    }
                }
            }
        }
    val customEntries = entries.filter { it.selection.category == StoredLutCategory.CUSTOM }
    val redEntries = entries.filter { it.selection.category == StoredLutCategory.RED }

    SettingsGroupCard(
        title = stringResource(R.string.lut_custom_library),
        caption = stringResource(R.string.lut_custom_caption),
    ) {
        if (customEntries.isEmpty()) {
            Text(
                stringResource(R.string.lut_custom_empty),
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.muted,
            )
        } else {
            customEntries.forEachIndexed { index, entry ->
                StoredLutEntryRow(
                    entry = entry,
                    selected = assistState.selectedLut == FeedLutSelection.Stored(entry.selection),
                    failure = failures[entry.selection],
                    showTopDivider = index != 0,
                    onSelect = {
                        scope.launch {
                            if (library.prepare(entry.selection)) {
                                assistState.selectStoredLut(entry.selection)
                                if (!assistState.isOn(AssistTool.LUT)) assistState.toggle(AssistTool.LUT)
                                feedback = resources.getString(R.string.lut_selected, entry.displayName)
                                onInteraction()
                            } else {
                                feedback = failures[entry.selection]?.operatorMessage
                                    ?: resources.getString(R.string.lut_prepare_failed)
                            }
                        }
                    },
                    onRemove = { pendingDeletion = entry },
                )
            }
        }
        SettingsInlineRow(
            title = stringResource(R.string.lut_import),
            showTopDivider = customEntries.isNotEmpty(),
        ) {
            SettingsLinkAction(stringResource(R.string.action_choose)) {
                importLauncher.launch(arrayOf("*/*"))
            }
        }
        feedback?.let { message ->
            Text(
                message,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.accent,
            )
        }
    }

    if (redEntries.isNotEmpty()) {
        SettingsGroupCard(
            title = stringResource(R.string.lut_stored_red),
            caption = stringResource(R.string.lut_stored_red_caption),
        ) {
            redEntries.forEachIndexed { index, entry ->
                StoredLutEntryRow(
                    entry = entry,
                    selected = assistState.selectedLut == FeedLutSelection.Stored(entry.selection),
                    failure = failures[entry.selection],
                    showTopDivider = index != 0,
                    onSelect = {
                        scope.launch {
                            if (library.prepare(entry.selection)) {
                                assistState.selectStoredLut(entry.selection)
                                if (!assistState.isOn(AssistTool.LUT)) assistState.toggle(AssistTool.LUT)
                                onInteraction()
                            }
                        }
                    },
                    onRemove = { pendingDeletion = entry },
                )
            }
        }
    }

    pendingDeletion?.let { entry ->
        AlertDialog(
            onDismissRequest = { pendingDeletion = null },
            title = { Text(stringResource(R.string.lut_remove_title, entry.displayName)) },
            text = {
                Text(
                    stringResource(R.string.lut_remove_message),
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        pendingDeletion = null
                        scope.launch {
                            if (library.delete(entry.selection)) {
                                val selectionBeforeDeletion = assistState.selectedLut
                                if (selectionBeforeDeletion == FeedLutSelection.Stored(entry.selection)) {
                                    val replacement = library.firstPreparedReplacement(entry.selection)
                                    when (
                                        val reconciled =
                                            reconciledLutSelectionAfterDeletion(
                                                selectionBeforeDeletion,
                                                entry.selection,
                                                replacement,
                                            )
                                    ) {
                                        is FeedLutSelection.BuiltIn -> assistState.selectLut(reconciled.value)
                                        is FeedLutSelection.Stored -> assistState.selectStoredLut(reconciled.value)
                                    }
                                }
                                feedback = resources.getString(R.string.lut_removed, entry.displayName)
                                onInteraction()
                            } else {
                                feedback = resources.getString(R.string.lut_remove_failed)
                            }
                        }
                    },
                ) { Text(stringResource(R.string.action_remove)) }
            },
            dismissButton = {
                TextButton(onClick = { pendingDeletion = null }) {
                    Text(stringResource(R.string.action_cancel))
                }
            },
        )
    }
}

/** One accessible custom/RED selection row with a distinct destructive action. */
@Composable
private fun StoredLutEntryRow(
    entry: StoredLutEntry,
    selected: Boolean,
    failure: StoredLutFailure?,
    showTopDivider: Boolean,
    onSelect: () -> Unit,
    onRemove: () -> Unit,
) {
    SettingsInlineRow(title = entry.displayName, showTopDivider = showTopDivider) {
        Row(
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            AssistChoice(label = stringResource(R.string.action_use), selected = selected, onClick = onSelect)
            SettingsLinkAction(stringResource(R.string.action_remove), onClick = onRemove)
        }
    }
    failure?.let {
        Text(
            it.operatorMessage,
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.accent,
        )
    }
}

/** Fail-closed Android RED delivery status; no network request or fixture exists in this build. */
@Composable
private fun RedLutWorkflowRows() {
    val context = LocalContext.current
    val gate = remember(context) { RedLutDownloadGate(context.applicationContext) }
    var readiness by remember { mutableStateOf(gate.readiness()) }
    SettingsGroupCard(
        title = stringResource(R.string.lut_red_ipp2),
        caption = stringResource(R.string.lut_red_caption),
    ) {
        SettingsInlineRow(title = stringResource(R.string.lut_terms_acknowledgement), showTopDivider = false) {
            SettingsValueText(stringResource(R.string.status_not_configured))
        }
        SettingsInlineRow(title = stringResource(R.string.lut_delivery)) {
            SettingsValueText(
                stringResource(
                    if (readiness.canEnterWorkflow) R.string.status_ready else R.string.status_blocked,
                ),
            )
        }
        SettingsInlineRow(title = stringResource(R.string.lut_network_guard)) {
            SettingsValueText(
                when (readiness.network) {
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.AVAILABLE -> stringResource(R.string.network_internet_ready)
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT -> stringResource(R.string.network_camera_ap)
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.NO_INTERNET -> stringResource(R.string.status_offline)
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE -> stringResource(R.string.status_core_unavailable)
                },
            )
        }
        SettingsInlineRow(title = stringResource(R.string.lut_refresh_status)) {
            SettingsLinkAction(stringResource(R.string.action_refresh)) { readiness = gate.readiness() }
        }
        Text(
            readiness.network.operatorMessage,
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
        readiness.configurationMessage?.let { message ->
            Text(
                message,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.accent,
            )
        }
        Text(
            "[VERIFY-ON-HW] Validate RED authorization, terms acknowledgement, authenticated download, " +
                "camera-AP blocking, and import on a real Android device before enabling delivery.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
    }
}

/** A 48dp local-framing switch with native checked semantics. */
@Composable
private fun FramingAssistSwitchRow(
    title: String,
    isOn: Boolean,
    showTopDivider: Boolean = true,
    onToggle: () -> Unit,
) {
    SettingsInlineRow(title = title, showTopDivider = showTopDivider) {
        Box(
            Modifier.size(48.dp).toggleable(
                value = isOn,
                role = Role.Switch,
                onValueChange = { onToggle() },
            ).semantics { contentDescription = title },
            contentAlignment = Alignment.Center,
        ) {
            SettingsSwitchGraphic(isOn)
        }
    }
}

/** Radio choices for the active delivery-guide family tab. */
@Composable
private fun FramingGuideFamilyChoices(
    selected: LocalFramingGuideFamily,
    onSelect: (LocalFramingGuideFamily) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LocalFramingGuideFamily.entries.forEach { family ->
            FramingAssistChoice(
                label = framingFamilyLabel(family),
                selected = family == selected,
                modifier = Modifier.weight(1f),
            ) { onSelect(family) }
        }
    }
}

/** Multi-select ratio rows for the active iOS-equivalent delivery family. */
@Composable
private fun FramingGuideChoices(
    family: LocalFramingGuideFamily,
    selected: Set<LocalFramingAspectRatio>,
    onToggle: (LocalFramingAspectRatio) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LocalFramingAspectRatio.forFamily(family).chunked(3).forEach { row ->
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                row.forEach { ratio ->
                    FramingAssistToggleChoice(
                        label = framingRatioLabel(ratio),
                        checked = ratio in selected,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(ratio) }
                }
                repeat(3 - row.size) { Spacer(Modifier.weight(1f)) }
            }
        }
    }
}

/** Independent thirds, phi, and diagonal composition-grid choices. */
@Composable
private fun FramingGridChoices(
    thirds: Boolean,
    phi: Boolean,
    diagonal: Boolean,
    onToggleThirds: () -> Unit,
    onTogglePhi: () -> Unit,
    onToggleDiagonal: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        FramingAssistToggleChoice(
            label = stringResource(R.string.framing_grid_thirds),
            checked = thirds,
            modifier = Modifier.weight(1f),
            onClick = onToggleThirds,
        )
        FramingAssistToggleChoice(
            label = stringResource(R.string.framing_grid_phi),
            checked = phi,
            modifier = Modifier.weight(1f),
            onClick = onTogglePhi,
        )
        FramingAssistToggleChoice(
            label = stringResource(R.string.framing_grid_diagonal),
            checked = diagonal,
            modifier = Modifier.weight(1f),
            onClick = onToggleDiagonal,
        )
    }
}

/** Compact radio rows for every supported local de-squeeze factor. */
@Composable
private fun DesqueezeRatioChoices(
    selected: LocalDesqueezeRatio,
    onSelect: (LocalDesqueezeRatio) -> Unit,
) {
    Column(
        Modifier.fillMaxWidth().selectableGroup(),
        verticalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LocalDesqueezeRatio.entries.chunked(3).forEach { row ->
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                row.forEach { ratio ->
                    FramingAssistChoice(
                        label = desqueezeRatioLabel(ratio),
                        selected = ratio == selected,
                        modifier = Modifier.weight(1f),
                    ) { onSelect(ratio) }
                }
            }
        }
    }
}

/** Two iOS-matching presentation choices for the local camera-level assist. */
@Composable
private fun LevelStyleChoices(
    selected: LocalLevelStyle,
    onSelect: (LocalLevelStyle) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LocalLevelStyle.entries.forEach { style ->
            FramingAssistChoice(
                label =
                    stringResource(
                        if (style == LocalLevelStyle.HORIZON) R.string.level_horizon
                        else R.string.level_gauge,
                    ),
                selected = style == selected,
                modifier = Modifier.weight(1f),
            ) { onSelect(style) }
        }
    }
}

/** Radio choice for the source axis compressed by the local anamorphic capture. */
@Composable
private fun DesqueezeOrientationChoices(
    selected: LocalDesqueezeOrientation,
    onSelect: (LocalDesqueezeOrientation) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(6.dp),
    ) {
        LocalDesqueezeOrientation.entries.forEach { orientation ->
            FramingAssistChoice(
                label =
                    stringResource(
                        if (orientation == LocalDesqueezeOrientation.HORIZONTAL) {
                            R.string.orientation_horizontal
                        } else {
                            R.string.orientation_vertical
                        },
                    ),
                selected = orientation == selected,
                modifier = Modifier.weight(1f),
            ) { onSelect(orientation) }
        }
    }
}

/** Accessible 48dp radio choice shared by the local-framing configuration. */
@Composable
private fun FramingAssistChoice(
    label: String,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .height(48.dp)
            .background(
                if (selected) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                ChromeShape,
            )
            .border(1.dp, if (selected) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
            .selectable(selected = selected, role = Role.RadioButton, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(10.5f, FontWeight.SemiBold, mono = true),
            color = if (selected) LiveDesign.accent else LiveDesign.muted,
            maxLines = 1,
        )
    }
}

/** Accessible multi-select choice shared by guide-ratio and grid-pattern controls. */
@Composable
private fun FramingAssistToggleChoice(
    label: String,
    checked: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .height(48.dp)
            .background(
                if (checked) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                ChromeShape,
            )
            .border(1.dp, if (checked) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
            .toggleable(
                value = checked,
                role = Role.Checkbox,
                onValueChange = { onClick() },
            )
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            style = chromeStyle(10.5f, FontWeight.SemiBold, mono = true),
            color = if (checked) LiveDesign.accent else LiveDesign.muted,
            maxLines = 1,
        )
    }
}

/** Five-option Android mirror of iOS's `SettingsCrushClipSegmented` control. */
@Composable
private fun ScopeCrushClipCompensationChoices(
    selected: ScopeCrushClipCompensation,
    onSelect: (ScopeCrushClipCompensation) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().selectableGroup(),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
    ) {
        ScopeCrushClipCompensation.entries.forEach { option ->
            val active = option == selected
            val optionLabel =
                stringResource(
                    when (option) {
                        ScopeCrushClipCompensation.ZERO -> R.string.crush_clip_zero
                        ScopeCrushClipCompensation.QUARTER -> R.string.crush_clip_quarter
                        ScopeCrushClipCompensation.HALF -> R.string.crush_clip_half
                        ScopeCrushClipCompensation.THREE_QUARTER ->
                            R.string.crush_clip_three_quarter
                        ScopeCrushClipCompensation.ONE -> R.string.crush_clip_one
                    },
                )
            val compactLabel =
                stringResource(
                    when (option) {
                        ScopeCrushClipCompensation.ZERO -> R.string.crush_clip_zero
                        ScopeCrushClipCompensation.QUARTER -> R.string.crush_clip_quarter_compact
                        ScopeCrushClipCompensation.HALF -> R.string.crush_clip_half_compact
                        ScopeCrushClipCompensation.THREE_QUARTER ->
                            R.string.crush_clip_three_quarter_compact
                        ScopeCrushClipCompensation.ONE -> R.string.crush_clip_one_compact
                    },
                )
            val description =
                stringResource(R.string.crush_clip_description, optionLabel)
            Box(
                Modifier
                    .weight(1f)
                    .height(48.dp)
                    .background(
                        if (active) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                        ChromeShape,
                    )
                    .border(1.dp, if (active) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
                    .selectable(
                        selected = active,
                        role = Role.RadioButton,
                        onClick = { onSelect(option) },
                    )
                    .semantics {
                        contentDescription = description
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    compactLabel,
                    style = chromeStyle(15f, FontWeight.SemiBold, mono = true),
                    color = if (active) LiveDesign.accent else LiveDesign.muted,
                    maxLines = 1,
                )
            }
        }
    }
}

/** Controls whose effects stay wholly within the Android shell. */
@Composable
private fun ControlsRows(
    settings: OperatorSettings,
    onToggle: (OperatorSettings.Toggle) -> Unit,
) {
    // iOS Controls is one switch card: Record Confirmation, Bluetooth Remote
    // Shutter, Haptics, Keep Screen Awake — no extra captions under rows.
    SettingsRowCard {
        SettingsSwitchRow(
            stringResource(R.string.settings_record_confirmation),
            isOn = settings.recordConfirmationEnabled.value,
            showTopDivider = false,
        ) { onToggle(settings.recordConfirmationEnabled) }
        SettingsSwitchRow(
            stringResource(R.string.settings_media_remote),
            isOn = settings.mediaRemoteShutterEnabled.value,
        ) { onToggle(settings.mediaRemoteShutterEnabled) }
        SettingsSwitchRow(stringResource(R.string.settings_haptics), isOn = settings.hapticsEnabled.value) {
            onToggle(settings.hapticsEnabled)
        }
        SettingsSwitchRow(stringResource(R.string.settings_keep_awake), isOn = settings.keepScreenAwake.value) {
            onToggle(settings.keepScreenAwake)
        }
    }
}

/** Maps a vertical settings drag to a clamped row index. */
internal fun settingsReorderIndex(pointerY: Float, rowHeight: Float, itemCount: Int): Int {
    require(rowHeight > 0f && itemCount > 0) { "settings reorder list must contain positive rows" }
    return floor(pointerY / rowHeight).toInt().coerceIn(0, itemCount - 1)
}

/** Only the trailing handle lane can begin a settings reorder. */
internal fun settingsReorderGripHit(
    pointerX: Float,
    containerWidth: Float,
    gripWidth: Float,
): Boolean {
    require(containerWidth >= 0f && gripWidth > 0f) { "settings reorder grip must be positive" }
    return pointerX >= (containerWidth - gripWidth).coerceAtLeast(0f) &&
        pointerX <= containerWidth
}

/** Signed per-frame parent-scroll step while a reorder finger rides a viewport edge. */
internal fun settingsReorderAutoScrollDelta(
    pointerRootY: Float,
    viewportTop: Float,
    viewportBottom: Float,
    edgeThreshold: Float,
    maximumStep: Float,
): Float {
    require(viewportBottom >= viewportTop && edgeThreshold > 0f && maximumStep >= 0f) {
        "settings reorder viewport must be valid"
    }
    val topDistance = pointerRootY - viewportTop
    if (topDistance < edgeThreshold) {
        return -maximumStep * ((edgeThreshold - topDistance) / edgeThreshold).coerceIn(0f, 1f)
    }
    val bottomDistance = viewportBottom - pointerRootY
    if (bottomDistance < edgeThreshold) {
        return maximumStep * ((edgeThreshold - bottomDistance) / edgeThreshold).coerceIn(0f, 1f)
    }
    return 0f
}

/** Direct-drag assist order with a TalkBack-equivalent move action on every handle. */
@Composable
internal fun AssistToolbarOrderList(
    settings: OperatorSettings,
    onInteraction: () -> Unit,
    parentScrollState: ScrollState? = null,
    viewportBounds: Rect? = null,
) {
    val tools = settings.assistToolbarOrder
    val latestTools by rememberUpdatedState(tools)
    val latestOnInteraction by rememberUpdatedState(onInteraction)
    var draggingTool by remember { mutableStateOf<AssistTool?>(null) }
    var dragPosition by remember { mutableStateOf(Offset.Zero) }
    var dragRootY by remember { mutableStateOf<Float?>(null) }
    var listBounds by remember { mutableStateOf<Rect?>(null) }
    val rowHeight = 50.dp
    val gripWidth = 48.dp
    val density = LocalDensity.current
    val rowHeightPx = with(density) { rowHeight.toPx() }
    val gripWidthPx = with(density) { gripWidth.toPx() }
    val edgeThresholdPx = with(density) { 48.dp.toPx() }
    val maximumScrollStepPx = with(density) { 12.dp.toPx() }

    LaunchedEffect(draggingTool, dragRootY, viewportBounds, parentScrollState) {
        val scrollState = parentScrollState ?: return@LaunchedEffect
        val rootY = dragRootY ?: return@LaunchedEffect
        val viewport = viewportBounds ?: return@LaunchedEffect
        while (draggingTool != null) {
            val delta =
                settingsReorderAutoScrollDelta(
                    pointerRootY = rootY,
                    viewportTop = viewport.top,
                    viewportBottom = viewport.bottom,
                    edgeThreshold = edgeThresholdPx,
                    maximumStep = maximumScrollStepPx,
                )
            if (delta == 0f) return@LaunchedEffect
            scrollState.scrollBy(delta)
            delay(16)
            val tool = draggingTool ?: return@LaunchedEffect
            val bounds = listBounds ?: continue
            val current = latestTools
            if (current.isNotEmpty()) {
                val target = settingsReorderIndex(rootY - bounds.top, rowHeightPx, current.size)
                if (current.indexOf(tool) != target) {
                    settings.moveAssistToolbarTool(tool, target)
                }
            }
        }
    }

    BoxWithConstraints(
        Modifier.fillMaxWidth()
            .height(rowHeight * tools.size)
            .onGloballyPositioned { listBounds = it.boundsInRoot() }
            .pointerInput(Unit) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { start ->
                        if (settingsReorderGripHit(start.x, size.width.toFloat(), gripWidthPx)) {
                            val current = latestTools
                            if (current.isNotEmpty()) {
                                val index = settingsReorderIndex(start.y, rowHeightPx, current.size)
                                draggingTool = current[index]
                                dragPosition = start
                                dragRootY = listBounds?.top?.plus(start.y)
                                latestOnInteraction()
                            }
                        }
                    },
                    onDrag = { change, _ ->
                        val tool = draggingTool
                        if (tool != null) {
                            change.consume()
                            dragPosition = change.position
                            dragRootY = listBounds?.top?.plus(change.position.y)
                            val current = latestTools
                            if (current.isNotEmpty()) {
                                val target =
                                    settingsReorderIndex(
                                        change.position.y,
                                        rowHeightPx,
                                        current.size,
                                    )
                                if (current.indexOf(tool) != target) {
                                    settings.moveAssistToolbarTool(tool, target)
                                }
                            }
                        }
                    },
                    onDragEnd = {
                        draggingTool = null
                        dragRootY = null
                    },
                    onDragCancel = {
                        draggingTool = null
                        dragRootY = null
                    },
                )
            },
    ) {
        val listHeightPx = constraints.maxHeight.toFloat()
        tools.forEachIndexed { index, tool ->
            key(tool) {
                val toolTitle = stringResource(tool.titleResource())
                val moveEarlier = stringResource(R.string.settings_move_earlier, toolTitle)
                val moveLater = stringResource(R.string.settings_move_later, toolTitle)
                val positionDescription = stringResource(R.string.settings_position, index + 1)
                val positionLabel = stringResource(R.string.settings_position_number, index + 1)
                val visibilityDescription =
                    stringResource(R.string.settings_toolbar_visibility, toolTitle)
                val visibilityState =
                    stringResource(
                        if (settings.isAssistToolbarToolVisible(tool)) R.string.status_visible
                        else R.string.status_hidden,
                    )
                val reorderDescription =
                    stringResource(R.string.settings_reorder_position, toolTitle, index + 1)
                val dragging = tool == draggingTool
                val y =
                    if (dragging) {
                        (dragPosition.y - rowHeightPx / 2f)
                            .coerceIn(0f, (listHeightPx - rowHeightPx).coerceAtLeast(0f))
                    } else {
                        index * rowHeightPx
                    }
                val accessibilityActions =
                    buildList {
                        if (index > 0) {
                            add(
                                CustomAccessibilityAction(moveEarlier) {
                                    settings.moveAssistToolbarTool(tool, index - 1)
                                    onInteraction()
                                    true
                                },
                            )
                        }
                        if (index < tools.lastIndex) {
                            add(
                                CustomAccessibilityAction(moveLater) {
                                    settings.moveAssistToolbarTool(tool, index + 1)
                                    onInteraction()
                                    true
                                },
                            )
                        }
                    }
                Column(
                    Modifier.offset { IntOffset(0, y.roundToInt()) }
                        .fillMaxWidth()
                        .height(rowHeight)
                        .graphicsLayer {
                            scaleX = if (dragging) 1.02f else 1f
                            scaleY = if (dragging) 1.02f else 1f
                            shadowElevation = if (dragging) 12.dp.toPx() else 0f
                            shape = ChromeShape
                        }
                        .zIndex(if (dragging) 1f else 0f)
                        .background(if (dragging) LiveDesign.surface else androidx.compose.ui.graphics.Color.Transparent),
                ) {
                    if (index != 0) {
                        Box(Modifier.fillMaxWidth().height(1.dp).background(LiveDesign.hairline))
                    }
                    Row(
                        Modifier.fillMaxWidth().weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            Modifier.size(22.dp)
                                .background(LiveDesign.surface, CircleShape)
                                .semantics { contentDescription = positionDescription },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                positionLabel,
                                style = chromeStyle(9f, FontWeight.Medium, mono = true),
                                color = LiveDesign.muted,
                            )
                        }
                        Text(
                            toolTitle,
                            style = chromeStyle(12.5f, FontWeight.SemiBold),
                            color =
                                if (settings.isAssistToolbarToolVisible(tool)) {
                                    LiveDesign.text
                                } else {
                                    LiveDesign.muted
                                },
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            modifier = Modifier.weight(1f),
                        )
                        if (tool == AssistTool.LUT) {
                            SettingsValueText(stringResource(R.string.settings_pinned))
                        } else {
                            Box(
                                Modifier.settingsClickable(role = Role.Switch) {
                                    settings.toggleAssistToolbarToolVisibility(tool)
                                    onInteraction()
                                }.semantics {
                                    contentDescription = visibilityDescription
                                    stateDescription = visibilityState
                                },
                            ) {
                                SettingsSwitchGraphic(settings.isAssistToolbarToolVisible(tool))
                            }
                        }
                        Box(
                            Modifier.width(gripWidth)
                                .fillMaxHeight()
                                .semantics {
                                    contentDescription = reorderDescription
                                    customActions = accessibilityActions
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Canvas(Modifier.size(18.dp, 14.dp)) {
                                val stroke = 1.6.dp.toPx()
                                listOf(2f, 7f, 12f).forEach { yOffset ->
                                    drawLine(
                                        LiveDesign.faint,
                                        Offset(1.dp.toPx(), yOffset.dp.toPx()),
                                        Offset(size.width - 1.dp.toPx(), yOffset.dp.toPx()),
                                        strokeWidth = stroke,
                                        cap = StrokeCap.Round,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/** Direct-drag DISP order with an equivalent TalkBack move action. */
@Composable
internal fun DisplayModeOrderList(
    settings: OperatorSettings,
    onInteraction: () -> Unit,
) {
    val modes = settings.displayModeOrder
    val latestModes by rememberUpdatedState(modes)
    var draggingMode by remember { mutableStateOf<MonitorDisplayMode?>(null) }
    var dragPosition by remember { mutableStateOf(Offset.Zero) }
    val rowHeight = 50.dp
    val gripWidth = 48.dp
    val density = LocalDensity.current
    val rowHeightPx = with(density) { rowHeight.toPx() }
    val gripWidthPx = with(density) { gripWidth.toPx() }

    BoxWithConstraints(
        Modifier.fillMaxWidth()
            .height(rowHeight * modes.size)
            .pointerInput(Unit) {
                detectDragGesturesAfterLongPress(
                    onDragStart = { start ->
                        if (settingsReorderGripHit(start.x, size.width.toFloat(), gripWidthPx)) {
                            val current = latestModes
                            if (current.isNotEmpty()) {
                                draggingMode =
                                    current[
                                        settingsReorderIndex(
                                            start.y,
                                            rowHeightPx,
                                            current.size,
                                        )
                                    ]
                                dragPosition = start
                                onInteraction()
                            }
                        }
                    },
                    onDrag = { change, _ ->
                        val mode = draggingMode
                        if (mode != null) {
                            change.consume()
                            dragPosition = change.position
                            val current = latestModes
                            if (current.isNotEmpty()) {
                                val target =
                                    settingsReorderIndex(
                                        change.position.y,
                                        rowHeightPx,
                                        current.size,
                                    )
                                if (current.indexOf(mode) != target) {
                                    settings.moveDisplayMode(mode, target)
                                }
                            }
                        }
                    },
                    onDragEnd = { draggingMode = null },
                    onDragCancel = { draggingMode = null },
                )
            },
    ) {
        val listHeightPx = constraints.maxHeight.toFloat()
        modes.forEachIndexed { index, mode ->
            key(mode) {
                val modeLabel = stringResource(mode.labelResource())
                val moveEarlier = stringResource(R.string.settings_move_earlier, modeLabel)
                val moveLater = stringResource(R.string.settings_move_later, modeLabel)
                val positionDescription = stringResource(R.string.settings_position, index + 1)
                val positionLabel = stringResource(R.string.settings_position_number, index + 1)
                val includeDescription =
                    stringResource(R.string.settings_disp_include, modeLabel)
                val reorderDescription =
                    stringResource(R.string.settings_reorder_position, modeLabel, index + 1)
                val enabled = mode in settings.enabledDisplayModes
                val enabledState =
                    stringResource(
                        if (enabled) R.string.status_enabled else R.string.status_disabled,
                    )
                val dragging = mode == draggingMode
                val y =
                    if (dragging) {
                        (dragPosition.y - rowHeightPx / 2f)
                            .coerceIn(0f, (listHeightPx - rowHeightPx).coerceAtLeast(0f))
                    } else {
                        index * rowHeightPx
                    }
                val accessibilityActions =
                    buildList {
                        if (index > 0) {
                            add(
                                CustomAccessibilityAction(moveEarlier) {
                                    settings.moveDisplayMode(mode, index - 1)
                                    onInteraction()
                                    true
                                },
                            )
                        }
                        if (index < modes.lastIndex) {
                            add(
                                CustomAccessibilityAction(moveLater) {
                                    settings.moveDisplayMode(mode, index + 1)
                                    onInteraction()
                                    true
                                },
                            )
                        }
                    }
                Column(
                    Modifier.offset { IntOffset(0, y.roundToInt()) }
                        .fillMaxWidth()
                        .height(rowHeight)
                        .graphicsLayer {
                            scaleX = if (dragging) 1.02f else 1f
                            scaleY = if (dragging) 1.02f else 1f
                            shadowElevation = if (dragging) 12.dp.toPx() else 0f
                            shape = ChromeShape
                        }
                        .zIndex(if (dragging) 1f else 0f)
                        .background(
                            if (dragging) LiveDesign.surface else androidx.compose.ui.graphics.Color.Transparent,
                        ),
                ) {
                    if (index != 0) {
                        Box(Modifier.fillMaxWidth().height(1.dp).background(LiveDesign.hairline))
                    }
                    Row(
                        Modifier.fillMaxWidth().weight(1f),
                        horizontalArrangement = Arrangement.spacedBy(9.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(
                            Modifier.size(22.dp)
                                .background(LiveDesign.surface, CircleShape)
                                .semantics { contentDescription = positionDescription },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                positionLabel,
                                style = chromeStyle(9f, FontWeight.Medium, mono = true),
                                color = LiveDesign.muted,
                            )
                        }
                        Text(
                            modeLabel,
                            style = chromeStyle(12.5f, FontWeight.SemiBold),
                            color = if (enabled) LiveDesign.text else LiveDesign.muted,
                            maxLines = 1,
                            modifier = Modifier.weight(1f),
                        )
                        Box(
                            Modifier.settingsClickable(role = Role.Switch) {
                                if (settings.toggleDisplayMode(mode)) onInteraction()
                            }.semantics {
                                contentDescription = includeDescription
                                stateDescription = enabledState
                            },
                        ) {
                            SettingsSwitchGraphic(enabled)
                        }
                        Box(
                            Modifier.width(gripWidth)
                                .fillMaxHeight()
                                .semantics {
                                    contentDescription = reorderDescription
                                    customActions = accessibilityActions
                                },
                            contentAlignment = Alignment.Center,
                        ) {
                            Canvas(Modifier.size(18.dp, 14.dp)) {
                                val stroke = 1.6.dp.toPx()
                                listOf(2f, 7f, 12f).forEach { yOffset ->
                                    drawLine(
                                        LiveDesign.faint,
                                        Offset(1.dp.toPx(), yOffset.dp.toPx()),
                                        Offset(size.width - 1.dp.toPx(), yOffset.dp.toPx()),
                                        strokeWidth = stroke,
                                        cap = StrokeCap.Round,
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

/**
 * Display tab. Every exposed toggle maps to Android monitor chrome rather
 * than merely recording an intent for a later shell pass.
 */
@Composable
private fun DisplayRows(
    settings: OperatorSettings,
    compact: Boolean,
    onToggle: (OperatorSettings.Toggle) -> Unit,
    onInteraction: () -> Unit,
    parentScrollState: ScrollState,
    viewportBounds: Rect?,
) {
    // iOS Display: View Assist toolbar, Live Status Readouts, DISP Button Order.
    // Reset lives in each card header (iOS SettingsGroupCard onReset).
    SettingsGroupCard(
        title = stringResource(R.string.settings_assist_toolbar),
        caption = stringResource(R.string.settings_assist_toolbar_caption),
        onReset = {
            settings.resetAssistToolbarPreferences()
            onInteraction()
        },
    ) {
        AssistToolbarOrderList(
            settings = settings,
            onInteraction = onInteraction,
            parentScrollState = parentScrollState,
            viewportBounds = viewportBounds,
        )
    }
    SettingsGroupCard(
        title = stringResource(R.string.settings_live_readouts),
        caption = stringResource(R.string.settings_live_readouts_caption),
    ) {
        DisplayToggleGrid(
            compact = compact,
            entries =
                listOf(
                    DisplayToggleEntry(stringResource(R.string.settings_toggle_rec), settings.recReadoutVisible.value) {
                        onToggle(settings.recReadoutVisible)
                    },
                    DisplayToggleEntry(stringResource(R.string.settings_toggle_codec), settings.codecReadoutVisible.value) {
                        onToggle(settings.codecReadoutVisible)
                    },
                    DisplayToggleEntry(stringResource(R.string.settings_toggle_media), settings.mediaReadoutVisible.value) {
                        onToggle(settings.mediaReadoutVisible)
                    },
                    DisplayToggleEntry(stringResource(R.string.settings_toggle_fps), settings.fpsReadoutVisible.value) {
                        onToggle(settings.fpsReadoutVisible)
                    },
                ),
        )
    }
    SettingsGroupCard(
        title = stringResource(R.string.settings_disp_order),
        caption = stringResource(R.string.settings_disp_order_caption),
        onReset = {
            settings.resetDisplayModePreferences()
            onInteraction()
        },
    ) {
        DisplayModeOrderList(settings, onInteraction)
    }
}

private const val FOUR_COLUMN_DISPLAY_TOGGLE_MIN_WIDTH_DP: Float = 480f

/** Number of switch columns that fit without compressing a label or switch. */
internal fun displayToggleGridColumnCount(compact: Boolean, availableWidthDp: Float): Int {
    require(availableWidthDp >= 0f) { "display toggle width must not be negative" }
    return if (compact || availableWidthDp < FOUR_COLUMN_DISPLAY_TOGGLE_MIN_WIDTH_DP) 2 else 4
}

private data class DisplayToggleEntry(
    val title: String,
    val isOn: Boolean,
    val onToggle: () -> Unit,
)

/** Responsive 4-up/2-by-2 switch grid for the narrow post-tab-rail pane. */
@Composable
private fun DisplayToggleGrid(
    compact: Boolean,
    entries: List<DisplayToggleEntry>,
    twoColumnOrder: List<Int>? = null,
) {
    BoxWithConstraints(Modifier.fillMaxWidth()) {
        val columns = displayToggleGridColumnCount(compact, maxWidth.value)
        val orderedEntries =
            if (columns == 2 && twoColumnOrder != null) {
                twoColumnOrder.map(entries::get)
            } else {
                entries
            }
        Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
            orderedEntries.chunked(columns).forEach { rowEntries ->
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.spacedBy(7.dp),
                ) {
                    rowEntries.forEach { entry ->
                        DisplayToggleItem(
                            entry.title,
                            isOn = entry.isOn,
                            modifier = Modifier.weight(1f),
                            onToggle = entry.onToggle,
                        )
                    }
                }
            }
        }
    }
}

/** Compact active/inactive choice chip shared by the local image-assist settings. */
@Composable
private fun AssistChoice(label: String, selected: Boolean, onClick: () -> Unit) {
    Text(
        label,
        style = chromeStyle(10f, FontWeight.SemiBold, mono = true),
        color = if (selected) LiveDesign.accent else LiveDesign.muted,
        maxLines = 1,
        modifier =
            Modifier
                .background(
                    if (selected) LiveDesign.accentDim else LiveDesign.background.copy(alpha = 0.38f),
                    ChromeShape,
                )
                .border(1.dp, if (selected) LiveDesign.accentDim else LiveDesign.hairline, ChromeShape)
                .settingsClickable(role = Role.RadioButton, onClick = onClick)
                .padding(horizontal = 6.dp, vertical = 5.dp),
    )
}

/** Local progressive-media cache controls, available before a camera connects. */
@Composable
private fun StorageRows(
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController?,
    condensed: Boolean,
    onCompletedMediaCacheCleared: () -> Unit,
) {
    val context = LocalContext.current
    val resources = LocalResources.current
    val scope = rememberCoroutineScope()
    val storageState = remember(mediaCacheStore) { MediaCacheSettingsState(mediaCacheStore) }
    var snapshot by remember(mediaCacheStore) { mutableStateOf<MediaCacheStorageSnapshot?>(null) }
    var loadFailure by remember(mediaCacheStore) { mutableStateOf<String?>(null) }
    var clearing by remember { mutableStateOf(false) }

    LaunchedEffect(storageState) {
        try {
            snapshot = withContext(Dispatchers.IO) { storageState.refresh() }
            loadFailure = null
        } catch (error: Exception) {
            loadFailure = error.message ?: resources.getString(R.string.cache_read_failed)
        }
    }

    // iOS order: Frame.io first, then one Local Media Cache / Clear Cache card.
    frameioController?.let { controller ->
        FrameioStorageRows(controller, condensed)
    }
    fun clearNow() {
        clearing = true
        loadFailure = null
        scope.launch {
            try {
                snapshot = withContext(Dispatchers.IO) { storageState.clearCompleted() }
                onCompletedMediaCacheCleared()
            } catch (error: Exception) {
                loadFailure = error.message ?: resources.getString(R.string.cache_clear_failed)
            } finally {
                clearing = false
            }
        }
    }
    SettingsRowCard {
        if (condensed) {
            CondensedStorageRow(title = stringResource(R.string.cache_cached_media), showTopDivider = false) {
                SettingsValueText(cacheSizeLabel(context, snapshot?.usage?.totalBytes))
            }
            CondensedStorageRow(title = stringResource(R.string.cache_clear)) {
                StorageClearAction(clearing, ::clearNow)
            }
        } else {
            SettingsInlineRow(title = stringResource(R.string.cache_cached_media), showTopDivider = false) {
                SettingsValueText(cacheSizeLabel(context, snapshot?.usage?.totalBytes))
            }
            SettingsInlineRow(title = stringResource(R.string.cache_clear)) {
                StorageClearAction(clearing, ::clearNow)
            }
        }
        snapshot?.clearResult?.let { result ->
            Text(
                clearResultLabel(context, result),
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.good,
            )
        }
        loadFailure?.let { message ->
            Text(
                message,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.accent,
            )
        }
    }
}

/** Frame.io account entry point; upload project selection lives beside media selection. */
@Composable
private fun FrameioStorageRows(controller: FrameioDeliveryController, condensed: Boolean) {
    val context = LocalContext.current
    LaunchedEffect(controller) { controller.refresh() }

    fun beginSignIn() {
        val authorizationURL = controller.beginSignIn() ?: return
        try {
            context.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(authorizationURL)))
        } catch (_: Exception) {
            controller.signInBrowserUnavailable()
        }
    }

    @Suppress("UNUSED_PARAMETER")
    val unusedCondensed = condensed
    val connectionLabel =
        when (controller.connectionState) {
            FrameioConnectionState.UNCONFIGURED -> stringResource(R.string.status_not_configured)
            FrameioConnectionState.SIGNED_OUT -> stringResource(R.string.frameio_not_connected)
            FrameioConnectionState.AUTHORIZING -> stringResource(R.string.frameio_waiting_signin)
            FrameioConnectionState.CONNECTED -> stringResource(R.string.status_connected)
            FrameioConnectionState.ERROR -> stringResource(R.string.status_needs_attention)
        }

    // iOS Storage: single "Frame.io" row with Log out / Sign in / status value.
    SettingsRowCard {
        SettingsInlineRow(title = stringResource(R.string.frameio_delivery), showTopDivider = false) {
            when (controller.connectionState) {
                FrameioConnectionState.CONNECTED ->
                    SettingsLinkAction(stringResource(R.string.action_log_out)) {
                        controller.disconnect()
                    }
                FrameioConnectionState.UNCONFIGURED ->
                    SettingsValueText(stringResource(R.string.frameio_not_set_up))
                FrameioConnectionState.SIGNED_OUT ->
                    if (controller.networkState == FrameioNetworkState.CAMERA_ACCESS_POINT) {
                        SettingsLinkAction(stringResource(R.string.frameio_sign_in_over_internet)) {
                            beginSignIn()
                        }
                    } else {
                        SettingsLinkAction(stringResource(R.string.action_sign_in)) { beginSignIn() }
                    }
                FrameioConnectionState.ERROR ->
                    SettingsLinkAction(stringResource(R.string.action_try_again)) { beginSignIn() }
                FrameioConnectionState.AUTHORIZING -> SettingsValueText(connectionLabel)
            }
        }
        controller.errorMessage?.let { message ->
            Text(
                message,
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.accent,
            )
        }
    }
}

/** Short landscape storage row that preserves a 48dp clear-cache target. */
@Composable
private fun CondensedStorageRow(
    title: String,
    showTopDivider: Boolean = true,
    trailing: @Composable () -> Unit,
) {
    Column {
        if (showTopDivider) {
            Box(Modifier.fillMaxWidth().height(1.dp).background(LiveDesign.hairline))
        }
        Row(
            Modifier.fillMaxWidth().height(44.dp),
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                title,
                style = chromeStyle(12.5f, FontWeight.SemiBold),
                color = LiveDesign.text,
                maxLines = 1,
            )
            Spacer(Modifier.weight(1f))
            trailing()
        }
    }
}

/** Accessible destructive-cache action used in regular and short layouts. */
@Composable
private fun StorageClearAction(clearing: Boolean, onClick: () -> Unit) {
    if (clearing) {
        SettingsValueText(stringResource(R.string.cache_clearing))
    } else {
        val description = stringResource(R.string.cache_clear_description)
        Box(
            Modifier.size(48.dp)
                .settingsClickable(role = Role.Button, onClick = onClick)
                .semantics { contentDescription = description },
            contentAlignment = Alignment.CenterEnd,
        ) {
            Text(
                stringResource(R.string.action_clear),
                style = chromeStyle(13f, FontWeight.SemiBold),
                color = LiveDesign.accent,
            )
        }
    }
}

private fun cacheSizeLabel(context: Context, bytes: Long?): String =
    when {
        bytes == null -> context.getString(R.string.status_calculating)
        bytes == 0L -> context.getString(R.string.status_empty)
        else -> Formatter.formatFileSize(context, bytes)
    }

private fun clearResultLabel(context: Context, result: MediaCacheClearResult): String =
    when {
        result.removedCompleteEntryCount == 0 -> context.getString(R.string.cache_none_removed)
        result.preservedIncompleteEntryCount == 0 ->
            context.getString(
                R.string.cache_removed,
                cacheSizeLabel(context, result.removedCompleteBytes),
            )
        else ->
            context.getString(
                R.string.cache_removed_preserved,
                cacheSizeLabel(context, result.removedCompleteBytes),
                cacheSizeLabel(context, result.preservedIncompleteBytes),
            )
    }

/** System tab: native support/share intents, replayable guide, project links, and build data. */
@Composable
internal fun SystemRows(
    actions: SystemSettingsActions,
    onReportProblem: () -> Unit,
    guideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)?,
    onShowGuideOnNextRealFrame: () -> Unit,
) {
    val context = LocalContext.current
    val unavailableMessage = stringResource(R.string.system_action_unavailable)
    fun runAction(action: () -> Boolean) {
        if (!action()) {
            Toast.makeText(
                context,
                unavailableMessage,
                Toast.LENGTH_SHORT,
            ).show()
        }
    }

    // iOS System uses titled SettingsRowCard sections (no captions / no licenses row).
    SettingsRowCard(title = stringResource(R.string.system_help_feedback)) {
        SettingsInlineRow(stringResource(R.string.system_support), showTopDivider = false) {
            SettingsLinkAction(
                stringResource(R.string.action_open),
                stringResource(R.string.system_open_support),
            ) { runAction(actions::openSupport) }
        }
        SettingsInlineRow(stringResource(R.string.system_report_problem)) {
            SettingsActionPill(stringResource(R.string.action_report), onReportProblem)
        }
        SettingsInlineRow(stringResource(R.string.system_request_feature)) {
            SettingsLinkAction(
                stringResource(R.string.action_request),
                stringResource(R.string.system_request_feature),
            ) {
                runAction(actions::requestFeature)
            }
        }
        SettingsInlineRow(stringResource(R.string.system_share_diagnostics)) {
            SettingsActionPill(stringResource(R.string.action_share)) {
                runAction(actions::shareDiagnostics)
            }
        }
        SettingsInlineRow(stringResource(R.string.system_live_view_guide)) {
            SettingsActionPill(stringResource(R.string.action_show_again)) {
                if (onShowGuideNow != null) {
                    onShowGuideNow()
                } else {
                    onShowGuideOnNextRealFrame()
                }
            }
        }
    }

    SettingsRowCard(title = stringResource(R.string.system_project_legal)) {
        SettingsInlineRow(stringResource(R.string.system_source_code), showTopDivider = false) {
            SettingsLinkAction(
                stringResource(R.string.action_open),
                stringResource(R.string.system_open_source_code),
            ) { runAction(actions::openSource) }
        }
        SettingsInlineRow(stringResource(R.string.system_privacy)) {
            SettingsLinkAction(
                stringResource(R.string.action_open),
                stringResource(R.string.system_open_privacy),
            ) { runAction(actions::openPrivacy) }
        }
        SettingsInlineRow(stringResource(R.string.system_terms)) {
            SettingsLinkAction(
                stringResource(R.string.action_open),
                stringResource(R.string.system_open_terms),
            ) { runAction(actions::openTerms) }
        }
    }

    SettingsRowCard(title = stringResource(R.string.system_app_information)) {
        SettingsInlineRow(stringResource(R.string.system_theme), showTopDivider = false) {
            SettingsValueText(stringResource(R.string.system_theme_warm_dark))
        }
        SettingsInlineRow(stringResource(R.string.system_protocol)) {
            SettingsValueText("PTP / PTP-IP")
        }
        SettingsInlineRow(stringResource(R.string.system_app_version)) {
            SettingsValueText(appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
        }
    }
}
