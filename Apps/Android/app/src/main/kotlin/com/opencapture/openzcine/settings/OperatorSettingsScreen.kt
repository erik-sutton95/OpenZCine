package com.opencapture.openzcine.settings

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.text.format.Formatter
import android.view.HapticFeedbackConstants
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawing
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.layout.windowInsetsPadding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.AlertDialog
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
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalUriHandler
import androidx.compose.ui.platform.LocalView
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.opencapture.openzcine.BuildConfig
import com.opencapture.openzcine.AssistState
import com.opencapture.openzcine.AssistTool
import com.opencapture.openzcine.ChromeShape
import com.opencapture.openzcine.LiveDesign
import com.opencapture.openzcine.chromeStyle
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.FeedFalseColorScale
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.glass
import com.opencapture.openzcine.frameio.FrameioConnectionState
import com.opencapture.openzcine.frameio.FrameioDeliveryController
import com.opencapture.openzcine.frameio.FrameioNetworkState
import com.opencapture.openzcine.media.MediaCacheClearResult
import com.opencapture.openzcine.media.MediaCacheStore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import com.opencapture.openzcine.lut.CustomLutImportResult
import com.opencapture.openzcine.lut.RedLutDownloadGate
import com.opencapture.openzcine.lut.StoredLutCategory
import com.opencapture.openzcine.lut.StoredLutEntry
import com.opencapture.openzcine.lut.StoredLutFailure
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Operator Setup rail tabs — the Android v1 subset of the iOS
 * `OperatorSettingsTab` set (Link / View Assist / Controls / Display /
 * Storage / System). Android exposes every tab whose current controls are
 * locally actionable; camera-property and integration tabs arrive with their
 * underlying platform adapters.
 */
