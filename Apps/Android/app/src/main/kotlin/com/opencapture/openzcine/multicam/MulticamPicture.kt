package com.opencapture.openzcine.multicam

import android.graphics.Bitmap
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.selected
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.stateDescription
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.opencapture.monitorui.MonitorImagePreview
import com.opencapture.monitorui.MonitorInspector
import com.opencapture.monitorui.MonitorPalette
import com.opencapture.monitorui.MonitorTypography
import com.opencapture.monitorui.monitorChromeClickable
import com.opencapture.opencine.appkit.MultiviewStageViewport
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedEffects
import com.opencapture.openzcine.FeedEffectsConfiguration
import com.opencapture.openzcine.FeedEffectsRenderPlans
import com.opencapture.openzcine.FeedEffectsRenderer
import com.opencapture.openzcine.FeedLut
import com.opencapture.openzcine.FeedLutSelection
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.lut.AndroidLutLibrary
import java.util.concurrent.Executors
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.asCoroutineDispatcher
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withContext

/**
 * Applies one look to one member's tile picture with the shipped native effect chain. Called only
 * on that member's own worker thread; it may hold GPU resources until [close].
 */
interface MulticamLookRenderer : AutoCloseable {
    /** The graded picture, or `null` when this look cannot render now. */
    fun render(frame: Bitmap, selection: FeedLutSelection): Bitmap?
}

/**
 * The production adapter: the same immutable plan and AGSL chain the single-camera feed and the
 * Watch relay use ([FeedEffectsRenderPlans], [FeedEffectsRenderer.bakePreview]). Stored cubes come
 * from the app's one [AndroidLutLibrary]; its render generation invalidates a same-name revision.
 */
@RequiresApi(33)
internal class NativeMulticamLookRenderer(private val library: AndroidLutLibrary?) : MulticamLookRenderer {
    private val plans = FeedEffectsRenderPlans()
    private var key: Pair<FeedLutSelection, Long>? = null
    private var renderer: FeedEffectsRenderer? = null

    override fun render(frame: Bitmap, selection: FeedLutSelection): Bitmap? {
        val next = selection to (library?.renderGeneration?.value ?: 0L)
        if (key != next) {
            renderer?.close()
            renderer = null
            key = next
            if (selection is FeedLutSelection.Stored) {
                // This worker is the member's own thread, never Main.
                runBlocking { library?.prepare(selection.value) }
            }
            val plan = plans.create(FeedEffects(lut = selection), FeedEffectsConfiguration(), ExposureAssistCameraInput(), library)
                ?.takeIf { it.baseCube != null } ?: return null
            renderer = FeedEffectsRenderer.create(plan)
        }
        return renderer?.bakePreview(frame, frame.width)
    }

    override fun close() {
        renderer?.close()
        renderer = null
        key = null
        plans.close()
    }
}

/** A member renderer factory only with the AGSL floor and the staged Swift core; otherwise absent. */
internal fun multicamLookRendererFactory(library: AndroidLutLibrary?): (() -> MulticamLookRenderer)? =
    if (Build.VERSION.SDK_INT >= 33 && SwiftCore.isAvailable) ({ NativeMulticamLookRenderer(library) }) else null

/**
 * One member's picture owner: its latest accepted raw tile frame, its own look (on/off and
 * selection) and what the tile shows. Fields are Main-confined; only rendering runs on the member's
 * single worker. A bake publishes only while its source frame and look are still current and the
 * member has not retired; the newest frame wins and at most one bake runs.
 */
class MulticamPicture internal constructor(
    initialSelection: FeedLutSelection,
    private val publish: (ImageBitmap?) -> Unit,
) {
    var lutEnabled by mutableStateOf(false)
        private set
    var selection by mutableStateOf(initialSelection)
        private set
    /** A real native renderer is attached: the LUT tool can act on this member. */
    var renderCapable by mutableStateOf(false)
        private set

    private var scope: CoroutineScope? = null
    private var renderer: MulticamLookRenderer? = null
    private val executor = lazy { Executors.newSingleThreadExecutor { Thread(it, "multiview-member-look") } }
    private val worker by lazy { executor.value.asCoroutineDispatcher() }
    private var raw: Bitmap? = null
    private var sourceGeneration = 0L
    private var lookRevision = 0L
    private var bake: Job? = null
    private var retired = false

    /** Attaches the member's renderer once; a member without one never offers LUT. */
    internal fun attach(scope: CoroutineScope, factory: (() -> MulticamLookRenderer)?, initial: FeedLutSelection) {
        if (retired || renderer != null || factory == null) return
        this.scope = scope
        // The operator's current single-camera look seeds this member; never an automatic one.
        if (!lutEnabled) selection = initial
        renderer = factory()
        renderCapable = true
    }

    /** A newly accepted frame. The caller hands over an immutable bitmap it no longer reuses. */
    fun accept(frame: Bitmap) {
        if (retired) return
        raw = frame
        sourceGeneration += 1
        if (lutEnabled && renderCapable) schedule() else publish(frame.asImageBitmap())
    }

    fun showLut(enabled: Boolean) {
        if (retired || enabled == lutEnabled || (enabled && !renderCapable)) return
        lutEnabled = enabled
        lookChanged()
    }

    fun select(next: FeedLutSelection) {
        if (retired || next == selection) return
        selection = next
        lookRevision += 1
        // A shown look re-renders the latest accepted picture now; a hidden one changes nothing visible.
        if (lutEnabled) schedule()
    }

    private fun lookChanged() {
        lookRevision += 1
        // The latest accepted picture re-renders now; no fresh camera frame is needed.
        if (lutEnabled) schedule() else raw?.let { publish(it.asImageBitmap()) }
    }

    private fun schedule() {
        if (bake?.isActive == true) return // the running bake loops to the newest frame and look
        val scope = scope ?: return
        bake = scope.launch {
            while (!retired && lutEnabled) {
                val frame = raw ?: return@launch
                val source = sourceGeneration
                val look = lookRevision
                val chosen = selection
                val renderer = renderer ?: return@launch
                val output = withContext(worker) { runCatching { renderer.render(frame, chosen) }.getOrNull() }
                if (retired) return@launch
                if (source == sourceGeneration && look == lookRevision) {
                    if (lutEnabled) publish((output ?: frame).asImageBitmap())
                    return@launch
                }
            }
        }
    }

    /** The member's link or session changed: work for frames accepted before now never publishes. */
    internal fun invalidate() {
        sourceGeneration += 1
        bake?.cancel()
        bake = null
    }

    /** The member left or was replaced: late work is discarded and only its own pixels clear. */
    internal fun retire() {
        if (retired) return
        retired = true
        bake?.cancel()
        bake = null
        raw = null
        renderCapable = false
        publish(null)
        val renderer = renderer
        this.renderer = null
        if (executor.isInitialized()) {
            // Runs after any in-flight render on the same worker, never on Main.
            executor.value.execute { runCatching { renderer?.close() } }
            executor.value.shutdown()
        } else {
            renderer?.close()
        }
    }
}

