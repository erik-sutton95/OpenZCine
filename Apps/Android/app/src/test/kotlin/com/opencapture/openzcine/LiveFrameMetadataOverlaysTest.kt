package com.opencapture.openzcine

import com.opencapture.openzcine.core.LiveCameraLevel
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult
import com.opencapture.openzcine.settings.LocalLevelStyle
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertTrue

class LiveFrameMetadataOverlaysTest {
    @Test
    fun `focus lock label clamps its full width at both visible feed edges`() {
        val feed = LiveOverlayRect(left = -100f, top = 0f, width = 600f, height = 300f)
        val viewport = LiveOverlayRect(left = 0f, top = 0f, width = 400f, height = 300f)

        assertEquals(
            5f,
            focusLockLabelLeft(feed, viewport, preferredLeft = -40f, labelWidth = 96f, inset = 5f),
        )
        val rightEdge =
            focusLockLabelLeft(
                feed,
                viewport,
                preferredLeft = 380f,
                labelWidth = 96f,
                inset = 5f,
            )
        assertEquals(299f, rightEdge)
        assertTrue(rightEdge + 96f <= viewport.right)
    }

    @Test
    fun `landscape gauge seats within the visible feed and above bottom chrome`() {
        val feed = LiveOverlayRect(left = 40f, top = 0f, width = 800f, height = 390f)
        val visible = LiveOverlayRect(left = 0f, top = 0f, width = 874f, height = 402f)

        val seats =
            liveGaugeSeats(
                feed = feed,
                visibleBounds = visible,
                isPortrait = false,
                bottomChromeInset = 0f,
                metrics = gaugeMetrics(),
            )

        assertEquals(440f, seats.roll.x)
        assertEquals(286f, seats.roll.y)
        assertEquals(796f, seats.pitch.x)
        assertEquals(195f, seats.pitch.y)
    }

    @Test
    fun `portrait fill gauge clamps seats to the on screen portion of desqueezed feed`() {
        val feed = LiveOverlayRect(left = 125f, top = 0f, width = 750f, height = 560f)
        val visible = LiveOverlayRect(left = 299f, top = 0f, width = 402f, height = 560f)

        val seats =
            liveGaugeSeats(
                feed = feed,
                visibleBounds = visible,
                isPortrait = true,
                bottomChromeInset = 64f,
                metrics = gaugeMetrics(),
            )

        assertEquals(500f, seats.roll.x)
        assertEquals(466f, seats.roll.y)
        assertEquals(657f, seats.pitch.x)
        assertEquals(280f, seats.pitch.y)
    }

    @Test
    fun `landscape gauge uses the measured capture strip inset when it exceeds default clearance`() {
        val metrics = gaugeMetrics()
        val feed = LiveOverlayRect(left = 0f, top = 0f, width = 1_280f, height = 720f)
        val chromeTop = 586f

        val seats =
            liveGaugeSeats(
                feed = feed,
                visibleBounds = feed,
                isPortrait = false,
                bottomChromeInset = feed.bottom - chromeTop,
                metrics = metrics,
            )

        assertTrue(seats.roll.y + metrics.centerTickHalfLength < chromeTop)
    }

