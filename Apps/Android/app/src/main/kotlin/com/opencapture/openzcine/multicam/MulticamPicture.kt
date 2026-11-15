package com.opencapture.openzcine.multicam

import android.graphics.Bitmap
import android.os.Build
import androidx.annotation.RequiresApi
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import com.opencapture.openzcine.ExposureAssistCameraInput
import com.opencapture.openzcine.FeedEffects
import com.opencapture.openzcine.FeedEffectsConfiguration
import com.opencapture.openzcine.FeedEffectsRenderPlans
import com.opencapture.openzcine.FeedEffectsRenderer
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

    /** Another camera takes the tile: the last frame is dropped, so no look re-bakes it. */
    internal fun clear() {
        invalidate()
        raw = null
        publish(null)
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
