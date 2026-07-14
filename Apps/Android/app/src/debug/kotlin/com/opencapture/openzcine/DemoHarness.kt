package com.opencapture.openzcine

import android.content.Intent
import com.opencapture.openzcine.bridge.SwiftCoreSessionProbe
import com.opencapture.openzcine.core.CameraIdentity
import com.opencapture.openzcine.core.CameraSession
import com.opencapture.openzcine.core.CameraSessionState
import com.opencapture.openzcine.core.FakeCameraSession
import com.opencapture.openzcine.core.LiveFrameSource
import com.opencapture.openzcine.pairing.PairingCredentials
import com.opencapture.openzcine.pairing.PairingEnvironment
import com.opencapture.openzcine.pairing.PairingFlowState
import com.opencapture.openzcine.pairing.PairingPath
import com.opencapture.openzcine.pairing.PairingScript
import com.opencapture.openzcine.pairing.PairingStep
import com.opencapture.openzcine.transport.CameraDiscovery
import com.opencapture.openzcine.transport.DiscoveredCamera
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
 *
 * Drive the pairing wizard to any state (screenshot verification):
 * ```
 * adb shell am start -n com.opencapture.openzcine/.MainActivity \
 *   --es zc.demo.pairing permissions|choose|prepare|network|discover|connecting \
 *   --es zc.demo.pairingPath ap|hotspot
 * ```
 *
 * Feed effects (needs API 33 + the staged Swift core; combine freely):
 * ```
 * --es zc.assist lut,falsecolor,peaking,zebra   which effects are on
 * --es zc.lut log3g10|nlog|mono                 built-in look (default log3g10)
 * --es zc.fc.scale stops|ire                    false-colour scale (default stops)
 * ```
 */
object DemoHarness {
    /** Boolean intent extra that switches the synthetic demo feed on. */
    const val EXTRA_DEMO_FEED = "zc.demo.feed"

    /** String intent extra selecting the pairing wizard state to script. */
    const val EXTRA_PAIRING_STEP = "zc.demo.pairing"

    /** String intent extra selecting the scripted pairing path (`ap` or `hotspot`). */
    const val EXTRA_PAIRING_PATH = "zc.demo.pairingPath"

    /** String intent extra forcing a glass tier (`full`/`blur`/`flat`) for testing. */
    const val EXTRA_GLASS_TIER = "zc.glass.tier"

    /**
     * Glass-tier override: `--es zc.glass.tier blur` (or `flat`/`full`) pins
     * the chrome glass to that tier so each fallback can be exercised on one
     * device. Null (the default, and always in release) lets [resolveTier]
     * pick the platform ceiling. The override can only lower the tier.
     */
    fun glassTierOverride(intent: Intent): String? = intent.getStringExtra(EXTRA_GLASS_TIER)

    /** String intent extra selecting a scope: `wave|parade|histo|vector`. */
    const val EXTRA_SCOPES = "zc.scopes"

    /**
     * The scope selected by the debug intent, or null. Activate with e.g.
     * ```
     * adb shell am start -n com.opencapture.openzcine/.MainActivity \
     *   --ez zc.demo.feed true --es zc.scopes wave
     * ```
     */
    fun scopeKind(intent: Intent): ScopeKind? =
        ScopeKind.fromToken(intent.getStringExtra(EXTRA_SCOPES))

    /**
     * A demo session + synthetic 25 fps frame source when [intent] carries
     * [EXTRA_DEMO_FEED]; null in a normal launch. Also the debug intent entry
     * point for the Swift-core session probe (`zc.session.host` — see
     * [SwiftCoreSessionProbe]), which runs as a logcat side effect without
     * replacing the shell's session, and for the feed-effect flags
     * (`zc.assist` — applied to whichever feed renders, demo or live).
     */
    fun demoLiveFeed(intent: Intent): Pair<CameraSession, LiveFrameSource>? {
        SwiftCoreSessionProbe.maybeStart(intent)
        FeedEffectsState.current =
            FeedEffects.parse(
                intent.getStringExtra("zc.assist"),
                intent.getStringExtra("zc.lut"),
                intent.getStringExtra("zc.fc.scale"),
            )
        if (!intent.getBooleanExtra(EXTRA_DEMO_FEED, false)) return null
        val session =
            FakeCameraSession(
                CameraIdentity(name = "Demo Feed", model = "OpenZCine Demo", serialNumber = "DEMO"),
            )
        return session to DemoFrameSource()
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
            if (requestedHotspot || step == PairingStep.DISCOVER) {
                PairingPath.PHONE_HOTSPOT
            } else {
                PairingPath.CAMERA_ACCESS_POINT
            }
        return PairingScript(
            start = PairingFlowState(step = step, path = path),
            environment = scriptedEnvironment(),
            autoConnect = raw == "connecting",
        )
    }

    private fun scriptedEnvironment(): PairingEnvironment {
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
            credentials = credentials,
        )
    }

    /** Connects slowly (8 s) so the connecting state can be screenshotted. */
    private class ScriptedPairingSession : CameraSession {
        private val mutableState =
            MutableStateFlow<CameraSessionState>(CameraSessionState.Disconnected)

        override val state: StateFlow<CameraSessionState> = mutableState.asStateFlow()

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

        override suspend fun disconnect() {
            mutableState.value = CameraSessionState.Disconnected
        }
    }
}