    @Test
    fun `focus coordinates map into exact aspect-fit content rather than monitor zone`() {
        val content = liveFeedContentRect(1_000f, 1_000f, 1_920, 1_080)
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
    fun `vertical desqueeze keeps focus and level geometry centred in the rendered feed`() {
        val content = liveFeedContentRect(1_000f, 1_000f, 1_920, 1_080)
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
                deviceGravity = DeviceGravityLevel(rollDegrees = 12.0, pitchDegrees = 5.0),
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
                deviceGravity = DeviceGravityLevel(rollDegrees = 2.0, pitchDegrees = -1.0),
            )

        assertNotNull(reading)
        assertEquals(LiveLevelSource.DEVICE_GRAVITY, reading.source)
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

    @Test
    fun `low pass accelerometer tilt stays normalized and maps device axes like gravity`() {
        val portraitRest = lowPassDeviceTilt(null, sampleX = 0f, sampleY = -9.81f, sampleZ = 0f)
        val landscapeRest = lowPassDeviceTilt(null, sampleX = -9.81f, sampleY = 0f, sampleZ = 0f)

        assertNotNull(portraitRest)
        assertNotNull(landscapeRest)
        assertEquals(1f, vectorMagnitude(portraitRest), absoluteTolerance = 0.000_001f)
        assertEquals(1f, vectorMagnitude(landscapeRest), absoluteTolerance = 0.000_001f)

        val portrait =
            deviceGravityLevel(
                gravityX = portraitRest.x,
                gravityY = portraitRest.y,
                gravityZ = portraitRest.z,
                isPortrait = true,
                provenance = DeviceTiltProvenance.ACCELEROMETER_LOW_PASS,
            )
        val landscape =
            deviceGravityLevel(
                gravityX = landscapeRest.x,
                gravityY = landscapeRest.y,
                gravityZ = landscapeRest.z,
                isPortrait = false,
                provenance = DeviceTiltProvenance.ACCELEROMETER_LOW_PASS,
            )

        assertNotNull(portrait)
        assertNotNull(landscape)
        assertTrue(kotlin.math.abs(portrait.rollDegrees) < 0.000_001)
        assertTrue(kotlin.math.abs(landscape.rollDegrees) < 0.000_001)

        val smoothed =
            lowPassDeviceTilt(
                previous = portraitRest,
                sampleX = 9.81f,
                sampleY = 0f,
                sampleZ = 0f,
                retention = 0.8f,
            )
        assertNotNull(smoothed)
        assertEquals(1f, vectorMagnitude(smoothed), absoluteTolerance = 0.000_001f)
        assertTrue(smoothed.x > 0f)
        assertTrue(smoothed.y < 0f)

        val fallback = resolveLiveLevel(camera = null, deviceGravity = portrait)
        assertNotNull(fallback)
        assertEquals(DeviceTiltProvenance.ACCELEROMETER_LOW_PASS, fallback.deviceTiltProvenance)
    }

    @Test
    fun `gravity conversion is level at portrait and landscape rest positions`() {
        val portrait = deviceGravityLevel(gravityX = 0f, gravityY = -1f, gravityZ = 0f, isPortrait = true)
        val landscape = deviceGravityLevel(gravityX = -1f, gravityY = 0f, gravityZ = 0f, isPortrait = false)

        assertNotNull(portrait)
        assertNotNull(landscape)
        assertTrue(kotlin.math.abs(portrait.rollDegrees) < 0.000_001)
        assertTrue(kotlin.math.abs(portrait.pitchDegrees) < 0.000_001)
        assertTrue(kotlin.math.abs(landscape.rollDegrees) < 0.000_001)
        assertTrue(kotlin.math.abs(landscape.pitchDegrees) < 0.000_001)
    }

    private fun gaugeMetrics(): LiveGaugeMetrics =
        LiveGaugeMetrics(
            landscapeRollLift = 104f,
            portraitRollLift = 30f,
            trailingInset = 44f,
            chromeClearance = 8f,
            axisSpan = 84f,
            maxAngleDegrees = 8.0,
            tickStepDegrees = 2.0,
            levelThresholdDegrees = 0.6,
            baselineStrokeWidth = 2f,
            centerTickHalfLength = 9f,
            tickHalfLength = 5f,
            tickStrokeWidth = 1f,
            beadRadius = 6.5f,
            beadStrokeWidth = 2f,
            chevronGap = 16f,
            chevronStep = 8f,
            chevronHalfSize = 3f,
            chevronStrokeWidth = 1.5f,
            readoutOffset = 24f,
            verticalReadoutOffset = 42f,
            readoutTextSize = 11f,
        )

    private fun vectorMagnitude(vector: DeviceTiltVector): Float =
        kotlin.math.sqrt(vector.x * vector.x + vector.y * vector.y + vector.z * vector.z)
}
