package com.opencapture.openzcine

import android.content.Intent
import android.util.Log
import com.opencapture.openzcine.bridge.SwiftCore
import com.opencapture.openzcine.bridge.SwiftCoreCameraSession
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraRecordingException
import com.opencapture.openzcine.core.CameraRecordingState
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.FakeCameraSession
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.media.MediaGalleryFailureInjection
import com.opencapture.openzcine.pairing.PairingCredentials
import com.opencapture.openzcine.pairing.PairingEnvironment
import com.opencapture.openzcine.pairing.PairingFlowState
import com.opencapture.openzcine.pairing.PairingPath
import com.opencapture.openzcine.pairing.PairingScript
import com.opencapture.openzcine.pairing.PairingStep
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
import com.opencapture.openzcine.transport.UsbPtpCamera
import com.opencapture.openzcine.transport.UsbPtpCameraAccess
import com.opencapture.openzcine.transport.UsbPtpCameraSource
import com.opencapture.openzcine.transport.UsbPtpOpenResult
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.flow

/**
 * Debug-only demo hooks, mirroring `ios/Runner/DemoHarness.swift`: this real
 * implementation lives in `src/debug` only, `src/release` carries an inert
 * stub, so release builds physically cannot activate demo behaviour — the
 * Android equivalent of the iOS `#if DEBUG` isolation.
 *
 * Activate the synthetic feed:
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity --ez zc.demo.feed true
 * ```
 * Add `--es zc.demo.levelSource none` to omit the fixture horizon and exercise
 * the visibly labelled device-tilt fallback instead.
 *
 * Drive the pairing wizard to any state (screenshot verification):
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity \
 *   --es zc.demo.pairing permissions|choose|prepare|network|discover|connecting \
 *   --es zc.demo.pairingPath ap|hotspot|usb
 *   --es zc.demo.usbState empty|needs-permission|denied|ready
 * ```
 *
 * Feed effects (needs API 33 + the staged Swift core; combine freely):
 * ```
 * --es zc.assist lut,falsecolor,peaking,zebra   which effects are on
 * --es zc.lut log3g10|nlog|mono                 built-in look (default log3g10)
 * --es zc.fc.scale stops|ire                    false-colour scale (default stops)
 * ```
 *
 * Or drive the real shell session (Swift-core PTP-IP connect + live view)
 * against a camera or fake-ZR server:
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity --es zc.session.host <ipv4>
 * ```
 * (fake ZR on the development Mac: `adb reverse tcp:15740 tcp:15740`, host
 * `127.0.0.1`; connect phases log under the `SwiftCoreCameraSession` tag).
 */
object DemoHarness {
    private const val TAG = "SwiftCoreCameraSession"

    /** Boolean intent extra that switches the synthetic demo feed on. */
    const val EXTRA_DEMO_FEED = "zc.demo.feed"

    /**
     * Debug-only virtual-horizon source selector. `none` omits synthetic
     * camera-level metadata so the monitor exercises its device-gravity
     * fallback; every other value keeps the explicitly labelled fixture.
     */
    private const val EXTRA_DEMO_LEVEL_SOURCE = "zc.demo.levelSource"

    /** String intent extra selecting the pairing wizard state to script. */
    const val EXTRA_PAIRING_STEP = "zc.demo.pairing"

    /** String intent extra selecting the scripted pairing path (`ap`, `hotspot`, or `usb`). */
    const val EXTRA_PAIRING_PATH = "zc.demo.pairingPath"

    /**
     * Debug-only USB discovery state for pairing screenshots. The fixture
     * never asks Android for USB permission or opens a physical device.
     */
    const val EXTRA_USB_STATE = "zc.demo.usbState"

    /** String intent extra forcing a glass tier (`full`/`blur`/`flat`) for testing. */
    const val EXTRA_GLASS_TIER = "zc.glass.tier"

    /**
     * Glass-tier override: `--es zc.glass.tier blur` (or `flat`/`full`) pins
     * the chrome glass to that tier so each fallback can be exercised on one
     * device. Null (the default, and always in release) lets [resolveTier]
     * pick the platform ceiling. The override can only lower the tier.
     */
    fun glassTierOverride(intent: Intent): String? = intent.getStringExtra(EXTRA_GLASS_TIER)

    /** String intent extra selecting scopes: `wave,parade,histo,vector,lights`. */
    const val EXTRA_SCOPES = "zc.scopes"

    /**
     * Explicit debug image-assist override, distinct from mutable runtime
     * toolbar state. `null` means a normal launch must restore preferences;
     * an explicitly empty `zc.assist` value intentionally means all effects
     * off for the scripted session.
     */
    fun assistEffects(intent: Intent): FeedEffects? =
        if (intent.hasExtra("zc.assist")) {
            FeedEffects.parse(
                intent.getStringExtra("zc.assist"),
                intent.getStringExtra("zc.lut"),
                intent.getStringExtra("zc.fc.scale"),
            )
        } else {
            null
        }

