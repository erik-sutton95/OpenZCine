package com.opencapture.openzcine

import com.opencapture.openzcine.bridge.ZoneFrame
import com.opencapture.openzcine.core.LiveFocusBox
import com.opencapture.openzcine.core.LiveFocusInfo
import com.opencapture.openzcine.core.LiveFocusResult
import com.opencapture.openzcine.settings.MonitorDisplayMode
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertIs
import kotlin.test.assertNull
import kotlin.test.assertTrue

class FocusFeedGesturesTest {
    @Test
    fun `focus reset requires meaningful camera displacement or a tracking latch`() {
        fun focus(
            centerX: Int = 500,
            centerY: Int = 250,
            tracking: Boolean = false,
            debug: Boolean = false,
        ): LiveFocusInfo =
            LiveFocusInfo(
                coordinateWidth = 1_000,
                coordinateHeight = 500,
                result = LiveFocusResult.FOCUSED,
                subjectDetectionActive = tracking,
                trackingAFActive = tracking,
                selectedBoxIndex = if (tracking) 0 else null,
                boxes = listOf(LiveFocusBox(centerX, centerY, 100, 100)),
                isDebugFixture = debug,
            )

        assertEquals(false, focusResetAvailable(focus(), focusPointLocked = false))
        assertEquals(false, focusResetAvailable(focus(centerX = 540), focusPointLocked = false))
        assertTrue(focusResetAvailable(focus(centerX = 541), focusPointLocked = false))
        assertTrue(focusResetAvailable(focus(tracking = true), focusPointLocked = false))
        assertEquals(false, focusResetAvailable(focus(tracking = true), focusPointLocked = true))
        assertEquals(false, focusResetAvailable(focus(debug = true), focusPointLocked = false))
    }

