// JNI facade over OpenZCineCore for the Android app.
//
// Hand-written `@_cdecl` shims (not swift-java/jextract — see
// docs/investigations/android-core-feasibility.md, Phase 1 note) matching the
// `external fun` declarations in
// Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/bridge/SwiftCore.kt.
// Coarse boundary rules apply: strings/byte arrays and primitives only.
//
// This file compiles empty on Darwin so `just native-check` is unaffected.
#if os(Android)

    import CJNI
    import Foundation
    import OpenZCineCore

    // MARK: - JNI plumbing

    /// Returns the JNI function table for an env handle.
    ///
    /// SAFETY: The JVM always passes a non-nil env with a fully populated
    /// function table to native methods (JNI spec); the same guarantee applies to
    /// every function-pointer slot force-unwrapped below.
    private func table(_ env: UnsafeMutablePointer<JNIEnv?>) -> JNINativeInterface {
        env.pointee!.pointee
    }

    /// Converts a Swift string to a JVM-owned `jstring` local reference.
    private func javaString(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: String
    ) -> jstring? {
        value.withCString { table(env).NewStringUTF!(env, $0) }
    }

    /// Copies a `jstring` into a Swift `String`.
    private func swiftString(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: jstring?
    ) -> String? {
        guard let value,
            let chars = table(env).GetStringUTFChars!(env, value, nil)
        else { return nil }
        defer { table(env).ReleaseStringUTFChars!(env, value, chars) }
        return String(cString: chars)
    }

    /// Copies a `jbyteArray` into a Swift `[UInt8]`.
    private func swiftBytes(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ value: jbyteArray?
    ) -> [UInt8]? {
        guard let value else { return nil }
        let fns = table(env)
        let length = Int(fns.GetArrayLength!(env, value))
        guard length > 0 else { return [] }
        var out = [UInt8](repeating: 0, count: length)
        out.withUnsafeMutableBytes { raw in
            fns.GetByteArrayRegion!(
                env, value, 0, jsize(length),
                raw.baseAddress?.assumingMemoryBound(to: jbyte.self))
        }
        return out
    }

    /// Copies a Swift byte buffer into a new JVM `byte[]` local reference.
    private func javaByteArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ bytes: [UInt8]
    ) -> jbyteArray? {
        let fns = table(env)
        guard let array = fns.NewByteArray!(env, jsize(bytes.count)) else { return nil }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            fns.SetByteArrayRegion!(
                env, array, 0, jsize(bytes.count), base.assumingMemoryBound(to: jbyte.self))
        }
        return array
    }

    /// Copies unsigned PTP values (represented losslessly as signed Int64s)
    /// into a JVM-owned `long[]` local reference.
    private func javaLongArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ values: [Int64]
    ) -> jlongArray? {
        let fns = table(env)
        guard let array = fns.NewLongArray!(env, jsize(values.count)) else { return nil }
        values.withUnsafeBufferPointer { buffer in
            fns.SetLongArrayRegion!(env, array, 0, jsize(values.count), buffer.baseAddress)
        }
        return array
    }

    /// Copies a Swift float buffer into a new JVM `float[]` local reference.
    private func javaFloatArray(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ values: [Float]
    ) -> jfloatArray? {
        let fns = table(env)
        guard let array = fns.NewFloatArray!(env, jsize(values.count)) else { return nil }
        values.withUnsafeBufferPointer { buffer in
            fns.SetFloatArrayRegion!(env, array, 0, jsize(values.count), buffer.baseAddress)
        }
        return array
    }

    /// Closes a Kotlin-owned raw USB transport before a Swift handle exists.
    ///
    /// `sessionConnectUsb` receives an already-claimed Android interface. If
    /// constructing its global JNI handle fails, no Swift session will reach
    /// the normal disconnect path, so release that platform resource directly
    /// instead of leaving the camera interface claimed until process exit.
    private func closeKotlinUSBTransport(
        _ env: UnsafeMutablePointer<JNIEnv?>, _ transport: jobject?
    ) {
        guard let transport else { return }
        let fns = table(env)
        guard let type = fns.GetObjectClass!(env, transport) else { return }
        defer { fns.DeleteLocalRef!(env, type) }
        guard let close = fns.GetMethodID!(env, type, "close", "()V") else { return }
        var arguments = jvalue()
        fns.CallVoidMethodA!(env, transport, close, &arguments)
    }

    // MARK: - Info

    /// `SwiftCore.coreVersion(): String` — proves the Swift core is alive in-process.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_coreVersion")
    public func swiftCoreVersion(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) -> jstring? {
        #if arch(arm64)
            let arch = "arm64"
        #elseif arch(x86_64)
            let arch = "x86_64"
        #else
            let arch = "unknown"
        #endif
        return javaString(env, "OpenZCineCore swift-android/\(arch)")
    }

    // MARK: - Protocol logic

    /// `SwiftCore.deriveAccessPointSSID(cameraName): String?` — real core call:
    /// PTP friendly name `ZR_6001234` → camera-AP SSID `NIKON_ZR_01234`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_deriveAccessPointSSID")
    public func swiftCoreDeriveAccessPointSSID(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, cameraName: jstring?
    ) -> jstring? {
        guard let name = swiftString(env, cameraName),
            let ssid = CameraWiFiSSID.deriveSSID(fromCameraName: name)
        else { return nil }
        return javaString(env, ssid)
    }

    /// `SwiftCore.parseCameraWifiScreen(transcript): String?` — sends one
    /// ephemeral ML Kit transcript through the shared camera-screen policy.
    /// Kotlin receives only a validated `SSID<US>key` wire value, never a local
    /// reimplementation of the Nikon OCR correction rules.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_parseCameraWifiScreen")
    public func swiftCoreParseCameraWifiScreen(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, transcript: jstring?
    ) -> jstring? {
        guard let transcript = swiftString(env, transcript), !transcript.isEmpty,
            let parsed = AndroidCameraWiFiScreenParserWire.parse(transcript)
        else { return nil }
        return javaString(env, parsed)
    }

    /// `SwiftCore.resolveDisplayName(rawName): String` — operator-facing device
    /// title from the raw PTP name (`ZR_6001234` → `Nikon ZR`).
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_resolveDisplayName")
    public func swiftCoreResolveDisplayName(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, rawName: jstring?
    ) -> jstring? {
        let name = swiftString(env, rawName) ?? ""
        let display = ConnectionProgressCopy.resolveDisplayName(
            rawName: name, savedCamera: nil)
        return javaString(env, display)
    }

    // MARK: - Frame.io OAuth + request policy

    /// `SwiftCore.frameioBeginAuthorization(clientID, redirectURI): String?`
    /// — starts a shared-core PKCE transaction. The JSON wire can contain a
    /// verifier and must remain process-local; Kotlin must never log it.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_frameioBeginAuthorization")
    public func swiftCoreFrameioBeginAuthorization(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, clientID: jstring?,
        redirectURI: jstring?
    ) -> jstring? {
        guard
            let clientID = swiftString(env, clientID),
            let redirectURI = swiftString(env, redirectURI),
            let payload = AndroidFrameioWire.beginAuthorization(
                clientID: clientID, redirectURI: redirectURI)
        else { return nil }
        return javaString(env, payload)
    }

    /// `SwiftCore.frameioParseRedirect(redirectURI, callbackURI, expectedState): String?`
    /// — validates exact redirect identity plus OAuth state, returning only a
    /// code. Error details and code values are deliberately not logged here.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_frameioParseRedirect")
    public func swiftCoreFrameioParseRedirect(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, redirectURI: jstring?,
        callbackURI: jstring?, expectedState: jstring?
    ) -> jstring? {
        guard
            let redirectURI = swiftString(env, redirectURI),
            let callbackURI = swiftString(env, callbackURI),
            let expectedState = swiftString(env, expectedState),
            let code = AndroidFrameioWire.parseRedirect(
                redirectURI: redirectURI, callbackURI: callbackURI, expectedState: expectedState)
        else { return nil }
        return javaString(env, code)
    }

    /// `SwiftCore.frameioTokenRequest(...)` — builds the shared Adobe IMS form
    /// request for the Android HTTPS adapter. The returned form can contain an
    /// auth code or refresh token and must never be logged.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_frameioTokenRequest")
    public func swiftCoreFrameioTokenRequest(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, kind: jstring?, clientID: jstring?,
        redirectURI: jstring?, code: jstring?, verifier: jstring?, refreshToken: jstring?
    ) -> jstring? {
        guard
            let kind = swiftString(env, kind),
            let clientID = swiftString(env, clientID),
            let redirectURI = swiftString(env, redirectURI),
            let payload = AndroidFrameioWire.tokenRequest(
                kind: kind, clientID: clientID, redirectURI: redirectURI,
                code: swiftString(env, code), verifier: swiftString(env, verifier),
                refreshToken: swiftString(env, refreshToken))
        else { return nil }
        return javaString(env, payload)
    }

    /// `SwiftCore.frameioAPIRequest(...)` — plans one portable V4 endpoint and
    /// JSON body. Kotlin attaches an encrypted stored bearer token and performs
    /// HTTPS; endpoint / request-model policy stays in Swift.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_frameioAPIRequest")
    public func swiftCoreFrameioAPIRequest(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, operation: jstring?,
        accountID: jstring?,
        workspaceID: jstring?, folderID: jstring?, fileID: jstring?, name: jstring?, fileSize: jlong
    ) -> jstring? {
        guard
            let operation = swiftString(env, operation),
            let payload = AndroidFrameioWire.apiRequest(
                operation: operation,
                accountID: swiftString(env, accountID), workspaceID: swiftString(env, workspaceID),
                folderID: swiftString(env, folderID), fileID: swiftString(env, fileID),
                name: swiftString(env, name), fileSize: Int64(fileSize))
        else { return nil }
        return javaString(env, payload)
    }

    /// `SwiftCore.frameioDecodeResponse(operation, response): String?` —
    /// decodes API JSON through the shared Codable models before Kotlin uses it
    /// for presentation. The raw response is never logged at the bridge.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_frameioDecodeResponse")
    public func swiftCoreFrameioDecodeResponse(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, operation: jstring?,
        response: jstring?
    ) -> jstring? {
        guard
            let operation = swiftString(env, operation),
            let response = swiftString(env, response),
            let decoded = AndroidFrameioWire.decodedResponse(
                operation: operation, response: response)
        else { return nil }
        return javaString(env, decoded)
    }

    /// `SwiftCore.frameioMediaTypeForFilename(filename): String` — asks the
    /// shared core for the upload MIME family instead of inferring it in Kotlin.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_frameioMediaTypeForFilename")
    public func swiftCoreFrameioMediaTypeForFilename(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, filename: jstring?
    ) -> jstring? {
        let filename = swiftString(env, filename) ?? ""
        return javaString(env, AndroidFrameioWire.mediaType(forFilename: filename))
    }

    // MARK: - Monitor layout

    /// `SwiftCore.monitorZoneMap(...): FloatArray` — the shared core's
    /// `MonitorZoneLayout.map` flattened per `MonitorZoneMapWire` (records of
    /// `[kind, style, x, y, width, height]`). The Compose shell consumes the
    /// same zone frames the iOS shell does; no layout math lives in Kotlin.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_monitorZoneMap")
    public func swiftCoreMonitorZoneMap(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        viewportWidth: jfloat, viewportHeight: jfloat,
        safeTop: jfloat, safeLeading: jfloat, safeBottom: jfloat, safeTrailing: jfloat,
        mode: jint, isPortrait: jboolean, aspectFill: jboolean,
        scopeCount: jint, mirrored: jboolean, bottomBarHeight: jfloat
    ) -> jfloatArray? {
        let flat = MonitorZoneMapWire.flattened(
            viewportWidth: Double(viewportWidth),
            viewportHeight: Double(viewportHeight),
            safeTop: Double(safeTop),
            safeLeading: Double(safeLeading),
            safeBottom: Double(safeBottom),
            safeTrailing: Double(safeTrailing),
            mode: Int(mode),
            isPortrait: isPortrait != 0,
            aspectFill: aspectFill != 0,
            scopeCount: Int(scopeCount),
            mirrored: mirrored != 0,
            bottomBarHeight: Double(bottomBarHeight)
        )
        let fns = table(env)
        guard let array = fns.NewFloatArray!(env, jsize(flat.count)) else { return nil }
        flat.withUnsafeBufferPointer { buffer in
            fns.SetFloatArrayRegion!(env, array, 0, jsize(flat.count), buffer.baseAddress)
        }
        return array
    }

    // MARK: - Scopes

    /// `SwiftCore.scopeAnchors(curve): FloatArray` — fixed axis anchors and
    /// vectorscope graticule targets per `ScopeFrameWire.anchors`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_scopeAnchors")
    public func swiftCoreScopeAnchors(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, curve: jint
    ) -> jfloatArray? {
        javaFloatArray(env, ScopeFrameWire.anchors(curveOrdinal: Int(curve)))
    }

    /// `SwiftCore.scopeTraces(rgba, width, height, bytesPerRow, curve, compensation): FloatArray`
    /// — one scope tick's waveform/parade/histogram payload plus the additive
    /// Swift-owned Traffic Lights trailer described by `ScopeFrameWire.traces`.
    /// `compensation` is a persisted core enum raw value; Swift decodes and
    /// applies it while Kotlin stays presentation-only. The trailer is
    /// versioned so malformed data fails closed in Kotlin. Blocking; Kotlin
    /// calls it off the main thread.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_scopeTraces")
    public func swiftCoreScopeTraces(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, rgba: jbyteArray?,
        width: jint, height: jint, bytesPerRow: jint, curve: jint, compensation: jint
    ) -> jfloatArray? {
        guard let buffer = swiftBytes(env, rgba) else { return nil }
        return javaFloatArray(
            env,
            ScopeFrameWire.traces(
                rgba: buffer, width: Int(width), height: Int(height),
                bytesPerRow: Int(bytesPerRow), curveOrdinal: Int(curve),
                crushClipCompensationRaw: Int(compensation)))
    }

    /// `SwiftCore.scopeVector(rgba, width, height, bytesPerRow, curve): ByteArray`
    /// — one scope tick's 128×128 premultiplied-RGBA vectorscope density image
    /// per `ScopeFrameWire.vectorPixels`. Empty for a frame with no samples.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_scopeVector")
    public func swiftCoreScopeVector(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, rgba: jbyteArray?,
        width: jint, height: jint, bytesPerRow: jint, curve: jint
    ) -> jbyteArray? {
        guard let buffer = swiftBytes(env, rgba) else { return nil }
        return javaByteArray(
            env,
            ScopeFrameWire.vectorPixels(
                rgba: buffer, width: Int(width), height: Int(height),
                bytesPerRow: Int(bytesPerRow), curveOrdinal: Int(curve)))
    }

    // MARK: - Feed effects (baked in the core, uploaded by Kotlin)

    /// `SwiftCore.bakeLut(lookOrdinal, size): ByteArray?` — a built-in monitor
    /// look baked by the core into the packed-2D RGBA8 grid described in
    /// `FeedEffectsWire`. Null for unknown ordinals/sizes.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_bakeLut")
    public func swiftCoreBakeLut(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, lookOrdinal: jint, size: jint
    ) -> jbyteArray? {
        guard
            let bytes = FeedEffectsWire.bakedLUT(
                lookOrdinal: Int(lookOrdinal), size: Int(size))
        else { return nil }
        return javaByteArray(env, bytes)
    }

    /// `SwiftCore.bakeFalseColorCube(scaleOrdinal, curveOrdinal): ByteArray?` —
    /// the core's false-colour cube (64³) in the same packed-2D RGBA8 grid.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_bakeFalseColorCube")
    public func swiftCoreBakeFalseColorCube(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, scaleOrdinal: jint,
        curveOrdinal: jint
    ) -> jbyteArray? {
        guard
            let bytes = FeedEffectsWire.bakedFalseColor(
                scaleOrdinal: Int(scaleOrdinal), curveOrdinal: Int(curveOrdinal))
        else { return nil }
        return javaByteArray(env, bytes)
    }

    /// `SwiftCore.feedEffectsScalars(curveOrdinal, zebraHighlightIre, zebraMidtoneIre):
    /// FloatArray?` — `[deLogBlack, deLogClip, zebraHighlight, zebraMidtoneCentre]`
    /// on the normalized 0–1 code axis (see `FeedEffectsWire.scalars`).
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_feedEffectsScalars")
    public func swiftCoreFeedEffectsScalars(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, curveOrdinal: jint,
        zebraHighlightIre: jfloat, zebraMidtoneIre: jfloat
    ) -> jfloatArray? {
        guard
            let values = FeedEffectsWire.scalars(
                curveOrdinal: Int(curveOrdinal),
                zebraHighlightIRE: Double(zebraHighlightIre),
                zebraMidtoneIRE: Double(zebraMidtoneIre))
        else { return nil }
        return javaFloatArray(env, values)
    }

    // MARK: - Callback / streaming shape

    /// Listener state that crosses to the pushing thread.
    ///
    /// The raw pointers are a JNI global reference, a process-wide `jmethodID`,
    /// and the process-wide `JavaVM*` — all explicitly valid across threads per
    /// the JNI spec, hence `@unchecked Sendable`.
    private struct ListenerHandle: @unchecked Sendable {
        let vm: UnsafeMutablePointer<JavaVM?>
        let listener: jobject
        let method: jmethodID
    }

    /// `SwiftCore.startConnectionDemo(listener)` — registers a Kotlin listener and
    /// pushes a canned connection-phase sequence from a Swift background thread.
    /// Proves the callback/streaming pattern (attach thread → upcall → detach)
    /// that session events and live-view frames will use.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_startConnectionDemo")
    public func swiftCoreStartConnectionDemo(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, listener: jobject?
    ) {
        let fns = table(env)
        var vm: UnsafeMutablePointer<JavaVM?>?
        guard fns.GetJavaVM!(env, &vm) == JNI_OK, let vm else { return }
        guard let listener, let global = fns.NewGlobalRef!(env, listener) else { return }
        guard let cls = fns.GetObjectClass!(env, global),
            let method = fns.GetMethodID!(
                env, cls, "onPhase", "(Ljava/lang/String;Ljava/lang/String;)V")
        else {
            fns.DeleteGlobalRef!(env, global)
            return
        }

        let handle = ListenerHandle(vm: vm, listener: global, method: method)
        Thread.detachNewThread { pushDemoPhases(handle) }
    }

    // MARK: - Camera session (PTP-IP)

    /// Kotlin-side listener for `sessionConnect`, resolved to global refs +
    /// method IDs so the connect thread can push into it.
    ///
    /// The raw pointers are a JNI global reference, process-wide `jmethodID`s,
    /// and the process-wide `JavaVM*` — all valid across threads per the JNI
    /// spec, hence `@unchecked Sendable`.
    private struct SessionListenerHandle: @unchecked Sendable {
        let vm: UnsafeMutablePointer<JavaVM?>
        let listener: jobject
        let onPhase: jmethodID
        let onConnected: jmethodID
        let onFailed: jmethodID
    }

    /// Kotlin-side listener for one active session's PTP-IP event stream.
    /// The global reference and method IDs remain valid on the Swift-owned
    /// event reader thread until its single terminal callback releases them.
    private struct SessionEventListenerHandle: @unchecked Sendable {
        let vm: UnsafeMutablePointer<JavaVM?>
        let listener: jobject
        let onEvent: jmethodID
        let onEnded: jmethodID
    }

    /// Process-wide active session slot behind the coarse JNI facade: one
    /// camera at a time, matching the app's single-camera model. Every native
    /// connect attempt carries a Kotlin-generated owner token, so a delayed
    /// cancellation can release only its own pending/active resources.
    private final class ActiveSessionSlot: @unchecked Sendable {
        private struct ActiveConnection {
            let owner: Int64
            let session: PTPIPClientSession
        }

        private struct PendingUSBConnection {
            let owner: Int64
            let transport: AndroidUSBPTPTransport
        }

        static let shared = ActiveSessionSlot()
        private let lock = NSLock()
        private var active: ActiveConnection?
        /// The newest request allowed to publish a session. A stale Wi-Fi
        /// connect can finish its socket handshake, but it cannot displace a
        /// newer request after this owner changes or is cancelled.
        private var pendingOwner: Int64?
        /// A claimed USB interface while its Swift connection thread is still
        /// handshaking. It is owned by [pendingOwner], not by a process-global
        /// cancellation call.
        private var pendingUSB: PendingUSBConnection?

        /// Begins a connection attempt and returns only a superseded pending
        /// USB transport. The current active session remains usable until a
        /// newer attempt succeeds, matching the prior reconnect behavior.
        func beginConnection(
            owner: Int64,
            usbTransport: AndroidUSBPTPTransport? = nil
        ) -> AndroidUSBPTPTransport? {
            lock.lock()
            defer { lock.unlock() }
            let supersededUSB = pendingUSB?.transport
            pendingOwner = owner
            pendingUSB = usbTransport.map { PendingUSBConnection(owner: owner, transport: $0) }
            return supersededUSB
        }

        func current() -> PTPIPClientSession? {
            lock.lock()
            defer { lock.unlock() }
            return active?.session
        }

        /// Promotes exactly the still-current connection request into the
        /// active slot. A rejected completion must disconnect its local session
        /// without publishing a late Kotlin success callback.
        func completeConnection(
            owner: Int64,
            session new: PTPIPClientSession
        ) -> (accepted: Bool, displacedSession: PTPIPClientSession?) {
            lock.lock()
            defer { lock.unlock() }
            guard pendingOwner == owner else { return (false, nil) }
            pendingOwner = nil
            if pendingUSB?.owner == owner {
                pendingUSB = nil
            }
            let displaced = active?.session
            active = ActiveConnection(owner: owner, session: new)
            return (true, displaced)
        }

        /// Clears one failed/cancelled pending request and returns its claimed
        /// USB interface, if any, for teardown outside the slot lock.
        func clearPendingConnection(owner: Int64) -> AndroidUSBPTPTransport? {
            lock.lock()
            defer { lock.unlock() }
            guard pendingOwner == owner else { return nil }
            pendingOwner = nil
            guard pendingUSB?.owner == owner else { return nil }
            let transport = pendingUSB?.transport
            pendingUSB = nil
            return transport
        }

        /// Atomically takes only [owner]'s resources. This is the key boundary
        /// that prevents cleanup for a cancelled attempt A from closing retry
        /// B when Kotlin exposes an immediate retry affordance.
        func takeOwnedConnection(owner: Int64) -> (
            session: PTPIPClientSession?, pendingUSBTransport: AndroidUSBPTPTransport?
        ) {
            lock.lock()
            defer { lock.unlock() }
            let removedSession: PTPIPClientSession?
            if active?.owner == owner {
                removedSession = active?.session
                active = nil
            } else {
                removedSession = nil
            }
            let removedUSB: AndroidUSBPTPTransport?
            if pendingOwner == owner {
                pendingOwner = nil
                if pendingUSB?.owner == owner {
                    removedUSB = pendingUSB?.transport
                    pendingUSB = nil
                } else {
                    removedUSB = nil
                }
            } else {
                removedUSB = nil
            }
            return (removedSession, removedUSB)
        }
    }

    /// `SwiftCore.sessionConnect(host, connectionOwner, listener)` — async connect: PTP-IP Init
    /// handshake + Nikon open/pair/identify on a Swift background thread, with
    /// phases pushed to the listener (`onPhase`), ending in `onConnected` or
    /// `onFailed`. The established session parks in the process-wide slot for
    /// `sessionReadProperty` / `sessionDisconnect`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionConnect")
    public func swiftCoreSessionConnect(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, host: jstring?, owner: jlong,
        listener: jobject?
    ) {
        let fns = table(env)
        var vm: UnsafeMutablePointer<JavaVM?>?
        guard fns.GetJavaVM!(env, &vm) == JNI_OK, let vm else { return }
        guard let listener, let global = fns.NewGlobalRef!(env, listener) else { return }
        guard let cls = fns.GetObjectClass!(env, global),
            let onPhase = fns.GetMethodID!(
                env, cls, "onPhase", "(Ljava/lang/String;Ljava/lang/String;)V"),
            let onConnected = fns.GetMethodID!(
                env, cls, "onConnected",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
            let onFailed = fns.GetMethodID!(env, cls, "onFailed", "(Ljava/lang/String;)V")
        else {
            fns.DeleteGlobalRef!(env, global)
            return
        }
        let handle = SessionListenerHandle(
            vm: vm, listener: global, onPhase: onPhase, onConnected: onConnected,
            onFailed: onFailed)
        let hostString = swiftString(env, host) ?? ""
        let connectionOwner = Int64(owner)
        ActiveSessionSlot.shared.beginConnection(owner: connectionOwner)?.close()
        Thread.detachNewThread {
            runSessionConnect(handle, host: hostString, owner: connectionOwner)
        }
    }

    /// `SwiftCore.sessionConnectUsb(transport, host, cameraNameHint, connectionOwner, listener)`
    /// — async USB PTP connect. Kotlin retains Android USB ownership and
    /// provides raw endpoint I/O only; the Swift facade frames generic PTP
    /// containers, performs the same open/pair/identify sequence as Wi-Fi,
    /// and retains the raw transport for the active session lifetime.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionConnectUsb")
    public func swiftCoreSessionConnectUsb(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, transport: jobject?,
        host: jstring?, cameraNameHint: jstring?, owner: jlong, listener: jobject?
    ) {
        let fns = table(env)
        var vm: UnsafeMutablePointer<JavaVM?>?
        guard fns.GetJavaVM!(env, &vm) == JNI_OK, let vm else {
            closeKotlinUSBTransport(env, transport)
            return
        }
        guard let listener, let global = fns.NewGlobalRef!(env, listener) else {
            closeKotlinUSBTransport(env, transport)
            return
        }
        guard let cls = fns.GetObjectClass!(env, global),
            let onPhase = fns.GetMethodID!(
                env, cls, "onPhase", "(Ljava/lang/String;Ljava/lang/String;)V"),
            let onConnected = fns.GetMethodID!(
                env, cls, "onConnected",
                "(Ljava/lang/String;Ljava/lang/String;Ljava/lang/String;)V"),
            let onFailed = fns.GetMethodID!(env, cls, "onFailed", "(Ljava/lang/String;)V")
        else {
            fns.DeleteGlobalRef!(env, global)
            closeKotlinUSBTransport(env, transport)
            return
        }
        let listenerHandle = SessionListenerHandle(
            vm: vm, listener: global, onPhase: onPhase, onConnected: onConnected,
            onFailed: onFailed)
        guard let transportHandle = JNIUSBPTPTransportHandle(env: env, transport: transport) else {
            closeKotlinUSBTransport(env, transport)
            let message = javaString(env, "Android could not initialize the USB camera transport.")
            var arguments = [jvalue(l: message)]
            fns.CallVoidMethodA!(env, global, onFailed, &arguments)
            if let message { fns.DeleteLocalRef!(env, message) }
            fns.DeleteGlobalRef!(env, global)
            return
        }
        let hostString = swiftString(env, host) ?? ""
        let cameraName = swiftString(env, cameraNameHint) ?? ""
        let facadeTransport = AndroidUSBPTPTransport(rawIO: transportHandle)
        let connectionOwner = Int64(owner)
        ActiveSessionSlot.shared.beginConnection(
            owner: connectionOwner,
            usbTransport: facadeTransport
        )?.close()
        Thread.detachNewThread {
            runUSBSessionConnect(
                listenerHandle,
                transport: facadeTransport,
                host: hostString,
                cameraNameHint: cameraName,
                owner: connectionOwner
            )
        }
    }

    /// Connect-thread body: attaches to the JVM, drives the blocking session
    /// establishment, and pushes phases/terminal callbacks to the listener.
    private func runSessionConnect(
        _ handle: SessionListenerHandle,
        host: String,
        owner: Int64
    ) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else {
            ActiveSessionSlot.shared.clearPendingConnection(owner: owner)?.close()
            return
        }
        defer { _ = invoke.DetachCurrentThread!(handle.vm) }
        let fns = table(env)
        defer { fns.DeleteGlobalRef!(env, handle.listener) }

        func callStrings(_ method: jmethodID, _ values: [String]) {
            let jValues = values.map { javaString(env, $0) }
            var args = jValues.map { jvalue(l: $0) }
            fns.CallVoidMethodA!(env, handle.listener, method, &args)
            for value in jValues where value != nil {
                fns.DeleteLocalRef!(env, value)
            }
        }

        do {
            let session = try PTPIPClientSession.connect(host: host) { phase, detail in
                callStrings(handle.onPhase, [String(describing: phase), detail])
            }
            let completion = ActiveSessionSlot.shared.completeConnection(
                owner: owner,
                session: session
            )
            guard completion.accepted else {
                // A cancellation or newer request won the race. Release this
                // local session without publishing a stale Kotlin success.
                session.disconnect()
                return
            }
            completion.displacedSession?.disconnect()
            callStrings(
                handle.onConnected,
                [
                    session.identity.displayName, session.identity.model,
                    session.identity.serialNumber,
                ])
        } catch {
            ActiveSessionSlot.shared.clearPendingConnection(owner: owner)?.close()
            callStrings(handle.onFailed, [error.localizedDescription])
        }
    }

    /// Connect-thread body for a platform-claimed USB interface. This mirrors
    /// `runSessionConnect` exactly so JNI listener ownership and terminal
    /// cleanup remain identical across Wi-Fi and USB sessions.
    private func runUSBSessionConnect(
        _ handle: SessionListenerHandle,
        transport: AndroidUSBPTPTransport,
        host: String,
        cameraNameHint: String,
        owner: Int64
    ) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else {
            ActiveSessionSlot.shared.clearPendingConnection(owner: owner)?.close()
            transport.close()
            return
        }
        defer { _ = invoke.DetachCurrentThread!(handle.vm) }
        let fns = table(env)
        defer { fns.DeleteGlobalRef!(env, handle.listener) }

        func callStrings(_ method: jmethodID, _ values: [String]) {
            let jValues = values.map { javaString(env, $0) }
            var args = jValues.map { jvalue(l: $0) }
            fns.CallVoidMethodA!(env, handle.listener, method, &args)
            for value in jValues where value != nil {
                fns.DeleteLocalRef!(env, value)
            }
        }

        do {
            let session = try PTPIPClientSession.connectUSB(
                transport: transport,
                host: host,
                cameraNameHint: cameraNameHint,
                onPhase: { phase, detail in
                    callStrings(handle.onPhase, [String(describing: phase), detail])
                }
            )
            let completion = ActiveSessionSlot.shared.completeConnection(
                owner: owner,
                session: session
            )
            guard completion.accepted else {
                // `sessionDisconnect` or a newer USB request won the race.
                // Do not publish a late success into Kotlin.
                session.disconnect()
                return
            }
            completion.displacedSession?.disconnect()
            callStrings(
                handle.onConnected,
                [
                    session.identity.displayName, session.identity.model,
                    session.identity.serialNumber,
                ])
        } catch {
            ActiveSessionSlot.shared.clearPendingConnection(owner: owner)?.close()
            transport.close()
            callStrings(handle.onFailed, [error.localizedDescription])
        }
    }

    /// `SwiftCore.sessionReadProperty(code): String?` — reads one camera
    /// property through the active session, decoded by the core (battery →
    /// percent, others → raw hex). Null when disconnected or rejected.
    /// Blocking; Kotlin calls it from `Dispatchers.IO`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionReadProperty")
    public func swiftCoreSessionReadProperty(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, code: jint
    ) -> jstring? {
        guard let session = ActiveSessionSlot.shared.current(),
            let value = try? session.readPropertyDisplayValue(code: UInt32(bitPattern: code))
        else { return nil }
        return javaString(env, value)
    }

    /// `SwiftCore.sessionRefreshPropertySnapshot(request, recording, propertyCode): String?` —
    /// performs one bounded semantic Android monitor refresh. Kotlin supplies
    /// only a lifecycle selector, recording state, and a raw `DevicePropChanged`
    /// value that it already received; Swift owns the property-code allowlist,
    /// PTP reads, byte decoders, storage lookup, and semantic wire shape.
    /// Blocking; Kotlin invokes it from `Dispatchers.IO`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionRefreshPropertySnapshot")
    public func swiftCoreSessionRefreshPropertySnapshot(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, request: jint,
        recording: jboolean, propertyCode: jlong
    ) -> jstring? {
        guard let session = ActiveSessionSlot.shared.current() else {
            return javaString(
                env,
                AndroidCameraPropertyReadbackWire.encode(
                    AndroidCameraPropertyReadback(
                        result: .noSession, properties: PTPCameraPropertySnapshot(), storage: nil)))
        }

        let refreshRequest: AndroidCameraPropertyRefreshRequest
        switch request {
        case 0:
            refreshRequest = .bootstrap
        case 1:
            refreshRequest = .next(isRecording: recording != 0)
        case 2:
            guard propertyCode >= 0, propertyCode <= jlong(UInt32.max) else {
                return javaString(
                    env,
                    AndroidCameraPropertyReadbackWire.encode(
                        AndroidCameraPropertyReadback(
                            result: .unsupported, properties: PTPCameraPropertySnapshot(),
                            storage: nil)))
            }
            refreshRequest = .propertyChanged(UInt32(propertyCode))
        default:
            return javaString(
                env,
                AndroidCameraPropertyReadbackWire.encode(
                    AndroidCameraPropertyReadback(
                        result: .unsupported,
                        properties: PTPCameraPropertySnapshot(),
                        storage: nil)))
        }
        return javaString(
            env,
            AndroidCameraPropertyReadbackWire.encode(
                session.refreshAndroidPropertySnapshot(refreshRequest)))
    }

    /// `SwiftCore.sessionStartEventStream(listener)` — starts the active
    /// facade session's dedicated PTP-IP event reader. Valid raw event codes,
    /// transaction IDs, and UINT32 parameters cross as primitives; Kotlin
    /// decides which established event semantics to apply. The native reader
    /// owns the global listener reference until `onEnded` fires exactly once.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionStartEventStream")
    public func swiftCoreSessionStartEventStream(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, listener: jobject?
    ) {
        let fns = table(env)
        var vm: UnsafeMutablePointer<JavaVM?>?
        guard fns.GetJavaVM!(env, &vm) == JNI_OK, let vm else { return }
        guard let listener, let global = fns.NewGlobalRef!(env, listener) else { return }
        guard let cls = fns.GetObjectClass!(env, global),
            let onEvent = fns.GetMethodID!(env, cls, "onEvent", "(IJ[J)V"),
            let onEnded = fns.GetMethodID!(env, cls, "onEnded", "(Ljava/lang/String;)V")
        else {
            fns.DeleteGlobalRef!(env, global)
            return
        }
        let handle = SessionEventListenerHandle(
            vm: vm, listener: global, onEvent: onEvent, onEnded: onEnded)

        /// Failure before a Swift-owned reader exists: invoke the callback on
        /// the JVM-owned caller thread and only release the global reference.
        func endOnCallerThread(_ message: String?) {
            let value = message.flatMap { javaString(env, $0) }
            var args = [jvalue(l: value)]
            fns.CallVoidMethodA!(env, global, onEnded, &args)
            if let value { fns.DeleteLocalRef!(env, value) }
            fns.DeleteGlobalRef!(env, global)
        }

        guard let session = ActiveSessionSlot.shared.current() else {
            endOnCallerThread("Not connected to a camera.")
            return
        }
        do {
            try session.startEventDrain(
                onEvent: { pushSessionEvent(handle, event: $0) },
                onEnded: { finishSessionEventStream(handle, message: $0) })
        } catch {
            endOnCallerThread(error.localizedDescription)
        }
    }

    /// Delivers one parsed PTP event from the Swift-owned event reader. PTP
    /// UINT16/UINT32 fields fit losslessly in signed JVM `Int`/`Long`; Kotlin
    /// exposes them as non-negative raw values rather than guessing unknown
    /// Nikon semantics.
    private func pushSessionEvent(_ handle: SessionEventListenerHandle, event: PTPEvent) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else { return }
        let fns = table(env)
        let parameters = event.parameters.map(Int64.init)
        guard let parameterArray = javaLongArray(env, parameters) else { return }
        var args = [
            jvalue(i: jint(event.rawEventCode)),
            jvalue(j: Int64(event.transactionID)),
            jvalue(l: parameterArray),
        ]
        fns.CallVoidMethodA!(env, handle.listener, handle.onEvent, &args)
        fns.DeleteLocalRef!(env, parameterArray)
    }

    /// Terminal event-reader callback: it releases the listener global
    /// reference and detaches the one Swift-owned thread that delivered the
    /// stream. It is intentionally separate from the caller-thread fast-fail
    /// path above so the JVM is never detached by a JVM-owned thread.
    private func finishSessionEventStream(
        _ handle: SessionEventListenerHandle, message: String?
    ) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else { return }
        let fns = table(env)
        let value = message.flatMap { javaString(env, $0) }
        var args = [jvalue(l: value)]
        fns.CallVoidMethodA!(env, handle.listener, handle.onEnded, &args)
        if let value { fns.DeleteLocalRef!(env, value) }
        fns.DeleteGlobalRef!(env, handle.listener)
        _ = invoke.DetachCurrentThread!(handle.vm)
    }

    /// Stable scalar results for `SwiftCore.sessionSetRecording`. Kotlin maps
    /// these to its typed `CameraRecordingException` hierarchy; no protocol
    /// error string crosses the JNI boundary as unstructured control flow.
    private enum RecordingCommandResult: jint {
        case accepted = 0
        case noSession = 1
        case mediaBusy = 2
        case rejected = 3
        case transportFailed = 4
    }

    /// Stable scalar results for `SwiftCore.sessionApplyControl`. Kotlin maps
    /// these to its typed `CameraControlException` hierarchy; Nikon property
    /// bytes and protocol errors never cross the JNI boundary as unstructured
    /// control flow.
    private enum ControlCommandResult: jint {
        case accepted = 0
        case noSession = 1
        case mediaBusy = 2
        case unsupported = 3
        case rejected = 4
        case transportFailed = 5
    }

    /// `SwiftCore.sessionSetRecording(recording): Int` — sends Nikon's
    /// `StartMovieRecInCard` / `EndMovieRec` through the active facade
    /// session. The session transaction lock serializes this with live view;
    /// Kotlin invokes the blocking JNI call from `Dispatchers.IO`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionSetRecording")
    public func swiftCoreSessionSetRecording(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, recording: jboolean
    ) -> jint {
        guard let session = ActiveSessionSlot.shared.current() else {
            return RecordingCommandResult.noSession.rawValue
        }
        do {
            if recording != 0 {
                try session.startRecording()
            } else {
                try session.stopRecording()
            }
            return RecordingCommandResult.accepted.rawValue
        } catch let error as PTPIPClientSessionError {
            switch error {
            case .mediaModeActive, .mediaModeRequired:
                return RecordingCommandResult.mediaBusy.rawValue
            case .operationRejected:
                return RecordingCommandResult.rejected.rawValue
            default:
                return RecordingCommandResult.transportFailed.rawValue
            }
        } catch {
            return RecordingCommandResult.transportFailed.rawValue
        }
    }

    /// `SwiftCore.sessionApplyControl(control, label): Int` — validates the
    /// semantic Kotlin selector, then applies its human-readable selection on
    /// the active facade session. Swift resolves every Nikon property ID and
    /// data payload through `PTPCameraPropertyWrite`, including Kelvin's
    /// mode-then-temperature sequence. Kotlin invokes this blocking call from
    /// `Dispatchers.IO`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionApplyControl")
    public func swiftCoreSessionApplyControl(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, control: jint, label: jstring?
    ) -> jint {
        guard let session = ActiveSessionSlot.shared.current() else {
            return ControlCommandResult.noSession.rawValue
        }
        guard let cameraControl = AndroidCameraControlWire.control(selector: Int(control)) else {
            return ControlCommandResult.unsupported.rawValue
        }
        let selection = swiftString(env, label) ?? ""
        do {
            try session.applyControl(cameraControl, label: selection)
            return ControlCommandResult.accepted.rawValue
        } catch let error as PTPIPClientSessionError {
            switch error {
            case .mediaModeActive, .mediaModeRequired:
                return ControlCommandResult.mediaBusy.rawValue
            case .unsupportedControl:
                return ControlCommandResult.unsupported.rawValue
            case .operationRejected:
                return ControlCommandResult.rejected.rawValue
            default:
                return ControlCommandResult.transportFailed.rawValue
            }
        } catch {
            return ControlCommandResult.transportFailed.rawValue
        }
    }

    /// `SwiftCore.sessionDisconnect(connectionOwner)` — graceful teardown of
    /// only that attempt's active or pending session: best-effort
    /// `CloseSession` then the owned transport. A stale cancellation is a
    /// no-op when a newer owner is active.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionDisconnect")
    public func swiftCoreSessionDisconnect(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, owner: jlong
    ) {
        let removed = ActiveSessionSlot.shared.takeOwnedConnection(owner: Int64(owner))
        removed.pendingUSBTransport?.close()
        removed.session?.disconnect()
    }

    // MARK: - Live view

    /// Kotlin-side `LiveFrameListener`, resolved to a global ref + method IDs
    /// so the facade's pump thread can push into it.
    ///
    /// The raw pointers are a JNI global reference, process-wide `jmethodID`s,
    /// and the process-wide `JavaVM*` — all valid across threads per the JNI
    /// spec, hence `@unchecked Sendable`.
    private struct LiveFrameListenerHandle: @unchecked Sendable {
        let vm: UnsafeMutablePointer<JavaVM?>
        let listener: jobject
        let onFrame: jmethodID
        let onEnded: jmethodID
    }

    /// `SwiftCore.sessionStartLiveView(listener)` — starts live view on the
    /// active session (blocking `StartLiveView` + readiness poll on the caller
    /// thread) and pumps JPEG frames to
    /// `listener.onFrame(jpeg, timestampNanos, isRecording, audio...)` from
    /// the facade's pump thread. `onEnded` fires exactly once when the
    /// stream ends — stop, disconnect, a transport error, or (immediately, on
    /// the calling thread) when there is no active session or the start fails.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionStartLiveView")
    public func swiftCoreSessionStartLiveView(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, listener: jobject?
    ) {
        let fns = table(env)
        var vm: UnsafeMutablePointer<JavaVM?>?
        guard fns.GetJavaVM!(env, &vm) == JNI_OK, let vm else { return }
        guard let listener, let global = fns.NewGlobalRef!(env, listener) else { return }
        guard let cls = fns.GetObjectClass!(env, global),
            let onFrame = fns.GetMethodID!(env, cls, "onFrame", "([BJZDDDDZ)V"),
            let onEnded = fns.GetMethodID!(env, cls, "onEnded", "()V")
        else {
            fns.DeleteGlobalRef!(env, global)
            return
        }
        let handle = LiveFrameListenerHandle(
            vm: vm, listener: global, onFrame: onFrame, onEnded: onEnded)

        /// Terminal path on the CALLING (JVM-owned) thread: report the end and
        /// release the listener without ever detaching this thread.
        func endOnCallerThread() {
            var noArguments = jvalue()
            fns.CallVoidMethodA!(env, global, onEnded, &noArguments)
            fns.DeleteGlobalRef!(env, global)
        }

        guard let session = ActiveSessionSlot.shared.current() else {
            endOnCallerThread()
            return
        }
        do {
            // Both callbacks run on the ONE pump thread, `onEnded` last —
            // that ordering is what makes the attach-per-callback /
            // detach-once-at-the-end pairing below sound.
            try session.startLiveView(
                onFrame: { frame, timestampNanos in
                    let audio = LiveAudioMeterWire(sound: frame.sound)
                    pushLiveFrame(
                        handle, jpeg: frame.jpeg, timestampNanos: timestampNanos,
                        isRecording: frame.isRecording, audio: audio)
                },
                onEnded: { finishLiveFrameStream(handle) })
        } catch {
            endOnCallerThread()
        }
    }

    /// `SwiftCore.sessionStopLiveView()` — stops the pump and blocks until it
    /// has exited (the camera got its `EndLiveView`). No-op when idle.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionStopLiveView")
    public func swiftCoreSessionStopLiveView(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) {
        ActiveSessionSlot.shared.current()?.stopLiveView()
    }

    /// Delivers one JPEG frame to the Kotlin listener from the pump thread.
    /// Attaches the thread on every call (idempotent and cheap when already
    /// attached); the matching single detach happens in `finishLiveFrameStream`.
    private func pushLiveFrame(
        _ handle: LiveFrameListenerHandle, jpeg: Data, timestampNanos: Int64,
        isRecording: Bool, audio: LiveAudioMeterWire
    ) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else { return }
        let fns = table(env)
        guard let array = fns.NewByteArray!(env, jsize(jpeg.count)) else { return }
        jpeg.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.baseAddress else { return }
            fns.SetByteArrayRegion!(
                env, array, 0, jsize(jpeg.count),
                base.assumingMemoryBound(to: jbyte.self))
        }
        var args = [
            jvalue(l: array), jvalue(j: timestampNanos),
            jvalue(z: isRecording ? 1 : 0),
            jvalue(d: audio.leftLevelDB), jvalue(d: audio.leftPeakDB),
            jvalue(d: audio.rightLevelDB), jvalue(d: audio.rightPeakDB),
            jvalue(z: audio.hasLevels ? 1 : 0),
        ]
        fns.CallVoidMethodA!(env, handle.listener, handle.onFrame, &args)
        fns.DeleteLocalRef!(env, array)
    }

    /// Terminal upcall from the pump thread: report the end, release the
    /// listener, and detach the (Swift-owned) thread from the JVM.
    private func finishLiveFrameStream(_ handle: LiveFrameListenerHandle) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else { return }
        let fns = table(env)
        var noArguments = jvalue()
        fns.CallVoidMethodA!(env, handle.listener, handle.onEnded, &noArguments)
        fns.DeleteGlobalRef!(env, handle.listener)
        _ = invoke.DetachCurrentThread!(handle.vm)
    }

    // MARK: - Media browse (OPE-34)

    /// `SwiftCore.sessionListMedia(maxObjects): String?` — lists browsable
    /// media on the active session's cards (bounded enumeration; see
    /// `PTPIPClientSession.listMedia`), flattened per `MediaListWire`. Null
    /// when disconnected or the listing failed; empty string for an empty
    /// card. Blocking; Kotlin calls it from `Dispatchers.IO`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionListMedia")
    public func swiftCoreSessionListMedia(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, maxObjects: jint
    ) -> jstring? {
        guard let session = ActiveSessionSlot.shared.current() else { return nil }
        session.enterMediaMode()
        guard
            let clips = try? session.listMedia(maxObjects: Int(maxObjects))
        else { return nil }
        return javaString(env, MediaListWire.encode(clips))
    }

    /// `SwiftCore.sessionThumbnail(handle): ByteArray?` — the camera's
    /// embedded thumbnail JPEG for one object (`GetThumb`). Null when
    /// disconnected, rejected, or the object has no thumbnail. Blocking;
    /// Kotlin calls it from `Dispatchers.IO`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionThumbnail")
    public func swiftCoreSessionThumbnail(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, handle: jint
    ) -> jbyteArray? {
        guard let session = ActiveSessionSlot.shared.current(),
            let jpeg = try? session.thumbnail(handle: UInt32(bitPattern: handle))
        else { return nil }
        let fns = table(env)
        guard let array = fns.NewByteArray!(env, jsize(jpeg.count)) else { return nil }
        jpeg.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            fns.SetByteArrayRegion!(
                env, array, 0, jsize(jpeg.count),
                base.assumingMemoryBound(to: jbyte.self))
        }
        return array
    }

    /// `SwiftCore.sessionExitMediaMode()` — stops any payload transfer, then
    /// releases media ownership so the monitor may restart live view.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionExitMediaMode")
    public func swiftCoreSessionExitMediaMode(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) {
        ActiveSessionSlot.shared.current()?.exitMediaMode()
    }

    /// `SwiftCore.sessionResolveMediaSize(handle, reportedSize): Long` —
    /// authoritative object length for cache creation, including Nikon's
    /// 64-bit query when ObjectInfo carried the UINT32 sentinel.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionResolveMediaSize")
    public func swiftCoreSessionResolveMediaSize(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        handle: jint, reportedSize: jlong
    ) -> jlong {
        guard reportedSize >= 0, let session = ActiveSessionSlot.shared.current(),
            let size = try? session.resolvedObjectSize(
                handle: UInt32(bitPattern: handle), reportedSize: UInt64(reportedSize)),
            size <= UInt64(Int64.max)
        else { return -1 }
        return Int64(size)
    }

    // MARK: - Media transfer (OPE-34 playback)

    /// Kotlin-side `MediaTransferListener`, retained across the Swift pump
    /// thread with JNI global references and process-wide method IDs.
    private struct MediaTransferListenerHandle: @unchecked Sendable {
        let vm: UnsafeMutablePointer<JavaVM?>
        let listener: jobject
        let onStarted: jmethodID
        let onChunk: jmethodID
        let onCompleted: jmethodID
        let onStopped: jmethodID
        let onFailed: jmethodID
    }

    /// `SwiftCore.sessionStartMediaTransfer(...)` — validates/resolves the
    /// object on the caller's IO thread, then the facade pump pushes ordered
    /// cache chunks from one Swift-owned thread.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionStartMediaTransfer")
    public func swiftCoreSessionStartMediaTransfer(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?,
        handle: jint, reportedSize: jlong, resumeOffset: jlong, listener: jobject?
    ) {
        let fns = table(env)
        var vm: UnsafeMutablePointer<JavaVM?>?
        guard fns.GetJavaVM!(env, &vm) == JNI_OK, let vm else { return }
        guard let listener, let global = fns.NewGlobalRef!(env, listener) else { return }
        guard let cls = fns.GetObjectClass!(env, global),
            let onStarted = fns.GetMethodID!(env, cls, "onStarted", "(J)V"),
            let onChunk = fns.GetMethodID!(env, cls, "onChunk", "(J[B)Z"),
            let onCompleted = fns.GetMethodID!(env, cls, "onCompleted", "(J)V"),
            let onStopped = fns.GetMethodID!(env, cls, "onStopped", "(J)V"),
            let onFailed = fns.GetMethodID!(
                env, cls, "onFailed", "(Ljava/lang/String;)V")
        else {
            fns.DeleteGlobalRef!(env, global)
            return
        }
        let listenerHandle = MediaTransferListenerHandle(
            vm: vm, listener: global, onStarted: onStarted, onChunk: onChunk,
            onCompleted: onCompleted, onStopped: onStopped, onFailed: onFailed)

        func failOnCallerThread(_ message: String) {
            let value = javaString(env, message)
            var args = [jvalue(l: value)]
            fns.CallVoidMethodA!(env, global, onFailed, &args)
            if let value { fns.DeleteLocalRef!(env, value) }
            fns.DeleteGlobalRef!(env, global)
        }

        guard reportedSize >= 0, resumeOffset >= 0 else {
            failOnCallerThread("Camera-media offsets must not be negative.")
            return
        }
        guard let session = ActiveSessionSlot.shared.current() else {
            failOnCallerThread("Not connected to a camera.")
            return
        }

        do {
            try session.startMediaTransfer(
                handle: UInt32(bitPattern: handle),
                reportedSize: UInt64(reportedSize),
                resumeOffset: UInt64(resumeOffset),
                onStarted: { pushMediaStarted(listenerHandle, totalBytes: $0) },
                onChunk: { pushMediaChunk(listenerHandle, offset: $0, data: $1) },
                onCompleted: {
                    finishMediaTransfer(
                        listenerHandle, method: listenerHandle.onCompleted, value: $0)
                },
                onStopped: {
                    finishMediaTransfer(
                        listenerHandle, method: listenerHandle.onStopped, value: $0)
                },
                onFailed: { finishMediaTransfer(listenerHandle, message: $0) })
        } catch {
            failOnCallerThread(error.localizedDescription)
        }
    }

    /// `SwiftCore.sessionStopMediaTransfer()` — joins the progressive object
    /// pump after its terminal callback.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionStopMediaTransfer")
    public func swiftCoreSessionStopMediaTransfer(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) {
        ActiveSessionSlot.shared.current()?.stopMediaTransfer()
    }

    private func mediaTransferEnvironment(
        _ handle: MediaTransferListenerHandle
    ) -> UnsafeMutablePointer<JNIEnv?>? {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var environment: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &environment, nil) == JNI_OK else {
            return nil
        }
        return environment
    }

    private func pushMediaStarted(
        _ handle: MediaTransferListenerHandle, totalBytes: UInt64
    ) {
        guard let env = mediaTransferEnvironment(handle) else { return }
        var args = [jvalue(j: Int64(bitPattern: totalBytes))]
        table(env).CallVoidMethodA!(env, handle.listener, handle.onStarted, &args)
    }

    private func pushMediaChunk(
        _ handle: MediaTransferListenerHandle, offset: UInt64, data: Data
    ) -> Bool {
        guard let env = mediaTransferEnvironment(handle) else { return false }
        let fns = table(env)
        guard let array = fns.NewByteArray!(env, jsize(data.count)) else { return false }
        data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            fns.SetByteArrayRegion!(
                env, array, 0, jsize(data.count),
                base.assumingMemoryBound(to: jbyte.self))
        }
        var args = [jvalue(j: Int64(bitPattern: offset)), jvalue(l: array)]
        let accepted = fns.CallBooleanMethodA!(env, handle.listener, handle.onChunk, &args)
        fns.DeleteLocalRef!(env, array)
        return accepted != 0
    }

    private func finishMediaTransfer(
        _ handle: MediaTransferListenerHandle, method: jmethodID, value: UInt64
    ) {
        guard let env = mediaTransferEnvironment(handle) else { return }
        let fns = table(env)
        var args = [jvalue(j: Int64(bitPattern: value))]
        fns.CallVoidMethodA!(env, handle.listener, method, &args)
        fns.DeleteGlobalRef!(env, handle.listener)
        // SAFETY: this terminal callback runs on the Swift-owned pump thread.
        _ = handle.vm.pointee!.pointee.DetachCurrentThread!(handle.vm)
    }

    private func finishMediaTransfer(
        _ handle: MediaTransferListenerHandle, message: String
    ) {
        guard let env = mediaTransferEnvironment(handle) else { return }
        let fns = table(env)
        let value = javaString(env, message)
        var args = [jvalue(l: value)]
        fns.CallVoidMethodA!(env, handle.listener, handle.onFailed, &args)
        if let value { fns.DeleteLocalRef!(env, value) }
        fns.DeleteGlobalRef!(env, handle.listener)
        // SAFETY: this terminal callback runs on the Swift-owned pump thread.
        _ = handle.vm.pointee!.pointee.DetachCurrentThread!(handle.vm)
    }

    /// Pushes `discovering → handshaking → connected` copy from the core to the
    /// registered listener, then releases it.
    private func pushDemoPhases(_ handle: ListenerHandle) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else { return }
        defer { _ = invoke.DetachCurrentThread!(handle.vm) }

        let fns = table(env)
        defer { fns.DeleteGlobalRef!(env, handle.listener) }

        let phases: [CameraConnectionPhase] = [.discovering, .handshaking, .connected]
        for phase in phases {
            let title = ConnectionProgressCopy.statusTitle(phase: phase, isUSB: false)
            let detail = ConnectionProgressCopy.statusDetail(
                phase: phase, deviceName: "Nikon ZR", friendlyError: nil)
            guard let jTitle = javaString(env, title),
                let jDetail = javaString(env, detail)
            else { continue }
            var args = [jvalue(l: jTitle), jvalue(l: jDetail)]
            fns.CallVoidMethodA!(env, handle.listener, handle.method, &args)
            fns.DeleteLocalRef!(env, jTitle)
            fns.DeleteLocalRef!(env, jDetail)
            Thread.sleep(forTimeInterval: 0.15)
        }
    }

#endif
