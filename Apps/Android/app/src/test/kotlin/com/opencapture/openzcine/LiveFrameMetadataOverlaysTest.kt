package com.opencapture.openzcine

import com.opencapture.monitorui.MonitorDeviceTilt
import com.opencapture.monitorui.MonitorLevelGeometry
import com.opencapture.monitorui.MonitorScopeRect
import com.opencapture.monitorui.MonitorTiltSource
import com.opencapture.opencine.nikon.LiveCameraLevel
import com.opencapture.opencine.nikon.LiveFocusBox
import com.opencapture.opencine.nikon.LiveFocusInfo
import com.opencapture.opencine.nikon.LiveFocusResult
import com.opencapture.openzcine.settings.LocalLevelStyle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue
import com.opencapture.opencine.runtime.nativeFeedContentRect

class LiveFrameMetadataOverlaysTest {
    @Test
    fun `nikon AF boxes normalize to the shared focus layer with the result as its colour`() {
        val focus =
            LiveFocusInfo(
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                result = LiveFocusResult.NOT_FOCUSED,
                subjectDetectionActive = false,
                trackingAFActive = false,
                selectedBoxIndex = null,
                boxes = listOf(
                    LiveFocusBox(centerX = 960, centerY = 540, width = 192, height = 108),
                    LiveFocusBox(centerX = 480, centerY = 270, width = 96, height = 54),
                ),
            )

        val areas = assertNotNull(nikonFocusAreas(focus))

        val primary = assertNotNull(areas.primary)
        assertEquals(0.45, primary.x, absoluteTolerance = 0.0001)
        assertEquals(0.45, primary.y, absoluteTolerance = 0.0001)
        assertEquals(0.1, primary.width, absoluteTolerance = 0.0001)
        assertEquals(0.225, areas.others.single().x, absoluteTolerance = 0.0001)
        assertEquals(false, areas.confirmed)
        assertTrue(assertNotNull(nikonFocusAreas(focus.copy(trackingAFActive = true))).confirmed)
        assertTrue(assertNotNull(nikonFocusAreas(focus.copy(result = LiveFocusResult.FOCUSED))).confirmed)
        assertEquals(null, nikonFocusAreas(focus.copy(coordinateWidth = 0)))
    }

    @Test
    fun `landscape gauge sits within the visible feed and above bottom chrome`() {
        val feed = MonitorScopeRect(0f, 0f, 1_280f, 720f)
        val chromeTop = 586f
        val bounds =
            levelGaugeBounds(
                visibleBounds = LiveOverlayRect(left = 0f, top = 0f, width = 1_280f, height = 720f),
                bottomChromeInset = 720f - chromeTop,
                density = 1f,
            )

        val frames = MonitorLevelGeometry.frames(feed, bounds, portrait = false)

        assertEquals(MonitorScopeRect(0f, 0f, 1_280f, chromeTop), bounds)
        assertTrue(frames.roll.maxY < chromeTop)
        assertTrue(frames.tilt.minY >= 0f && frames.tilt.maxY <= chromeTop)
    }

    @Test
    fun `portrait fill gauge stays on the on screen part of the desqueezed feed`() {
        val density = 2f
        val feed = MonitorScopeRect(125f / density, 0f, 750f / density, 560f / density)
        val bounds =
            levelGaugeBounds(
                visibleBounds = LiveOverlayRect(left = 299f, top = 0f, width = 402f, height = 560f),
                bottomChromeInset = 64f,
                density = density,
            )

        val frames = MonitorLevelGeometry.frames(feed, bounds, portrait = true)

        assertEquals(MonitorScopeRect(149.5f, 0f, 201f, 248f), bounds)
        assertTrue(frames.roll.minX >= bounds.minX && frames.roll.maxX <= bounds.maxX)
        assertTrue(frames.roll.maxY <= bounds.maxY)
        assertTrue(frames.tilt.maxX <= bounds.maxX)
    }

    @Test
    fun `gauge bounds never go negative when chrome covers the whole feed`() {
        val bounds =
            levelGaugeBounds(
                visibleBounds = LiveOverlayRect(left = 0f, top = 0f, width = 100f, height = 50f),
                bottomChromeInset = 80f,
                density = 1f,
            )
        assertEquals(0f, bounds.height)
    }