public enum class OperatorSettingsTab(
    public val title: String,
    public val compactTitle: String,
    public val railSubtitle: String,
    public val subtitle: String,
    public val pill: String,
) {
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
    initialTab: OperatorSettingsTab = OperatorSettingsTab.ASSIST,
    onClose: () -> Unit,
) {
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
        assistState.toggle(tool)
        if (hapticsEnabled) {
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
            SettingsHeader(session, compact)
            if (compact) {
                SettingsTabStrip(selectedTab, onSelect = { selectedTab = it })
                SettingsContentPane(
                    selectedTab,
                    settings,
                    assistState,
                    mediaCacheStore,
                    frameioController,
                    lutLibrary,
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
                        settings,
                        assistState,
                        mediaCacheStore,
                        frameioController,
                        lutLibrary,
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
private fun SettingsHeader(session: CameraSession?, compact: Boolean) {
    if (compact) {
        Column(
            Modifier.fillMaxWidth(),
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            SettingsTitle(Modifier.padding(start = 45.dp))
            SettingsLiveTile(session, Modifier.fillMaxWidth(), expanded = true)
        }
    } else {
        Row(
            Modifier.fillMaxWidth().padding(start = 45.dp),
            verticalAlignment = Alignment.Top,
        ) {
            SettingsTitle()
            Spacer(Modifier.weight(1f))
            SettingsLiveTile(session, expanded = false)
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
    modifier: Modifier = Modifier,
    expanded: Boolean,
) {
    val disconnectedState = remember { MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected) }
    val state by (session?.state ?: disconnectedState).collectAsState()
    val standalone = session == null
    val linked = state is CameraSessionState.Connected
    val tint = if (linked) LiveDesign.good else LiveDesign.faint
    val detail =
        if (standalone) {
            "No camera · local setup only"
        } else {
            when (val current = state) {
                is CameraSessionState.Connected -> "${current.identity.name} · PTP-IP"
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
        // ponytail: bars are binary (4 or 0) until Android grows the iOS
        // linkHealth score; swap in the quartile mapping with it.
        Row(horizontalArrangement = Arrangement.spacedBy(2.dp), verticalAlignment = Alignment.Bottom) {
            repeat(4) { index ->
                Box(
                    Modifier.size(width = 3.dp, height = (6 + index * 3).dp)
                        .background(
                            if (linked) tint.copy(alpha = 0.52f + index * 0.12f)
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
    settings: OperatorSettings,
    assistState: AssistState,
    mediaCacheStore: MediaCacheStore,
    frameioController: FrameioDeliveryController?,
    lutLibrary: AndroidLutLibrary?,
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
                Column(
                    Modifier.fillMaxSize().verticalScroll(rememberScrollState()),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    when (tab) {
                        OperatorSettingsTab.ASSIST ->
                            AssistRows(
                                settings,
                                assistState,
                                lutLibrary,
                                onSettingToggle,
                                onAssistToggle,
                                onInteraction,
                            )
                        OperatorSettingsTab.CONTROLS -> ControlsRows(settings, onSettingToggle)
                        OperatorSettingsTab.DISPLAY ->
                            DisplayRows(settings, compact, onSettingToggle, onInteraction)
                        OperatorSettingsTab.STORAGE -> StorageRows(mediaCacheStore, frameioController, condensed)
                        OperatorSettingsTab.SYSTEM -> SystemRows()
                    }
                }
            }
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
    onSettingToggle: (OperatorSettings.Toggle) -> Unit,
    onAssistToggle: (AssistTool) -> Unit,
    onInteraction: () -> Unit,
) {
    SettingsRowCard {
        // Local framing tools have their own configuration group below. They
        // do not belong to AssistState, which intentionally owns only image
        // effects, scopes, and audio metering.
        AssistTool.entries
            .filterNot { it in AssistTool.framingTools }
            .forEachIndexed { index, tool ->
            SettingsSwitchRow(
                tool.settingsTitle,
                isOn = assistState.isOn(tool),
                showTopDivider = index != 0,
            ) { onAssistToggle(tool) }
        }
    }
    if (lutLibrary != null) {
        StoredLutLibraryRows(
            library = lutLibrary,
            assistState = assistState,
            onInteraction = onInteraction,
        )
        RedLutWorkflowRows()
    }
    SettingsGroupCard(
        title = "Image Processing",
        caption = "Choose the look and false-color scale used when each assist is enabled.",
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
        SettingsInlineRow(title = "False Color") {
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
    }
    SettingsGroupCard(
        title = "Traffic Lights",
        caption = "Configure the shared Swift meter used by the histogram and goal-post panel.",
    ) {
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
                                if (assistState.selectedLut == FeedLutSelection.Stored(entry.selection)) {
                                    assistState.selectLut(FeedLut.LOG3G10_709)
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
            SettingsLinkAction("Remove", onRemove)
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
            "Monitor-only; Android cannot reliably identify Bluetooth sources. Phone volume keys remain unchanged.",
    ) {
        SettingsSwitchRow(
            "Enable Media Remote",
            isOn = settings.mediaRemoteShutterEnabled.value,
            showTopDivider = false,
        ) { onToggle(settings.mediaRemoteShutterEnabled) }
        Text(
            "Play/Pause, headset, and Record keys control recording; confirmation is skipped.",
            style = chromeStyle(10.5f, FontWeight.Normal),
            color = LiveDesign.muted,
        )
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
) {
    SettingsGroupCard(
        title = "Monitor Chrome",
        caption = "Show only the monitor regions you need during a take.",
    ) {
        if (compact) {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    DisplayToggleItem(
                        "STATUS",
                        isOn = settings.statusBarVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(settings.statusBarVisible) }
                    DisplayToggleItem(
                        "ASSISTS",
                        isOn = settings.assistToolbarVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(settings.assistToolbarVisible) }
                }
                DisplayToggleItem(
                    "VALUES",
                    isOn = settings.cameraValuesVisible.value,
                    modifier = Modifier.fillMaxWidth(),
                ) { onToggle(settings.cameraValuesVisible) }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                DisplayToggleItem(
                    "STATUS",
                    isOn = settings.statusBarVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.statusBarVisible) }
                DisplayToggleItem(
                    "ASSISTS",
                    isOn = settings.assistToolbarVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.assistToolbarVisible) }
                DisplayToggleItem(
                    "VALUES",
                    isOn = settings.cameraValuesVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.cameraValuesVisible) }
            }
        }
    }
    SettingsGroupCard(
        title = "View Assist Toolbar",
        caption = "Show or hide tools, then use arrows to set their monitor order.",
    ) {
        settings.assistToolbarOrder.forEachIndexed { index, tool ->
            SettingsInlineRow(
                title = "${index + 1}. ${tool.settingsTitle}",
                showTopDivider = index != 0,
            ) {
                Row(
                    horizontalArrangement = Arrangement.spacedBy(4.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    if (tool == AssistTool.LUT) {
                        SettingsValueText("PINNED")
                    } else {
                        Box(
                            Modifier.settingsClickable(role = Role.Switch) {
                                settings.toggleAssistToolbarToolVisibility(tool)
                                onInteraction()
                            },
                        ) {
                            SettingsSwitchGraphic(settings.isAssistToolbarToolVisible(tool))
                        }
                    }
                    SettingsLinkAction("↑") {
                        settings.moveAssistToolbarTool(tool, direction = -1)
                        onInteraction()
                    }
                    SettingsLinkAction("↓") {
                        settings.moveAssistToolbarTool(tool, direction = 1)
                        onInteraction()
                    }
                }
            }
        }
        SettingsLinkAction("Reset toolbar") {
            settings.resetAssistToolbarPreferences()
            onInteraction()
        }
    }
    SettingsGroupCard(
        title = "Live Status Readouts",
        caption = "Hide readouts you do not ride during a take.",
    ) {
        if (compact) {
            Column(verticalArrangement = Arrangement.spacedBy(7.dp)) {
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    DisplayToggleItem(
                        "REC",
                        isOn = settings.recReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(settings.recReadoutVisible) }
                    DisplayToggleItem(
                        "CODEC",
                        isOn = settings.codecReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(settings.codecReadoutVisible) }
                }
                Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                    DisplayToggleItem(
                        "MEDIA",
                        isOn = settings.mediaReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(settings.mediaReadoutVisible) }
                    DisplayToggleItem(
                        "FPS",
                        isOn = settings.fpsReadoutVisible.value,
                        modifier = Modifier.weight(1f),
                    ) { onToggle(settings.fpsReadoutVisible) }
                }
            }
        } else {
            Row(horizontalArrangement = Arrangement.spacedBy(7.dp)) {
                DisplayToggleItem(
                    "REC",
                    isOn = settings.recReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.recReadoutVisible) }
                DisplayToggleItem(
                    "CODEC",
                    isOn = settings.codecReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.codecReadoutVisible) }
                DisplayToggleItem(
                    "MEDIA",
                    isOn = settings.mediaReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.mediaReadoutVisible) }
                DisplayToggleItem(
                    "FPS",
                    isOn = settings.fpsReadoutVisible.value,
                    modifier = Modifier.weight(1f),
                ) { onToggle(settings.fpsReadoutVisible) }
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
            "Adobe PKCE sign-in and project selection for complete cached media. OpenZCine never switches away from camera Wi-Fi to reach Frame.io."
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

/** System tab — fully real: version, support, legal links, licenses (iOS `systemRows`). */
@Composable
private fun SystemRows() {
    val uriHandler = LocalUriHandler.current
    SettingsRowCard {
        SettingsInlineRow("Theme", showTopDivider = false) {
            SettingsValueText("Warm Dark")
        }
        SettingsInlineRow("Protocol Implementation") {
            SettingsValueText("PTP / PTP-IP")
        }
        SettingsInlineRow("App Version") {
            SettingsValueText(appVersionText(BuildConfig.VERSION_NAME, BuildConfig.VERSION_CODE))
        }
        SettingsInlineRow("Support") {
            SettingsLinkAction("Open") { uriHandler.openUri("https://openzcine.app/support/") }
        }
        SettingsInlineRow("Legal") {
            Row(
                horizontalArrangement = Arrangement.spacedBy(10.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                SettingsQuietLink("Privacy") { uriHandler.openUri("https://openzcine.app/privacy") }
                SettingsQuietLink("Terms") { uriHandler.openUri("https://openzcine.app/terms") }
            }
        }
        SettingsInlineRow("Open-Source Licenses") {
            SettingsValueText("Third-Party Notices")
        }
    }
}
