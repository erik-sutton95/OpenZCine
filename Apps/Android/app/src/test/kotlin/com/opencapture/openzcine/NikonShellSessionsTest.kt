package com.opencapture.openzcine

import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.FakeCameraSession
import com.opencapture.openzcine.core.MonitorDataAvailability
import kotlinx.coroutines.test.runTest
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotSame
import kotlin.test.assertSame

class NikonShellSessionsTest {
    @Test
    fun pairingCamerasAndMonitorReuseOneCommonLifetime() = runTest {
        val native = FakeCameraSession(CameraIdentity("SIMULATED", "Nikon", "test"), true)
        val owner = NikonShellSessions(backgroundScope)
        val paired = owner.acquire(native)
        assertSame(paired, owner.acquire(native))
        owner.retire(native)
        assertEquals(ConnectionState.Disconnected(SessionCloseReason.REQUESTED), paired.snapshots.value.connection)
        assertNotSame(paired, owner.acquire(native))
    }

    @Test
    fun watcherTokenAndHostSurrenderGateCommonReceiptsWithoutClearingReports() = runTest {
        val native = FakeCameraSession(CameraIdentity("SIMULATED", "Nikon", "test"), true)
        val owner = NikonShellSessions(backgroundScope)
        val common = owner.acquire(native)
        val before = common.snapshots.value
        common.updateMonitorAuthority(MonitorDataAvailability.watcher(false), false)
        val denied = common.request(CameraCommandIntent.StartRecording)
        assertEquals(CommandStage.Rejected(CommandRejection.NoAuthority), denied.stage)
        assertEquals(null, native.reportedRecording.value)
        assertEquals(before.value(SettingKey.ISO).value, common.snapshots.value.value(SettingKey.ISO).value)
        common.updateMonitorAuthority(MonitorDataAvailability.watcher(true), false)
        assertEquals(
            CommandStage.Confirmed,
            common.request(CameraCommandIntent.StartRecording).stage,
        )
        common.updateMonitorAuthority(MonitorDataAvailability.OWNING, true)
        val surrendered = common.request(CameraCommandIntent.StopRecording)
        assertEquals(CommandStage.Rejected(CommandRejection.NoAuthority), surrendered.stage)
        assertEquals(true, native.reportedRecording.value)
        assertSame(common, owner.acquire(native))
    }

    @Test
    fun pendingTargetsChangePresentationWithoutChangingCameraReports() {
        val reported = CameraPropertySnapshot(iso = 800, isoAuto = true, whiteBalanceMode = "Auto", whiteBalanceKelvin = 5600)
        val pending = mapOf(
            SettingKey.ISO to SettingValue.Iso(ISOValue.Manual(1600)),
            SettingKey.WHITE_BALANCE to SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(3200)),
        )
        val shown = reported.withPendingControls(pending)
        assertEquals(1600L, shown.iso)
        assertEquals(false, shown.isoAuto)
        assertEquals(3200, shown.whiteBalanceKelvin)
        assertEquals("Color temp", shown.whiteBalanceMode)
        assertEquals(800L, reported.iso)
        assertEquals(true, reported.isoAuto)
        assertEquals("Auto", reported.whiteBalanceMode)
        assertEquals(reported, reported.withPendingControls(emptyMap()))
    }
}
