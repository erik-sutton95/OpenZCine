package com.opencapture.openzcine.settings

import android.content.Context
import android.content.Intent
import android.content.res.Configuration
import android.net.Uri
import android.os.Build
import android.text.format.Formatter
import android.view.HapticFeedbackConstants
import android.widget.Toast
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
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalView
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
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
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
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioNetworkState
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
 * Operator Setup rail tabs — the Android v1 subset of the iOS
 * `OperatorSettingsTab` set (Link / View Assist / Controls / Display /
 * Storage / System). The Link tab is bound to the active Android session;
 * every other tab exposes controls the shell can already honor.
 */
public enum class OperatorSettingsTab(
    public val title: String,
    public val compactTitle: String,
    public val railSubtitle: String,
    public val subtitle: String,
    public val pill: String,
) {
    LINK("Link", "Link", "Connection", "Transport & preview", "LIVE"),
    ASSIST("View Assist", "Assist", "Scopes & overlays", "Behavior for live-view tools.", "ASSIST"),
    CONTROLS("Controls", "Controls", "Dials & safety", "Touch behavior and safety.", "TOUCH"),
    DISPLAY("Display", "Display", "Live view", "Live view buttons and chrome.", "VISIBILITY"),
    STORAGE("Storage", "Storage", "Local media", "Local cache and offline media.", "STORAGE"),
    SYSTEM("System", "System", "App behavior", "App-level behavior.", "APP"),
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
    liveViewGuideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)? = null,
    onShowGuideOnNextRealFrame: () -> Unit,
    onCompletedMediaCacheCleared: () -> Unit = {},
    initialTab: OperatorSettingsTab = OperatorSettingsTab.ASSIST,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
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
                "2 scopes max in fit view. Close one or rotate to landscape.",
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
            "OPENZCINE",
            color = LiveDesign.accent,
            fontSize = 9.5.sp,
            fontWeight = FontWeight.Bold,
            letterSpacing = 0.8.sp,
        )
        Text(
            "Operator Setup",
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
            "No camera · local setup only"
        } else {
            when (val current = state) {
                is CameraSessionState.Connected ->
                    health.detail.ifBlank { "${current.identity.name} · PTP-IP" }
                CameraSessionState.Connecting -> "Connecting…"
                CameraSessionState.Disconnected -> "No camera"
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
                if (linked) "Active Link" else if (standalone) "Local Setup" else "No Link",
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

/** Horizontal tab selector used when the landscape rail cannot fit. */
@Composable
private fun SettingsTabStrip(
    selected: OperatorSettingsTab,
    onSelect: (OperatorSettingsTab) -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().glass(ChromeShape).padding(5.dp),
        horizontalArrangement = Arrangement.spacedBy(5.dp),
    ) {
        OperatorSettingsTab.entries.forEach { tab ->
            val active = tab == selected
            Column(
                Modifier.weight(1f)
                    .height(43.dp)
                    .background(
                        if (active) LiveDesign.surface else LiveDesign.surface.copy(alpha = 0f),
                        ChromeShape,
                    )
                    .settingsClickable(role = Role.Tab) { onSelect(tab) }
                    .padding(horizontal = 4.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.Center,
            ) {
                Text(
                    tab.compactTitle,
                    style = chromeStyle(11.5f, FontWeight.SemiBold),
                    color = if (active) LiveDesign.text else LiveDesign.muted,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                )
                Box(
                    Modifier.padding(top = 3.dp)
                        .size(width = 18.dp, height = 3.dp)
                        .background(
                            if (active) LiveDesign.accent else LiveDesign.accent.copy(alpha = 0f),
                            CircleShape,
                        )
                )
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
                tab.title,
                style = chromeStyle(13f, FontWeight.SemiBold),
                color = if (active) LiveDesign.text else LiveDesign.muted,
                maxLines = 1,
            )
            Text(
                tab.railSubtitle,
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
                        tab.title,
                        style = chromeStyle(if (condensed) 21f else 24f, FontWeight.SemiBold),
                        color = LiveDesign.text,
                    )
                    if (!condensed) {
                        Text(
                            tab.subtitle,
                            style = chromeStyle(12.5f, FontWeight.Normal),
                            color = LiveDesign.muted,
                            maxLines = 2,
                        )
                    }
                }
                Spacer(Modifier.weight(1f))
                Text(
                    tab.pill,
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

/** Active camera transport, health, and Swift-owned preview policy. */
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
    val disconnectedProperties = remember { MutableStateFlow(CameraPropertySnapshot()) }
    val cameraProperties by (session?.cameraProperties ?: disconnectedProperties).collectAsState()
    val noPreviewApplication =
        remember { MutableStateFlow<SwiftLiveViewPreviewState>(SwiftLiveViewPreviewState.Idle) }
    val previewApplication by
        (liveViewSource?.previewState ?: noPreviewApplication).collectAsState()
    val health = linkHealth?.presentation ?: LinkHealthPresentation()
    val thermalTier = rememberAndroidThermalTier()
    val warningLabel =
        when (cameraProperties.temperatureStatus) {
            CameraTemperatureStatus.NORMAL -> "OK"
            CameraTemperatureStatus.WARNING -> "CHECK"
            CameraTemperatureStatus.HOT -> "HOT"
            null -> "Not reported"
        }
    val thermalPreviewLabel =
        when (thermalTier) {
            AndroidThermalTier.NOMINAL -> "Nominal · full preview request"
            AndroidThermalTier.FAIR -> "Fair · full preview request"
            AndroidThermalTier.SERIOUS -> "Serious · preview reduced"
            AndroidThermalTier.CRITICAL -> "Critical · preview minimized"
        }
    val previewApplicationLabel =
        when (val state = previewApplication) {
            SwiftLiveViewPreviewState.Idle -> "Waiting for live view"
            is SwiftLiveViewPreviewState.Pending -> "Applying preview request"
            is SwiftLiveViewPreviewState.Applied -> "Applied"
            is SwiftLiveViewPreviewState.Rejected ->
                if (state.retainedRequest != null) {
                    "Rejected · keeping prior stream"
                } else {
                    "Rejected · live view paused"
                }
        }

    SettingsGroupCard(
        title = "Link Health",
        caption =
            if (session == null) {
                "No active camera. Link measurements appear only after a session connects."
            } else {
                health.detail
            },
    ) {
        LinkHealthMeter(score = health.score, signalBars = health.signalBars)
        SettingsInlineRow(title = "Health", showTopDivider = false) {
            SettingsValueText(if (session == null) "No Link" else "${health.score}%")
        }
        SettingsInlineRow(title = "Current Transport") {
            SettingsValueText(activeTransportLabel ?: "Not reported")
        }
    }

    SettingsGroupCard(
        title = "Preview Stream",
        caption =
            "These choices restart only the disposable live-view JPEG stream through Swift. Recording format and card writes stay unchanged.",
    ) {
        Text(
            "Stream Preset",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        Row(
            Modifier.fillMaxWidth().selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            LiveViewStreamPreset.entries.forEach { preset ->
                FramingAssistChoice(
                    label = preset.label,
                    selected = settings.streamPreset == preset,
                    modifier = Modifier.weight(1f),
                ) {
                    settings.streamPreset = preset
                    onInteraction()
                }
            }
        }
        Text(
            "Quality Bias",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        Row(
            Modifier.fillMaxWidth().selectableGroup(),
            horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            LiveViewQualityBias.entries.forEach { bias ->
                FramingAssistChoice(
                    label = bias.label,
                    selected = settings.qualityBias == bias,
                    modifier = Modifier.weight(1f),
                ) {
                    settings.qualityBias = bias
                    onInteraction()
                }
            }
        }
        SettingsInlineRow(title = "Thermal Preview", showTopDivider = false) {
            SettingsValueText(thermalPreviewLabel)
        }
        SettingsInlineRow(title = "Preview Apply") {
            SettingsValueText(
                if (liveViewSource == null) "Native source unavailable" else previewApplicationLabel,
            )
        }
        SettingsInlineRow(title = "Camera Warning") { SettingsValueText(warningLabel) }
    }

    SettingsGroupCard(
        title = "Connection",
        caption =
            "Reconnect returns to the saved-camera owner so Wi-Fi and USB cleanup stay scoped to the active profile.",
    ) {
        SettingsInlineRow(title = "Disconnect", showTopDivider = false) {
            if (onDisconnect == null) {
                SettingsValueText(if (session == null) "No active camera" else "No saved profile")
            } else {
                SettingsLinkAction("Disconnect", onClick = onDisconnect)
            }
        }
        SettingsInlineRow(title = "Reconnect") {
            if (onReconnect == null) {
                SettingsValueText("No saved profile")
            } else {
                SettingsLinkAction("Reconnect", onClick = onReconnect)
            }
        }
    }
}

/** Compact iOS-style dash meter backed by the shared Swift score and bars. */
@Composable
private fun LinkHealthMeter(score: Int, signalBars: Int) {
    val tint =
        when {
            signalBars >= 3 -> LiveDesign.good
            signalBars == 2 -> LiveDesign.accent
            signalBars == 1 -> LiveDesign.rec
            else -> LiveDesign.faint
        }
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        repeat(12) { index ->
            val threshold = (index + 1) * 100 / 12
            Box(
                Modifier.weight(1f)
                    .height(6.dp)
                    .background(if (score >= threshold) tint else LiveDesign.hairline, CircleShape),
            )
        }
    }
}

/**
 * View Assist tab. Effect switches are alternate controls for the monitor's
 * shared [AssistState]; local framing controls use [OperatorSettings] and
 * therefore persist independently from every camera-owned setting.
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
    val configuration = settings.feedEffectsConfiguration
    val imageEffectsAvailable = Build.VERSION.SDK_INT >= 33 && SwiftCore.isAvailable
    SettingsRowCard {
        // Local framing tools have their own configuration group below. They
        // do not belong to AssistState, which intentionally owns only image
        // effects, scopes, and audio metering.
        AssistTool.entries
            .filterNot { it in AssistTool.framingTools }
            .filter { imageEffectsAvailable || it !in imageEffectTools }
            .forEachIndexed { index, tool ->
            SettingsSwitchRow(
                tool.settingsTitle,
                isOn = assistState.isOn(tool),
                showTopDivider = index != 0,
            ) { onAssistToggle(tool) }
        }
    }
    if (imageEffectsAvailable) {
        if (lutLibrary != null) {
            StoredLutLibraryRows(
                library = lutLibrary,
                assistState = assistState,
                onInteraction = onInteraction,
            )
            RedLutWorkflowRows()
        }
        SettingsGroupCard(
            title = "Monitor LUT",
            caption = "Choose the built-in monitor look used when LUT is enabled.",
        ) {
            SettingsInlineRow(title = "LUT Look", showTopDivider = false) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    FeedLut.entries.forEach { lut ->
                        AssistChoice(
                            label = lut.label,
                            selected = assistState.selectedLut == FeedLutSelection.BuiltIn(lut),
                        ) {
                            assistState.selectLut(lut)
                            onInteraction()
                        }
                    }
                }
            }
        }
        SettingsGroupCard(
            title = "False Color",
            caption = "Choose the camera-aware scale and optional movable reference display.",
            onReset = {
                assistState.resetFalseColorSelection()
                settings.resetFalseColorConfiguration()
                onInteraction()
            },
        ) {
            SettingsInlineRow(title = "Scale", showTopDivider = false) {
                Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                    FeedFalseColorScale.entries.forEach { scale ->
                        AssistChoice(
                            label = scale.label,
                            selected = assistState.selectedFalseColorScale == scale,
                        ) {
                            assistState.selectFalseColorScale(scale)
                            onInteraction()
                        }
                    }
                }
            }
            SettingsSwitchRow(
                "Reference Display",
                isOn = settings.feedEffectsConfiguration.falseColorReferenceEnabled,
            ) {
                val enabled = !configuration.falseColorReferenceEnabled
                settings.feedEffectsConfiguration =
                    settings.feedEffectsConfiguration.copy(
                        falseColorReferenceEnabled = enabled,
                    )
                // iOS makes the key immediately useful by revealing False Color
                // when it is enabled. Preserve the existing LUT activation; the
                // renderer decides the visual precedence for the selected scale.
                if (enabled && !assistState.isOn(AssistTool.FALSE)) {
                    onAssistToggle(AssistTool.FALSE)
                } else {
                    onInteraction()
                }
            }
            Text(
                "Shows the Swift-derived palette key only while False Color is active.",
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.muted,
            )
        }
        PeakingSettingsRows(settings, onInteraction)
        ZebraSettingsRows(settings, cameraInput, onInteraction)
    } else {
        SettingsGroupCard(
            title = "Image Processing",
            caption = "LUT, False Color, Peaking, and Zebra require Android 13 or newer and the bundled Swift core.",
        ) {
            Text(
                "Unavailable on this device. Scope and framing assists remain fully functional.",
                style = chromeStyle(10.5f, FontWeight.Normal),
                color = LiveDesign.muted,
            )
        }
    }
    ScopeSettingsRows(settings, onInteraction)
    SettingsGroupCard(
        title = "Traffic Lights",
        caption = "Configure the shared Swift meter used by the histogram and goal-post panel.",
        onReset = {
            settings.resetTrafficLightsConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Panel Scale", showTopDivider = false) {
            ScopeScaleSlider(
                selected = settings.scopeAssistConfiguration.trafficLightsScale,
                onSelect = { value ->
                    settings.scopeAssistConfiguration =
                        settings.scopeAssistConfiguration.copy(trafficLightsScale = value)
                    onInteraction()
                },
            )
        }
        SettingsSwitchRow(
            "Histogram Traffic Lights",
            isOn = settings.histogramTrafficLightsEnabled.value,
            showTopDivider = false,
        ) {
            settings.histogramTrafficLightsEnabled.toggle()
            onInteraction()
        }
        Text(
            "Show small RGB edge blocks for crushed and clipped channels.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
        Text(
            "Crush/Clip Compensation",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        ScopeCrushClipCompensationChoices(
            selected = settings.scopeCrushClipCompensation,
            onSelect = { compensation ->
                settings.scopeCrushClipCompensation = compensation
                onInteraction()
            },
        )
        Text(
            "Forwarded to the shared Swift meter; Kotlin only stores and presents this choice.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
    }
    SettingsGroupCard(
        title = "Local Framing",
        caption = "OpenZCine draws these monitor-only overlays over the visible feed. They never change the camera's Grid Display setting.",
    ) {
        FramingAssistSwitchRow(
            title = "Show Delivery Guides",
            isOn = settings.guidesVisible.value,
            showTopDivider = false,
        ) {
            // Use the same seeding behavior as the monitor toolbar: turning
            // on an empty guide selection must produce the iOS-default 2.39:1
            // frame instead of an apparently broken empty overlay.
            settings.toggleLocalFramingTool(AssistTool.GUIDES)
            onInteraction()
        }
        Text(
            "Delivery Guide Family",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        FramingGuideFamilyChoices(
            selected = settings.guideFamily,
            onSelect = { family ->
                settings.guideFamily = family
                onInteraction()
            },
        )
        FramingGuideChoices(
            family = settings.guideFamily,
            selected = settings.selectedGuideRatios,
            onToggle = { ratio ->
                settings.toggleGuideRatio(ratio)
                onInteraction()
            },
        )
        FramingAssistSwitchRow(
            title = "Mask Outside Selected Frames",
            isOn = settings.guideMaskEnabled.value,
        ) {
            onSettingToggle(settings.guideMaskEnabled)
        }
        Text(
            "Composition Grid",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        FramingAssistSwitchRow(
            title = "Show Composition Grid",
            isOn = settings.localGridVisible.value,
        ) {
            // Likewise, re-enabling an otherwise empty grid starts with
            // thirds so the visible result always matches the control state.
            settings.toggleLocalFramingTool(AssistTool.GRID)
            onInteraction()
        }
        FramingGridChoices(
            thirds = settings.ruleOfThirdsEnabled.value,
            phi = settings.phiGridEnabled.value,
            diagonal = settings.diagonalGridEnabled.value,
            onToggleThirds = { onSettingToggle(settings.ruleOfThirdsEnabled) },
            onTogglePhi = { onSettingToggle(settings.phiGridEnabled) },
            onToggleDiagonal = { onSettingToggle(settings.diagonalGridEnabled) },
        )
        FramingAssistSwitchRow(
            title = "Centre Crosshair",
            isOn = settings.centerCrosshairEnabled.value,
        ) {
            onSettingToggle(settings.centerCrosshairEnabled)
        }
        Text(
            "Desqueeze",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        FramingAssistSwitchRow(
            title = "Enable Local Desqueeze",
            isOn = settings.desqueezeEnabled.value,
        ) {
            onSettingToggle(settings.desqueezeEnabled)
        }
        Text(
            "Ratio",
            style = chromeStyle(11.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        DesqueezeRatioChoices(
            selected = settings.desqueezeRatio,
            onSelect = { ratio ->
                settings.desqueezeRatio = ratio
                onInteraction()
            },
        )
        Text(
            "Compressed Axis",
            style = chromeStyle(11.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        DesqueezeOrientationChoices(
            selected = settings.desqueezeOrientation,
            onSelect = { orientation ->
                settings.desqueezeOrientation = orientation
                onInteraction()
            },
        )
        Text(
            "Guides, masks, grids, crosshair, and desqueeze are local display assists. Camera Grid Display remains camera-owned and unchanged.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
    }
    SettingsGroupCard(
        title = "Camera Level",
        caption = "Uses the camera virtual horizon when its live-view header reports a reliable value.",
    ) {
        FramingAssistSwitchRow(
            title = "Level",
            isOn = settings.levelAssistEnabled.value,
            showTopDivider = false,
        ) {
            onSettingToggle(settings.levelAssistEnabled)
        }
        Text(
            "Style",
            style = chromeStyle(12.5f, FontWeight.SemiBold),
            color = LiveDesign.text,
        )
        LevelStyleChoices(
            selected = settings.levelStyle,
            onSelect = { style ->
                settings.levelStyle = style
                onInteraction()
            },
        )
        Text(
            "If the camera does not provide a level, the monitor may use labelled device tilt fallback.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
    }
}

private val imageEffectTools: Set<AssistTool> =
    setOf(AssistTool.LUT, AssistTool.PEAK, AssistTool.FALSE, AssistTool.ZEBRA)

/** iOS-matched peaking choices; Swift resolves the actual detector values and RGB. */
@Composable
private fun PeakingSettingsRows(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.feedEffectsConfiguration
    SettingsGroupCard(
        title = "Focus Peaking",
        caption = "Sensitivity and color are resolved by the shared Swift exposure-assist facade.",
        onReset = {
            settings.resetPeakingConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Sensitivity", showTopDivider = false) {
            Row(
                Modifier.widthIn(max = 220.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                FeedPeakingSensitivity.entries.forEach { sensitivity ->
                    AssistChoice(
                        label = sensitivity.label,
                        selected = configuration.peakingSensitivity == sensitivity,
                    ) {
                        settings.feedEffectsConfiguration =
                            configuration.copy(peakingSensitivity = sensitivity)
                        onInteraction()
                    }
                }
            }
        }
        SettingsInlineRow(title = "Color") {
            Row(
                Modifier.widthIn(max = 220.dp).horizontalScroll(rememberScrollState()),
                horizontalArrangement = Arrangement.spacedBy(4.dp),
            ) {
                FeedPeakingColor.entries.forEach { color ->
                    AssistChoice(label = color.label, selected = configuration.peakingColor == color) {
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
    SettingsGroupCard(
        title = "Zebra",
        caption = "Highlight and midtone warnings use the active camera curve; 0–255 changes only the editor.",
        onReset = {
            settings.resetZebraConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Units", showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                FeedZebraUnit.entries.forEach { unit ->
                    AssistChoice(label = unit.label, selected = configuration.zebraUnit == unit) {
                        settings.feedEffectsConfiguration = configuration.copy(zebraUnit = unit)
                        onInteraction()
                    }
                }
            }
        }
        SettingsSwitchRow("Highlight", isOn = configuration.zebraHighlightEnabled) {
            settings.feedEffectsConfiguration =
                configuration.copy(zebraHighlightEnabled = !configuration.zebraHighlightEnabled)
            onInteraction()
        }
        SettingsInlineRow(title = "Highlight Threshold") {
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
        SettingsInlineRow(title = "Highlight Color") {
            ZebraColorChoices(
                selected = configuration.zebraHighlightColor,
                onSelect = { color ->
                    settings.feedEffectsConfiguration = configuration.copy(zebraHighlightColor = color)
                    onInteraction()
                },
            )
        }
        SettingsSwitchRow("Midtone", isOn = configuration.zebraMidtoneEnabled) {
            settings.feedEffectsConfiguration =
                configuration.copy(zebraMidtoneEnabled = !configuration.zebraMidtoneEnabled)
            onInteraction()
        }
        SettingsInlineRow(title = "Midtone Threshold") {
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
        SettingsInlineRow(title = "Midtone Color") {
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
                    contentDescription = "Zebra threshold, 0 to ${maximum.roundToInt()}"
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
            AssistChoice(label = color.label, selected = selected == color) { onSelect(color) }
        }
    }
}

/** Canvas-only scope controls. Each option below has a corresponding render/sampler path. */
@Composable
private fun ScopeSettingsRows(settings: OperatorSettings, onInteraction: () -> Unit) {
    val configuration = settings.scopeAssistConfiguration
    SettingsGroupCard(
        title = "Waveform",
        caption = "Mode, trace brightness, guides, and footprint are applied by the clean-frame Canvas view.",
        onReset = {
            settings.resetWaveformConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Mode", showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScopeWaveformMode.entries.forEach { mode ->
                    AssistChoice(label = mode.label, selected = configuration.waveformMode == mode) {
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
        ScopeScaleRow(
            scale = configuration.waveformScale,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(waveformScale = value)
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
    SettingsGroupCard(
        title = "Parade",
        caption = "RGB or YRGB channel layout with independent trace and guide controls.",
        onReset = {
            settings.resetParadeConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Mode", showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScopeParadeMode.entries.forEach { mode ->
                    AssistChoice(label = mode.label, selected = configuration.paradeMode == mode) {
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
        ScopeScaleRow(
            scale = configuration.paradeScale,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(paradeScale = value)
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
    SettingsGroupCard(
        title = "Vectorscope",
        caption = "Zoom changes core density binning; brightness and footprint affect only the rendered trace.",
        onReset = {
            settings.resetVectorscopeConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Trace Zoom", showTopDivider = false) {
            Row(horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                ScopeVectorscopeZoom.entries.forEach { zoom ->
                    AssistChoice(label = zoom.label, selected = configuration.vectorscopeZoom == zoom) {
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
        ScopeScaleRow(
            scale = configuration.vectorscopeScale,
            onSelect = { value ->
                settings.scopeAssistConfiguration = configuration.copy(vectorscopeScale = value)
                onInteraction()
            },
        )
    }
    SettingsGroupCard(
        title = "Histogram",
        caption = "Histogram footprint and shared edge warnings remain independently persisted.",
        onReset = {
            settings.resetHistogramConfiguration()
            onInteraction()
        },
    ) {
        SettingsInlineRow(title = "Histogram Scale", showTopDivider = false) {
            ScopeScaleSlider(
                selected = configuration.histogramScale,
                onSelect = { value ->
                    settings.scopeAssistConfiguration = configuration.copy(histogramScale = value)
                    onInteraction()
                },
            )
        }
    }
}

@Composable
private fun ScopeBrightnessRow(brightness: Int, onSelect: (Int) -> Unit) {
    SettingsInlineRow(title = "Brightness") {
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
            SettingsValueText("$brightness%")
        }
    }
}

@Composable
private fun ScopeScaleRow(scale: Float, onSelect: (Float) -> Unit) {
    SettingsInlineRow(title = "Panel Scale") { ScopeScaleSlider(scale, onSelect) }
}

@Composable
private fun ScopeScaleSlider(selected: Float, onSelect: (Float) -> Unit) {
    Row(
        Modifier.widthIn(max = 250.dp),
        horizontalArrangement = Arrangement.spacedBy(7.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Slider(
            value = selected,
            onValueChange = { value -> onSelect((value * 100).roundToInt() / 100f) },
            valueRange = ScopeAssistConfiguration.MIN_SCALE..ScopeAssistConfiguration.MAX_SCALE,
            modifier = Modifier.weight(1f),
        )
        SettingsValueText("${(selected * 100).roundToInt()}%")
    }
}

@Composable
private fun ScopeGuideRows(guides: ScopeGuideLines, onChange: (ScopeGuideLines) -> Unit) {
    SettingsSwitchRow("Safe Border Clip", isOn = guides.clip) {
        onChange(guides.copy(clip = !guides.clip))
    }
    SettingsSwitchRow("Safe Border Crush", isOn = guides.crush) {
        onChange(guides.copy(crush = !guides.crush))
    }
    SettingsSwitchRow("Middle Gray", isOn = guides.middle) {
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
                            feedback = "${result.entry.displayName} added to the private library."
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
        title = "Custom LUT Library",
        caption =
            "Choose one .cube document. Swift validates it before a bounded app-private copy; " +
                "OpenZCine never keeps the document URI or scans storage.",
    ) {
        if (customEntries.isEmpty()) {
            Text(
                "No custom LUTs yet. Import a .cube to add a monitor look.",
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
                                feedback = "${entry.displayName} selected."
                                onInteraction()
                            } else {
                                feedback = failures[entry.selection]?.operatorMessage
                                    ?: "This LUT could not be prepared."
                            }
                        }
                    },
                    onRemove = { pendingDeletion = entry },
                )
            }
        }
        SettingsInlineRow(title = "Import .cube", showTopDivider = customEntries.isNotEmpty()) {
            SettingsLinkAction("Choose") { importLauncher.launch(arrayOf("*/*")) }
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
            title = "Stored RED LUTs",
            caption = "Only LUTs added by an authorized RED workflow appear here; none are bundled.",
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
            title = { Text("Remove ${entry.displayName}?") },
            text = {
                Text(
                    "Only OpenZCine's app-private copy will be removed. The document you selected " +
                        "from storage is untouched.",
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
                                feedback = "${entry.displayName} removed."
                                onInteraction()
                            } else {
                                feedback = "OpenZCine could not remove that private LUT copy."
                            }
                        }
                    },
                ) { Text("Remove") }
            },
            dismissButton = {
                TextButton(onClick = { pendingDeletion = null }) { Text("Cancel") }
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
            AssistChoice(label = "USE", selected = selected, onClick = onSelect)
            SettingsLinkAction("Remove", onClick = onRemove)
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
        title = "RED IPP2 LUTs",
        caption = "RED assets are never bundled. Download remains unavailable until RED authorizes an Android endpoint and terms workflow.",
    ) {
        SettingsInlineRow(title = "Terms acknowledgement", showTopDivider = false) {
            SettingsValueText("Not configured")
        }
        SettingsInlineRow(title = "Delivery") {
            SettingsValueText(if (readiness.canEnterWorkflow) "Ready" else "Blocked")
        }
        SettingsInlineRow(title = "Network guard") {
            SettingsValueText(
                when (readiness.network) {
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.AVAILABLE -> "Internet ready"
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.ON_CAMERA_ACCESS_POINT -> "Camera AP"
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.NO_INTERNET -> "Offline"
                    com.opencapture.openzcine.lut.RedLutNetworkAvailability.SWIFT_CORE_UNAVAILABLE -> "Core unavailable"
                },
            )
        }
        SettingsInlineRow(title = "Refresh status") {
            SettingsLinkAction("Refresh") { readiness = gate.readiness() }
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
                label = family.label,
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
                        label = ratio.label,
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
            label = "Thirds",
            checked = thirds,
            modifier = Modifier.weight(1f),
            onClick = onToggleThirds,
        )
        FramingAssistToggleChoice(
            label = "Phi Grid",
            checked = phi,
            modifier = Modifier.weight(1f),
            onClick = onTogglePhi,
        )
        FramingAssistToggleChoice(
            label = "Diagonal",
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
                        label = ratio.label,
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
                label = style.label,
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
                label = orientation.label,
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
                        contentDescription = "${option.label} stops crush/clip compensation"
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    option.compactLabel,
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
    SettingsRowCard {
        SettingsSwitchRow(
            "Record Confirmation",
            isOn = settings.recordConfirmationEnabled.value,
            showTopDivider = false,
        ) { onToggle(settings.recordConfirmationEnabled) }
        SettingsSwitchRow("Haptics", isOn = settings.hapticsEnabled.value) {
            onToggle(settings.hapticsEnabled)
        }
        SettingsSwitchRow("Keep Screen Awake", isOn = settings.keepScreenAwake.value) {
            onToggle(settings.keepScreenAwake)
        }
    }
    SettingsGroupCard(
        title = "Media Remote Shutter",
        caption =
            "Monitor-only; Android cannot reliably distinguish Bluetooth from phone hardware keys.",
    ) {
        SettingsSwitchRow(
            "Enable Media Remote",
            isOn = settings.mediaRemoteShutterEnabled.value,
            showTopDivider = false,
        ) { onToggle(settings.mediaRemoteShutterEnabled) }
        Text(
            "Volume Up/Down and Play/Pause toggle recording; Record/Play start and Pause/Stop stop. Confirmation is skipped.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
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
                                CustomAccessibilityAction("Move ${tool.settingsTitle} earlier") {
                                    settings.moveAssistToolbarTool(tool, index - 1)
                                    onInteraction()
                                    true
                                },
                            )
                        }
                        if (index < tools.lastIndex) {
                            add(
                                CustomAccessibilityAction("Move ${tool.settingsTitle} later") {
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
                                .semantics { contentDescription = "Position ${index + 1}" },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "${index + 1}",
                                style = chromeStyle(9f, FontWeight.Medium, mono = true),
                                color = LiveDesign.muted,
                            )
                        }
                        Text(
                            tool.settingsTitle,
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
                            SettingsValueText("PINNED")
                        } else {
                            Box(
                                Modifier.settingsClickable(role = Role.Switch) {
                                    settings.toggleAssistToolbarToolVisibility(tool)
                                    onInteraction()
                                }.semantics {
                                    contentDescription = "Show ${tool.settingsTitle} in monitor toolbar"
                                    stateDescription =
                                        if (settings.isAssistToolbarToolVisible(tool)) {
                                            "Visible"
                                        } else {
                                            "Hidden"
                                        }
                                },
                            ) {
                                SettingsSwitchGraphic(settings.isAssistToolbarToolVisible(tool))
                            }
                        }
                        Box(
                            Modifier.width(gripWidth)
                                .fillMaxHeight()
                                .semantics {
                                    contentDescription =
                                        "Reorder ${tool.settingsTitle}, position ${index + 1}"
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
                                CustomAccessibilityAction("Move ${mode.label} earlier") {
                                    settings.moveDisplayMode(mode, index - 1)
                                    onInteraction()
                                    true
                                },
                            )
                        }
                        if (index < modes.lastIndex) {
                            add(
                                CustomAccessibilityAction("Move ${mode.label} later") {
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
                                .semantics { contentDescription = "Position ${index + 1}" },
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "${index + 1}",
                                style = chromeStyle(9f, FontWeight.Medium, mono = true),
                                color = LiveDesign.muted,
                            )
                        }
                        val enabled = mode in settings.enabledDisplayModes
                        Text(
                            mode.label,
                            style = chromeStyle(12.5f, FontWeight.SemiBold),
                            color = if (enabled) LiveDesign.text else LiveDesign.muted,
                            maxLines = 1,
                            modifier = Modifier.weight(1f),
                        )
                        Box(
                            Modifier.settingsClickable(role = Role.Switch) {
                                if (settings.toggleDisplayMode(mode)) onInteraction()
                            }.semantics {
                                contentDescription = "Include ${mode.label} in DISP cycle"
                                stateDescription = if (enabled) "Enabled" else "Disabled"
                            },
                        ) {
                            SettingsSwitchGraphic(enabled)
                        }
                        Box(
                            Modifier.width(gripWidth)
                                .fillMaxHeight()
                                .semantics {
                                    contentDescription =
                                        "Reorder ${mode.label}, position ${index + 1}"
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
    SettingsGroupCard(
        title = "Monitor Chrome",
        caption =
            "Show only the monitor regions you need. Settings stays reachable when landscape rails are hidden.",
    ) {
        DisplayToggleGrid(
            compact = compact,
            entries =
                listOf(
                    DisplayToggleEntry("STATUS", settings.statusBarVisible.value) {
                        onToggle(settings.statusBarVisible)
                    },
                    DisplayToggleEntry("RAILS", settings.sideRailsVisible.value) {
                        onToggle(settings.sideRailsVisible)
                    },
                    DisplayToggleEntry("ASSISTS", settings.assistToolbarVisible.value) {
                        onToggle(settings.assistToolbarVisible)
                    },
                    DisplayToggleEntry("VALUES", settings.cameraValuesVisible.value) {
                        onToggle(settings.cameraValuesVisible)
                    },
                ),
            twoColumnOrder = listOf(0, 2, 1, 3),
        )
    }
    SettingsGroupCard(
        title = "View Assist Toolbar",
        caption = "Show or hide tools, then drag a trailing handle to set their monitor order.",
    ) {
        AssistToolbarOrderList(
            settings = settings,
            onInteraction = onInteraction,
            parentScrollState = parentScrollState,
            viewportBounds = viewportBounds,
        )
        SettingsLinkAction("Reset toolbar") {
            settings.resetAssistToolbarPreferences()
            onInteraction()
        }
    }
    SettingsGroupCard(
        title = "Live Status Readouts",
        caption = "Hide readouts you do not ride during a take.",
    ) {
        DisplayToggleGrid(
            compact = compact,
            entries =
                listOf(
                    DisplayToggleEntry("REC", settings.recReadoutVisible.value) {
                        onToggle(settings.recReadoutVisible)
                    },
                    DisplayToggleEntry("CODEC", settings.codecReadoutVisible.value) {
                        onToggle(settings.codecReadoutVisible)
                    },
                    DisplayToggleEntry("MEDIA", settings.mediaReadoutVisible.value) {
                        onToggle(settings.mediaReadoutVisible)
                    },
                    DisplayToggleEntry("FPS", settings.fpsReadoutVisible.value) {
                        onToggle(settings.fpsReadoutVisible)
                    },
                ),
        )
    }
    SettingsGroupCard(
        title = "DISP Button Order",
        caption = "Drag to reorder; disable modes you do not use. One mode always remains.",
    ) {
        DisplayModeOrderList(settings, onInteraction)
        SettingsLinkAction("Reset DISP") {
            settings.resetDisplayModePreferences()
            onInteraction()
        }
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
    val scope = rememberCoroutineScope()
    val storageState = remember(mediaCacheStore) { MediaCacheSettingsState(mediaCacheStore) }
    var snapshot by remember(mediaCacheStore) { mutableStateOf<MediaCacheStorageSnapshot?>(null) }
    var loadFailure by remember(mediaCacheStore) { mutableStateOf<String?>(null) }
    var showClearConfirmation by remember { mutableStateOf(false) }
    var clearing by remember { mutableStateOf(false) }

    LaunchedEffect(storageState) {
        try {
            snapshot = withContext(Dispatchers.IO) { storageState.refresh() }
            loadFailure = null
        } catch (error: Exception) {
            loadFailure = error.message ?: "Couldn't read the local media cache."
        }
    }

    SettingsGroupCard(
        title = "Local Media Cache",
        caption =
            if (condensed) {
                "Completed offline cache only. Camera originals, share files, accounts, and transfers stay untouched."
            } else {
                "Offline camera cache only. Nothing on the camera is deleted."
            },
    ) {
        Column(verticalArrangement = Arrangement.spacedBy(if (condensed) 4.dp else 11.dp)) {
            if (condensed) {
                CondensedStorageRow(title = "Cached Media", showTopDivider = false) {
                    SettingsValueText(cacheSizeLabel(context, snapshot?.usage?.totalBytes))
                }
            } else {
                SettingsInlineRow(title = "Cached Media", showTopDivider = false) {
                    SettingsValueText(cacheSizeLabel(context, snapshot?.usage?.totalBytes))
                }
            }
            snapshot?.usage?.let { usage ->
                if (usage.incompleteEntryCount > 0) {
                    if (condensed) {
                        CondensedStorageRow(title = "Incomplete Transfers") {
                            SettingsValueText(cacheSizeLabel(context, usage.incompleteBytes))
                        }
                    } else {
                        SettingsInlineRow(title = "Incomplete Transfers") {
                            SettingsValueText(cacheSizeLabel(context, usage.incompleteBytes))
                        }
                        Text(
                            "Incomplete transfers stay in place so they can resume safely.",
                            style = chromeStyle(10.5f, FontWeight.Normal),
                            color = LiveDesign.muted,
                        )
                    }
                }
            }
            if (condensed) {
                CondensedStorageRow(title = "Clear Cache") {
                    StorageClearAction(clearing) { showClearConfirmation = true }
                }
            } else {
                SettingsInlineRow(title = "Clear Cache") {
                    StorageClearAction(clearing) { showClearConfirmation = true }
                }
                Text(
                    "Clearing removes completed offline camera files only. Share files, accounts, and camera originals stay untouched.",
                    style = chromeStyle(10.5f, FontWeight.Normal),
                    color = LiveDesign.muted,
                )
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

    if (showClearConfirmation) {
        AlertDialog(
            onDismissRequest = { showClearConfirmation = false },
            title = { Text("Clear local media cache?") },
            text = {
                Text(
                    "Completed offline camera files will be removed from this phone. " +
                        "Camera originals, share files, accounts, and incomplete transfers stay untouched.",
                )
            },
            confirmButton = {
                TextButton(
                    onClick = {
                        showClearConfirmation = false
                        clearing = true
                        loadFailure = null
                        scope.launch {
                            try {
                                snapshot = withContext(Dispatchers.IO) { storageState.clearCompleted() }
                                onCompletedMediaCacheCleared()
                            } catch (error: Exception) {
                                loadFailure =
                                    error.message ?: "Couldn't clear the local media cache."
                            } finally {
                                clearing = false
                            }
                        }
                    },
                ) {
                    Text("Clear cache")
                }
            },
            dismissButton = {
                TextButton(onClick = { showClearConfirmation = false }) { Text("Cancel") }
            },
        )
    }

    frameioController?.let { controller ->
        FrameioStorageRows(controller, condensed)
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

    val connectionLabel =
        when (controller.connectionState) {
            FrameioConnectionState.UNCONFIGURED -> "Not configured"
            FrameioConnectionState.SIGNED_OUT -> "Not connected"
            FrameioConnectionState.AUTHORIZING -> "Waiting for sign-in"
            FrameioConnectionState.CONNECTED -> "Connected"
            FrameioConnectionState.ERROR -> "Needs attention"
        }
    val networkLabel =
        when (controller.networkState) {
            FrameioNetworkState.ONLINE -> "Ready"
            FrameioNetworkState.CAMERA_ACCESS_POINT -> "Camera Wi-Fi"
            FrameioNetworkState.OFFLINE -> "Offline"
        }
    val caption =
        if (!controller.isConfigured) {
            "This Android build is intentionally unavailable until an approved Adobe Native App client and exact redirect are supplied."
        } else if (condensed) {
            "Adobe PKCE sign-in. Delivery accepts only final cache copies; native Share is unchanged."
        } else {
            "Adobe PKCE sign-in and project selection for complete cached media. On a camera access point, Media requires an explicit hop and verifies the saved-camera reconnect afterward."
        }

    SettingsGroupCard(title = "Frame.io Delivery", caption = caption) {
        SettingsInlineRow(title = "Connection", showTopDivider = false) {
            when (controller.connectionState) {
                FrameioConnectionState.CONNECTED ->
                    SettingsLinkAction("Disconnect") { controller.disconnect() }
                FrameioConnectionState.SIGNED_OUT ->
                    SettingsLinkAction("Sign in") { beginSignIn() }
                FrameioConnectionState.ERROR ->
                    SettingsLinkAction("Try again") { beginSignIn() }
                else -> SettingsValueText(connectionLabel)
            }
        }
        SettingsInlineRow(title = "Internet") { SettingsValueText(networkLabel) }
        SettingsInlineRow(title = "Upload Project") {
            SettingsValueText(controller.selectedDestination?.projectName ?: "Choose in media")
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
        SettingsValueText("Clearing…")
    } else {
        Box(
            Modifier.size(48.dp)
                .settingsClickable(role = Role.Button, onClick = onClick)
                .semantics { contentDescription = "Clear local media cache" },
            contentAlignment = Alignment.CenterEnd,
        ) {
            Text(
                "Clear",
                style = chromeStyle(13f, FontWeight.SemiBold),
                color = LiveDesign.accent,
            )
        }
    }
}

private fun cacheSizeLabel(context: Context, bytes: Long?): String =
    when {
        bytes == null -> "Calculating…"
        bytes == 0L -> "Empty"
        else -> Formatter.formatFileSize(context, bytes)
    }

private fun clearResultLabel(context: Context, result: MediaCacheClearResult): String =
    when {
        result.removedCompleteEntryCount == 0 -> "No completed cache files to remove."
        result.preservedIncompleteEntryCount == 0 ->
            "Removed ${cacheSizeLabel(context, result.removedCompleteBytes)} of offline media."
        else ->
            "Removed ${cacheSizeLabel(context, result.removedCompleteBytes)}. " +
                "${cacheSizeLabel(context, result.preservedIncompleteBytes)} remains resumable."
    }

/** System tab: native support/share intents, replayable guide, project links, and build data. */
@Composable
internal fun SystemRows(
    actions: SystemSettingsActions,
    guideController: LiveViewGuideController,
    onShowGuideNow: (() -> Unit)?,
    onShowGuideOnNextRealFrame: () -> Unit,
) {
    val context = LocalContext.current
    fun runAction(action: () -> Boolean) {
        if (!action()) {
            Toast.makeText(context, "No app is available for that action.", Toast.LENGTH_SHORT).show()
        }
    }

    SettingsGroupCard(
        title = "Help & Feedback",
        caption = "Open project support, report reproducible Android problems, or share a local report you can review first.",
    ) {
        SettingsInlineRow("Support", showTopDivider = false) {
            SettingsLinkAction("Open", "Open Support") { runAction(actions::openSupport) }
        }
        SettingsInlineRow("Report a Problem") {
            SettingsLinkAction("Report", "Report an Android Problem") {
                runAction(actions::reportBug)
            }
        }
        SettingsInlineRow("Request a Feature") {
            SettingsLinkAction("Request", "Request a Feature") {
                runAction(actions::requestFeature)
            }
        }
        SettingsInlineRow("Share Diagnostics") {
            SettingsLinkAction("Share", "Share Diagnostics") {
                runAction(actions::shareDiagnostics)
            }
        }
    }

    SettingsGroupCard(
        title = "Live View Guide",
        caption =
            "Replay the short camera-controls, View Assist, and system-controls introduction without enabling camera commands underneath it.",
    ) {
        SettingsInlineRow("Guide Status", showTopDivider = false) {
            SettingsValueText(guideController.status.label)
        }
        SettingsInlineRow("Replay") {
            Row(
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                if (onShowGuideNow != null && guideController.canReplayNow) {
                    SettingsLinkAction("Now", "Show Live View Guide Now", onShowGuideNow)
                }
                SettingsLinkAction(
                    "Next frame",
                    "Show Live View Guide on Next Real Frame",
                    onShowGuideOnNextRealFrame,
                )
            }
        }
    }

    SettingsGroupCard(
        title = "Project & Legal",
        caption = "OpenZCine is open source. These links leave the app only when you choose them.",
    ) {
        SettingsInlineRow("Source Code", showTopDivider = false) {
            SettingsLinkAction("Open", "Open Source Code") { runAction(actions::openSource) }
        }
        SettingsInlineRow("Privacy") {
            SettingsLinkAction("Open", "Open Privacy Policy") { runAction(actions::openPrivacy) }
        }
        SettingsInlineRow("Terms") {
            SettingsLinkAction("Open", "Open Terms of Use") { runAction(actions::openTerms) }
        }
        SettingsInlineRow("Open-Source Licenses") {
            SettingsValueText("Third-Party Notices")
        }
    }

    SettingsGroupCard(
        title = "App Information",
        caption = "Build and protocol details for support reports.",
    ) {
        SettingsInlineRow("Theme", showTopDivider = false) {
            SettingsValueText("Warm Dark")
        }
        SettingsInlineRow("Protocol Implementation") {
            SettingsValueText("PTP / PTP-IP")
        }
        SettingsInlineRow("App Version") {
            SettingsValueText(appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
        }
    }
}
