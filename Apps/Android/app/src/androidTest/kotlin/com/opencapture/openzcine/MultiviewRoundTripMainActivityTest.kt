package com.opencapture.openzcine

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.compose.ui.semantics.SemanticsActions
import com.opencapture.opencine.appkit.MultiviewStageLayout
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.nikon.CameraControl
import com.opencapture.opencine.nikon.CameraCommandAdmission
import com.opencapture.opencine.nikon.CameraControlException
import kotlinx.coroutines.launch
import kotlinx.coroutines.delay
import java.util.concurrent.atomic.AtomicBoolean
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraSession
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.opencine.nikon.NikonOpenCineSession
import com.opencapture.opencine.nikon.SavedCameraRecord
import com.opencapture.opencine.nikon.SavedCameraTransport
import com.opencapture.openzcine.multicam.MemberStatus
import com.opencapture.openzcine.multicam.MulticamLink
import com.opencapture.openzcine.multicam.MulticamMember
import kotlinx.coroutines.flow.emptyFlow
import kotlinx.coroutines.runBlocking
import org.junit.Rule
import org.junit.Assume.assumeTrue
import androidx.compose.ui.graphics.asAndroidBitmap
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame
import kotlin.test.assertTrue

/** SIMULATED session inside actual MainActivity, its borrowed monitor and retained shared stage. */
@RunWith(AndroidJUnit4::class)
class MultiviewRoundTripMainActivityTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()

    @Test fun borrowedMonitorKeepsTheActualStageAndPresentationWithoutCameraCommands() {
        val context = compose.activity.applicationContext
        val saved = PreferencesSnapshot(context, "multiview-presentation")
        val fake = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "multiview-round-trip"))
        runBlocking { fake.connect() }
        val session = CountedSession(fake)
        lateinit var root: AppRoot
        lateinit var member: MulticamMember
        try {
            compose.runOnIdle {
                root = MainActivity::class.java.getDeclaredField("root").apply { isAccessible = true }
                    .get(compose.activity) as AppRoot
                root.multicam.begin()
                root.multicam.presentation.apply {
                    layout = MultiviewStageLayout.GRID
                    selected = 0
                    fill = true
                    clean = false
                    toolsExpanded = true
                }
                val record = SavedCameraRecord(host = "SIMULATED", cameraName = "SIMULATED", transport = SavedCameraTransport.USB_C,
                    lastSeenAtEpochMillis = 1, wifiSsid = null)
                member = MulticamMember(0, record).also {
                    it.link = MulticamLink(session, emptyFlow())
                    it.control = NikonOpenCineSession(session, root.scope)
                    it.status = MemberStatus.Live
                }
                root.multicam.members.add(member)
                val control = assertNotNull(member.control)
                root.multicam.group.add(MonitorEntryDescriptor(
                    id = member.id, name = "SIMULATED", device = control.refresh().device,
                    cameraSession = control.id, telemetry = TelemetrySource.CAMERA_SESSION,
                    controlAuthority = ControlAuthority.Owner,
                ))
            }
            val original = compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id
            compose.runOnIdle {
                root.activeSavedCamera = member.record
                root.monitorSession = assertNotNull(root.multicam.lend(member.id))
            }
            compose.onNodeWithContentDescription("Return to Multiview").performClick()
            compose.waitUntil(5_000) { root.monitorSession == null && root.multicam.lent == null }
            val returned = compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id
            assertEquals(original, returned, "The actual native stage composition must survive Live View")
            compose.runOnIdle {
                assertSame(session, member.link?.session)
                assertEquals(MultiviewStageLayout.GRID, root.multicam.presentation.layout)
                assertEquals(true, root.multicam.presentation.fill)
                assertEquals(true, root.multicam.presentation.toolsExpanded)
                assertNull(root.monitorSession)
                assertEquals(0, session.commands)
                assertEquals(0, session.disconnects)
                root.multicam.end()
            }
        } finally { saved.restore() }
    }

    @Test fun hiddenStageRetiresGroupConfirmationWithUnchangedRecordContext() {
        val saved = PreferencesSnapshot(compose.activity.applicationContext, "multiview-presentation")
        val fake = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", "hidden-confirmation"))
        val cover = FakeCameraSession(CameraIdentity("SIMULATED cover", "SIMULATED", "cover-only"))
        runBlocking { fake.connect(); fake.setRecording(false); cover.connect() }
        val session = CountedSession(fake)
        lateinit var root: AppRoot
        lateinit var member: MulticamMember
        try {
            compose.runOnIdle {
                root = MainActivity::class.java.getDeclaredField("root").apply { isAccessible = true }
                    .get(compose.activity) as AppRoot
                root.multicam.begin()
                val record = SavedCameraRecord(host = "SIMULATED-confirmation", cameraName = "SIMULATED",
                    transport = SavedCameraTransport.USB_C, lastSeenAtEpochMillis = 1, wifiSsid = null)
                member = MulticamMember(0, record).also {
                    it.link = MulticamLink(session, emptyFlow())
                    it.control = NikonOpenCineSession(session, root.scope)
                    it.status = MemberStatus.Live
                }
                root.multicam.members.add(member)
                val control = assertNotNull(member.control)
                root.multicam.group.add(MonitorEntryDescriptor(
                    id = member.id, name = "SIMULATED", device = control.refresh().device,
                    cameraSession = control.id, telemetry = TelemetrySource.CAMERA_SESSION,
                    controlAuthority = ControlAuthority.Owner,
                ))
            }
            val original = compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id
            val plan = root.multicam.groupPlan()
            assertEquals(true, plan.isExecutable)
            compose.onNodeWithTag("multiview.recordAll").performClick()
            compose.onNodeWithText("Start recording?").assertIsDisplayed()
            val oldStart = assertNotNull(compose.onNodeWithText("Start").fetchSemanticsNode()
                .config[SemanticsActions.OnClick].action)
            // Retain the exact app callback installed on the actual rendered button. The
            // semantics wrapper plays a sound first and refuses detached nodes before calling
            // the app. This second receipt reaches the app's approval-token guard directly.
            val oldAppStart = originalButtonCallback(oldStart)
            fun replayRetiredStart() {
                try { oldStart() } catch (error: IllegalStateException) {
                    // Compose itself refuses an event whose actual modifier node was detached.
                    // A different failure remains a test failure; no camera command is permitted.
                    assertEquals("Cannot read CompositionLocal because the Modifier node is not currently attached.",
                        error.message)
                }
            }
            // Cover the actual retained stage without lending its member: lending also changes
            // the record plan, which would mask this separate presentation-lifetime defect.
            compose.runOnIdle { root.monitorSession = cover }
            compose.waitForIdle()
            compose.runOnIdle { assertEquals(plan, root.multicam.groupPlan()) }
            compose.onNodeWithText("Start recording?").assertDoesNotExist()
            compose.runOnIdle {
                replayRetiredStart()
                oldAppStart()
                assertEquals(0, session.commands)
                root.monitorSession = null
            }
            compose.waitForIdle()
            compose.onNodeWithText("Start recording?").assertDoesNotExist()
            compose.runOnIdle { replayRetiredStart(); oldAppStart(); assertEquals(0, session.commands) }
            assertEquals(original, compose.onNodeWithTag("multicam.stage", useUnmergedTree = true).fetchSemanticsNode().id)
            compose.runOnIdle {
                assertSame(session, member.link?.session)
                assertEquals(0, session.commands)
            }
            compose.onNodeWithTag("multiview.recordAll").performClick()
            compose.onNodeWithText("Start recording?").assertIsDisplayed()
            compose.runOnIdle { replayRetiredStart(); oldAppStart(); assertEquals(0, session.commands) }
            compose.onNodeWithText("Start recording?").assertIsDisplayed()
            compose.onNodeWithText("Cancel").performClick()
            compose.runOnIdle {
                assertEquals(0, session.commands)
                root.multicam.end()
            }
        } finally { saved.restore() }
    }

    @Test fun actualMultiviewSettingsRouteOnlyToSelectedMember() {
        val saved = PreferencesSnapshot(compose.activity.applicationContext, "multiview-presentation")
        val fakeA = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED-A", "settings-A"))
        val fakeB = FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED-B", "settings-B"))
        runBlocking {
            fakeA.connect(); fakeB.connect()
            fakeA.applyControl(CameraControl.ISO, "400")
        }
        val first = CountedSession(fakeA)
        val second = CountedSession(fakeB)
        lateinit var root: AppRoot
        try {
            compose.runOnIdle {
                root = MainActivity::class.java.getDeclaredField("root").apply { isAccessible = true }
                    .get(compose.activity) as AppRoot
                root.multicam.begin()
                root.multicam.presentation.toolsExpanded = true
                listOf(first, second).forEachIndexed { slot, session ->
                    val record = SavedCameraRecord(host = "SIMULATED-settings-$slot", cameraName = "SIMULATED-$slot",
                        transport = SavedCameraTransport.USB_C, lastSeenAtEpochMillis = 1, wifiSsid = null)
                    val member = MulticamMember(slot, record).also {
                        it.link = MulticamLink(session, emptyFlow())
                        it.control = NikonOpenCineSession(session, root.scope)
                        it.status = MemberStatus.Live
                    }
                    root.multicam.members.add(member)
                    val control = assertNotNull(member.control)
                    root.multicam.group.add(MonitorEntryDescriptor(id = member.id, name = member.displayName,
                        device = control.refresh().device, cameraSession = control.id,
                        telemetry = TelemetrySource.CAMERA_SESSION, controlAuthority = ControlAuthority.Owner))
                }
            }
            compose.onNodeWithTag("multiview.recordAll").assertIsDisplayed()
            compose.onNodeWithTag("multiview.settings").assertIsDisplayed().performClick()
            compose.onNodeWithTag("multiview.settings.panel").assertIsDisplayed()
            val oldISO = assertNotNull(compose.onNodeWithTag("multiview.settings.iso")
                .fetchSemanticsNode().config[SemanticsActions.SetProgress].action)
            compose.runOnIdle { oldISO(4f) }
            compose.waitUntil(5_000) { first.writes == listOf(CameraControl.ISO to "500") }
            compose.runOnIdle { assertTrue(second.writes.isEmpty()) }
            compose.onNodeWithTag("multiview.settings.camera.1").performClick()
            compose.onNodeWithTag("multiview.settings.iso").assertIsDisplayed()
            val drained = AtomicBoolean(false)
            compose.runOnIdle {
                oldISO(5f)
                root.scope.launch { delay(250); drained.set(true) }
            }
            compose.waitUntil(5_000) { drained.get() }
            compose.runOnIdle {
                assertEquals(listOf(CameraControl.ISO to "500"), first.writes)
                assertTrue(second.writes.isEmpty())
            }
            compose.onNodeWithTag("monitor.capture.close").performClick()
            compose.onNodeWithTag("multiview.settings.panel").assertDoesNotExist()
            compose.runOnIdle { assertEquals(0, first.recordCommands + second.recordCommands); root.multicam.end() }
        } finally { saved.restore() }
    }

    /** SIMULATED members: the actual stage offers LUT and each tile shows its own native look. */
    @Test fun actualMultiviewLutToolGradesEachMembersOwnPicture() {
        assumeTrue("Native looks need API 33 and the staged Swift core",
            com.opencapture.openzcine.multicam.multicamLookRendererFactory(null) != null)
        val saved = PreferencesSnapshot(compose.activity.applicationContext, "multiview-presentation")
        val sessions = listOf("lut-A", "lut-B").map { serial ->
            CountedSession(FakeCameraSession(CameraIdentity("SIMULATED", "SIMULATED", serial)).also { runBlocking { it.connect() } })
        }
        val red = android.graphics.Bitmap.createBitmap(8, 8, android.graphics.Bitmap.Config.ARGB_8888)
            .apply { eraseColor(android.graphics.Color.rgb(220, 30, 30)) }.copy(android.graphics.Bitmap.Config.ARGB_8888, false)
        lateinit var root: AppRoot
        val members = mutableListOf<MulticamMember>()
        fun tilePixel(member: MulticamMember): Int {
            var color = 0
            compose.runOnIdle { color = assertNotNull(member.frame).asAndroidBitmap().getPixel(4, 4) }
            return color
        }
        fun isMono(color: Int) = android.graphics.Color.red(color).let { r ->
            kotlin.math.abs(r - android.graphics.Color.green(color)) <= 3 &&
                kotlin.math.abs(r - android.graphics.Color.blue(color)) <= 3 && r in 40..110
        }
        try {
            compose.runOnIdle {
                root = MainActivity::class.java.getDeclaredField("root").apply { isAccessible = true }
                    .get(compose.activity) as AppRoot
                root.multicam.begin()
                root.multicam.presentation.toolsExpanded = true
                sessions.forEachIndexed { slot, session ->
                    val record = SavedCameraRecord(host = "SIMULATED-lut-$slot", cameraName = "SIMULATED-$slot",
                        transport = SavedCameraTransport.USB_C, lastSeenAtEpochMillis = 1, wifiSsid = null)
                    val member = MulticamMember(slot, record).also {
                        it.link = MulticamLink(session, emptyFlow())
                        it.control = NikonOpenCineSession(session, root.scope)
                        it.status = MemberStatus.Live
                    }
                    root.multicam.members.add(member)
                    members += member
                    root.multicam.attachPicture(member)
                    root.multicam.setLUTSelection(member.id, com.opencapture.openzcine.FeedLutSelection.BuiltIn(com.opencapture.openzcine.FeedLut.MONO))
                    member.picture.accept(red)
                }
                assertEquals(setOf(0, 1), root.multicam.pictureLUTSlots)
            }
            compose.onNodeWithTag("multicam.tile.picture.0", useUnmergedTree = true).assertExists()
            members.forEach { assertEquals(android.graphics.Color.rgb(220, 30, 30), tilePixel(it)) }
            compose.onNodeWithTag("multiview.lut").assertIsDisplayed().performClick()
            compose.waitUntil(10_000) { members.all { isMono(tilePixel(it)) } }
            compose.runOnIdle {
                assertTrue(root.multicam.lutOn)
                // One member back to its raw picture; the other keeps its own look.
                root.multicam.setLUTEnabled(members[1].id, false)
            }
            assertEquals(android.graphics.Color.rgb(220, 30, 30), tilePixel(members[1]))
            assertTrue(isMono(tilePixel(members[0])))
            compose.onNodeWithTag("multiview.lut").performClick()
            compose.waitUntil(10_000) { members.all { isMono(tilePixel(it)) } }
            compose.onNodeWithTag("multiview.lut").performClick()
            compose.waitUntil(10_000) { members.all { tilePixel(it) == android.graphics.Color.rgb(220, 30, 30) } }
            compose.runOnIdle {
                assertEquals(0, sessions.sumOf { it.commands })
                root.multicam.end()
            }
        } finally { saved.restore() }
    }

    @Suppress("UNCHECKED_CAST")
    private fun originalButtonCallback(semanticsAction: () -> Boolean): () -> Unit {
        val node = semanticsAction.javaClass.declaredFields.firstNotNullOfOrNull { field ->
            field.isAccessible = true
            field.get(semanticsAction)?.takeIf { captured ->
                generateSequence(captured.javaClass as Class<*>?) { it.superclass }
                    .any { it.name == "androidx.compose.foundation.AbstractClickableNode" }
            }
        }
        val actualNode = assertNotNull(node, "Actual rendered semantics action must retain its click node")
        val owner = generateSequence(actualNode.javaClass as Class<*>?) { it.superclass }
            .first { it.name == "androidx.compose.foundation.AbstractClickableNode" }
        val callbackField = owner.getDeclaredField("onClick").apply { isAccessible = true }
        assertEquals("kotlin.jvm.functions.Function0", callbackField.type.name, "Pinned Compose callback shape changed")
        val callback = callbackField.get(actualNode)
        return assertNotNull(callback as? (() -> Unit), "Actual button must hold its original app callback")
    }

    private class CountedSession(private val delegate: CameraSession) : CameraSession by delegate {
        var commands = 0
        var recordCommands = 0
        val writes = mutableListOf<Pair<CameraControl, String>>()
        var disconnects = 0
        override suspend fun setRecording(recording: Boolean) { commands++; recordCommands++; delegate.setRecording(recording) }
        override suspend fun applyControl(control: CameraControl, label: String) { commands++; writes += control to label; delegate.applyControl(control, label) }
        override suspend fun applyControl(control: CameraControl, label: String, admission: CameraCommandAdmission) {
            if (!admission.admits(this)) throw CameraControlException.CommandRejected
            applyControl(control, label)
        }
        override suspend fun disconnect() { disconnects++; delegate.disconnect() }
    }
}
