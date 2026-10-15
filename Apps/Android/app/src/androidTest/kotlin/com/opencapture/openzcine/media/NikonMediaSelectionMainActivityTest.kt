package com.opencapture.openzcine.media

import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Point
import android.graphics.Rect
import android.graphics.Region
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.PixelCopy
import android.view.accessibility.AccessibilityNodeInfo
import android.view.accessibility.AccessibilityWindowInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.Condition
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.Until
import com.opencapture.opencine.nikon.NikonMediaClipRecord
import com.opencapture.opencine.nikon.NikonMediaContentKind
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import java.nio.file.Files
import java.nio.file.Path
import java.util.Comparator
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONArray
import org.json.JSONObject
import com.opencapture.opencine.appkit.MonitorMediaViewOptions
import com.opencapture.opencine.appkit.MonitorMediaSort
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import com.opencapture.monitorui.MonitorThumbnailSize
import com.opencapture.monitorui.MonitorMediaLayout
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport

/** Actual source-owned offline library; all content is SIMULATED metadata/stub bytes. */
@RunWith(AndroidJUnit4::class)
class NikonMediaSelectionMainActivityTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context = instrumentation.targetContext
    private val device = UiDevice.getInstance(instrumentation)
    private val preferences = context.getSharedPreferences("openzcine.media-library", Context.MODE_PRIVATE)
    private val bucket = "SIMULATED-SELECTION-${System.nanoTime()}"
    private val cache = MediaCacheStore(context.noBackupFilesDir.resolve("media-cache").toPath())
    private val savedCameraStore = SharedPreferencesSavedCameraStore(context)
    private var baseline: Map<String, *>? = null
    private var savedCameraBaseline: List<SavedCameraRecord>? = null
    private var createdDirectory: Path? = null
    private var scenario: ActivityScenario<MainActivity>? = null
    private var originalRotation = 0
    private var originalIdleTimeout = 0L
    private var pointerTrace: JSONArray? = null
    private val stationaryIntervalMs = 1_250L

    @Before
    fun seedIsolatedCompletedCatalog() {
        originalIdleTimeout = Configurator.getInstance().waitForIdleTimeout
        // Observe a live native frame clock instead of waiting until its scroll
        // reaches the catalog end and becomes idle before taking both snapshots.
        Configurator.getInstance().waitForIdleTimeout = 0
        baseline = preferences.all.toMap()
        savedCameraBaseline = savedCameraStore.records()
        val record = SavedCameraRecord(
            host = "simulated-selection-fixture", cameraName = "SIMULATED selection",
            transport = SavedCameraTransport.USB_C, lastSeenAtEpochMillis = 1, wifiSsid = null,
        )
        savedCameraStore.replace(listOf(record))
        originalRotation = device.displayRotation
        val clips = (1..40).map { number ->
            NikonMediaClipRecord(
                handle = number.toLong(), storageId = 65_537, sizeBytes = 4,
                captureDate = "20261003T10%02d00".format(number), pixelWidth = 1_920, pixelHeight = 1_080,
                filename = "SIMULATED-SEL-%02d.R3D".format(number),
                contentKind = NikonMediaContentKind.R3D_MASTER, stillPhoto = null,
            )
        }
        val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        index.rememberCameraListing(bucket, clips)
        index.rememberCameraBucket(record.id, bucket, record.displayTitle)
        index.mediaPreferences(bucket).saveViewOptions(MonitorMediaViewOptions(
            layout = MonitorMediaLayout.LIST, sort = MonitorMediaSort.NAME, thumbnailSize = MonitorThumbnailSize.SMALL,
        ))
        clips.forEach { clip ->
            cache.openEntry(bucket, MediaCacheObjectIdentity(clip), clip.sizeBytes).apply {
                check(finalPath.parent.parent == cache.rootDirectory)
                createdDirectory = finalPath.parent
                append(0, byteArrayOf(1, 2, 3, 4))
                complete()
            }
        }
        scenario = ActivityScenario.launch(Intent(context, MainActivity::class.java)
            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK))
        // Launch can replace the orientation measured while the test host was active.
        device.setOrientationNatural()
        settleNaturalOrientation()
        requireNotNull(device.wait(Until.findObject(By.desc("Media library")), 15_000)).click()
        row("01")
        settleNaturalOrientation()
    }

    @After
    fun restoreOnlyFixtureState() {
        try { scenario?.close() } finally {
            Configurator.getInstance().waitForIdleTimeout = originalIdleTimeout
            savedCameraBaseline?.let {
                savedCameraStore.replace(it)
                assertEquals(it, savedCameraStore.records())
            }
            baseline?.let { saved ->
                val editor = preferences.edit().clear()
                saved.forEach { (key, value) ->
                    when (value) {
                        is String -> editor.putString(key, value)
                        is Boolean -> editor.putBoolean(key, value)
                        is Int -> editor.putInt(key, value)
                        is Long -> editor.putLong(key, value)
                        is Float -> editor.putFloat(key, value)
                        is Set<*> -> editor.putStringSet(key, value.map { requireNotNull(it as? String) }.toSet())
                        else -> error("Unsupported saved preference type for $key")
                    }
                }
                check(editor.commit())
                assertEquals(saved, preferences.all)
            }
            createdDirectory?.let { directory ->
                check(directory.parent == cache.rootDirectory)
                if (Files.exists(directory)) Files.walk(directory).use { paths ->
                    paths.sorted(Comparator.reverseOrder()).forEach { Files.deleteIfExists(it) }
                }
                assertEquals(false, Files.exists(directory))
            }
            when (originalRotation) {
                1 -> device.setOrientationLeft()
                3 -> device.setOrientationRight()
                else -> device.setOrientationNatural()
            }
            device.unfreezeRotation()
            println("SELECTION_NATIVE_RESTORED=$bucket preferences=${baseline == preferences.all}")
        }
    }

    @Test
    fun actualSelectingTapAndVerticalDragPreserveSelectionAndResumeScrolling() {
        trace("initial-list")
        val viewport = catalogViewport()
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        trace("selection-entered-before-tap")
        tap(center(stableRowBounds("02")))
        selectedCount(2)
        val before = visibleRows()
        swipe(Point(viewport.centerX(), viewport.bottom - 60),
            Point(viewport.centerX(), viewport.top + 80), 420)
        selectedCount(2)
        assertNotEquals(before, visibleRows())
        trace("selecting-after-native-vertical-scroll")
        requireNotNull(device.findObject(By.desc("Exit media selection"))).click()
        assertTrue(device.wait(Until.gone(By.text("2 selected")), 5_000))
        val scrollingBefore = visibleRows()
        swipe(Point(viewport.centerX(), viewport.top + 80),
            Point(viewport.centerX(), viewport.bottom - 60), 420)
        assertNotEquals(scrollingBefore, visibleRows())
        trace("native-scroll-after-selection-exit")
    }

    @Test
    fun actualStationaryHeldEdgeScrollsMountedRows() {
        val browsingViewport = catalogViewport()
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        trace("selection-entered-before-sweep")
        // Selection hides the density controls and grows the viewport. Measure
        // its current native owner so the held point is inside the real band.
        val viewport = catalogViewport()
        val start = center(stableRowBounds("03"))
        val edge = Point(viewport.centerX(), viewport.bottom - 12)
        println("SIMULATED_SELECTION_VIEWPORT browse=$browsingViewport selecting=$viewport edge=$edge")
        val down = SystemClock.uptimeMillis()
        val times = JSONObject().put("downRequestedMs", down)
        pointerTrace = JSONArray()
        try {
            inject(MotionEvent.ACTION_DOWN, start, down)
            times.put("downReturnedMs", SystemClock.uptimeMillis())
            SystemClock.sleep(650)
            times.put("holdReturnedMs", SystemClock.uptimeMillis())
            move(start, edge, down, 420)
            times.put("moveReturnedMs", SystemClock.uptimeMillis())
            times.put("beforeSnapshotRequestedMs", SystemClock.uptimeMillis())
            val beforeHold = nativeVisibleRows(viewport)
            times.put("beforeSnapshotReturnedMs", SystemClock.uptimeMillis())
            times.put("stationarySleepStartedMs", SystemClock.uptimeMillis())
            SystemClock.sleep(stationaryIntervalMs)
            times.put("afterSnapshotRequestedMs", SystemClock.uptimeMillis())
            val afterHold = nativeVisibleRows(viewport)
            times.put("afterSnapshotReturnedMs", SystemClock.uptimeMillis())
            times.put("beforeRows", JSONArray(beforeHold)).put("afterRows", JSONArray(afterHold))
            println("SELECTION_STATIONARY_PROGRESS=${beforeHold != afterHold}")
            assertNotEquals("Stationary held edge must scroll real mounted rows", beforeHold, afterHold)
        } finally {
            inject(MotionEvent.ACTION_UP, edge, down)
            println("SIMULATED_SELECTION_TIMING=" + times.put("events", pointerTrace))
            pointerTrace = null
        }
        requireNotNull(device.findObject(By.desc("Exit media selection"))).click()
        trace("edge-terminal")
    }

    @Test
    fun actualGridFavoritePersistsAndBrowseAdmissionKeepsSelectionSeparate() {
        pressControl("Grid view")
        awaitStableCatalogGeometry(expectGrid = true)
        val first = stableRowBounds("01")
        val second = stableRowBounds("02")
        assertTrue("Small Grid must mount two distinct columns", first.centerX() != second.centerX())
        pressControl("Add SIMULATED-SEL-01.R3D to favorites")
        val removed = waitForCurrentFavoriteControl("Remove SIMULATED-SEL-01.R3D from favorites")
        if (removed == null) nativeDiagnostic("favorite-remove-not-mounted", includeFavorites = true)
        assertNotNull(removed)
        requireNotNull(scenario).recreate()
        pressControl("Media library")
        assertNotNull(waitForCurrentFavoriteControl("Remove SIMULATED-SEL-01.R3D from favorites"))
        val restoredFirst = stableRowBounds("01")
        val restoredSecond = stableRowBounds("02")
        assertTrue("Persisted Grid must retain its native columns", restoredFirst.centerX() != restoredSecond.centerX())
        tap(center(restoredSecond))
        assertNotNull(device.wait(Until.findObject(By.text(
            "SIMULATED-SEL-02.R3D is a camera master; preview is unavailable.")), 5_000))
        assertTrue(device.wait(Until.gone(By.desc("Exit media selection")), 5_000))
        trace("grid-master-admission-and-favorite")
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        traceMatrixFinalTap("grid-native-hold-and-tap", "02")
        matrixSelected("grid-native-hold-and-tap", names("01", "02"))
        traceMatrixSelection("grid-native-hold-and-tap")
    }

    @Test
    fun actualGridSweepReversesMixedSelectionWithoutLosingOriginalItems() {
        pressControl("Grid view")
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        tap(center(stableRowBounds("04")))
        selectedCount(2)
        val viewport = catalogViewport()
        val second = center(stableRowBounds("02"))
        val third = center(stableRowBounds("03"))
        val fourth = center(stableRowBounds("04"))
        assertEquals(names("01", "04"), nativeRowsSnapshot(viewport).selected)
        val down = SystemClock.uptimeMillis()
        pointerTrace = JSONArray()
        try {
            inject(MotionEvent.ACTION_DOWN, second, down)
            SystemClock.sleep(650)
            assertEquals(names("01", "02", "04"), nativeRowsSnapshot(viewport).selected)
            move(second, third, down, 210)
            move(third, fourth, down, 210)
            assertEquals(names("01", "02", "03", "04"), nativeRowsSnapshot(viewport).selected)
            move(fourth, third, down, 210)
            move(third, second, down, 210)
            assertEquals(names("01", "02", "04"), nativeRowsSnapshot(viewport).selected)
        } finally {
            inject(MotionEvent.ACTION_UP, second, down)
            finishMatrixTrace("reversible-grid")
        }
        selectedCount(3)
        trace("grid-reversible-mixed-set")
    }

    @Test
    fun actualHeldRotationRetiresOldPointerAndLeavesFreshInputUsable() {
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        val start = center(stableRowBounds("02"))
        val down = SystemClock.uptimeMillis()
        var terminal = start
        pointerTrace = JSONArray()
        try {
            inject(MotionEvent.ACTION_DOWN, start, down)
            SystemClock.sleep(650)
            selectedCount(2)
            assertEquals(names("01", "02"), nativeRowsSnapshot(catalogViewport()).selected)
            device.setOrientationLeft()
            assertTrue("Actual native window must be landscape", device.displayWidth > device.displayHeight)
            awaitStableCatalogGeometry(expectGrid = false)
            stableRowBounds("01")
            val viewport = catalogViewport()
            terminal = center(stableRowBounds("03"))
            assertEquals(names("01", "02"), nativeRowsSnapshot(viewport).selected)
            inject(MotionEvent.ACTION_MOVE, terminal, down)
            SystemClock.sleep(125)
        } finally {
            inject(MotionEvent.ACTION_UP, terminal, down)
            finishMatrixTrace("rotation-retired-pointer")
        }
        val viewport = catalogViewport()
        assertEquals(names("01", "02"), nativeRowsSnapshot(viewport).selected)
        selectedCount(2)
        tap(center(stableRowBounds("03")))
        selectedCount(3)
        trace("list-landscape-fresh-input-after-retirement")
        pressControl("Exit media selection")
        assertTrue(device.wait(Until.gone(By.text("3 selected")), 5_000))
        val before = visibleRows()
        swipe(Point(viewport.centerX(), viewport.bottom - 30),
            Point(viewport.centerX(), viewport.top + 40), 420)
        assertNotEquals(before, visibleRows())
        trace("list-landscape-scroll-after-retirement")
    }

    @Test
    fun actualBackCancellationAllowsLayoutDensityAndCategoryRemount() {
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        val start = center(stableRowBounds("02"))
        val down = SystemClock.uptimeMillis()
        var terminal = start
        pointerTrace = JSONArray()
        try {
            inject(MotionEvent.ACTION_DOWN, start, down)
            SystemClock.sleep(650)
            selectedCount(2)
            val backRequested = SystemClock.uptimeMillis()
            val backAcknowledged = device.pressBack()
            println("SIMULATED_SELECTION_BACK=" + JSONObject()
                .put("requestedMs", backRequested).put("returnedMs", SystemClock.uptimeMillis())
                .put("accessibilityEventAcknowledged", backAcknowledged))
            // UiAutomator 2.3 waits for event2048; that acknowledgement can time
            // out after the actual Back callback already retired selection.
            assertTrue(device.wait(Until.gone(By.desc("Exit media selection")), 5_000))
            assertEquals(emptySet<String>(), nativeRowsSnapshot(catalogViewport()).selected)
            terminal = center(stableRowBounds("03"))
            inject(MotionEvent.ACTION_MOVE, terminal, down)
            SystemClock.sleep(125)
        } finally {
            inject(MotionEvent.ACTION_UP, terminal, down)
            finishMatrixTrace("back-retired-pointer")
        }
        assertTrue(device.wait(Until.gone(By.desc("Exit media selection")), 5_000))
        assertTrue(device.wait(Until.gone(By.text(
            "SIMULATED-SEL-03.R3D is a camera master; preview is unavailable.")), 5_000))
        val viewport = catalogViewport()
        pressControl("Grid view")
        val small = stableRowBounds("01")
        pressControl("Large thumbnails")
        val large = stableRowBounds("01")
        assertTrue("Large density must change drawn native card width", large.width() > small.width())
        pressControl("Small thumbnails")
        assertEquals(small.width(), stableRowBounds("01").width())
        pressControl("List view")
        assertTrue(stableRowBounds("01").width() > small.width())
        pressControl("Add SIMULATED-SEL-01.R3D to favorites")
        pressControl("Show Favorites media")
        assertEquals(names("01").toList(), nativeVisibleRows(viewport))
        pressControl("Show All media")
        assertTrue(nativeVisibleRows(viewport).size > 1)
        pressControl("Grid view")
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        traceMatrixFinalTap("grid-remounted-after-back-layout-density-category", "02")
        val current = matrixSelected("grid-remounted-after-back-layout-density-category", names("01", "02"))
        traceMatrixSelection("grid-remounted-after-back-layout-density-category", renderedWindowMatch = current)
        pressControl("Exit media selection")
        val before = visibleRows()
        swipe(Point(viewport.centerX(), viewport.bottom - 60),
            Point(viewport.centerX(), viewport.top + 80), 420)
        assertNotEquals(before, visibleRows())
        trace("grid-scroll-after-context-remount")
    }

    private fun waitForCurrentFavoriteControl(description: String): UiObject2? {
        val selector = By.desc(description)
        return device.wait(object : Condition<UiDevice, UiObject2> {
            override fun apply(device: UiDevice): UiObject2? {
                freshAccessibility()
                return device.findObject(selector)
            }
        }, 5_000)
    }

    private fun names(vararg numbers: String): Set<String> =
        numbers.map { "SIMULATED-SEL-$it.R3D" }.toSet()

    private fun pressControl(description: String) {
        var previous: Rect? = null
        var stable = 0
        repeat(50) {
            freshAccessibility()
            try {
                val target = device.findObject(By.desc(description))
                val bounds = target?.visibleBounds
                if (bounds != null && !bounds.isEmpty && nativeControlPointAvailable(description, bounds)) {
                    stable = if (bounds == previous) stable + 1 else 0
                    previous = Rect(bounds)
                    if (stable >= 2) {
                        println("SIMULATED_SELECTION_CONTROL=" + JSONObject()
                            .put("description", description).put("bounds", bounds.toShortString())
                            .put("rotation", device.displayRotation)
                            .put("displayWidth", device.displayWidth).put("displayHeight", device.displayHeight))
                        val previousTrace = pointerTrace
                        pointerTrace = JSONArray()
                        try { tap(center(bounds)) } finally {
                            println("SIMULATED_SELECTION_CONTROL_TIMING=" + JSONObject()
                                .put("description", description).put("bounds", bounds.toShortString())
                                .put("x", bounds.centerX()).put("y", bounds.centerY()).put("events", pointerTrace))
                            pointerTrace = previousTrace
                        }
                        return
                    }
                } else {
                    stable = 0
                    previous = null
                }
            } catch (_: StaleObjectException) {
                stable = 0
                previous = null
            }
            SystemClock.sleep(100)
        }
        nativeDiagnostic("control-did-not-settle", includeFavorites = true)
        error("Actual visible control did not settle: $description")
    }

    private fun nativeControlPointAvailable(description: String, targetBounds: Rect): Boolean {
        val started = SystemClock.uptimeMillis()
        val windows = instrumentation.uiAutomation.windows
        val matching = linkedMapOf<Int, Int>()
        fun containsCurrentTarget(node: AccessibilityNodeInfo, windowID: Int): Boolean {
            val bounds = Rect().also(node::getBoundsInScreen)
            if (node.isVisibleToUser && node.windowId == windowID &&
                node.packageName?.toString() == context.packageName &&
                node.contentDescription?.toString() == description && bounds == targetBounds) return true
            for (index in 0 until node.childCount) {
                val child = node.getChild(index)
                if (child != null && containsCurrentTarget(child, windowID)) return true
            }
            return false
        }
        for (window in windows) {
            if (window.type != AccessibilityWindowInfo.TYPE_APPLICATION) continue
            val root = window.root ?: continue
            if (root.packageName?.toString() == context.packageName && containsCurrentTarget(root, window.id)) {
                matching[window.id] = window.layer
            }
        }
        val blocked = JSONArray()
        val targetLayer = matching.values.singleOrNull()
        if (targetLayer != null) {
            for (window in windows) {
                if (window.type != AccessibilityWindowInfo.TYPE_SYSTEM || window.layer <= targetLayer) continue
                val region = Region().also(window::getRegionInScreen)
                if (region.contains(targetBounds.centerX(), targetBounds.centerY())) {
                    blocked.put(JSONObject().put("id", window.id).put("type", window.type)
                        .put("layer", window.layer).put("region", region.toString()))
                }
            }
        }
        val elapsed = SystemClock.uptimeMillis() - started
        println("SIMULATED_SELECTION_CONTROL_WINDOW=" + JSONObject()
            .put("description", description).put("bounds", targetBounds.toShortString())
            .put("x", targetBounds.centerX()).put("y", targetBounds.centerY())
            .put("matchingWindowIDs", JSONArray(matching.keys.toList()))
            .put("targetLayer", targetLayer ?: JSONObject.NULL).put("blockedBy", blocked)
            .put("elapsedMs", elapsed))
        assertTrue("Native control window lookup must fit the original observer bound", elapsed < stationaryIntervalMs)
        return matching.size == 1 && blocked.length() == 0
    }

    private fun settleNaturalOrientation() {
        var stable = 0
        repeat(50) {
            stable = if (device.displayRotation == 0 && device.displayHeight > device.displayWidth) stable + 1 else 0
            if (stable >= 3) {
                println("SIMULATED_SELECTION_ORIENTATION=" + JSONObject()
                    .put("rotation", device.displayRotation).put("displayWidth", device.displayWidth)
                    .put("displayHeight", device.displayHeight).put("uptimeMs", SystemClock.uptimeMillis()))
                return
            }
            SystemClock.sleep(100)
        }
        assertEquals("Actual launched fixture must settle in natural portrait", 0, device.displayRotation)
        assertTrue(device.displayHeight > device.displayWidth)
        error("Actual launched fixture orientation did not settle")
    }

    private data class NativeCatalogGeometry(
        val rotation: Int,
        val displayWidth: Int,
        val displayHeight: Int,
        val root: Rect,
        val owner: Rect,
        val first: Rect,
        val second: Rect,
    )

    private fun awaitStableCatalogGeometry(expectGrid: Boolean) {
        val deadline = SystemClock.uptimeMillis() + 10_000
        var previous: NativeCatalogGeometry? = null
        while (SystemClock.uptimeMillis() < deadline) {
            val current = nativeCatalogGeometry(expectGrid)
            if (current != null && current == previous) return
            previous = current
            SystemClock.sleep(80)
        }
        nativeDiagnostic("catalog-geometry-did-not-settle", includeFavorites = true)
        error("Actual native catalog geometry did not settle within the existing row discovery window")
    }

    private fun nativeCatalogGeometry(expectGrid: Boolean): NativeCatalogGeometry? {
        val started = SystemClock.uptimeMillis()
        freshAccessibility()
        val root = instrumentation.uiAutomation.rootInActiveWindow ?: run {
            println("SIMULATED_SELECTION_GEOMETRY_SAMPLE=missing-current-root")
            return null
        }
        assertEquals(context.packageName, root.packageName?.toString())
        val rotation = device.displayRotation
        val width = device.displayWidth
        val height = device.displayHeight
        val screen = Rect(0, 0, width, height)
        val rootBounds = Rect().also(root::getBoundsInScreen)
        var geometry: NativeCatalogGeometry? = null
        fun visit(node: AccessibilityNodeInfo): Map<String, Rect> {
            val rows = linkedMapOf<String, Rect>()
            for (index in 0 until node.childCount) node.getChild(index)?.let { rows.putAll(visit(it)) }
            val bounds = Rect().also(node::getBoundsInScreen)
            val description = node.contentDescription?.toString()
            if (description?.startsWith("SIMULATED-SEL-") == true && node.isVisibleToUser && !bounds.isEmpty) {
                rows[description.substringBefore(",")] = Rect(bounds)
            }
            val containedRows = rows.filterValues { screen.contains(it) && bounds.contains(it) }
            val first = containedRows["SIMULATED-SEL-01.R3D"]
            val second = containedRows["SIMULATED-SEL-02.R3D"]
            val verticalActions = node.actionList.any { it.id in setOf(4096, 8192, 16908344, 16908346) }
            if (geometry == null && node.isScrollable && verticalActions && node.isVisibleToUser &&
                screen.contains(rootBounds) && screen.contains(bounds) && first != null && second != null &&
                containedRows.size >= 3 &&
                bounds.height() > first.height() * 2 && (!expectGrid || first.centerX() != second.centerX())) {
                geometry = NativeCatalogGeometry(rotation, width, height, Rect(rootBounds),
                    Rect(bounds), Rect(first), Rect(second))
            }
            return rows
        }
        visit(root)
        val elapsed = SystemClock.uptimeMillis() - started
        println("SIMULATED_SELECTION_GEOMETRY_SAMPLE=" + JSONObject()
            .put("elapsedMs", elapsed).put("rotation", rotation).put("displayWidth", width)
            .put("displayHeight", height).put("rootBounds", rootBounds.toShortString())
            .put("ownerBounds", geometry?.owner?.toShortString())
            .put("firstBounds", geometry?.first?.toShortString())
            .put("secondBounds", geometry?.second?.toShortString()).put("expectGrid", expectGrid))
        assertTrue("Native geometry sample must fit the original observation window", elapsed < stationaryIntervalMs)
        return geometry
    }

    private fun nativeDiagnostic(name: String, includeFavorites: Boolean = false) {
        val directory = context.cacheDir.resolve("SIMULATED-selection-native").apply { mkdirs() }
        device.takeScreenshot(directory.resolve("$name.png"))
        val started = SystemClock.uptimeMillis()
        freshAccessibility()
        val fetchStarted = SystemClock.uptimeMillis()
        val root = requireNotNull(instrumentation.uiAutomation.rootInActiveWindow)
        val fetched = SystemClock.uptimeMillis()
        val nodes = JSONArray()
        fun visit(node: AccessibilityNodeInfo, parentBounds: Rect?) {
            val bounds = Rect().also(node::getBoundsInScreen)
            val description = node.contentDescription?.toString()
            val text = node.text?.toString()
            if (node.isVisibleToUser && !bounds.isEmpty) {
                nodes.put(JSONObject().put("description", description).put("text", text)
                    .put("bounds", bounds.toShortString()).put("parentBounds", parentBounds?.toShortString())
                    .put("clickable", node.isClickable).put("enabled", node.isEnabled)
                    .put("selected", node.isSelected).put("scrollable", node.isScrollable)
                    .put("className", node.className?.toString()).put("actions", JSONArray(
                        node.actionList.map { action -> JSONObject().put("id", action.id)
                            .put("label", action.label?.toString()) })))
            }
            for (index in 0 until node.childCount) node.getChild(index)?.let { visit(it, bounds) }
        }
        visit(root, null)
        val elapsed = SystemClock.uptimeMillis() - started
        val receipt = JSONObject().put("name", name).put("uptimeMs", started)
            .put("rotation", device.displayRotation).put("displayWidth", device.displayWidth)
            .put("displayHeight", device.displayHeight).put("package", root.packageName?.toString())
            .put("elapsedMs", elapsed).put("clearMs", fetchStarted - started)
            .put("rootFetchMs", fetched - fetchStarted).put("treeWalkMs", SystemClock.uptimeMillis() - fetched)
            .put("nodes", nodes)
        if (includeFavorites) receipt.put("persistedFavoriteIDs", JSONArray(
            MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context)).favoriteIDs(bucket).sorted()))
        receipt.put("storedViewOptions", MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
            .mediaPreferences(bucket).viewOptions().toString())
        directory.resolve("$name.json").writeText(receipt.toString(2))
        println("SIMULATED_SELECTION_DIAGNOSTIC=" + JSONObject()
            .put("name", name).put("rotation", device.displayRotation).put("elapsedMs", elapsed)
            .put("nodes", nodes.length()).put("persistedFavoriteIDs", receipt.optJSONArray("persistedFavoriteIDs")))
        assertEquals(context.packageName, root.packageName?.toString())
        assertTrue("Native diagnostic must fit the existing observation window", elapsed < stationaryIntervalMs)
    }

    private fun finishMatrixTrace(name: String) {
        println("SIMULATED_SELECTION_MATRIX_TIMING=" + JSONObject()
            .put("name", name).put("events", pointerTrace))
        pointerTrace = null
    }

    private fun row(number: String): UiObject2 {
        freshAccessibility()
        val found = device.wait(Until.findObject(By.descStartsWith("SIMULATED-SEL-$number.R3D")), 10_000)
        if (found == null) nativeDiagnostic("missing-row-$number", includeFavorites = true)
        return requireNotNull(found)
    }

    private fun selectedCount(count: Int) {
        assertNotNull(device.wait(Until.findObject(By.text("$count selected")), 5_000))
    }

    private fun visibleRows(): List<String> {
        // The native frame clock can retire a row while automation reads it.
        // Requery the complete current provider snapshot, never keep old nodes.
        repeat(20) {
            freshAccessibility()
            try {
                val rows = device.findObjects(By.descStartsWith("SIMULATED-SEL-"))
                    .filter { !it.visibleBounds.isEmpty }
                    .map { it.contentDescription.substringBefore(",") }.distinct().sorted()
                if (rows.isNotEmpty()) return rows
            } catch (_: StaleObjectException) {
                // The next attempt measures the newly mounted native rows.
            }
            SystemClock.sleep(20)
        }
        error("Actual mounted catalog rows did not produce a current native snapshot")
    }

    private data class NativeRowsSnapshot(val visible: List<String>, val selected: Set<String>)

    private fun nativeVisibleRows(viewport: Rect): List<String> = nativeRowsSnapshot(viewport).visible

    private fun nativeRowsSnapshot(viewport: Rect): NativeRowsSnapshot {
        // A live list retires UiObject2 IDs during every property refresh. Read
        // one current public native tree without refreshing each row again.
        val started = SystemClock.uptimeMillis()
        freshAccessibility()
        val fetchStarted = SystemClock.uptimeMillis()
        val root = requireNotNull(instrumentation.uiAutomation.rootInActiveWindow)
        val fetched = SystemClock.uptimeMillis()
        assertEquals(context.packageName, root.packageName?.toString())
        val rows = linkedSetOf<String>()
        val selected = linkedSetOf<String>()
        val rowBounds = JSONArray()
        fun visit(node: AccessibilityNodeInfo) {
            val description = node.contentDescription?.toString()
            if (description?.startsWith("SIMULATED-SEL-") == true && node.isVisibleToUser) {
                val bounds = Rect().also(node::getBoundsInScreen)
                if (bounds.intersect(viewport) && !bounds.isEmpty) {
                    val name = description.substringBefore(",")
                    rows += name
                    if (description.endsWith(", selected")) selected += name
                    rowBounds.put(JSONObject().put("name", name).put("visibleBounds", bounds.toShortString()))
                }
            }
            for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
        }
        visit(root)
        val elapsed = SystemClock.uptimeMillis() - started
        println("SIMULATED_SELECTION_SNAPSHOT=" + JSONObject()
            .put("elapsedMs", elapsed).put("clearMs", fetchStarted - started)
            .put("rootFetchMs", fetched - fetchStarted)
            .put("treeWalkMs", SystemClock.uptimeMillis() - fetched)
            .put("rows", JSONArray(rows.sorted())).put("selected", JSONArray(selected.sorted()))
            .put("visibleRowBounds", rowBounds))
        assertTrue("A live catalog snapshot must finish within one stationary measurement interval",
            elapsed < stationaryIntervalMs)
        assertTrue("Current native catalog snapshot must contain visible rows", rows.isNotEmpty())
        return NativeRowsSnapshot(rows.sorted(), selected)
    }

    private fun freshAccessibility() {
        // The provider replaces native node IDs when the selecting interaction mounts.
        // Retire the automation snapshot, then measure the current rendered provider.
        if (Build.VERSION.SDK_INT >= 33) instrumentation.uiAutomation.clearCache()
    }

    private fun catalogViewport(): Rect {
        freshAccessibility()
        val first = row("01")
        val rowHeight = first.visibleBounds.height()
        var parent = first.parent
        while (parent != null) {
            val rows = parent.findObjects(By.descStartsWith("SIMULATED-SEL-"))
                .map { it.contentDescription.substringBefore(",") }.distinct()
            val bounds = parent.visibleBounds
            if (rows.size >= 3 && bounds.height() > rowHeight * 2) return Rect(bounds)
            parent = parent.parent
        }
        nativeDiagnostic("missing-viewport", includeFavorites = true)
        error("Actual native catalog owner with mounted fixture rows was not found")
    }

    private fun stableRowBounds(number: String): Rect {
        var last: Rect? = null
        var stable = 0
        repeat(20) {
            SystemClock.sleep(80)
            try {
                val current = Rect(row(number).visibleBounds)
                stable = if (last == current && !current.isEmpty) stable + 1 else 0
                if (stable >= 2) return current
                last = current
            } catch (_: StaleObjectException) {
                last = null
                stable = 0
            }
        }
        error("Native target never settled")
    }

    private fun center(bounds: Rect) = Point(bounds.centerX(), bounds.centerY())
    private fun tap(point: Point) = hold(point, 40)
    private fun hold(point: Point, duration: Long) {
        val down = SystemClock.uptimeMillis()
        inject(MotionEvent.ACTION_DOWN, point, down)
        try { SystemClock.sleep(duration) } finally { inject(MotionEvent.ACTION_UP, point, down) }
    }

    private fun swipe(from: Point, to: Point, duration: Long) {
        val down = SystemClock.uptimeMillis()
        inject(MotionEvent.ACTION_DOWN, from, down)
        try { move(from, to, down, duration); SystemClock.sleep(100) }
        finally { inject(MotionEvent.ACTION_UP, to, down) }
        device.waitForIdle()
    }

    private fun move(from: Point, to: Point, down: Long, duration: Long) {
        val steps = 20
        for (step in 1..steps) {
            SystemClock.sleep(duration / steps)
            inject(MotionEvent.ACTION_MOVE, Point(
                from.x + (to.x - from.x) * step / steps,
                from.y + (to.y - from.y) * step / steps), down)
        }
    }

    private fun inject(action: Int, point: Point, down: Long) {
        val requested = SystemClock.uptimeMillis()
        val event = MotionEvent.obtain(down, SystemClock.uptimeMillis(), action,
            point.x.toFloat(), point.y.toFloat(), 0).apply { source = InputDevice.SOURCE_TOUCHSCREEN }
        try { check(instrumentation.uiAutomation.injectInputEvent(event, true)) }
        finally {
            pointerTrace?.put(JSONObject().put("action", action).put("eventMs", event.eventTime)
                .put("x", point.x).put("y", point.y)
                .put("requestedMs", requested).put("returnedMs", SystemClock.uptimeMillis()))
            event.recycle()
        }
    }

    private fun traceMatrixFinalTap(name: String, number: String) {
        val bounds = stableRowBounds(number)
        val point = center(bounds)
        val previousTrace = pointerTrace
        pointerTrace = JSONArray()
        try { tap(point) } finally {
            println("SIMULATED_SELECTION_FINAL_TAP=" + JSONObject()
                .put("name", name).put("row", number).put("bounds", bounds.toShortString())
                .put("x", point.x).put("y", point.y).put("events", pointerTrace))
            pointerTrace = previousTrace
        }
    }

    private fun matrixSelected(name: String, expected: Set<String>): JSONObject {
        val started = SystemClock.uptimeMillis()
        val deadline = started + 5_000
        var last: JSONObject? = null
        val matched = device.wait(object : Condition<UiDevice, JSONObject> {
            override fun apply(device: UiDevice): JSONObject? {
                if (SystemClock.uptimeMillis() >= deadline) return null
                val current = readMatrixSelectionSnapshot()
                last = current
                if (SystemClock.uptimeMillis() >= deadline || current.optString("status") != "available") {
                    return null
                }
                val selected = current.getJSONArray("selected")
                val selectedNames = (0 until selected.length()).map { selected.getString(it) }.toSet()
                return current.takeIf {
                    it.getString("header") == "${expected.size} selected" && selectedNames == expected
                }
            }
        }, 5_000)
        if (matched == null) {
            println("SIMULATED_SELECTION_CURRENT_FAILURE=" + JSONObject()
                .put("name", name).put("expected", JSONArray(expected.sorted()))
                .put("startedMs", started).put("deadlineMs", deadline).put("last", last ?: JSONObject.NULL))
            nativeDiagnostic("$name-current-selection-not-mounted", includeFavorites = true)
        }
        assertNotNull(matched)
        matched?.let { receipt ->
            val observed = receipt.getJSONArray("rowsObserved")
            val selectedRows = JSONArray()
            for (index in 0 until observed.length()) {
                val row = observed.getJSONObject(index)
                if (row.getString("description").substringBefore(",") in expected) selectedRows.put(row)
            }
            println("SIMULATED_SELECTION_CURRENT_MATCH=" + JSONObject()
                .put("name", name).put("startedMs", started).put("deadlineMs", deadline)
                .put("matchedMs", receipt.getLong("returnedMs"))
                .put("header", receipt.getString("header")).put("selected", receipt.getJSONArray("selected"))
                .put("selectedRows", selectedRows).put("package", receipt.getString("package"))
                .put("windowID", receipt.getInt("windowID")).put("matchingWindows", receipt.getJSONArray("matchingWindows"))
                .put("rootFetchRequestedMs", receipt.getLong("rootFetchRequestedMs"))
                .put("rootFetchedMs", receipt.getLong("rootFetchedMs")).put("readMs", receipt.getLong("elapsedMs")))
        }
        return requireNotNull(matched).put("deadlineMs", deadline)
    }

    private fun traceMatrixSelection(name: String, renderedWindowMatch: JSONObject? = null) {
        val directory = context.cacheDir.resolve("SIMULATED-selection-native").apply { mkdirs() }
        val requested = SystemClock.uptimeMillis()
        val captured = device.takeScreenshot(directory.resolve("$name.png"))
        val returned = SystemClock.uptimeMillis()
        println("SIMULATED_SELECTION_CURRENT_IMAGE=" + JSONObject()
            .put("name", name).put("requestedMs", requested)
            .put("returnedMs", returned).put("captured", captured))
        if (renderedWindowMatch != null) captureRenderedWindow(name, renderedWindowMatch)
    }

    private fun captureRenderedWindow(name: String, match: JSONObject) {
        val deadline = match.getLong("deadlineMs")
        val expectedWindowID = match.getInt("windowID")
        val retired = AtomicBoolean(false)
        val completion = CountDownLatch(1)
        val result = AtomicReference<JSONObject>()
        val completedBitmap = AtomicReference<Bitmap>()
        val handler = Handler(Looper.getMainLooper())
        fun complete(receipt: JSONObject, bitmap: Bitmap? = null) {
            result.set(receipt)
            // Only a completed copy transfers ownership. Retired callbacks never write files.
            if (bitmap != null) {
                if (retired.get()) bitmap.recycle() else {
                    completedBitmap.set(bitmap)
                    if (retired.get()) completedBitmap.getAndSet(null)?.recycle()
                }
            }
            completion.countDown()
        }
        fun unavailable(reason: String) {
            complete(JSONObject().put("status", "unavailable").put("reason", reason))
        }
        val posted = handler.post {
            if (retired.get() || SystemClock.uptimeMillis() >= deadline) {
                unavailable("deadline-before-window-read")
            } else {
                try {
                    requireNotNull(scenario).onActivity { activity ->
                        val window = activity.window
                        val decor = window.peekDecorView()
                        val component = activity.componentName
                        val token = decor?.windowToken
                        val node = decor?.createAccessibilityNodeInfo()
                        val windowID = node?.windowId
                        val nodePackage = node?.packageName?.toString()
                        val location = IntArray(2)
                        val inWindow = IntArray(2)
                        decor?.getLocationOnScreen(location)
                        decor?.getLocationInWindow(inWindow)
                        val width = decor?.width
                        val height = decor?.height
                        val source = if (width != null && height != null) {
                            Rect(inWindow[0], inWindow[1], inWindow[0] + width, inWindow[1] + height)
                        } else null
                        val screen = if (width != null && height != null) {
                            Rect(location[0], location[1], location[0] + width, location[1] + height)
                        } else null
                        val facts = JSONObject().put("component", component.flattenToString())
                            .put("windowID", windowID ?: JSONObject.NULL)
                            .put("nodePackage", nodePackage ?: JSONObject.NULL)
                            .put("windowTokenIdentity", token?.let(System::identityHashCode) ?: JSONObject.NULL)
                            .put("attached", decor?.isAttachedToWindow ?: JSONObject.NULL)
                            .put("focused", decor?.hasWindowFocus() ?: JSONObject.NULL)
                            .put("hardware", decor?.isHardwareAccelerated ?: JSONObject.NULL)
                            .put("screenBounds", screen?.toShortString() ?: JSONObject.NULL)
                            .put("sourceBounds", source?.toShortString() ?: JSONObject.NULL)
                            .put("bitmapWidth", width ?: JSONObject.NULL).put("bitmapHeight", height ?: JSONObject.NULL)
                            .put("windowReadMs", SystemClock.uptimeMillis())
                        if (decor == null || token == null || windowID != expectedWindowID || nodePackage != context.packageName ||
                            component.packageName != context.packageName || component.className != MainActivity::class.java.name ||
                            activity.isDestroyed || activity.isFinishing || !decor.isAttachedToWindow ||
                            !decor.hasWindowFocus() || !decor.isHardwareAccelerated || width == null || height == null ||
                            width <= 0 || height <= 0 || source == null ||
                            retired.get() || SystemClock.uptimeMillis() >= deadline) {
                            complete(facts.put("status", "unavailable").put("reason", "unknown-or-changed-window-identity"))
                        } else {
                            val bitmap = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888)
                            val requested = SystemClock.uptimeMillis()
                            if (retired.get() || requested >= deadline) {
                                bitmap.recycle()
                                complete(facts.put("status", "unavailable").put("reason", "deadline-before-copy-request"))
                            } else try {
                                PixelCopy.request(window, source, bitmap, { status ->
                                    val returned = SystemClock.uptimeMillis()
                                    facts.put("requestedMs", requested).put("callbackMs", returned).put("copyStatus", status)
                                    try {
                                        val currentNode = decor.createAccessibilityNodeInfo()
                                        val currentLocation = IntArray(2).also(decor::getLocationOnScreen)
                                        val currentInWindow = IntArray(2).also(decor::getLocationInWindow)
                                        val sameWindow = activity.window === window && window.peekDecorView() === decor &&
                                            decor.windowToken === token && currentNode.windowId == expectedWindowID &&
                                            currentNode.packageName?.toString() == context.packageName && activity.componentName == component &&
                                            !activity.isDestroyed && !activity.isFinishing && decor.isAttachedToWindow &&
                                            decor.hasWindowFocus() && decor.isHardwareAccelerated
                                        val sameGeometry = decor.width == width && decor.height == height &&
                                            currentLocation.contentEquals(location) && currentInWindow.contentEquals(inWindow)
                                        val checked = SystemClock.uptimeMillis()
                                        facts.put("identityUnchanged", sameWindow).put("geometryUnchanged", sameGeometry)
                                            .put("callbackCheckedMs", checked)
                                            .put("callbackScreenBounds", Rect(currentLocation[0], currentLocation[1],
                                                currentLocation[0] + decor.width, currentLocation[1] + decor.height).toShortString())
                                            .put("callbackSourceBounds", Rect(currentInWindow[0], currentInWindow[1],
                                                currentInWindow[0] + decor.width, currentInWindow[1] + decor.height).toShortString())
                                            .put("status", if (status == PixelCopy.SUCCESS && sameWindow && sameGeometry && checked < deadline) "available" else "unavailable")
                                    } catch (error: RuntimeException) {
                                        facts.put("status", "unavailable").put("reason", "callback-window-read-" + error.javaClass.simpleName)
                                    } finally {
                                        complete(facts, bitmap)
                                    }
                                }, handler)
                            } catch (error: IllegalArgumentException) {
                                bitmap.recycle()
                                complete(facts.put("status", "unavailable").put("reason", "copy-source-unavailable")
                                    .put("exception", error.javaClass.simpleName))
                            } catch (error: RuntimeException) {
                                // An unexpected request error cannot prove that a copy is no longer in flight.
                                complete(facts.put("status", "unavailable").put("reason", "copy-request-" + error.javaClass.simpleName))
                            }
                        }
                    }
                } catch (error: RuntimeException) {
                    unavailable("window-read-" + error.javaClass.simpleName)
                }
            }
        }
        if (!posted) unavailable("main-handler-unavailable")
        var interrupted = false
        val finished = try {
            completion.await((deadline - SystemClock.uptimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
        } catch (error: InterruptedException) {
            interrupted = true
            Thread.currentThread().interrupt()
            false
        } finally {
            retired.set(true)
        }
        val bitmap = completedBitmap.getAndSet(null)
        val receipt = result.get()?.let { JSONObject(it.toString()) }
            ?: JSONObject().put("status", "unavailable").put("reason", "copy-did-not-complete-before-deadline")
        receipt.put("name", name).put("deadlineMs", deadline).put("completedWithinWait", finished)
        if (!finished) receipt.put("status", "unavailable")
        if (interrupted) receipt.put("reason", "copy-wait-interrupted")
        val current = if (!interrupted && SystemClock.uptimeMillis() < deadline) {
            readMatrixSelectionSnapshot().also {
                if (it.getLong("returnedMs") >= deadline) it.put("status", "unavailable").put("reason", "after-copy-native-read-deadline")
            }
        } else JSONObject().put("status", "unavailable").put("reason", "after-copy-native-read-deadline")
        current.put("name", name).put("deadlineMs", deadline)
        println("SIMULATED_SELECTION_AFTER_COPY_NATIVE=" + current)
        try {
            if (receipt.optString("status") == "available" && bitmap != null) {
                val target = context.cacheDir.resolve("SIMULATED-selection-native/$name-rendered-window.png")
                receipt.put("pngWriteRequestedMs", SystemClock.uptimeMillis())
                target.outputStream().use { stream ->
                    val written = bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
                    receipt.put("pngWritten", written)
                    if (!written) receipt.put("status", "unavailable").put("reason", "png-write-failed")
                }
                receipt.put("pngWriteReturnedMs", SystemClock.uptimeMillis())
            }
        } catch (error: Exception) {
            receipt.put("status", "unavailable").put("reason", "png-write-" + error.javaClass.simpleName)
        } finally {
            bitmap?.recycle()
        }
        println("SIMULATED_SELECTION_RENDERED_WINDOW=" + receipt)
    }

    private fun readMatrixSelectionSnapshot(): JSONObject {
        val started = SystemClock.uptimeMillis()
        val receipt = JSONObject()
            .put("requestedMs", started).put("status", "unavailable")
            .put("header", JSONObject.NULL).put("selected", JSONObject.NULL)
        try {
            freshAccessibility()
            val fetchStarted = SystemClock.uptimeMillis()
            val root = instrumentation.uiAutomation.rootInActiveWindow
            val fetched = SystemClock.uptimeMillis()
            receipt.put("rootFetchRequestedMs", fetchStarted).put("rootFetchedMs", fetched)
            if (root == null) {
                receipt.put("reason", "missing-current-root")
            } else {
                val packageName = root.packageName?.toString()
                val windowID = root.windowId
                val windows = instrumentation.uiAutomation.windows.filter { it.id == windowID }
                receipt.put("package", packageName ?: JSONObject.NULL).put("windowID", windowID)
                    .put("matchingWindows", JSONArray(windows.map { window ->
                        val bounds = Rect().also(window::getBoundsInScreen)
                        JSONObject().put("id", window.id).put("type", window.type)
                            .put("layer", window.layer).put("bounds", bounds.toShortString())
                    }))
                val headers = JSONArray()
                val rows = JSONArray()
                val selected = linkedSetOf<String>()
                var missingChildren = 0
                var unknownSelectionLabels = 0
                fun visit(node: AccessibilityNodeInfo) {
                    val bounds = Rect().also(node::getBoundsInScreen)
                    if (node.isVisibleToUser && !bounds.isEmpty) {
                        val text = node.text?.toString()
                        if (text?.matches(Regex("[0-9]+ selected")) == true) {
                            headers.put(JSONObject().put("text", text).put("bounds", bounds.toShortString()))
                        }
                        val description = node.contentDescription?.toString()
                        if (description?.startsWith("SIMULATED-SEL-") == true) {
                            val isSelected = when {
                                description.endsWith(", selected") -> true
                                description.endsWith(", not selected") -> false
                                else -> null
                            }
                            val rowName = description.substringBefore(",")
                            if (isSelected == true) selected += rowName
                            if (isSelected == null) unknownSelectionLabels += 1
                            rows.put(JSONObject().put("description", description)
                                .put("bounds", bounds.toShortString())
                                .put("selected", isSelected ?: JSONObject.NULL))
                        }
                    }
                    for (index in 0 until node.childCount) {
                        val child = node.getChild(index)
                        if (child == null) missingChildren += 1 else visit(child)
                    }
                }
                visit(root)
                receipt.put("headersObserved", headers).put("rowsObserved", rows)
                    .put("selectedObserved", JSONArray(selected.sorted()))
                    .put("missingChildren", missingChildren).put("unknownSelectionLabels", unknownSelectionLabels)
                val available = packageName == context.packageName && windows.size == 1 &&
                    windows.single().type == AccessibilityWindowInfo.TYPE_APPLICATION &&
                    headers.length() == 1 && rows.length() > 0 && missingChildren == 0 && unknownSelectionLabels == 0
                if (available) {
                    receipt.put("status", "available").put("header", headers.getJSONObject(0).getString("text"))
                        .put("selected", JSONArray(selected.sorted()))
                } else {
                    receipt.put("reason", "missing-stale-or-ambiguous-current-metadata")
                }
            }
        } catch (error: RuntimeException) {
            receipt.put("reason", "native-read-unavailable").put("exception", error.javaClass.simpleName)
        }
        val returned = SystemClock.uptimeMillis()
        return receipt.put("returnedMs", returned).put("elapsedMs", returned - started)
    }

    @Test
    fun actualCommonCardFavoriteFloorAcceptsNativeEdgeInput() {
        val density = context.resources.displayMetrics.density
        val floor = (44f * density + 0.5f).toInt()
        val inset = (5f * density + 0.5f).toInt()
        val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        val favoriteID = index.persistedClips(bucket).single {
            it.filename == "SIMULATED-SEL-01.R3D"
        }.libraryKey(bucket)
        assertEquals(emptySet<String>(), index.favoriteIDs(bucket))

        var inputOwner: Pair<Rect, Rect>? = null
        var inputWindowID: Int? = null

        fun edgeTap(description: String, layout: String) {
            val deadline = SystemClock.uptimeMillis() + 5_000
            var previous: Pair<Rect, Rect>? = null
            var stable = 0
            while (SystemClock.uptimeMillis() < deadline) {
                freshAccessibility()
                val root = instrumentation.uiAutomation.rootInActiveWindow
                val matches = mutableListOf<Pair<Rect, Rect>>()
                fun visit(node: AccessibilityNodeInfo) {
                    if (node.isVisibleToUser && node.isEnabled &&
                        node.packageName?.toString() == context.packageName &&
                        node.contentDescription?.toString() == description) {
                        val owner = node.parent
                        if (owner != null && owner.isVisibleToUser && owner.isEnabled && owner.isClickable &&
                            owner.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK } &&
                            owner.packageName?.toString() == context.packageName &&
                            owner.windowId == node.windowId && owner.windowId == root?.windowId) {
                            var labels = 0
                            fun countLabels(child: AccessibilityNodeInfo) {
                                if (child.contentDescription?.toString() == description) labels++
                                for (index in 0 until child.childCount) child.getChild(index)?.let(::countLabels)
                            }
                            countLabels(owner)
                            val ownerBounds = Rect().also(owner::getBoundsInScreen)
                            val glyphBounds = Rect().also(node::getBoundsInScreen)
                            if (labels == 1 && ownerBounds.contains(glyphBounds)) {
                                matches += ownerBounds to glyphBounds
                            }
                        }
                    }
                    for (childIndex in 0 until node.childCount) {
                        node.getChild(childIndex)?.let(::visit)
                    }
                }
                root?.let(::visit)
                val windows = instrumentation.uiAutomation.windows
                val appWindow = root?.let { current ->
                    windows.singleOrNull { it.id == current.windowId &&
                        it.type == AccessibilityWindowInfo.TYPE_APPLICATION }
                }
                val target = matches.singleOrNull()
                val bounds = target?.first
                val glyph = target?.second
                val screen = Rect(0, 0, device.displayWidth, device.displayHeight)
                val point = bounds?.let { Point(it.left + inset, it.centerY()) }
                val blocked = if (appWindow != null && point != null) windows.any {
                    it.type == AccessibilityWindowInfo.TYPE_SYSTEM && it.layer > appWindow.layer &&
                        Region().also(it::getRegionInScreen).contains(point.x, point.y)
                } else true
                val available = root?.packageName?.toString() == context.packageName &&
                    appWindow != null && bounds != null && glyph != null && point != null &&
                    screen.contains(bounds) && bounds.width() >= floor && bounds.height() >= floor &&
                    bounds.contains(point.x, point.y) && !blocked &&
                    SystemClock.uptimeMillis() < deadline
                if (available) {
                    stable = if (target == previous) stable + 1 else 0
                    previous = Rect(requireNotNull(bounds)) to Rect(requireNotNull(glyph))
                    if (stable >= 2) {
                        val ownerBounds = requireNotNull(bounds)
                        val glyphBounds = requireNotNull(glyph)
                        val input = requireNotNull(point)
                        val sourceFloor = Rect(ownerBounds.centerX() - floor / 2, ownerBounds.centerY() - floor / 2,
                            ownerBounds.centerX() - floor / 2 + floor, ownerBounds.centerY() - floor / 2 + floor)
                        assertTrue("Edge input must lie inside the centered44dp source floor", sourceFloor.contains(input.x, input.y))
                        assertTrue("Edge input must lie outside the actual drawn glyph bounds", !glyphBounds.contains(input.x, input.y))
                        inputOwner = Rect(ownerBounds) to Rect(glyphBounds)
                        inputWindowID = requireNotNull(appWindow).id
                        val previousTrace = pointerTrace
                        pointerTrace = JSONArray()
                        try { tap(input) } finally {
                            println("SIMULATED_MEDIA_CELL_FLOOR=" + JSONObject()
                                .put("layout", layout).put("description", description)
                                .put("bounds", ownerBounds.toShortString()).put("glyphBounds", glyphBounds.toShortString())
                                .put("sourceFloorBounds", sourceFloor.toShortString()).put("density", density)
                                .put("floorPixels", floor).put("x", input.x).put("y", input.y)
                                .put("sourceGlyphWidthDp", 13).put("windowID", requireNotNull(appWindow).id)
                                .put("layer", appWindow.layer).put("rotation", device.displayRotation)
                                .put("displayWidth", device.displayWidth).put("displayHeight", device.displayHeight)
                                .put("events", pointerTrace))
                            pointerTrace = previousTrace
                        }
                        return
                    }
                } else {
                    previous = null
                    stable = 0
                }
                SystemClock.sleep(80)
            }
            nativeDiagnostic("card-floor-unavailable", includeFavorites = true)
            error("Actual current44dp favorite owner is unavailable: $description")
        }

        fun observeListFrame(name: String, description: String, deadline: Long) {
            val observation = JSONObject().put("name", name).put("deadlineMs", deadline)
                .put("status", "unavailable")
            fun currentOwner(): JSONObject {
                val started = SystemClock.uptimeMillis()
                val value = JSONObject().put("requestedMs", started).put("status", "unavailable")
                if (started >= deadline) return value.put("returnedMs", started).put("reason", "deadline-before-native-read")
                try {
                    freshAccessibility()
                    val root = instrumentation.uiAutomation.rootInActiveWindow
                    val matches = mutableListOf<Pair<Rect, Rect>>()
                    fun visit(node: AccessibilityNodeInfo) {
                        if (node.isVisibleToUser && node.isEnabled &&
                            node.packageName?.toString() == context.packageName &&
                            node.contentDescription?.toString() == description) {
                            val owner = node.parent
                            if (owner != null && owner.isVisibleToUser && owner.isEnabled && owner.isClickable &&
                                owner.actionList.any { it.id == AccessibilityNodeInfo.ACTION_CLICK } &&
                                owner.packageName?.toString() == context.packageName &&
                                owner.windowId == node.windowId && owner.windowId == root?.windowId) {
                                val bounds = Rect().also(owner::getBoundsInScreen)
                                val glyph = Rect().also(node::getBoundsInScreen)
                                if (bounds.contains(glyph)) matches += bounds to glyph
                            }
                        }
                        for (index in 0 until node.childCount) node.getChild(index)?.let(::visit)
                    }
                    root?.let(::visit)
                    val window = root?.let { current -> instrumentation.uiAutomation.windows.singleOrNull {
                        it.id == current.windowId && it.type == AccessibilityWindowInfo.TYPE_APPLICATION
                    } }
                    val owner = matches.singleOrNull()
                    val screen = Rect(0, 0, device.displayWidth, device.displayHeight)
                    if (root?.packageName?.toString() == context.packageName && window != null &&
                        window.id == inputWindowID && owner != null && owner == inputOwner &&
                        screen.contains(owner.first) && device.displayRotation == 1 &&
                        device.displayWidth > device.displayHeight && SystemClock.uptimeMillis() < deadline) {
                        value.put("status", "available").put("windowID", window.id).put("layer", window.layer)
                            .put("package", context.packageName).put("description", description)
                            .put("ownerBounds", owner.first.toShortString()).put("glyphBounds", owner.second.toShortString())
                            .put("rotation", device.displayRotation).put("displayWidth", device.displayWidth)
                            .put("displayHeight", device.displayHeight)
                    }
                } catch (error: RuntimeException) {
                    value.put("reason", error.javaClass.simpleName)
                }
                val returned = SystemClock.uptimeMillis()
                if (returned >= deadline) value.put("status", "unavailable").put("reason", "native-read-deadline")
                return value.put("returnedMs", returned)
            }
            var known: JSONObject? = null
            var previous: String? = null
            var stable = 0
            while (SystemClock.uptimeMillis() < deadline) {
                val current = currentOwner()
                val key = if (current.optString("status") == "available") {
                    listOf(current.getInt("windowID"), current.getInt("rotation"), current.getInt("displayWidth"),
                        current.getInt("displayHeight"), current.getString("ownerBounds"), current.getString("glyphBounds")).toString()
                } else null
                stable = if (key != null && key == previous) stable + 1 else 0
                previous = key
                if (stable >= 2) { known = current; break }
                SystemClock.sleep(80)
            }
            observation.put("stableNative", known ?: JSONObject.NULL)
            if (known == null) {
                println("SIMULATED_MEDIA_CELL_FRAME=" + observation.put("reason", "current-owner-or-orientation-unavailable"))
                return
            }
            val stableNative = requireNotNull(known)
            val expectedWindowID = stableNative.getInt("windowID")
            val retired = AtomicBoolean(false)
            val completion = CountDownLatch(1)
            val frame = AtomicReference<JSONObject>()
            val cancel = AtomicReference<(() -> Unit)?>(null)
            val handler = Handler(Looper.getMainLooper())
            handler.post {
                if (!retired.get() && SystemClock.uptimeMillis() < deadline) try {
                    requireNotNull(scenario).onActivity { activity ->
                        val window = activity.window
                        val decor = window.peekDecorView()
                        val token = decor?.windowToken
                        val node = decor?.createAccessibilityNodeInfo()
                        val observer = decor?.viewTreeObserver
                        val location = decor?.let { IntArray(2).also(it::getLocationOnScreen) }
                        if (decor == null || token == null || node?.windowId != expectedWindowID ||
                            node.packageName?.toString() != context.packageName ||
                            activity.componentName.className != MainActivity::class.java.name ||
                            activity.componentName.packageName != context.packageName || activity.isDestroyed ||
                            activity.isFinishing || !decor.isAttachedToWindow || !decor.hasWindowFocus() ||
                            !decor.isHardwareAccelerated || observer == null || !observer.isAlive ||
                            decor.width != stableNative.getInt("displayWidth") || decor.height != stableNative.getInt("displayHeight")) {
                            frame.set(JSONObject().put("status", "unavailable").put("reason", "exact-decor-unavailable"))
                            completion.countDown()
                        } else {
                            val width = decor.width
                            val height = decor.height
                            val registered = SystemClock.uptimeMillis()
                            val callback = Runnable {
                                val committed = SystemClock.uptimeMillis()
                                handler.post {
                                    if (!retired.get()) try {
                                        val currentNode = decor.createAccessibilityNodeInfo()
                                        val same = activity.window === window && window.peekDecorView() === decor &&
                                            decor.windowToken === token && currentNode.windowId == expectedWindowID &&
                                            currentNode.packageName?.toString() == context.packageName &&
                                            !activity.isDestroyed && !activity.isFinishing && decor.isAttachedToWindow &&
                                            decor.hasWindowFocus() && decor.isHardwareAccelerated &&
                                            decor.width == width && decor.height == height &&
                                            IntArray(2).also(decor::getLocationOnScreen).contentEquals(location)
                                        frame.set(JSONObject().put("status", if (same && SystemClock.uptimeMillis() < deadline) "available" else "unavailable")
                                            .put("registeredMs", registered).put("commitCallbackMs", committed)
                                            .put("checkedMs", SystemClock.uptimeMillis()).put("identityGeometryUnchanged", same)
                                            .put("windowID", expectedWindowID).put("token", System.identityHashCode(token))
                                            .put("hardware", true).put("submittedFrameOnly", true))
                                        completion.countDown()
                                    } catch (error: RuntimeException) {
                                        frame.set(JSONObject().put("status", "unavailable").put("reason", "callback-" + error.javaClass.simpleName))
                                        completion.countDown()
                                    }
                                }
                            }
                            cancel.set { if (observer.isAlive) observer.unregisterFrameCommitCallback(callback) }
                            if (!retired.get() && registered < deadline) observer.registerFrameCommitCallback(callback)
                        }
                    }
                } catch (error: RuntimeException) {
                    frame.set(JSONObject().put("status", "unavailable").put("reason", error.javaClass.simpleName))
                    completion.countDown()
                }
            }
            val completed = try {
                completion.await((deadline - SystemClock.uptimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
            } finally {
                retired.set(true)
                handler.post { cancel.getAndSet(null)?.invoke() }
            }
            val submitted = frame.get() ?: JSONObject().put("status", "unavailable").put("reason", "no-passive-frame-before-deadline")
            observation.put("frame", submitted).put("completedWithinWait", completed)
            val current = currentOwner()
            observation.put("afterCommitNative", current)
            if (completed && submitted.optString("status") == "available" && current.optString("status") == "available" &&
                SystemClock.uptimeMillis() < deadline) {
                captureRenderedWindow(name, JSONObject().put("windowID", expectedWindowID).put("deadlineMs", deadline))
                if (SystemClock.uptimeMillis() < deadline) {
                    val directory = context.cacheDir.resolve("SIMULATED-selection-native").apply { mkdirs() }
                    val requested = SystemClock.uptimeMillis()
                    val captured = device.takeScreenshot(directory.resolve("$name-after-frame-physical.png"))
                    val returned = SystemClock.uptimeMillis()
                    observation.put("physicalRequestedMs", requested).put("physicalReturnedMs", returned)
                        .put("physicalCaptured", captured).put("physicalWithinDeadline", returned < deadline)
                }
                observation.put("afterCopyNative", currentOwner()).put("status", "observed-submitted-frame")
            }
            println("SIMULATED_MEDIA_CELL_FRAME=" + observation)
        }

        device.setOrientationLeft()
        for ((layout, grid) in listOf("grid" to true, "list" to false)) {
            pressControl(if (grid) "Grid view" else "List view")
            val first = stableRowBounds("01")
            val second = stableRowBounds("02")
            assertEquals("Actual row geometry must match the requested layout", grid,
                first.centerX() != second.centerX())
            assertTrue("Floor proof starts in actual landscape", device.displayWidth > device.displayHeight)
            trace("card-floor-$layout-landscape-before")
            edgeTap("Add SIMULATED-SEL-01.R3D to favorites", layout)
            val favoriteDeadline = SystemClock.uptimeMillis() + 5_000
            assertNotNull(waitForCurrentFavoriteControl("Remove SIMULATED-SEL-01.R3D from favorites"))
            assertEquals(setOf(favoriteID), index.favoriteIDs(bucket))
            trace("card-floor-$layout-landscape-favorite")
            if (!grid) observeListFrame("card-floor-list-post-commit", "Remove SIMULATED-SEL-01.R3D from favorites", favoriteDeadline)
            pressControl("Remove SIMULATED-SEL-01.R3D from favorites")
            assertNotNull(waitForCurrentFavoriteControl("Add SIMULATED-SEL-01.R3D to favorites"))
            assertEquals(emptySet<String>(), index.favoriteIDs(bucket))
        }
        hold(center(stableRowBounds("01")), 650)
        selectedCount(1)
        assertTrue(device.wait(Until.gone(By.desc("Add SIMULATED-SEL-01.R3D to favorites")), 5_000))
        trace("card-floor-list-selecting")
        pressControl("Exit media selection")
        device.setOrientationNatural()
        settleNaturalOrientation()
        trace("card-floor-list-portrait")
    }

    private fun trace(name: String) {
        val directory = context.cacheDir.resolve("SIMULATED-selection-native").apply { mkdirs() }
        device.takeScreenshot(directory.resolve("$name.png"))
        println("SELECTION_NATIVE_TRACE=" + JSONObject().put("name", name)
            .put("uptimeMs", SystemClock.uptimeMillis())
            .put("rotation", device.displayRotation).put("rows", JSONArray(visibleRows())))
    }
}