    @Test
    fun `landscape fit maps exact inclusive edges and rejects letterbox input`() {
        val content = liveFeedContentRect(1_000f, 1_000f, 1_920, 1_080)
        requireNotNull(content)
        val geometry =
            focusFeedGeometry(
                content = content,
                horizontalPresentationScale = 1f,
                viewport = LiveOverlayRect(0f, 0f, 1_000f, 1_000f),
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                generation = 1,
            )
        requireNotNull(geometry)

        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(500f, 218f)))
        assertEquals(
            FocusFeedCoordinate(0, 0),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(0f, 219f)),
        )
        assertEquals(
            FocusFeedCoordinate(1_919, 1_079),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(1_000f, 782f)),
        )
        assertEquals(
            FocusFeedCoordinate(960, 540),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(500f, 500.5f)),
        )
        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(500f, 783f)))
    }

    @Test
    fun `photo full-height frame maps corner and band-edge taps in range`() {
        // The photography feed container IS the letterboxed 3:2 image
        // (photographyFeedFrame): container aspect == source aspect, so the
        // content rect fills the box exactly and every corner maps inclusive.
        val container = photographyFeedFrame(
            cinemaFeed = ZoneFrame(59f, 0f, 683f, 384f),
            viewport = ZoneFrame(0f, 0f, 914f, 384f),
            imageArea = "FX",
            leadingLaneTrailing = 136f,
            trailingLaneLeading = 844f,
        )
        val content =
            liveFeedContentRect(container.width, container.height, 5_760, 3_840)
        requireNotNull(content)
        val geometry =
            focusFeedGeometry(
                content = content,
                horizontalPresentationScale = 1f,
                viewport = LiveOverlayRect(0f, 0f, container.width, container.height),
                coordinateWidth = 5_760,
                coordinateHeight = 3_840,
                generation = 1,
            )
        requireNotNull(geometry)

        // Corners clamp to the zero-based inclusive endpoints — never the
        // dimension itself, never negative.
        assertEquals(
            FocusFeedCoordinate(0, 0),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(0f, 0f)),
        )
        assertEquals(
            FocusFeedCoordinate(5_759, 3_839),
            geometry.cameraCoordinateAt(
                FocusFeedPixelPoint(container.width, container.height),
            ),
        )
        // A tap in the band-overlaid bottom strip of the image is still ON the
        // image: valid, clamped coordinates.
        val bandTap =
            geometry.cameraCoordinateAt(
                FocusFeedPixelPoint(container.width / 2f, container.height - 4f),
            )
        requireNotNull(bandTap)
        assertTrue(bandTap.x in 0..5_759)
        assertTrue(bandTap.y in 0..3_839)
        // Outside the image box (the letterbox side lanes host chrome and are
        // outside this container) the gesture rejects rather than emitting
        // out-of-range coordinates.
        assertNull(
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(container.width + 24f, 100f)),
        )
        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(-6f, 100f)))
    }

    @Test
    fun `portrait fill maps the visible crop against the full offscreen feed`() {
        val content = liveFeedContentRect(400f, 600f, 1_920, 1_080, aspectFill = true)
        requireNotNull(content)
        assertEquals(LiveFeedContentRect(left = -333, top = 0, width = 1_067, height = 600), content)
        val geometry =
            focusFeedGeometry(
                content = content,
                horizontalPresentationScale = 1f,
                viewport = LiveOverlayRect(0f, 0f, 400f, 600f),
                coordinateWidth = 1_920,
                coordinateHeight = 1_080,
                generation = 8,
            )
        requireNotNull(geometry)

        assertEquals(-333f, geometry.presentedFeed.left)
        assertEquals(1_067f, geometry.presentedFeed.width)
        assertEquals(LiveOverlayRect(0f, 0f, 400f, 600f), geometry.hitBounds)
        assertEquals(
            FocusFeedCoordinate(599, 0),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(0f, 0f)),
        )
        assertEquals(
            FocusFeedCoordinate(1_318, 1_079),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(400f, 600f)),
        )
    }

    @Test
    fun `horizontal and vertical desqueeze use the full presented rectangle`() {
        val content = LiveFeedContentRect(left = 0, top = 0, width = 800, height = 800)
        val geometry =
            focusFeedGeometry(
                content = content,
                horizontalPresentationScale = 0.5f,
                verticalPresentationScale = 0.25f,
                viewport = LiveOverlayRect(0f, 0f, 800f, 800f),
                coordinateWidth = 800,
                coordinateHeight = 400,
                generation = 2,
            )
        requireNotNull(geometry)

        assertEquals(LiveOverlayRect(200f, 300f, 400f, 200f), geometry.presentedFeed)
        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(199f, 400f)))
        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(400f, 299f)))
        assertEquals(
            FocusFeedCoordinate(0, 0),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(200f, 300f)),
        )
        assertEquals(
            FocusFeedCoordinate(799, 399),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(600f, 500f)),
        )
    }

    @Test
    fun `clipped viewport only limits hit testing and never renormalizes the visible slice`() {
        val geometry =
            focusFeedGeometry(
                content = LiveFeedContentRect(left = -200, top = -100, width = 1_200, height = 800),
                horizontalPresentationScale = 1f,
                viewport = LiveOverlayRect(0f, 0f, 600f, 400f),
                coordinateWidth = 1_200,
                coordinateHeight = 800,
                generation = 4,
            )
        requireNotNull(geometry)

        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(-1f, 0f)))
        assertEquals(
            FocusFeedCoordinate(200, 100),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(0f, 0f)),
        )
        assertEquals(
            FocusFeedCoordinate(799, 499),
            geometry.cameraCoordinateAt(FocusFeedPixelPoint(600f, 400f)),
        )
        assertNull(geometry.cameraCoordinateAt(FocusFeedPixelPoint(601f, 400f)))
    }

    @Test
    fun `coordinate mapping rounds half up and clamps both endpoints`() {
        val geometry =
            focusFeedGeometry(
                content = LiveFeedContentRect(0, 0, 100, 100),
                horizontalPresentationScale = 1f,
                viewport = LiveOverlayRect(0f, 0f, 100f, 100f),
                coordinateWidth = 3,
                coordinateHeight = 3,
                generation = 1,
            )
        requireNotNull(geometry)

        assertEquals(0, geometry.cameraCoordinateAt(FocusFeedPixelPoint(24.9f, 50f))?.x)
        assertEquals(1, geometry.cameraCoordinateAt(FocusFeedPixelPoint(25f, 50f))?.x)
        assertEquals(2, geometry.cameraCoordinateAt(FocusFeedPixelPoint(75f, 50f))?.x)
        assertEquals(2, geometry.cameraCoordinateAt(FocusFeedPixelPoint(100f, 100f))?.x)
    }

    @Test
    fun `missing AF dimensions preserve display geometry but never invent focus coordinates`() {
        val content = LiveFeedContentRect(0, 0, 100, 100)
        val viewport = LiveOverlayRect(0f, 0f, 100f, 100f)

        val noWidth =
            focusFeedGeometry(
                content,
                1f,
                viewport = viewport,
                coordinateWidth = 0,
                coordinateHeight = 100,
                generation = 1,
            )
        requireNotNull(noWidth)
        assertEquals(false, noWidth.hasAuthoritativeCoordinateSpace)
        assertTrue(noWidth.acceptsGestureAt(point(50f, 50f)))
        assertNull(noWidth.cameraCoordinateAt(point(50f, 50f)))

        val noHeight =
            focusFeedGeometry(
                content,
                1f,
                viewport = viewport,
                coordinateWidth = 100,
                coordinateHeight = 0,
                generation = 1,
            )
        requireNotNull(noHeight)
        assertEquals(false, noHeight.hasAuthoritativeCoordinateSpace)
        assertNull(noHeight.cameraCoordinateAt(point(50f, 50f)))

        assertNull(focusFeedGeometry(content, 0f, viewport = viewport, coordinateWidth = 100, coordinateHeight = 100, generation = 1))
        assertNull(
            focusFeedGeometry(
                content,
                1f,
                viewport = LiveOverlayRect(0f, 0f, Float.NaN, 100f),
                coordinateWidth = 100,
                coordinateHeight = 100,
                generation = 1,
            ),
        )
    }

    @Test
    fun `pre-frame viewport geometry supports display hit testing without AF coordinates`() {
        val geometry =
            focusFeedViewportGeometry(
                viewport = LiveOverlayRect(0f, 0f, 400f, 220f),
                generation = 3,
            )
        requireNotNull(geometry)

        assertTrue(geometry.acceptsGestureAt(point(200f, 110f)))
        assertNull(geometry.cameraCoordinateAt(point(200f, 110f)))
        assertNull(
            focusFeedViewportGeometry(
                viewport = LiveOverlayRect(0f, 0f, 0f, 220f),
                generation = 3,
            ),
        )
    }

    @Test
    fun `direct focus metadata requires real dimensions and at least one camera box`() {
        fun focus(boxes: List<LiveFocusBox>, debug: Boolean = false): LiveFocusInfo =
            LiveFocusInfo(
                coordinateWidth = 1_000,
                coordinateHeight = 500,
                result = LiveFocusResult.FOCUSED,
                subjectDetectionActive = false,
                trackingAFActive = false,
                selectedBoxIndex = null,
                boxes = boxes,
                isDebugFixture = debug,
            )

        val box = LiveFocusBox(500, 250, 100, 80)
        assertTrue(focusMetadataSupportsDirectInput(focus(listOf(box))))
        assertEquals(false, focusMetadataSupportsDirectInput(focus(emptyList())))
        assertEquals(false, focusMetadataSupportsDirectInput(focus(listOf(box), debug = true)))
        assertEquals(false, focusMetadataSupportsDirectInput(null))
    }

    @Test
    fun `ordinary release maps one immediate direct AF action`() {
        val context = gestureContext()
        val tracking =
            reduceFocusFeedGesture(
                state = FocusFeedGestureState.Idle,
                event = FocusFeedGestureEvent.Down(point(75f, 25f), uptimeMillis = 1_000),
                context = context,
            )
        assertIs<FocusFeedGestureState.Tracking>(tracking.state)

        val released =
            reduceFocusFeedGesture(
                state = tracking.state,
                event = FocusFeedGestureEvent.Up(point(75f, 25f), uptimeMillis = 1_100),
                context = context,
            )

        assertEquals(FocusFeedGestureState.Idle, released.state)
        assertEquals(
            FocusFeedGestureAction.SetFocusPoint(FocusFeedCoordinate(749, 250)),
            released.action,
        )
    }

    @Test
    fun `hold fires at 300 milliseconds and suppresses release tap`() {
        val context = gestureContext()
        val tracking = down(context, point(50f, 50f), uptimeMillis = 10)
        val early =
            reduceFocusFeedGesture(
                tracking,
                FocusFeedGestureEvent.HoldTimeout(uptimeMillis = 309),
                context,
            )
        assertNull(early.action)
        assertIs<FocusFeedGestureState.Tracking>(early.state)

        val held =
            reduceFocusFeedGesture(
                early.state,
                FocusFeedGestureEvent.HoldTimeout(uptimeMillis = 310),
                context,
            )
        assertEquals(FocusFeedGestureAction.ToggleFocusPointLock, held.action)
        assertIs<FocusFeedGestureState.Held>(held.state)

        val released =
            reduceFocusFeedGesture(
                held.state,
                FocusFeedGestureEvent.Up(point(50f, 50f), uptimeMillis = 400),
                context,
            )
        assertEquals(FocusFeedGestureState.Idle, released.state)
        assertNull(released.action)
    }

    @Test
    fun `hold accepts exactly ten points but larger motion permanently cancels it`() {
        val context = gestureContext()
        val exact = down(context, point(20f, 20f))
        val exactMove =
            reduceFocusFeedGesture(
                exact,
                FocusFeedGestureEvent.Move(point(30f, 20f), uptimeMillis = 300),
                context,
            )
        assertEquals(FocusFeedGestureAction.ToggleFocusPointLock, exactMove.action)

        val moved = down(context, point(20f, 20f))
        val beyond =
            reduceFocusFeedGesture(
                moved,
                FocusFeedGestureEvent.Move(point(30.1f, 20f), uptimeMillis = 200),
                context,
            )
        val returned =
            reduceFocusFeedGesture(
                beyond.state,
                FocusFeedGestureEvent.Move(point(20f, 20f), uptimeMillis = 300),
                context,
            )
        assertNull(returned.action)
        assertIs<FocusFeedGestureState.Tracking>(returned.state)
    }

    @Test
    fun `drag starts at 28 points and completed vertical swipes request explicit modes`() {
        val context = gestureContext()
        val down = down(context, point(50f, 50f))
        val dragging =
            reduceFocusFeedGesture(
                down,
                FocusFeedGestureEvent.Move(point(50f, 78f), uptimeMillis = 100),
                context,
            )
        assertIs<FocusFeedGestureState.Dragging>(dragging.state)
        assertNull(dragging.action)

        val downRequest =
            reduceFocusFeedGesture(
                dragging.state,
                FocusFeedGestureEvent.Up(point(50f, 95.1f), uptimeMillis = 150),
                context,
            )
        assertEquals(
            FocusFeedGestureAction.RequestDisplayMode(MonitorDisplayMode.CLEAN),
            downRequest.action,
        )

        val upTracking = down(context, point(50f, 50f))
        val upRequest =
            reduceFocusFeedGesture(
                upTracking,
                FocusFeedGestureEvent.Up(point(50f, 4.9f), uptimeMillis = 100),
                context,
            )
        assertEquals(
            FocusFeedGestureAction.RequestDisplayMode(MonitorDisplayMode.LIVE),
            upRequest.action,
        )
    }

    @Test
    fun `swipe completion requires strict distance and vertical dominance thresholds`() {
        val context = gestureContext()

        assertNull(dragRelease(context, deltaX = 0f, deltaY = 44f).action)
        assertNull(dragRelease(context, deltaX = 37f, deltaY = 45f).action)
        assertEquals(
            FocusFeedGestureAction.RequestDisplayMode(MonitorDisplayMode.CLEAN),
            dragRelease(context, deltaX = 36f, deltaY = 44.1f).action,
        )
    }

    @Test
    fun `second pointer cancels both pending taps and active swipes`() {
        val context = gestureContext()
        val tracking = down(context, point(20f, 20f))
        val pinched =
            reduceFocusFeedGesture(
                tracking,
                FocusFeedGestureEvent.Move(
                    point(20f, 20f),
                    uptimeMillis = 50,
                    pointerCount = 2,
                ),
                context,
            )
        assertEquals(FocusFeedGestureState.Idle, pinched.state)
        assertNull(pinched.action)
        assertNull(
            reduceFocusFeedGesture(
                pinched.state,
                FocusFeedGestureEvent.Up(point(20f, 80f), uptimeMillis = 100),
                context,
            ).action,
        )

        val dragging =
            reduceFocusFeedGesture(
                down(context, point(20f, 20f)),
                FocusFeedGestureEvent.Move(point(20f, 50f), uptimeMillis = 50),
                context,
            )
        assertIs<FocusFeedGestureState.Dragging>(dragging.state)
        val secondPointer =
            reduceFocusFeedGesture(
                dragging.state,
                FocusFeedGestureEvent.Move(point(20f, 80f), uptimeMillis = 80, pointerCount = 2),
                context,
            )
        assertEquals(FocusFeedGestureState.Idle, secondPointer.state)
        assertNull(secondPointer.action)
    }

    @Test
    fun `any consumed pointer event cancels or rejects the sequence`() {
        val context = gestureContext()
        val consumedDown =
            reduceFocusFeedGesture(
                FocusFeedGestureState.Idle,
                FocusFeedGestureEvent.Down(point(20f, 20f), 0, consumed = true),
                context,
            )
        assertEquals(FocusFeedGestureState.Idle, consumedDown.state)

        val consumedMove =
            reduceFocusFeedGesture(
                down(context, point(20f, 20f)),
                FocusFeedGestureEvent.Move(point(20f, 20f), 50, consumed = true),
                context,
            )
        assertEquals(FocusFeedGestureState.Idle, consumedMove.state)

        val consumedUp =
            reduceFocusFeedGesture(
                down(context, point(20f, 20f)),
                FocusFeedGestureEvent.Up(point(20f, 20f), 50, consumed = true),
                context,
            )
        assertEquals(FocusFeedGestureState.Idle, consumedUp.state)
        assertNull(consumedUp.action)
    }

    @Test
    fun `geometry generation change cancels an in progress gesture`() {
        val initial = gestureContext(generation = 7)
        val tracking = down(initial, point(40f, 40f))
        val changed = gestureContext(generation = 8)

        val reduction =
            reduceFocusFeedGesture(
                tracking,
                FocusFeedGestureEvent.ContextChanged,
                changed,
            )

        assertEquals(FocusFeedGestureState.Idle, reduction.state)
        assertNull(reduction.action)
    }

    @Test
    fun `focus dimensions change cancels even when visual generation is unchanged`() {
        val initial = gestureContext(generation = 7, coordinateWidth = 1_000, coordinateHeight = 1_000)
        val tracking = down(initial, point(40f, 40f))
        val changed = gestureContext(generation = 7, coordinateWidth = 2_000, coordinateHeight = 1_000)

        val reduction =
            reduceFocusFeedGesture(
                tracking,
                FocusFeedGestureEvent.ContextChanged,
                changed,
            )

        assertEquals(FocusFeedGestureState.Idle, reduction.state)
        assertNull(reduction.action)
    }

    @Test
    fun `rendered feed change cancels with identical generation and focus dimensions`() {
        val initial = gestureContext(generation = 7)
        val tracking = down(initial, point(40f, 40f))
        val changedGeometry =
            requireNotNull(initial.geometry).copy(
                presentedFeed = LiveOverlayRect(10f, 5f, 80f, 90f),
                hitBounds = LiveOverlayRect(10f, 5f, 80f, 90f),
            )
        val changed = initial.copy(geometry = changedGeometry)

        val cancelled =
            reduceFocusFeedGesture(
                tracking,
                FocusFeedGestureEvent.ContextChanged,
                changed,
            )
        assertEquals(FocusFeedGestureState.Idle, cancelled.state)
        assertNull(cancelled.action)

        val remapped =
            reduceFocusFeedGesture(
                down(changed, point(50f, 50f)),
                FocusFeedGestureEvent.Up(point(50f, 50f), 100),
                changed,
            )
        assertEquals(
            FocusFeedGestureAction.SetFocusPoint(FocusFeedCoordinate(500, 500)),
            remapped.action,
        )
    }

    @Test
    fun `interface lock and missing presentation geometry suppress every feed action`() {
        val contexts =
            listOf(
                gestureContext().copy(interfaceLocked = true),
                gestureContext().copy(geometry = null),
            )

        contexts.forEach { context ->
            val reduction =
                reduceFocusFeedGesture(
                    FocusFeedGestureState.Idle,
                    FocusFeedGestureEvent.Down(point(50f, 50f), 0),
                    context,
                )
            assertEquals(FocusFeedGestureState.Idle, reduction.state)
            assertNull(reduction.action)
        }

    }

    @Test
    fun `DISP swipe survives unavailable AF metadata while focus actions fail closed`() {
        val presentationOnly =
            requireNotNull(
                focusFeedViewportGeometry(
                    viewport = LiveOverlayRect(0f, 0f, 100f, 100f),
                    generation = 1,
                ),
            )
        val contexts =
            listOf(
                FocusFeedGestureContext(
                    geometry = presentationOnly,
                    focusAvailable = false,
                ),
                gestureContext().copy(focusAvailable = false),
                gestureContext().copy(commandPending = true),
                gestureContext().copy(mediaBusy = true),
            )

        contexts.forEach { context ->
            val tap =
                reduceFocusFeedGesture(
                    down(context, point(50f, 50f)),
                    FocusFeedGestureEvent.Up(point(50f, 50f), 100),
                    context,
                )
            assertNull(tap.action)

            val hold =
                reduceFocusFeedGesture(
                    down(context, point(50f, 50f)),
                    FocusFeedGestureEvent.HoldTimeout(300),
                    context,
                )
            assertNull(hold.action)

            assertEquals(
                FocusFeedGestureAction.RequestDisplayMode(MonitorDisplayMode.CLEAN),
                dragRelease(context, deltaX = 0f, deltaY = 50f).action,
            )
        }
    }

    @Test
    fun `focus point lock suppresses placement but permits hold to unlock and DISP swipes`() {
        val locked = gestureContext().copy(focusPointLocked = true)
        val tap =
            reduceFocusFeedGesture(
                down(locked, point(50f, 50f)),
                FocusFeedGestureEvent.Up(point(50f, 50f), 100),
                locked,
            )
        assertNull(tap.action)

        val hold =
            reduceFocusFeedGesture(
                down(locked, point(50f, 50f)),
                FocusFeedGestureEvent.HoldTimeout(300),
                locked,
            )
        assertEquals(FocusFeedGestureAction.ToggleFocusPointLock, hold.action)

        assertEquals(
            FocusFeedGestureAction.RequestDisplayMode(MonitorDisplayMode.CLEAN),
            dragRelease(locked, deltaX = 0f, deltaY = 50f).action,
        )
    }

    @Test
    fun `density scaling preserves all logical point thresholds`() {
        assertEquals(
            FocusFeedGestureThresholds(
                holdDurationMillis = 300,
                holdSlop = 25f,
                dragStartDistance = 70f,
                completedSwipeDistance = 110f,
                swipeAxisMargin = 20f,
            ),
            FocusFeedGestureThresholds.forDensity(2.5f),
        )
    }

    private fun gestureContext(
        generation: Long = 1,
        coordinateWidth: Int = 1_000,
        coordinateHeight: Int = 1_000,
    ): FocusFeedGestureContext {
        val geometry =
            focusFeedGeometry(
                content = LiveFeedContentRect(0, 0, 100, 100),
                horizontalPresentationScale = 1f,
                viewport = LiveOverlayRect(0f, 0f, 100f, 100f),
                coordinateWidth = coordinateWidth,
                coordinateHeight = coordinateHeight,
                generation = generation,
            )
        return FocusFeedGestureContext(geometry = geometry)
    }

    private fun down(
        context: FocusFeedGestureContext,
        position: FocusFeedPixelPoint,
        uptimeMillis: Long = 0,
    ): FocusFeedGestureState =
        reduceFocusFeedGesture(
            FocusFeedGestureState.Idle,
            FocusFeedGestureEvent.Down(position, uptimeMillis),
            context,
        ).state.also { assertTrue(it is FocusFeedGestureState.Tracking) }

    private fun dragRelease(
        context: FocusFeedGestureContext,
        deltaX: Float,
        deltaY: Float,
    ): FocusFeedGestureReduction {
        val origin = point(20f, 20f)
        return reduceFocusFeedGesture(
            down(context, origin),
            FocusFeedGestureEvent.Up(point(origin.x + deltaX, origin.y + deltaY), 100),
            context,
        )
    }

    private fun point(x: Float, y: Float): FocusFeedPixelPoint = FocusFeedPixelPoint(x, y)
}
