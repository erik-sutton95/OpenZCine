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

    /// Process-wide active session slot behind the coarse JNI facade: one
    /// camera at a time, matching the app's single-camera model.
    private final class ActiveSessionSlot: @unchecked Sendable {
        static let shared = ActiveSessionSlot()
        private let lock = NSLock()
        private var session: PTPIPClientSession?

        /// Stores `new` and returns the displaced session (for teardown).
        func replace(with new: PTPIPClientSession?) -> PTPIPClientSession? {
            lock.lock()
            defer { lock.unlock() }
            let old = session
            session = new
            return old
        }

        func current() -> PTPIPClientSession? {
            lock.lock()
            defer { lock.unlock() }
            return session
        }
    }

    /// `SwiftCore.sessionConnect(host, listener)` — async connect: PTP-IP Init
    /// handshake + Nikon open/pair/identify on a Swift background thread, with
    /// phases pushed to the listener (`onPhase`), ending in `onConnected` or
    /// `onFailed`. The established session parks in the process-wide slot for
    /// `sessionReadProperty` / `sessionDisconnect`.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionConnect")
    public func swiftCoreSessionConnect(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, host: jstring?, listener: jobject?
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
        Thread.detachNewThread { runSessionConnect(handle, host: hostString) }
    }

    /// Connect-thread body: attaches to the JVM, drives the blocking session
    /// establishment, and pushes phases/terminal callbacks to the listener.
    private func runSessionConnect(_ handle: SessionListenerHandle, host: String) {
        // SAFETY: JavaVM handle and invoke table are JVM-provided and non-nil.
        let invoke = handle.vm.pointee!.pointee
        var envOut: UnsafeMutablePointer<JNIEnv?>?
        guard invoke.AttachCurrentThread!(handle.vm, &envOut, nil) == JNI_OK,
            let env = envOut
        else { return }
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
            // A replaced session (reconnect without disconnect) is torn down
            // gracefully so the camera's slot is released.
            ActiveSessionSlot.shared.replace(with: session)?.disconnect()
            callStrings(
                handle.onConnected,
                [
                    session.identity.displayName, session.identity.model,
                    session.identity.serialNumber,
                ])
        } catch {
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

    /// `SwiftCore.sessionDisconnect()` — graceful teardown of the active
    /// session: best-effort `CloseSession` then both sockets (the iOS
    /// reconnect-wedge fix semantics). No-op when nothing is connected.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_sessionDisconnect")
    public func swiftCoreSessionDisconnect(
        env _: UnsafeMutablePointer<JNIEnv?>, this _: jobject?
    ) {
        ActiveSessionSlot.shared.replace(with: nil)?.disconnect()
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
    /// thread) and pumps JPEG frames to `listener.onFrame(jpeg, timestampNanos)`
    /// from the facade's pump thread. `onEnded` fires exactly once when the
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
            let onFrame = fns.GetMethodID!(env, cls, "onFrame", "([BJ)V"),
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
                    pushLiveFrame(handle, jpeg: frame.jpeg, timestampNanos: timestampNanos)
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
        _ handle: LiveFrameListenerHandle, jpeg: Data, timestampNanos: Int64
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
        var args = [jvalue(l: array), jvalue(j: timestampNanos)]
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
        guard let session = ActiveSessionSlot.shared.current(),
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
