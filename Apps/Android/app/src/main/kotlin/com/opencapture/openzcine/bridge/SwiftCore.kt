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

    // ── Scopes (anchored axis math + sampling in the Swift core) ──

    /**
     * Fixed scope-axis anchors and vectorscope graticule targets for a tone
     * curve ([curve]: 0 = RED Log3G10, 1 = Nikon N-Log):
     * `[crushLine, midGrayLevel, clipLine, (cb, cr) × 6 targets]` — see
     * [ScopeAnchors.parse] and the Swift mirror `ScopeFrameWire.anchors`.
     * Static per curve; call once.
     */
    external fun scopeAnchors(curve: Int): FloatArray

    /**
     * Samples one downsampled RGBA frame for the waveform / parade /
     * histogram scopes: `[N, (x, luma, r, g, b) × N, 4 × 256 display bins]`
     * with all levels already on the core's 3-anchor display axis — see
     * [ScopeTraces.parse] and the Swift mirror `ScopeFrameWire.traces`.
     * Blocking (one CPU sampling pass); call from a background dispatcher.
     */
    external fun scopeTraces(
        rgba: ByteArray,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        curve: Int,
    ): FloatArray

    /**
     * Samples one downsampled RGBA frame for the vectorscope: a 128×128
     * premultiplied-RGBA density image of the BT.709 chroma plane, computed
     * from the clean points pushed through the core's built-in display tone
     * map (`ScopeFrameWire.vectorPixels`). Empty when the frame yields no
     * samples. Blocking; call from a background dispatcher.
     */
    external fun scopeVector(
        rgba: ByteArray,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        curve: Int,
    ): ByteArray

    // ── Feed effects (colour math baked in the core, uploaded by Kotlin) ──

    /**
     * A built-in monitor look baked by the core into a packed-2D RGBA8 grid
     * (`size³ × 4` bytes) for a `width = size²`, `height = size` texture:
     * pixel `(x = b·size + r, y = g)` — slice tiles along x, so a shader
     * trilinearly samples with two bilinear taps. Null for an unknown
     * [lookOrdinal] (`FeedLut.wireOrdinal`) or size outside 2–64. Bake once
     * per selection (the cube generation is ~10⁵ transcendental calls), never
     * per frame.
     */
    external fun bakeLut(lookOrdinal: Int, size: Int): ByteArray?

    /**
     * The core's false-colour cube (64³) in the same packed-2D RGBA8 grid.
     * [scaleOrdinal] is `FeedFalseColorScale.wireOrdinal`; [curveOrdinal]
     * selects the signal curve (0 = Log3G10, 1 = N-Log). Null for unknown
     * ordinals.
     */
    external fun bakeFalseColorCube(scaleOrdinal: Int, curveOrdinal: Int): ByteArray?

    /**
     * Assist thresholds on the normalized 0–1 code axis:
     * `[deLogBlack, deLogClip, zebraHighlight, zebraMidtoneCentre]` — the
     * peaking de-log anchors and zebra comparison codes, computed by the
     * core's `ExposureSignalMapping` for [curveOrdinal] and the given
     * monitor-percent thresholds. Null for an unknown curve ordinal.
     */
    external fun feedEffectsScalars(
        curveOrdinal: Int,
        zebraHighlightIre: Float,
        zebraMidtoneIre: Float,
    ): FloatArray?

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

    /** Receives raw camera-pushed PTP events from the active event socket. */
    interface SessionEventListener {
        /**
         * One parsed PTP event. [rawEventCode] is `0..0xFFFF`,
         * [transactionId] and every [rawParameters] element are lossless
         * non-negative representations of wire UINT32 values. Unknown Nikon
         * codes remain raw rather than receiving speculative labels.
         */
        fun onEvent(rawEventCode: Int, transactionId: Long, rawParameters: LongArray)

        /**
         * The native event reader ended. `null` means normal local teardown;
         * a non-null message describes an unexpected event-channel failure.
         */
        fun onEnded(message: String?)
    }

    /** MTP BatteryLevel (0x5001) — UINT8 percentage. */
    const val PROP_BATTERY_LEVEL: Int = 0x5001

    /** Nikon MovieRecProhibitionCondition (0xD0A4) — 0 means recording is allowed. */
    const val PROP_MOVIE_REC_PROHIBITION: Int = 0xD0A4

    /** `sessionSetRecording` completed and the camera accepted the command. */
    const val RECORDING_COMMAND_ACCEPTED: Int = 0

    /** No active facade session existed when `sessionSetRecording` ran. */
    const val RECORDING_COMMAND_NO_SESSION: Int = 1

    /** Camera media owns the command channel, so recording cannot change. */
    const val RECORDING_COMMAND_MEDIA_BUSY: Int = 2

    /** The camera sent a non-OK response to the Nikon recording operation. */
    const val RECORDING_COMMAND_REJECTED: Int = 3

    /** The command channel failed before the recording operation completed. */
    const val RECORDING_COMMAND_TRANSPORT_FAILED: Int = 4

    /**
     * Connects to the camera at [host] (numeric IPv4, port 15740): PTP-IP Init
     * handshake on both channels, then the Nikon open/pair/identify sequence,
     * all inside the Swift core's session layer. Returns immediately; progress
     * and the terminal result arrive on [listener] from a background thread.
     */
    external fun sessionConnect(host: String, listener: SessionListener)

    /**
     * Starts draining the connected camera's dedicated PTP-IP event channel.
     * Returns after the Swift-owned reader starts; callbacks arrive from that
     * background thread until disconnect or an event-channel failure. Call
     * once for each successful [sessionConnect].
     */
    external fun sessionStartEventStream(listener: SessionEventListener)

    /**
     * Reads one camera property through the active session, decoded by the
     * Swift core (battery → percent string, others → raw hex). Null when no
     * session is active or the camera rejected the read. Blocking — call from
     * a background dispatcher.
     */
    external fun sessionReadProperty(code: Int): String?

    /**
     * Starts (`true`) or stops (`false`) movie recording on the active camera
     * session. The Swift facade sends Nikon `StartMovieRecInCard` / `EndMovieRec`
     * through its transaction serializer, so a live-view frame read cannot race
     * the command. Blocking — call from a background dispatcher.
     *
     * Returns one of [RECORDING_COMMAND_ACCEPTED],
     * [RECORDING_COMMAND_NO_SESSION], [RECORDING_COMMAND_MEDIA_BUSY],
     * [RECORDING_COMMAND_REJECTED], or [RECORDING_COMMAND_TRANSPORT_FAILED].
     */
    external fun sessionSetRecording(recording: Boolean): Int

    /**
     * Gracefully tears down the active session: best-effort `CloseSession` so
     * the camera frees its connection slot, then both sockets. Blocking
     * (bounded ~2 s) — call from a background dispatcher. A running live-view
     * pump is stopped first (`EndLiveView` before `CloseSession`). Safe when
     * idle.
     */
    external fun sessionDisconnect()

    /** Receives live-view frames pushed from Swift (the facade's pump thread). */
    interface LiveFrameListener {
        /**
         * One live-view JPEG, freshly pulled from the camera. [timestampNanos]
         * is `CLOCK_MONOTONIC` at delivery — the same clock as
         * `System.nanoTime()`. [isRecording] is the camera-authoritative
         * record flag decoded from the same live-view header.
         */
        fun onFrame(jpeg: ByteArray, timestampNanos: Long, isRecording: Boolean)

        /**
         * The stream ended — stop, disconnect, a transport error, or an
         * immediately-failed start. Called exactly once per
         * [sessionStartLiveView].
         */
        fun onEnded()
    }

    /**
     * Starts live view on the active session (blocking `StartLiveView` +
     * readiness poll — call from a background dispatcher) and pumps JPEG
     * frames to [listener] from a Swift background thread. Backpressure is
     * latest-wins: frames are pulled one at a time, so a slow consumer skips
     * camera frames instead of queueing latency.
     */
    external fun sessionStartLiveView(listener: LiveFrameListener)

    /**
     * Stops the live-view pump and blocks until the camera got its
     * `EndLiveView` (never leave the body streaming — the heat-audit rule).
     * Call from a background dispatcher. Safe when idle.
     */
    external fun sessionStopLiveView()

    // ── Media browse (OPE-34) ──

    /**
     * Lists browsable media (clips, stills, unpaired R3D masters) on the
     * active session's cards, flattened one record per line (see
     * `MediaClips.parse`). Enumeration is bounded to [maxObjects] ObjectInfo
     * reads so a packed card never blocks the session unboundedly. Null when
     * no session is active or the listing failed; empty string for an empty
     * card. Blocking — call from a background dispatcher.
     */
    external fun sessionListMedia(maxObjects: Int): String?

    /**
     * The camera's embedded thumbnail JPEG for one object handle, or null
     * when disconnected or the object has no thumbnail. Blocking — call from
     * a background dispatcher.
     */
    external fun sessionThumbnail(handle: Int): ByteArray?

    /**
     * Releases exclusive camera-media ownership. This stops any progressive
     * transfer first, then allows monitor live view to resume. Blocking and
     * safe when idle; call from a background dispatcher.
     */
    external fun sessionExitMediaMode()

    /**
     * Resolves the authoritative 64-bit object size through the shared core,
     * or -1 when disconnected/rejected. Blocking; call from IO.
     */
    external fun sessionResolveMediaSize(handle: Int, reportedSize: Long): Long

    /** Receives one progressive camera-object transfer from Swift. */
    interface MediaTransferListener {
        /** The core-resolved 64-bit size before the first chunk. */
        fun onStarted(totalBytes: Long)

        /** One ordered cache write at [offset]. */
        fun onChunk(offset: Long, bytes: ByteArray): Boolean

        /** The complete object is now cached. */
        fun onCompleted(totalBytes: Long)

        /** A requested stop completed after [cachedBytes] were delivered. */
        fun onStopped(cachedBytes: Long)

        /** Terminal transfer failure with operator-facing copy from Swift. */
        fun onFailed(message: String)
    }

    /**
     * Starts the shared core's object-transfer pump. Kotlin supplies identity
     * and cache resume state only; Swift owns operation selection, 64-bit
     * offset math, and chunk policy. Blocking setup, then callbacks arrive on
     * one Swift-owned thread.
     */
    external fun sessionStartMediaTransfer(
        handle: Int,
        reportedSize: Long,
        resumeOffset: Long,
        listener: MediaTransferListener,
    )

    /** Stops and joins the active transfer. Blocking and safe when idle. */
    external fun sessionStopMediaTransfer()
}
