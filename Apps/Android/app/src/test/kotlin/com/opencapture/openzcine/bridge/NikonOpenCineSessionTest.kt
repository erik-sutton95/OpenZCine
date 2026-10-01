package com.opencapture.openzcine.bridge

import com.opencapture.opencine.core.CameraCommand
import com.opencapture.opencine.core.CameraCommandIntent
import com.opencapture.opencine.core.CommandFailure
import com.opencapture.opencine.core.CommandPreconditions
import com.opencapture.opencine.core.CommandRejection
import com.opencapture.opencine.core.CommandStage
import com.opencapture.opencine.core.ConnectionState
import com.opencapture.opencine.core.ISOValue
import com.opencapture.opencine.core.OperationID
import com.opencapture.opencine.core.RecordingState
import com.opencapture.opencine.core.SessionCloseReason
import com.opencapture.opencine.core.SettingAccess
import com.opencapture.opencine.core.SettingKey
import com.opencapture.opencine.core.SettingValue
import com.opencapture.opencine.core.UnavailableReason
import com.opencapture.opencine.core.WhiteBalanceValue
import com.opencapture.openzcine.WbPickerPolicy
import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.core.CameraControlCapabilities
import com.opencapture.openzcine.core.CameraControlException
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraPropertySnapshot
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue
import kotlin.time.Duration.Companion.seconds
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.advanceTimeBy
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest

/**
 * CORE-02: the Nikon slice behind the OpenCine Kotlin `CameraSession`, over a fake of the monitor's
 * session. The fake accepts only what the Swift core would encode.
 */
@OptIn(ExperimentalCoroutinesApi::class)
class NikonOpenCineSessionTest {
    private class FakeNikon(properties: CameraPropertySnapshot, reported: Boolean? = false) : CameraSession {
        override val state =
            MutableStateFlow<CameraSessionState>(
                CameraSessionState.Connected(CameraIdentity("ZR", "ZR", "3000123")),
            )
        override val recordingState = MutableStateFlow(CameraRecordingState.STANDBY)
        override val reportedRecording = MutableStateFlow(reported)
        override val cameraProperties = MutableStateFlow(properties)
        val writes = mutableListOf<Pair<CameraControl, String>>()
        val records = mutableListOf<Boolean>()
        var controlFailure: CameraControlException? = null

        override suspend fun connect() = Unit

        override suspend fun disconnect() = Unit

        override suspend fun setRecording(recording: Boolean) {
            records += recording
        }

        override suspend fun applyControl(control: CameraControl, label: String) {
            // The Swift core's `androidControlWrites` rule: an advertised label, any numeric ISO,
            // a Kelvin label while the body offers Kelvin, or anything before descriptors land.
            val advertised = cameraProperties.value.controlCapabilities.options(control)
            val encodes =
                advertised.isEmpty() ||
                    label in advertised ||
                    (control == CameraControl.ISO && label.toIntOrNull() != null) ||
                    (
                        control == CameraControl.WHITE_BALANCE &&
                            WbPickerPolicy.isKelvinLabel(label) &&
                            advertised.any(WbPickerPolicy::isKelvinLabel)
                    )
            if (!encodes) throw CameraControlException.UnsupportedSelection
            controlFailure?.let { throw it }
            writes += control to label
        }
    }

    /** A ZR in movie mode, exposure M, H.265, with the Swift-authorized domains. */
    private fun movie(codec: String = "H.265 10-bit MOV") =
        CameraPropertySnapshot(
            iso = 800,
            isoAuto = false,
            exposureMode = "M",
            whiteBalanceMode = "Auto",
            whiteBalanceKelvin = 5560,
            codec = codec,
            batteryPercent = 80,
            captureSelector = "video",
            controlCapabilities =
                CameraControlCapabilities(
                    isoValues = listOf("200", "800", "6400", "25600"),
                    whiteBalanceValues = listOf("Auto", "Natural auto", "Sunny", "2500K", "5560K", "10000K"),
                ),
        )

