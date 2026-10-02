package com.opencapture.openzcine

import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.opencine.nikon.CameraIdentity
import com.opencapture.opencine.nikon.CameraPropertySnapshot
import com.opencapture.opencine.nikon.FakeCameraSession
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
        assertEquals(ConnectionState.Disconnected(com.opencapture.opencine.core.SessionCloseReason.REQUESTED), paired.snapshots.value.connection)
        assertNotSame(paired, owner.acquire(native))
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