/** A look the options list offers: a built-in procedural look or a stored cube. */
internal data class MulticamLookChoice(val selection: FeedLutSelection, val title: String)

internal fun multicamLookChoices(library: AndroidLutLibrary?): List<MulticamLookChoice> =
    FeedLut.entries.map { MulticamLookChoice(FeedLutSelection.BuiltIn(it), it.label) } +
        library?.entries?.value.orEmpty().map { MulticamLookChoice(FeedLutSelection.Stored(it.selection), it.displayName) }

/** Per-member look options: member tabs, that member's picture, its on/off and its look. */
@Composable
internal fun MulticamLookSettings(
    coordinator: MulticamCoordinator,
    slot: Int,
    viewport: MultiviewStageViewport,
    close: () -> Unit,
    select: (Int) -> Unit,
) {
    val member = coordinator.memberAt(slot)
    val picture = member?.picture
    coordinator.lutLibrary?.entries?.collectAsState()
    MonitorInspector(
        title = "LUT",
        viewportWidth = viewport.width,
        viewportHeight = viewport.height,
        onDismiss = close,
        modifier = Modifier.testTag("multiview.lut.panel"),
        trailing = true,
        hasNavigation = false,
        safeLeading = viewport.safeArea.leading,
        safeTrailing = viewport.safeArea.trailing,
        safeTop = viewport.safeArea.top,
        safeBottom = viewport.safeArea.bottom,
        close = { MulticamPanelClose("Close LUT", close) },
        compactHeader = true,
    ) {
        Column(Modifier.fillMaxSize(), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            MulticamMemberTabs(
                slots = coordinator.pictureLUTSlots.sorted(), selected = slot,
                title = { coordinator.memberAt(it)?.letter.orEmpty() },
                identifier = { "multiview.lut.camera.$it" }, select = select,
            )
            Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()),
                verticalArrangement = Arrangement.spacedBy(6.dp)) {
                MonitorImagePreview(member?.frame, "${member?.displayName.orEmpty()} picture",
                    Modifier.testTag("multiview.lut.preview"))
                if (member != null && picture != null) {
                    val on = picture.lutEnabled
                    Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).testTag("multiview.lut.enabled")
                        .monitorChromeClickable { coordinator.setLUTEnabled(member.id, !on) }
                        .semantics { role = Role.Switch; stateDescription = if (on) "On" else "Off"; contentDescription = "LUT" }
                        .padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                        Text("LUT", Modifier.weight(1f), style = MonitorTypography.text(13f, FontWeight.SemiBold), color = MonitorPalette.text)
                        Text(if (on) "On" else "Off", style = MonitorTypography.text(13f, FontWeight.Medium), color = MonitorPalette.muted)
                    }
                    multicamLookChoices(coordinator.lutLibrary).forEachIndexed { index, choice ->
                        val chosen = choice.selection == picture.selection
                        Row(Modifier.fillMaxWidth().heightIn(min = 44.dp).testTag("multiview.lut.choice.$index")
                            .monitorChromeClickable { coordinator.setLUTSelection(member.id, choice.selection) }
                            .semantics { role = Role.RadioButton; selected = chosen; contentDescription = choice.title }
                            .padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                            Text(choice.title, Modifier.weight(1f), style = MonitorTypography.text(13f, FontWeight.Medium),
                                color = if (chosen) MonitorPalette.text else MonitorPalette.muted)
                            if (chosen) Text("Selected", style = MonitorTypography.text(11f, FontWeight.Medium), color = MonitorPalette.muted)
                        }
                    }
                }
            }
        }
    }
}
