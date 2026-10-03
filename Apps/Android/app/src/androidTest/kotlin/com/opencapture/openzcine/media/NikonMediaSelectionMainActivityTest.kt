package com.opencapture.openzcine.media

import android.content.Context
import android.content.Intent
import android.graphics.Point
import android.graphics.Rect
import android.os.Build
import android.os.SystemClock
import android.view.InputDevice
import android.view.MotionEvent
import android.view.accessibility.AccessibilityNodeInfo
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.uiautomator.By
import androidx.test.uiautomator.Configurator
import androidx.test.uiautomator.UiDevice
import androidx.test.uiautomator.UiObject2
import androidx.test.uiautomator.StaleObjectException
import androidx.test.uiautomator.Until
import com.opencapture.openzcine.MainActivity
import com.opencapture.openzcine.pairing.SavedCameraRecord
import com.opencapture.openzcine.pairing.SavedCameraTransport
import com.opencapture.openzcine.pairing.SharedPreferencesSavedCameraStore
import java.nio.file.Files
import java.nio.file.Path
import java.util.Comparator
import org.json.JSONArray
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

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
        device.setOrientationNatural()
        val clips = (1..40).map { number ->
            MediaClipRecord(
                handle = number.toLong(), storageId = 65_537, sizeBytes = 4,
                captureDate = "20261003T10%02d00".format(number), pixelWidth = 1_920, pixelHeight = 1_080,
                filename = "SIMULATED-SEL-%02d.R3D".format(number),
                contentKind = MediaContentKind.R3D_MASTER, stillPhoto = null,
            )
        }
        val index = MediaLibraryIndex(SharedPreferencesMediaLibraryPreferences(context))
        index.rememberCameraListing(bucket, clips)
        index.rememberCameraBucket(record.id, bucket, record.displayTitle)
        index.saveViewOptions(MediaLibraryViewOptions(
            source = MediaLibrarySource.CAMERA, layout = MediaLibraryLayout.LIST,
            sortOrder = MediaLibrarySortOrder.NAME, thumbnailSize = MediaThumbnailSize.SMALL,
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
        requireNotNull(device.wait(Until.findObject(By.desc("Media library")), 15_000)).click()
        row("01")
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

    private fun row(number: String): UiObject2 {
        freshAccessibility()
        return requireNotNull(device.wait(
            Until.findObject(By.descStartsWith("SIMULATED-SEL-$number.R3D")), 10_000))
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

    private fun nativeVisibleRows(viewport: Rect): List<String> {
        // A live list retires UiObject2 IDs during every property refresh. Read
        // one current public native tree without refreshing each row again.
        val started = SystemClock.uptimeMillis()
        freshAccessibility()
        val fetchStarted = SystemClock.uptimeMillis()
        val root = requireNotNull(instrumentation.uiAutomation.rootInActiveWindow)
        val fetched = SystemClock.uptimeMillis()
        assertEquals(context.packageName, root.packageName?.toString())
        val rows = linkedSetOf<String>()
        val rowBounds = JSONArray()
        fun visit(node: AccessibilityNodeInfo) {
            val description = node.contentDescription?.toString()
            if (description?.startsWith("SIMULATED-SEL-") == true && node.isVisibleToUser) {
                val bounds = Rect().also(node::getBoundsInScreen)
                if (bounds.intersect(viewport) && !bounds.isEmpty) {
                    val name = description.substringBefore(",")
                    rows += name
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
            .put("rows", JSONArray(rows.sorted())).put("visibleRowBounds", rowBounds))
        assertTrue("A live catalog snapshot must finish within one stationary measurement interval",
            elapsed < stationaryIntervalMs)
        assertTrue("Current native catalog snapshot must contain visible rows", rows.isNotEmpty())
        return rows.sorted()
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
                .put("requestedMs", requested).put("returnedMs", SystemClock.uptimeMillis()))
            event.recycle()
        }
    }

    private fun trace(name: String) {
        val directory = context.cacheDir.resolve("SIMULATED-selection-native").apply { mkdirs() }
        device.takeScreenshot(directory.resolve("$name.png"))
        println("SELECTION_NATIVE_TRACE=" + JSONObject().put("name", name)
            .put("uptimeMs", SystemClock.uptimeMillis())
            .put("rotation", device.displayRotation).put("rows", JSONArray(visibleRows())))
    }
}
