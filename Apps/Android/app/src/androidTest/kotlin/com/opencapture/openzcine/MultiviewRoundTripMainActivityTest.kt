package com.opencapture.openzcine

import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithContentDescription
import androidx.compose.ui.test.onNodeWithTag
import androidx.compose.ui.test.performClick
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.opencapture.opencine.appkit.MultiviewStageLayout
import com.opencapture.opencine.core.ControlAuthority
import com.opencapture.opencine.core.MonitorEntryDescriptor
import com.opencapture.opencine.core.TelemetrySource
import com.opencapture.opencine.nikon.CameraControl
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
import org.junit.Test
import org.junit.runner.RunWith
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertSame

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

    private class CountedSession(private val delegate: CameraSession) : CameraSession by delegate {
        var commands = 0
        var disconnects = 0
        override suspend fun setRecording(recording: Boolean) { commands++; delegate.setRecording(recording) }
        override suspend fun applyControl(control: CameraControl, label: String) { commands++; delegate.applyControl(control, label) }
        override suspend fun disconnect() { disconnects++; delegate.disconnect() }
    }
}