    /**
     * The first scope selected by the debug intent, or null. Kept for callers
     * that still use the pre-multi-scope seam; new monitor wiring uses
     * [scopeKinds]. Activate with e.g.
     * ```
     * adb shell am start -n com.opencapture.openzcine/.MainActivity \
     *   --ez zc.demo.feed true --es zc.scopes wave
     * ```
     */
    fun scopeKind(intent: Intent): ScopeKind? =
        scopeKinds(intent)?.firstOrNull()

    /**
     * Ordered, deduplicated debug scope selection. Comma-separated values keep
     * screenshots deterministic while exercising concurrent panels:
     * `--es zc.scopes wave,parade,lights`.
     */
    fun scopeKinds(intent: Intent): List<ScopeKind>? =
        ScopeKind.parseTokens(intent.getStringExtra(EXTRA_SCOPES))

    /** String intent extra carrying the camera host for a real Swift-core session. */
    const val EXTRA_SESSION_HOST = "zc.session.host"

    /** `browse` opens Media; `play` also opens its first playable proxy. */
    const val EXTRA_MEDIA = "zc.media"

    /**
     * Fails the first Gallery write after MediaStore insertion, then permits a
     * retry. This exercises pending-row cleanup on hardware without touching
     * unrelated device media: `--es zc.gallery.failOnce write`.
     */
    const val EXTRA_GALLERY_FAILURE = "zc.gallery.failOnce"

    fun opensMedia(intent: Intent): Boolean =
        intent.getStringExtra(EXTRA_MEDIA) in setOf("browse", "play")

    fun autoPlaysMedia(intent: Intent): Boolean = intent.getStringExtra(EXTRA_MEDIA) == "play"

    /** Debug-only one-shot Gallery failure requested by [intent]. */
    internal fun galleryFailureInjection(intent: Intent): MediaGalleryFailureInjection =
        MediaGalleryFailureInjection.parse(intent.getStringExtra(EXTRA_GALLERY_FAILURE))

    /**
     * The debug session/feed override for [intent], or null in a normal
     * launch: `zc.session.host` makes the shell session a real
     * [SwiftCoreCameraSession] (null frame source — the shell streams the
     * session's own live view once connected); `zc.demo.feed` pairs a fake
     * session with the synthetic 25 fps frame source.
     */
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource?>? {
        intent.getStringExtra(EXTRA_SESSION_HOST)?.let { host ->
            if (!SwiftCore.isAvailable) {
                Log.w(TAG, "libOpenZCineAndroid.so not bundled — run `just android-core` first")
            }
            Log.i(TAG, "shell session → Swift core at $host")
            return SwiftCoreCameraSession(host) { phase, detail ->
                Log.i(TAG, "phase: $phase${if (detail.isEmpty()) "" else " — $detail"}")
            } to null
        }
        if (!intent.getBooleanExtra(EXTRA_DEMO_FEED, false)) return null
        val session =
            FakeCameraSession(
                CameraIdentity(name = "Demo Feed", model = "OpenZCine Demo", serialNumber = "DEMO"),
            )
        val includeDebugCameraLevel = intent.getStringExtra(EXTRA_DEMO_LEVEL_SOURCE) != "none"
        return session to DemoFrameSource(includeDebugCameraLevel = includeDebugCameraLevel)
    }

    /**
     * A scripted pairing-wizard state + fake backend when [intent] carries
     * [EXTRA_PAIRING_STEP]; null in a normal launch. Joins always succeed
     * after a beat, discovery finds a fake ZR after a few seconds, and the
     * session connects slowly enough to screenshot the connecting state.
     */
    fun pairingScript(intent: Intent): PairingScript? {
        val raw = intent.getStringExtra(EXTRA_PAIRING_STEP) ?: return null
        val requestedHotspot = intent.getStringExtra(EXTRA_PAIRING_PATH) == "hotspot"
        val requestedUsb = intent.getStringExtra(EXTRA_PAIRING_PATH) == "usb"
        val usbState =
            if (requestedUsb) {
                ScriptedUsbState.parse(intent.getStringExtra(EXTRA_USB_STATE))
            } else {
                null
            }
        val step =
            when (raw) {
                "permissions" -> PairingStep.PERMISSIONS
                "choose" -> PairingStep.CHOOSE_PATH
                "prepare" -> PairingStep.PREPARE
                "network", "connecting" -> PairingStep.NETWORK
                "discover" -> PairingStep.DISCOVER
                else -> PairingStep.CHOOSE_PATH
            }
        val path =
            if (requestedUsb) {
                PairingPath.USB_C
            } else if (requestedHotspot || step == PairingStep.DISCOVER) {
                PairingPath.PHONE_HOTSPOT
            } else {
                PairingPath.CAMERA_ACCESS_POINT
            }
        return PairingScript(
            start = PairingFlowState(step = step, path = path),
            environment = scriptedEnvironment(usbState),
            autoConnect = raw == "connecting",
        )
    }

