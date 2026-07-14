package com.opencapture.openzcine.bridge

/**
 * JNI binding to `libOpenZCineAndroid.so` — the shared Swift core
 * (`Sources/OpenZCineCore`) plus its facade (`Sources/OpenZCineAndroidFacade`).
 *
 * The native library is a build artifact staged into `jniLibs/` by
 * `just android-core`; it is never committed. Every `external fun` here must
 * have a matching `@_cdecl` shim in
 * `Sources/OpenZCineAndroidFacade/SwiftCoreJNI.swift`.
 */
object SwiftCore {
    /**
     * True when the Swift core library is bundled and loaded. False (with no
     * crash) when the APK was built without running `just android-core` first.
     */
    val isAvailable: Boolean by lazy {
        try {
            System.loadLibrary("OpenZCineAndroid")
            true
        } catch (_: UnsatisfiedLinkError) {
            false
        }
    }

    /** Receives connection-phase updates pushed from Swift (non-main thread). */
    fun interface ConnectionPhaseListener {
        /** Called once per phase with operator-facing copy resolved by the core. */
        fun onPhase(title: String, detail: String)
    }

    /** Core build identity string, resolved inside the Swift library. */
    external fun coreVersion(): String

    /**
     * Derives the camera access-point SSID from a PTP friendly name
     * (`ZR_6001234` → `NIKON_ZR_01234`), or null when the name is not a ZR.
     */
    external fun deriveAccessPointSSID(cameraName: String): String?

    /** Operator-facing device title for a raw PTP name (`ZR_6001234` → `Nikon ZR`). */
    external fun resolveDisplayName(rawName: String): String

    /**
     * Monitor zone map from the shared core's `MonitorZoneLayout.map` — the
     * exact frames the iOS shell lays chrome out with. Flat records of
     * `[kind, style, x, y, width, height]` (see [MonitorZones.parse] and the
     * Swift mirror `MonitorZoneMapWire`). All dimensions are dp.
     *
     * @param mode DispMode ordinal: 0 live, 1 clean, 2 command.
     * @param aspectFill portrait feed aspect; false = fit 16:9.
     * @param mirrored true for the mirrored landscape-right chrome.
     */
    external fun monitorZoneMap(
        viewportWidth: Float,
        viewportHeight: Float,
        safeTop: Float,
        safeLeading: Float,
        safeBottom: Float,
        safeTrailing: Float,
        mode: Int,
        isPortrait: Boolean,
        aspectFill: Boolean,
        scopeCount: Int,
        mirrored: Boolean,
        bottomBarHeight: Float,
    ): FloatArray

    /**
     * Registers [listener] and has Swift push a canned connection-phase
     * sequence from a background thread — the callback shape session events
     * and live-view frames will use.
     */
    external fun startConnectionDemo(listener: ConnectionPhaseListener)

    // ── Camera session (PTP-IP protocol/session layer in the Swift core) ──

    /** Receives session lifecycle callbacks pushed from Swift (non-main thread). */
    interface SessionListener {
        /**
         * Progress update. [phase] is a stable machine-readable name mirroring
         * the core's `CameraConnectionPhase` (`handshaking`, `pairing`,
         * `confirmOnCamera`, `connected`); [detail] carries the pairing PIN on
         * `confirmOnCamera` and the display name on `connected`.
         */
        fun onPhase(phase: String, detail: String)

        /** Terminal success: the PTP session is open and the camera identified. */
        fun onConnected(name: String, model: String, serialNumber: String)

        /** Terminal failure with an operator-facing message. */
        fun onFailed(message: String)
    }

    /** MTP BatteryLevel (0x5001) — UINT8 percentage. */
    const val PROP_BATTERY_LEVEL: Int = 0x5001

    /** Nikon MovieRecProhibitionCondition (0xD0A4) — 0 means recording is allowed. */
    const val PROP_MOVIE_REC_PROHIBITION: Int = 0xD0A4

    /**
     * Connects to the camera at [host] (numeric IPv4, port 15740): PTP-IP Init
     * handshake on both channels, then the Nikon open/pair/identify sequence,
     * all inside the Swift core's session layer. Returns immediately; progress
     * and the terminal result arrive on [listener] from a background thread.
     */
    external fun sessionConnect(host: String, listener: SessionListener)

    /**
     * Reads one camera property through the active session, decoded by the
     * Swift core (battery → percent string, others → raw hex). Null when no
     * session is active or the camera rejected the read. Blocking — call from
     * a background dispatcher.
     */
    external fun sessionReadProperty(code: Int): String?

    /**
     * Gracefully tears down the active session: best-effort `CloseSession` so
     * the camera frees its connection slot, then both sockets. Blocking
     * (bounded ~2 s) — call from a background dispatcher. Safe when idle.
     */
    external fun sessionDisconnect()
}
