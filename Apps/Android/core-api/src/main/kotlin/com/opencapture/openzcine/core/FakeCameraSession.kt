package com.opencapture.openzcine.core

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update

/**
 * In-memory [CameraSession] used by debug demo feeds and unit/UI tests.
 *
 * Drives the documented state machine without any I/O: [connect] moves
 * through [CameraSessionState.Connecting] and connects to [discoverable]
 * when one is provided, otherwise falls back to
 * [CameraSessionState.Disconnected] (the "no camera found" outcome).
 *
 * Seeds the same capture-bar + top-deck readouts/options iOS shows in
 * `CameraDisplayState.preview` / demo sessions so every capture cell is
 * actionable offline. [applyControl] applies those controls locally (no PTP).
 *
 * @property discoverable The camera this fake "finds", or `null` to
 *   simulate an empty network.
 */
public class FakeCameraSession(
    private val discoverable: CameraIdentity? = null,
    /**
     * When true and [discoverable] is non-null, the session starts already
     * connected so demo launches enter the monitor without an extra connect
     * handshake.
     */
    private val startConnected: Boolean = false,
) : CameraSession {
    private val mutableState =
        MutableStateFlow<CameraSessionState>(
            if (startConnected && discoverable != null) {
                CameraSessionState.Connected(discoverable)
            } else {
                CameraSessionState.Disconnected
            },
        )
    private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)
    private val mutableProperties = MutableStateFlow(DEMO_PROPERTIES)

    override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()
    override val recordingState: StateFlow<CameraRecordingState> =
        mutableRecordingState.asStateFlow()
    override val cameraProperties: StateFlow<CameraPropertySnapshot> =
        mutableProperties.asStateFlow()
    override val propertyRefreshStatus: StateFlow<CameraPropertyRefreshStatus> =
        MutableStateFlow(CameraPropertyRefreshStatus.Ready)

    override suspend fun connect() {
        mutableState.value = CameraSessionState.Connecting
        mutableState.value =
            discoverable?.let { CameraSessionState.Connected(it) }
                ?: CameraSessionState.Disconnected
    }

    override suspend fun setRecording(recording: Boolean) {
        if (mutableState.value !is CameraSessionState.Connected) {
            throw CameraRecordingException.NotConnected
        }
        mutableRecordingState.value =
            if (recording) CameraRecordingState.STARTING else CameraRecordingState.STOPPING
        mutableRecordingState.value =
            if (recording) CameraRecordingState.RECORDING else CameraRecordingState.STANDBY
    }

    override suspend fun applyControl(control: CameraControl, label: String) {
        if (mutableState.value !is CameraSessionState.Connected) {
            throw CameraControlException.NotConnected
        }
        when (control) {
            CameraControl.ISO ->
                mutableProperties.update {
                    it.copy(iso = label.toLongOrNull() ?: it.iso)
                }
            CameraControl.ISO_AUTO ->
                mutableProperties.update {
                    it.copy(isoAuto = label.equals("ON", ignoreCase = true))
                }
            CameraControl.BASE_ISO ->
                mutableProperties.update { it.copy(baseIso = label) }
            CameraControl.SHUTTER ->
                mutableProperties.update {
                    if (label.contains('°')) {
                        it.copy(shutterAngle = label, shutterMode = CameraShutterMode.ANGLE)
                    } else {
                        it.copy(shutterSpeed = label, shutterMode = CameraShutterMode.SPEED)
                    }
                }
            CameraControl.SHUTTER_MODE ->
                mutableProperties.update {
                    it.copy(
                        shutterMode =
                            when (label) {
                                "Speed" -> CameraShutterMode.SPEED
                                else -> CameraShutterMode.ANGLE
                            },
                    )
                }
            CameraControl.SHUTTER_LOCK ->
                mutableProperties.update {
                    it.copy(shutterLocked = label.equals("Locked", ignoreCase = true))
                }
            CameraControl.IRIS ->
                mutableProperties.update { it.copy(iris = label) }
            CameraControl.FOCUS_MODE ->
                mutableProperties.update { it.copy(focusMode = label) }
            CameraControl.FOCUS_AREA ->
                mutableProperties.update { it.copy(focusArea = label) }
            CameraControl.FOCUS_SUBJECT ->
                mutableProperties.update { it.copy(focusSubject = label) }
            CameraControl.RESOLUTION_FRAMERATE ->
                mutableProperties.update { it.copy(resolutionFrameRate = label) }
            CameraControl.CODEC ->
                mutableProperties.update {
                    it.copy(codec = label, codecSelection = label)
                }
            CameraControl.WHITE_BALANCE ->
                mutableProperties.update {
                    if (label.endsWith("K")) {
                        val kelvin = label.dropLast(1).toIntOrNull()
                        it.copy(
                            whiteBalanceMode = "Color temp",
                            whiteBalanceKelvin = kelvin,
                        )
                    } else {
                        it.copy(whiteBalanceMode = label)
                    }
                }
            CameraControl.WHITE_BALANCE_TINT ->
                mutableProperties.update { it.copy(whiteBalanceTint = label) }
            else -> throw CameraControlException.UnsupportedSelection
        }
    }

    override suspend fun disconnect() {
        mutableState.value = CameraSessionState.Disconnected
        mutableRecordingState.value = CameraRecordingState.STANDBY
        mutableProperties.value = DEMO_PROPERTIES
    }

    private companion object {
        /**
         * Mirrors iOS `CameraDisplayState.preview` + `CameraPicker.options` so
         * the capture strip reads ISO 800 · 180° · f/2.8 · 5560K · AF-C and
         * every picker drum has options offline.
         */
        val DEMO_PROPERTIES =
            CameraPropertySnapshot(
                iso = 800,
                baseIso = "Low",
                shutterMode = CameraShutterMode.ANGLE,
                shutterLocked = false,
                shutterAngle = "180°",
                shutterSpeed = "1/50",
                iris = "f/2.8",
                focusMode = "AF-C",
                focusArea = "Wide-L",
                focusSubject = "People",
                resolutionFrameRate = "6K · 25p",
                codec = "R3D NE",
                codecSelection = "R3D NE",
                whiteBalanceMode = "Color temp",
                whiteBalanceKelvin = 5_560,
                whiteBalanceTint = "Neutral",
                controlCapabilities =
                    CameraControlCapabilities(
                        isoValues =
                            listOf(
                                "200",
                                "250",
                                "320",
                                "400",
                                "500",
                                "640",
                                "800",
                                "1000",
                                "1250",
                                "1600",
                                "2000",
                                "2500",
                                "3200",
                            ),
                        baseIso = listOf("Low", "High"),
                        // Active angle circuit (iOS hardcoded angle ladder for demo).
                        shutterValues =
                            listOf(
                                "5.6°",
                                "11.2°",
                                "22.5°",
                                "45°",
                                "72°",
                                "86.4°",
                                "90°",
                                "108°",
                                "144°",
                                "172°",
                                "180°",
                                "216°",
                                "288°",
                                "346°",
                                "360°",
                            ),
                        shutterModes = listOf("Angle", "Speed"),
                        shutterLocks = listOf("Unlocked", "Locked"),
                        irisValues =
                            listOf(
                                "f/1.4",
                                "f/2.0",
                                "f/2.8",
                                "f/4.0",
                                "f/5.6",
                                "f/8.0",
                                "f/11.0",
                            ),
                        // iOS CameraPicker.focus.modes ladders (independent tabs).
                        focusModes = listOf("MF", "AF-S", "AF-C", "AF-F"),
                        focusAreas =
                            listOf("Single", "Wide-S", "Wide-L", "Auto", "Subject"),
                        focusSubjects =
                            listOf("Auto", "People", "Animal", "Bird", "Vehicle", "Airplane"),
                        resolutionFrameRates =
                            listOf(
                                "6K · 24p",
                                "6K · 25p",
                                "6K · 30p",
                                "6K · 50p",
                                "4K · 60p",
                            ),
                        codecs =
                            listOf(
                                "R3D NE",
                                "N-RAW",
                                "ProRes RAW HQ",
                                "ProRes 422 HQ",
                                "H.265 10-bit",
                            ),
                        // Nikon K dial steps (~10 mired; 5560 not 5600) + presets.
                        whiteBalanceValues =
                            listOf(
                                "2500K", "2560K", "2630K", "2700K", "2780K", "2860K",
                                "2940K", "3030K", "3130K", "3230K", "3330K", "3450K",
                                "3570K", "3700K", "3850K", "4000K", "4170K", "4350K",
                                "4550K", "4760K", "5000K", "5260K", "5560K", "5880K",
                                "6250K", "6670K", "7140K", "7690K", "8330K", "9090K",
                                "10000K",
                                "Auto",
                                "Natural auto",
                                "Sunny",
                                "Cloudy",
                                "Shade",
                                "Incandescent",
                                "Fluorescent",
                                "Flash",
                                "Preset",
                            ),
                        // Sparse sample of the 13×13 grid so the Tint tab is
                        // present; the pad can still emit any valid label.
                        whiteBalanceTints =
                            listOf(
                                "Neutral",
                                "A1 · G0.5",
                                "A2 · G1",
                                "B1 · M0.25",
                                "B1 · G1",
                            ),
                    ),
            )
    }
}
