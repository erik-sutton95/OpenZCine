package com.opencapture.openzcine.bridge

import com.opencapture.openzcine.core.CameraControl
import com.opencapture.openzcine.transport.UsbPtpTransport

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
     * Advances decoded-playback stereo peaks through Swift's shared dBFS and meter-ballistics
     * policy. [previousPayload] is empty for a new meter or the complete six-value payload from
     * the prior call; the returned state includes both peak ages so hold survives Android polls.
     */
    external fun playbackAudioMeterStep(
        previousPayload: FloatArray,
        leftPeakLinear: Float,
        rightPeakLinear: Float,
        deltaTimeSeconds: Float,
    ): FloatArray?

    /**
     * Derives the camera access-point SSID from a PTP friendly name
     * (`ZR_6001234` → `NIKON_ZR_01234`), or null when the name is not a ZR.
     */
    external fun deriveAccessPointSSID(cameraName: String): String?

    /**
     * Sends one ephemeral on-device OCR transcript through Swift's shared
     * `CameraWiFiScreenParser` policy. Returns `SSID<unit-separator>key` only
     * when both Nikon Connection-wizard fields validate; this bridge never
     * stores or logs recognized text. Kotlin only decodes the two-field wire
     * result and must not recreate the camera-specific correction policy.
     */
    external fun parseCameraWifiScreen(transcript: String): String?

    // ── Frame.io (OAuth/API policy remains in the portable Swift core) ──

    /**
     * Starts a Frame.io Adobe IMS PKCE transaction in the shared core.
     *
     * The returned process-local JSON contains `authorizationURL`, `state`,
     * and `verifier`. It is sensitive OAuth transaction material: callers
     * must encrypt it at rest, never log it, and clear it after the redirect.
     * Returns null when the build's public client configuration is absent or
     * malformed.
     */
    external fun frameioBeginAuthorization(clientID: String, redirectURI: String): String?

    /**
     * Verifies a returned callback against the configured redirect URI and
     * shared-core OAuth state. Returns the authorization code only on a valid
     * match; Kotlin must not parse query parameters or decide state policy.
     */
    external fun frameioParseRedirect(
        redirectURI: String,
        callbackURI: String,
        expectedState: String,
    ): String?

    /**
     * Builds the Adobe IMS form POST for `exchange` or `refresh` using the
     * shared OAuth policy. The process-local JSON contains `url`, `method`,
     * and `body`; body data can include a code or refresh token and must never
     * be logged.
     */
    external fun frameioTokenRequest(
        kind: String,
        clientID: String,
        redirectURI: String,
        code: String?,
        verifier: String?,
        refreshToken: String?,
    ): String?

    /**
     * Builds one Frame.io V4 request from the portable endpoint and Codable
     * model policy. The Android HTTPS adapter attaches its encrypted bearer
     * token; it must not recreate endpoint paths or request bodies locally.
     */
    external fun frameioAPIRequest(
        operation: String,
        accountID: String?,
        workspaceID: String?,
        folderID: String?,
        fileID: String?,
        name: String?,
        fileSize: Long,
    ): String?

    /**
     * Canonicalizes a Frame.io API response through the shared Codable models.
     * Null means the response did not match the known V4 model and must fail
     * closed rather than being guessed by the Android shell.
     */
    external fun frameioDecodeResponse(operation: String, response: String): String?

    /** Resolves an upload MIME family through the shared Frame.io core policy. */
    external fun frameioMediaTypeForFilename(filename: String): String

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
     * [clipNative] is a camera-resolved warning endpoint returned by the
     * Swift exposure facade, keeping the scope axis aligned with false colour
     * and zebras. [crushClipCompensationRaw] is the persisted raw value for
     * Swift's `AssistConfiguration.CrushClipCompensation`; Swift alone
     * applies it when measuring the additive Traffic Lights trailer.
     * [includePoints] is false for histogram/Traffic-Lights-only demand so
     * Swift skips point allocation and the JNI payload carries only bins and
     * the derived meter record.
     * Blocking (one CPU sampling pass); call from a background dispatcher.
     */
    external fun scopeTraces(
        rgba: ByteArray,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        curve: Int,
        clipNative: Float,
        crushClipCompensationRaw: Int,
        includePoints: Boolean,
    ): FloatArray

    /**
     * Samples one downsampled RGBA frame for the vectorscope: a 128×128
     * consecutive 128×128 premultiplied-RGBA density images of the BT.709
     * chroma plane (1.1-bin Gaussian soft pass, then crisp source), computed
     * from the clean points pushed through the active registered monitor LUT
     * (`ScopeFrameWire.vectorPixels`). [lutHandle] comes from
     * [registerScopeVectorLut] and avoids copying a 33–64³ cube on each tick.
     * [zoom] is the stable Swift-owned
     * trace-gain ordinal (0 = 1×, 1 = 2×, 2 = 4×); [brightness] is the
     * persisted 0…200 trace percentage and is applied while Swift produces
     * premultiplied pixels. Empty when the frame yields no samples. Blocking;
     * call from a background dispatcher.
     */
    external fun scopeVector(
        rgba: ByteArray,
        width: Int,
        height: Int,
        bytesPerRow: Int,
        curve: Int,
        zoom: Int,
        brightness: Int,
        lutHandle: Long,
    ): ByteArray

    /**
     * Registers the vectorscope's active monitor look once per selection.
     * [lookOrdinal] uses [com.opencapture.openzcine.FeedLut.wireOrdinal]; a
     * negative value decodes [packedRgba] as a [cubeSize]³ stored cube. Returns
     * a positive handle or `-1` for a malformed record. Blocking; call off the
     * main dispatcher.
     */
    external fun registerScopeVectorLut(
        lookOrdinal: Int,
        packedRgba: ByteArray?,
        cubeSize: Int,
    ): Long

    /** Releases a positive handle returned by [registerScopeVectorLut]. */
    external fun unregisterScopeVectorLut(handle: Long)

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
     * Resolves the active camera signal mapping in Swift: `[curveOrdinal,
     * blackNative, middleGrayNative, clipNative]`. Kotlin forwards raw
     * camera metadata only; it never selects a curve or derives a clip code.
     */
    external fun exposureAssistMapping(codec: String?, iso: Long, baseIso: String?): FloatArray

    /**
     * Converts a canonical monitor-percent zebra threshold into an editor
     * value. Unsupported [unitOrdinal] returns `NaN` and callers must leave
     * the saved canonical setting untouched.
     */
    external fun zebraEditorValue(
        codec: String?,
        iso: Long,
        baseIso: String?,
        unitOrdinal: Int,
        monitorPercent: Float,
    ): Float

    /**
     * Converts a native-code or monitor-IRE zebra editor value into the
     * canonical 0…100 monitor axis. Unsupported input returns `NaN`.
     */
    external fun zebraMonitorPercent(
        codec: String?,
        iso: Long,
        baseIso: String?,
        unitOrdinal: Int,
        editorValue: Float,
    ): Float

    /**
     * Swift-resolved shader record for source-measured peaking and dual
     * zebras. It contains the camera curve, de-log anchors, sensitivity
     * threshold/ramp, and all overlay RGB; Kotlin only validates and uploads
     * it (see `FeedEffectsRenderConfiguration`).
     */
    external fun feedEffectsConfiguration(
        codec: String?,
        iso: Long,
        baseIso: String?,
        peakingSensitivity: Int,
        peakingColor: Int,
        highlightEnabled: Boolean,
        highlightIre: Float,
        highlightColor: Int,
        midtoneEnabled: Boolean,
        midtoneIre: Float,
        midtoneColor: Int,
    ): FloatArray?

    /**
     * The core's false-colour cube (64³) in the same packed-2D RGBA8 grid.
     * [scaleOrdinal] is `FeedFalseColorScale.wireOrdinal`; [curveOrdinal]
     * and [clipNative] are already resolved by [exposureAssistMapping]. Null
     * for unsupported scales or curve records.
     */
    external fun bakeFalseColorCube(
        scaleOrdinal: Int,
        curveOrdinal: Int,
        clipNative: Float,
    ): ByteArray?

    /** Swift-owned Limits paint cube for composition over the selected LUT. */
    external fun bakeFalseColorLimitsPaint(curveOrdinal: Int, clipNative: Float): ByteArray?

    /** Swift-owned Limits zone-weight cube paired with the paint cube. */
    external fun bakeFalseColorLimitsWeight(curveOrdinal: Int, clipNative: Float): ByteArray?

    /**
     * Versioned reference-panel segments and stop-marker geometry, taken from
     * the exact false-colour scale/mapping that produced the GPU cube.
     */
    external fun falseColorReference(
        scaleOrdinal: Int,
        curveOrdinal: Int,
        clipNative: Float,
    ): FloatArray?

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

    // ── Stored LUT library (strict Swift parser + existing packed cube path) ──

    /**
     * Validates a selected `.cube` document before Android copies it into its app-private library.
     *
     * [utf8] is bounded by the Android SAF reader; Swift then enforces the shared `CubeLUT`
     * source cap, strict UTF-8, cube parser, safe generated [fileName], and canonical
     * `LUTSelection.cacheKey`. Returns the versioned `US`-separated record
     * `[version, cubeSize, cacheKey]`, or null when the import must be rejected. Kotlin must never
     * copy bytes before a non-null result and must not retain the source URI.
     *
     * @param categoryOrdinal 0 = Custom, 1 = RED. Built-ins do not use this API.
     */
    external fun validateImportedLut(
        utf8: ByteArray,
        categoryOrdinal: Int,
        fileName: String,
    ): String?

    /**
     * Revalidates an app-private cube and packs it into the existing RGBA8 2D texture layout used
     * by [com.opencapture.openzcine.FeedEffectsRenderer]. Null is an unavailable/corrupt state;
     * Kotlin must not parse or sample the cube as a fallback.
     */
    external fun packImportedLut(utf8: ByteArray): ByteArray?

    /**
     * Resolves the shared `RedLUTDownloadPolicy` decision as a versioned `US`-separated record
     * `[version, state]`: 0 = available, 1 = camera AP, 2 = no internet. Kotlin only decodes that
     * record into UI copy; it does not duplicate the camera-AP precedence rule.
     */
    external fun redLutDownloadAvailability(
        hasInternetPath: Boolean,
        isOnCameraAccessPoint: Boolean,
    ): String?

    // ── Link health and preview policy (Swift owns the policy) ──

    /**
     * Resolves Android's persisted stream choices through the shared Swift
     * preview policy. The result is `imageSize<TAB>compression<TAB>intervalNanos`;
     * Kotlin stores/presents the choices but never maps them to Nikon bytes or
     * applies thermal caps itself. Null rejects an unknown wire value.
     *
     * This affects only the live-view JPEG preview. It never changes camera
     * recording format, codec, frame rate, or an active card write.
     */
    /**
     * @param recordingFrameRate Camera-advertised movie fps (e.g. 25 for 6K·25p).
     *   Pass 0 when unknown so Swift applies its default cadence.
     */
    external fun resolveLiveViewRequest(
        streamPreset: Int,
        qualityBias: Int,
        thermalTier: Int,
        isRecording: Boolean,
        cameraOverheating: Boolean,
        recordingFrameRate: Int,
    ): String?

    /**
     * Scores current Android link observations through `CameraLinkHealthScorer`
     * and the shared `LinkSignalBars` hysteresis filter. Optional floating
     * values use an explicit presence flag, so an unavailable transport
     * measurement is never fabricated as zero. Returns
     * `score<TAB>bars<TAB>detail`, or null for an invalid phase.
     */
    external fun linkHealthSnapshot(
        phase: Int,
        roundTripMilliseconds: Double,
        hasRoundTrip: Boolean,
        liveViewFps: Double,
        hasLiveViewFps: Boolean,
        targetLiveViewFps: Double,
        secondsSinceLastGoodFrame: Double,
        hasLastGoodFrame: Boolean,
        consecutiveBadFrames: Int,
        recentCommandFailures: Int,
        isRecoveringStream: Boolean,
        isUsbTransport: Boolean,
        resetSignalBars: Boolean,
    ): String?

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

    /** Bounded first readback burst after a camera session connects. */
    const val PROPERTY_REFRESH_BOOTSTRAP: Int = 0

    /** One low-rate round-robin property read. */
    const val PROPERTY_REFRESH_NEXT: Int = 1

    /** One debounced read requested by a camera `DevicePropChanged` event. */
    const val PROPERTY_REFRESH_EVENT: Int = 2

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

    /** `sessionApplyControl` completed and the camera accepted every write. */
    const val CONTROL_COMMAND_ACCEPTED: Int = 0

    /** No active facade session existed when `sessionApplyControl` ran. */
    const val CONTROL_COMMAND_NO_SESSION: Int = 1

    /** Camera media owns the command channel, so a control cannot change. */
    const val CONTROL_COMMAND_MEDIA_BUSY: Int = 2

    /** The typed control selector or its human-readable label was unsupported. */
    const val CONTROL_COMMAND_UNSUPPORTED: Int = 3

    /** The camera sent a non-OK response to a property write. */
    const val CONTROL_COMMAND_REJECTED: Int = 4

    /** The command channel failed before every requested write completed. */
    const val CONTROL_COMMAND_TRANSPORT_FAILED: Int = 5

    /** The write response was OK, but authoritative property readback did not match. */
    const val CONTROL_COMMAND_READBACK_MISMATCH: Int = 6

    /** A focus command completed and the camera accepted its operation sequence. */
    const val FOCUS_COMMAND_ACCEPTED: Int = 0

    /** No active facade session existed when the focus command ran. */
    const val FOCUS_COMMAND_NO_SESSION: Int = 1

    /** Camera media owns the command channel, so the focus point cannot change. */
    const val FOCUS_COMMAND_MEDIA_BUSY: Int = 2

    /** Authoritative camera focus dimensions, header state, or modes are unavailable. */
    const val FOCUS_COMMAND_UNAVAILABLE: Int = 3

    /** The camera sent a non-OK response to the focus operation sequence. */
    const val FOCUS_COMMAND_REJECTED: Int = 4

    /** The command channel failed before the focus operation sequence completed. */
    const val FOCUS_COMMAND_TRANSPORT_FAILED: Int = 5

    /**
     * Connects to the camera at [host] (numeric IPv4, port 15740): PTP-IP Init
     * handshake on both channels, then the Nikon sequence selected by
     * [connectionStrategy], all inside the Swift core's session layer.
     * [initiatorGuid] is the stable, exactly 16-byte identity paired to this
     * Android installation; it is never logged. Returns immediately; progress
     * and the terminal result arrive on [listener] from a background thread.
     * [connectionOwner] is an opaque, per-attempt token used only to ensure a
     * stale cancellation cannot tear down a newer session.
     */
    external fun sessionConnect(
        host: String,
        connectionOwner: Long,
        connectionStrategy: Int,
        initiatorGuid: ByteArray,
        listener: SessionListener,
    )

    /**
     * Connects over a claimed Android USB PTP interface. Kotlin supplies only
     * raw bulk/interrupt bytes through [transport]; Swift owns PTP container
     * framing, session open/pair/identify strategy, and all camera operations.
     * [connectionStrategy] uses the same stable ordinal as the Wi-Fi path;
     * USB has no PTP-IP initiator GUID.
     * Progress and the terminal result arrive on [listener] from a background
     * thread, just like [sessionConnect]. [connectionOwner] scopes later
     * teardown to this exact connection attempt.
     */
    external fun sessionConnectUsb(
        transport: UsbPtpTransport,
        host: String,
        cameraNameHint: String,
        connectionOwner: Long,
        connectionStrategy: Int,
        listener: SessionListener,
    )

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
     * Latest successful serialized PTP command round-trip duration. Native
     * returns NaN before a transaction and after disconnect; callers expose
     * that sentinel as null rather than fabricating latency.
     */
    external fun sessionLatestRoundTripMilliseconds(): Double

    /**
     * Refreshes semantic Android camera state through the Swift core and
     * returns a flat semantic record consumed by `SwiftCoreCameraSession`. [request]
     * must be one of [PROPERTY_REFRESH_BOOTSTRAP], [PROPERTY_REFRESH_NEXT],
     * or [PROPERTY_REFRESH_EVENT]. [recording] informs the core's shared
     * low-rate poll policy. [propertyCode] is only a raw value forwarded from
     * an existing `DevicePropChanged` event; Kotlin never creates or decodes a
     * Nikon property identifier. Null is reserved for an unavailable native
     * bridge; non-null results always include a typed semantic status.
     *
     * Blocking — call from a background dispatcher.
     */
    external fun sessionRefreshPropertySnapshot(
        request: Int,
        recording: Boolean,
        propertyCode: Long,
    ): String?

    /**
     * Configures the next Android live-view run with a Swift-policy-approved
     * preview request. It writes only Nikon live-view JPEG properties and the
     * preview-pull cadence; it cannot change recording settings. Call before
     * [sessionStartLiveView] on an IO dispatcher. Returns false when no active
     * session accepts the request.
     */
    external fun sessionConfigureLiveView(
        imageSize: Int,
        compression: Int,
        frameIntervalNanoseconds: Long,
    ): Boolean

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
     * Applies one typed camera control selection on the active session. [control]
     * is a stable semantic selector owned by [CameraControl]; [label] is the
     * operator-facing selection such as `"5600K"` or `"AF-C"`. Swift owns all
     * Nikon property identifiers, payload bytes, Kelvin multi-write behavior,
     * and standard-versus-extended PTP operation selection. Blocking — call
     * from a background dispatcher.
     *
     * Returns one of [CONTROL_COMMAND_ACCEPTED],
     * [CONTROL_COMMAND_NO_SESSION], [CONTROL_COMMAND_MEDIA_BUSY],
     * [CONTROL_COMMAND_UNSUPPORTED], [CONTROL_COMMAND_REJECTED], or
     * [CONTROL_COMMAND_TRANSPORT_FAILED].
     */
    external fun sessionApplyControl(control: Int, label: String): Int

    /**
     * Moves the AF area to semantic camera-space [x]/[y] coordinates. Swift
     * owns the Nikon operation, its two UINT32 parameters, transaction ID, and
     * PTP-IP/USB framing. Blocking; call from an IO dispatcher.
     */
    external fun sessionChangeAfArea(x: Int, y: Int): Int

    /**
     * Recentres the AF area from current camera headers and focus properties,
     * including the shared subject-tracking release/restore policy. Blocking;
     * call from an IO dispatcher.
     */
    external fun sessionResetFocusPoint(): Int

    /**
     * Gracefully tears down the active session: best-effort `CloseSession` so
     * the camera frees its connection slot, then both sockets. Blocking
     * (bounded ~2 s) — call from a background dispatcher. A running live-view
     * pump is stopped first (`EndLiveView` before `CloseSession`). The opaque
     * [connectionOwner] means an old cancelled attempt cannot disconnect a
     * newer retry. Safe when idle or when the owner is no longer active.
     */
    external fun sessionDisconnect(connectionOwner: Long)

    /** Receives live-view frames pushed from Swift (the facade's pump thread). */
    interface LiveFrameListener {
        /**
         * One live-view JPEG, freshly pulled from the camera. [timestampNanos]
         * is `CLOCK_MONOTONIC` at delivery — the same clock as
         * `System.nanoTime()`. [isRecording] is the camera-authoritative
         * record flag decoded from the same live-view header. The four dBFS
         * values are resolved by the shared Swift core from that header's
         * sound indicator; [hasAudioLevels] is false when the body omitted it.
         */
        fun onFrame(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double = -60.0,
            leftPeakDb: Double = -60.0,
            rightLevelDb: Double = -60.0,
            rightPeakDb: Double = -60.0,
            hasAudioLevels: Boolean = false,
        )

        /**
         * Additive rich live-frame callback. The Swift facade prefers this
         * descriptor when it exists, while retaining [onFrame]'s established
         * descriptor as a safe fallback for older listeners.
         *
         * Focus coordinates and virtual-horizon angles were parsed and
         * normalized by the Swift core. [focusBoxes] is a flat sequence of
         * `[centerX, centerY, width, height]`; [hasFocus] and [hasLevel]
         * distinguish unavailable camera metadata from a valid zero value.
         */
        fun onFrameWithMetadata(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double,
            leftPeakDb: Double,
            rightLevelDb: Double,
            rightPeakDb: Double,
            hasAudioLevels: Boolean,
            hasFocus: Boolean,
            focusCoordinateWidth: Int,
            focusCoordinateHeight: Int,
            focusResult: Int,
            subjectDetectionActive: Boolean,
            trackingAFActive: Boolean,
            selectedBoxIndex: Int,
            focusBoxes: IntArray,
            hasLevel: Boolean,
            levelRollDegrees: Double,
            levelPitchDegrees: Double,
            levelYawDegrees: Double,
        ) {
            onFrame(
                jpeg = jpeg,
                timestampNanos = timestampNanos,
                isRecording = isRecording,
                leftLevelDb = leftLevelDb,
                leftPeakDb = leftPeakDb,
                rightLevelDb = rightLevelDb,
                rightPeakDb = rightPeakDb,
                hasAudioLevels = hasAudioLevels,
            )
        }

        /**
         * Newest additive live-frame callback. Camera timecode is decoded by
         * Swift from the same header as image/focus/level metadata. The
         * facade falls back to [onFrameWithMetadata] or [onFrame] when this
         * descriptor is absent, preserving the established JNI boundary.
         */
        fun onFrameWithFullMetadata(
            jpeg: ByteArray,
            timestampNanos: Long,
            isRecording: Boolean,
            leftLevelDb: Double,
            leftPeakDb: Double,
            rightLevelDb: Double,
            rightPeakDb: Double,
            hasAudioLevels: Boolean,
            hasFocus: Boolean,
            focusCoordinateWidth: Int,
            focusCoordinateHeight: Int,
            focusResult: Int,
            subjectDetectionActive: Boolean,
            trackingAFActive: Boolean,
            selectedBoxIndex: Int,
            focusBoxes: IntArray,
            hasLevel: Boolean,
            levelRollDegrees: Double,
            levelPitchDegrees: Double,
            levelYawDegrees: Double,
            timecodeOn: Boolean,
            timecodeHour: Int,
            timecodeMinute: Int,
            timecodeSecond: Int,
            timecodeFrame: Int,
        ) {
            onFrameWithMetadata(
                jpeg = jpeg,
                timestampNanos = timestampNanos,
                isRecording = isRecording,
                leftLevelDb = leftLevelDb,
                leftPeakDb = leftPeakDb,
                rightLevelDb = rightLevelDb,
                rightPeakDb = rightPeakDb,
                hasAudioLevels = hasAudioLevels,
                hasFocus = hasFocus,
                focusCoordinateWidth = focusCoordinateWidth,
                focusCoordinateHeight = focusCoordinateHeight,
                focusResult = focusResult,
                subjectDetectionActive = subjectDetectionActive,
                trackingAFActive = trackingAFActive,
                selectedBoxIndex = selectedBoxIndex,
                focusBoxes = focusBoxes,
                hasLevel = hasLevel,
                levelRollDegrees = levelRollDegrees,
                levelPitchDegrees = levelPitchDegrees,
                levelYawDegrees = levelYawDegrees,
            )
        }

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
     * Refreshes card capacity before claiming media ownership, snapshots object
     * handles across every usable camera card, and returns one versioned
     * cursor/readback record. A newer call invalidates the prior cursor before
     * taking its snapshot. Null means no session is active or the snapshot
     * failed. Blocking; call from a background dispatcher.
     */
    external fun sessionBeginMediaBrowse(): String?

    /**
     * Advances [cursor] by at most [maxObjects] ObjectInfo transactions and
     * returns one versioned `MediaBrowsePageWire`, or null when invalidated,
     * cancelled, or failed. Blocking; call from a background dispatcher.
     */
    external fun sessionNextMediaBrowsePage(cursor: Long, maxObjects: Int): String?

    /** Cancels one opaque media cursor. Safe after its final page. */
    external fun sessionCancelMediaBrowse(cursor: Long)

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