    private fun scriptedEnvironment(usbState: ScriptedUsbState?): PairingEnvironment {
        val credentials =
            object : PairingCredentials {
                override var lastSsid: String? = null
                private val saved = mutableMapOf<String, String>()

                override fun passphrase(ssid: String): String? = saved[ssid]

                override fun save(ssid: String, passphrase: String) {
                    saved[ssid] = passphrase
                }
            }
        return PairingEnvironment(
            joinCameraAp = { _, _ ->
                delay(1_500)
                true
            },
            releaseCameraAp = {},
            hotspotCameras =
                flow {
                    emit(emptyList())
                    delay(4_000)
                    emit(
                        listOf(
                            DiscoveredCamera(
                                name = "ZR_6001234",
                                host = "172.20.10.9",
                                port = CameraDiscovery.PTP_IP_PORT,
                            )
                        )
                    )
            },
            createSession = { ScriptedPairingSession() },
            usbCameraSource = usbState?.let(::ScriptedUsbCameraSource),
            createUsbSession = { ScriptedPairingSession() },
            credentials = credentials,
        )
    }

    /** Debug-only USB discovery variants for screenshot verification. */
    private enum class ScriptedUsbState {
        EMPTY,
        NEEDS_PERMISSION,
        DENIED,
        READY,
        ;

        companion object {
            fun parse(raw: String?): ScriptedUsbState =
                when (raw) {
                    "empty" -> EMPTY
                    "needs-permission" -> NEEDS_PERMISSION
                    "denied" -> DENIED
                    else -> READY
                }
        }
    }

    /**
     * Debug-only USB discovery source for UI screenshots. It never reads a
     * real device serial or opens a physical transport. Tapping Allow changes
     * the synthetic card to Ready so the permission-recovery copy can be
     * screenshot without invoking Android's actual USB permission dialog.
     */
    private class ScriptedUsbCameraSource(initialState: ScriptedUsbState) : UsbPtpCameraSource {
        private val mutableCameras = MutableStateFlow(camerasFor(initialState))
        override val cameras: StateFlow<List<UsbPtpCamera>> =
            mutableCameras.asStateFlow()

        override fun requestPermission(camera: UsbPtpCamera) {
            if (camera.token == DEBUG_USB_TOKEN) {
                mutableCameras.value = camerasFor(ScriptedUsbState.READY)
            }
        }

        override fun open(camera: UsbPtpCamera): UsbPtpOpenResult =
            UsbPtpOpenResult.Rejected("Debug USB camera cannot open a physical transport.")

        override fun close() = Unit

        private companion object {
            const val DEBUG_USB_TOKEN = "debug-usb-zr"
            const val DEBUG_USB_HOST_KEY = "usb:00000000000000000000000000000000"

            fun camerasFor(state: ScriptedUsbState): List<UsbPtpCamera> =
                if (state == ScriptedUsbState.EMPTY) {
                    emptyList()
                } else {
                    listOf(
                        UsbPtpCamera(
                            token = DEBUG_USB_TOKEN,
                            displayName = "Synthetic USB-C camera",
                            access =
                                when (state) {
                                    ScriptedUsbState.NEEDS_PERMISSION ->
                                        UsbPtpCameraAccess.NEEDS_PERMISSION
                                    ScriptedUsbState.DENIED -> UsbPtpCameraAccess.DENIED
                                    ScriptedUsbState.READY -> UsbPtpCameraAccess.READY
                                    ScriptedUsbState.EMPTY -> error("Empty USB state has no camera")
                                },
                            // This never renders; it keeps the source-set
                            // fixture structurally equivalent to a ready
                            // production camera record without resembling a
                            // real body identity.
                            hostKey =
                                if (state == ScriptedUsbState.READY) {
                                    DEBUG_USB_HOST_KEY
                                } else {
                                    null
                                },
                            isDebugFixture = true,
                        ),
                    )
                }
        }
    }

    /** Connects slowly (8 s) so the connecting state can be screenshotted. */
    private class ScriptedPairingSession : CameraSession {
        private val mutableState =
            MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)
        private val mutableRecordingState = MutableStateFlow(CameraRecordingState.STANDBY)

        override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()
        override val recordingState: StateFlow<CameraRecordingState> =
            mutableRecordingState.asStateFlow()

        override suspend fun connect() {
            // Idempotent: the monitor shell re-connects the handed-off session.
            if (mutableState.value is CameraSessionState.Connected) return
            mutableState.value = CameraSessionState.Connecting
            delay(8_000)
            mutableState.value =
                CameraSessionState.Connected(
                    CameraIdentity(name = "Nikon ZR", model = "NIKON ZR", serialNumber = "6001234")
                )
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

        override suspend fun disconnect() {
            mutableState.value = CameraSessionState.Disconnected
            mutableRecordingState.value = CameraRecordingState.STANDBY
        }
    }
}