    @Test
    fun everyAdvertisedValueReachesTheNativeCore() =
        runTest {
            val photo = movie().copy(captureSelector = "photo")
            for (properties in listOf(movie(), movie("R3D NE 12-bit R3D"), photo)) {
                val camera = FakeNikon(properties)
                val seam = NikonOpenCineSession(camera, backgroundScope)
                for (descriptor in seam.snapshots.value.capabilities.descriptors.values) {
                    if (descriptor.access != SettingAccess.READ_WRITE) continue
                    val domain = descriptor.domain
                    if (domain == null) {
                        assertEquals(SettingKey.RECORDING, descriptor.key)
                        val start = seam.request(CameraCommandIntent.StartRecording)
                        assertEquals(CommandStage.AwaitingObservation, start.stage)
                        assertEquals(listOf(true), camera.records)
                        continue
                    }
                    assertTrue(domain.choices.isNotEmpty(), "${descriptor.key} advertises an empty domain")
                    val bounds =
                        domain.range?.let { listOf(it.start, it.endInclusive) }.orEmpty().map {
                            SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(it.toInt()))
                        }
                    for (value in domain.choices + bounds) {
                        val receipt = seam.request(CameraCommandIntent.Set(value))
                        if (descriptor.key == SettingKey.ISO && properties === photo) {
                            val photoISO = CommandRejection.Unavailable(UnavailableReason.Mode)
                            assertEquals(CommandStage.Rejected(photoISO), receipt.stage)
                        } else {
                            assertEquals(CommandStage.Confirmed, receipt.stage, "$value never reached the core")
                        }
                    }
                }
            }
            // An advertised value the core cannot take never reports progress.
            val camera = FakeNikon(movie())
            camera.controlFailure = CameraControlException.UnsupportedSelection
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val iso = SettingValue.Iso(ISOValue.Manual(800))
            assertEquals(CommandStage.Failed(CommandFailure.NOT_SENT), seam.request(CameraCommandIntent.Set(iso)).stage)
        }

    @Test
    fun readbackDecidesTheOutcome() =
        runTest {
            val camera = FakeNikon(movie())
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val kelvin = CameraCommandIntent.Set(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5560)))
            assertEquals(CommandStage.Confirmed, seam.request(kelvin).stage)
            assertEquals(CameraControl.WHITE_BALANCE to "5560K", camera.writes.last())

            camera.controlFailure = CameraControlException.ReadbackMismatch
            assertEquals(CommandStage.Failed(CommandFailure.NOT_APPLIED), seam.request(kelvin).stage)
            assertFailsWith<CameraControlException.ReadbackMismatch> {
                seam.applyControl(CameraControl.ISO, "6400")
            }
            camera.controlFailure = CameraControlException.TransportFailed
            assertEquals(CommandStage.OutcomeUnknown, seam.request(kelvin).stage)
            camera.controlFailure = CameraControlException.CommandRejected
            assertEquals(CommandStage.Rejected(CommandRejection.CameraRefused), seam.request(kelvin).stage)

            // Off every domain the core would encode: never sent at all.
            val off = CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(40000)))
            assertEquals(CommandStage.Rejected(CommandRejection.OutOfDomain), seam.request(off).stage)
        }

    @Test
    fun theDomainCoversWhatTheMonitorOffersAndTheCoreEncodes() =
        runTest {
            // Auto parked ISO off the ladder; leaving Auto writes that value back.
            val parked = movie().copy(iso = 51200)
            val seam = NikonOpenCineSession(FakeNikon(parked), backgroundScope)
            val iso = seam.snapshots.value.capabilities[SettingKey.ISO]!!
            assertTrue(iso.accepts(SettingValue.Iso(ISOValue.Manual(51200))))
            // Before descriptors land the picker ladder and presets stay writable, as in the core.
            val bare = movie().copy(controlCapabilities = CameraControlCapabilities())
            val early = NikonOpenCineSession(FakeNikon(bare), backgroundScope).snapshots.value.capabilities
            assertTrue(early[SettingKey.ISO]!!.accepts(SettingValue.Iso(ISOValue.Manual(3200))))
            val earlyWB = early[SettingKey.WHITE_BALANCE]!!
            assertTrue(earlyWB.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Preset("Shade"))))
            assertTrue(earlyWB.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5570))))
            // Presets only: no Kelvin is invented.
            val presetsOnly =
                movie().copy(
                    controlCapabilities = CameraControlCapabilities(whiteBalanceValues = listOf("Auto", "Sunny")),
                )
            val wb = NikonOpenCineSession(FakeNikon(presetsOnly), backgroundScope).snapshots.value.capabilities
            val presetWB = wb[SettingKey.WHITE_BALANCE]!!
            assertFalse(presetWB.accepts(SettingValue.WhiteBalance(WhiteBalanceValue.Kelvin(5560))))
        }

    @Test
    fun confirmedTargetIsHonoredAndUnknownStaysUnknown() =
        runTest {
            // The camera already reports the target: nothing reaches the wire.
            val recording = FakeNikon(movie(), reported = true)
            val seam = NikonOpenCineSession(recording, backgroundScope)
            assertEquals(CommandStage.Confirmed, seam.request(CameraCommandIntent.StartRecording).stage)
            assertTrue(recording.records.isEmpty())

            // No live-view header yet: recording is unknown even though the shell says STANDBY,
            // and settings still work with no picture behind them.
            val fresh = FakeNikon(movie(), reported = null)
            val unknown = NikonOpenCineSession(fresh, backgroundScope)
            assertFalse(unknown.snapshots.value.recording.isKnown)
            val iso = CameraCommandIntent.Set(SettingValue.Iso(ISOValue.Manual(6400)))
            assertEquals(CommandStage.Confirmed, unknown.request(iso).stage)
            // Unknown is not idle: the explicit start is sent, and waits for the camera.
            assertEquals(CommandStage.AwaitingObservation, unknown.request(CameraCommandIntent.StartRecording).stage)
            assertEquals(listOf(true), fresh.records)
        }

    @Test
    fun anAcceptedRecordWaitsForTheCameraAndTimesOutWithoutIt() =
        runTest {
            val camera = FakeNikon(movie())
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val start = seam.request(CameraCommandIntent.StartRecording)
            assertEquals(CommandStage.AwaitingObservation, start.stage)
            camera.reportedRecording.value = true
            runCurrent()
            assertEquals(CommandStage.Confirmed, seam.outcome(start.operation)?.stage)
            assertEquals(RecordingState.RECORDING, seam.snapshots.value.recording.value)

            val stop = seam.request(CameraCommandIntent.StopRecording)
            advanceTimeBy(6.seconds)
            runCurrent()
            assertEquals(CommandStage.TimedOut, seam.outcome(stop.operation)?.stage)
            assertEquals(RecordingState.RECORDING, seam.snapshots.value.recording.value, "a timeout invents no state")
        }

    @Test
    fun relinkAndCloseStayHonest() =
        runTest {
            val camera = FakeNikon(movie())
            val seam = NikonOpenCineSession(camera, backgroundScope)
            val before = seam.snapshots.value
            camera.state.value = CameraSessionState.Disconnected
            runCurrent()
            camera.state.value = CameraSessionState.Connected(CameraIdentity("ZR", "ZR", "3000123"))
            runCurrent()
            val stale = CameraCommand(CameraCommandIntent.StopRecording, CommandPreconditions(before))
            assertEquals(CommandStage.Rejected(CommandRejection.StaleEpoch), seam.submit(stale).stage)

            val pending = seam.request(CameraCommandIntent.StartRecording)
            seam.close(SessionCloseReason.LINK_LOST)
            assertEquals(CommandStage.OutcomeUnknown, seam.outcome(pending.operation)?.stage)
            assertEquals(ConnectionState.Disconnected(SessionCloseReason.LINK_LOST), seam.snapshots.value.connection)
            val after = seam.request(CameraCommandIntent.StopRecording)
            assertEquals(CommandStage.Rejected(CommandRejection.SessionClosed), after.stage)
            assertNull(seam.outcome(OperationID()))
            assertFailsWith<CameraRecordingException.NotConnected> { seam.setRecording(false) }
        }
}