    @Test
    fun `focus coordinates map into exact aspect-fit content rather than monitor zone`() {
        val content = nativeFeedContentRect(1_000f, 1_000f, 1_920, 1_080)
        assertNotNull(content)
        assertEquals(0, content.left)
        assertEquals(219, content.top)
        assertEquals(1_000, content.width)
        assertEquals(563, content.height)

        val feed = liveOverlayFeedRect(content, horizontalPresentationScale = 0.5f)
        assertNotNull(feed)
        assertEquals(250f, feed.left)
        assertEquals(500f, feed.width)

        val focus =
            LiveFocusInfo(
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                result = LiveFocusResult.FOCUSED,
                subjectDetectionActive = false,
                trackingAFActive = false,
                selectedBoxIndex = null,
                boxes = listOf(LiveFocusBox(centerX = 960, centerY = 540, width = 384, height = 216)),
            )
        val rect = liveFocusBoxRect(focus, focus.boxes.single(), feed)

        assertNotNull(rect)
        assertEquals(450f, rect.left)
        assertEquals(444.2f, rect.top, absoluteTolerance = 0.01f)
        assertEquals(100f, rect.width)
        assertEquals(112.6f, rect.height, absoluteTolerance = 0.01f)
    }

    @Test
    fun `mirrored focus boxes fold across the feed the way the picture does`() {
        val content = requireNotNull(nativeFeedContentRect(1_000f, 1_000f, 1_920, 1_080))
        val feed = requireNotNull(liveOverlayFeedRect(content, horizontalPresentationScale = 1f))
        val focus =
            LiveFocusInfo(
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                result = LiveFocusResult.FOCUSED,
                subjectDetectionActive = false,
                trackingAFActive = false,
                selectedBoxIndex = null,
                boxes = listOf(LiveFocusBox(centerX = 480, centerY = 270, width = 384, height = 216)),
            )
        val box = focus.boxes.single()
        val plain = requireNotNull(liveFocusBoxRect(focus, box, feed))
        val mirrored = requireNotNull(liveFocusBoxRect(focus, box, feed, mirrored = true))

        // A box a quarter in from the camera's left lands a quarter in from the operator's right.
        assertEquals(feed.right - plain.right, mirrored.left - feed.left, absoluteTolerance = 0.01f)
        // Size and vertical placement are untouched — the fold is horizontal only.
        assertEquals(plain.width, mirrored.width, absoluteTolerance = 0.01f)
        assertEquals(plain.top, mirrored.top, absoluteTolerance = 0.01f)
        assertEquals(plain.height, mirrored.height, absoluteTolerance = 0.01f)
    }

    @Test
    fun `vertical desqueeze keeps focus and level geometry centred in the rendered feed`() {
        val content = nativeFeedContentRect(1_000f, 1_000f, 1_920, 1_080)
        assertNotNull(content)

        val feed =
            liveOverlayFeedRect(
                content = content,
                horizontalPresentationScale = 1f,
                verticalPresentationScale = 0.5f,
            )

        assertNotNull(feed)
        assertEquals(0f, feed.left)
        assertEquals(359.75f, feed.top)
        assertEquals(1_000f, feed.width)
        assertEquals(281.5f, feed.height)
    }

    @Test
    fun `camera horizon always wins over device gravity fallback`() {
        val reading =
            resolveLiveLevel(
                camera = LiveCameraLevel(rollDegrees = -0.5, pitchDegrees = 1.0, yawDegrees = 0.0),
                deviceGravity = MonitorDeviceTilt(12.0, 5.0, MonitorTiltSource.GRAVITY_SENSOR),
            )

        assertNotNull(reading)
        assertEquals(LiveLevelSource.CAMERA, reading.source)
        assertEquals(-0.5, reading.rollDegrees)
        assertEquals(1.0, reading.pitchDegrees)
    }

    @Test
    fun `gravity is explicitly secondary when camera level is absent`() {
        val reading =
            resolveLiveLevel(
                camera = null,
                deviceGravity = MonitorDeviceTilt(2.0, -1.0, MonitorTiltSource.ACCELEROMETER_LOW_PASS),
            )

        assertNotNull(reading)
        assertEquals(LiveLevelSource.DEVICE_GRAVITY, reading.source)
        assertEquals(MonitorTiltSource.ACCELEROMETER_LOW_PASS, reading.deviceTiltProvenance)
    }

    @Test
    fun `debug level accessibility never claims fixture data is a camera horizon`() {
        val description =
            liveLevelAccessibilityDescription(
                reading =
                    LiveLevelReading(
                        rollDegrees = 0.0,
                        pitchDegrees = 0.0,
                        source = LiveLevelSource.CAMERA,
                        isDebugFixture = true,
                    ),
                style = LocalLevelStyle.HORIZON,
            )

        assertEquals("Debug fixture level, not camera metadata, horizon", description)
    }

    @Test
    fun `debug focus accessibility never claims fixture data is camera focus`() {
        val description =
            LiveFocusInfo(
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                result = LiveFocusResult.FOCUSED,
                subjectDetectionActive = true,
                trackingAFActive = true,
                selectedBoxIndex = 0,
                boxes = listOf(LiveFocusBox(centerX = 960, centerY = 540, width = 200, height = 200)),
                isDebugFixture = true,
            ).accessibilityDescription()

        assertTrue(description.startsWith("Debug focus fixture, not camera focus data."))
    }
}
