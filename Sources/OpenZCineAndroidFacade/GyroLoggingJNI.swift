#if os(Android)
    import OpenCineJNISupport

    /// Allocates one Android motion capture owner.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroCreate")
    public func gyroCreateJNI(_ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?) -> jstring? {
        javaString(env, GyroLoggingWire.shared.create())
    }

    /// Delivers one bounded numeric sensor batch to shared take policy.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroIngest")
    public func gyroIngestJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        bytes: jbyteArray?
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let bytes = swiftBytes(env, bytes, maximumCount: 512 * 32),
            let reply = GyroLoggingWire.shared.ingest(owner: owner, bytes: bytes)
        else { return nil }
        return javaString(env, reply)
    }

    /// Delivers a camera-authoritative record observation.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroObserve")
    public func gyroObserveJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        recording: jboolean, timestamp: jdouble, dateSeconds: jdouble, cameraLabel: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let label = swiftString(env, cameraLabel),
            let reply = GyroLoggingWire.shared.observe(
                owner: owner, recording: recording != 0,
                timestamp: timestamp, dateSeconds: dateSeconds, cameraLabel: label)
        else { return nil }
        return javaString(env, reply)
    }

    /// Advances sample-health and postroll deadlines.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroPoll")
    public func gyroPollJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        timestamp: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroLoggingWire.shared.poll(owner: owner, timestamp: timestamp)
        else { return nil }
        return javaString(env, reply)
    }

    /// Finalizes motion files without sending camera commands.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroFinish")
    public func gyroFinishJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        reason: jstring?, timestamp: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let reason = swiftString(env, reason),
            let reply = GyroLoggingWire.shared.finish(
                owner: owner, reason: reason, timestamp: timestamp)
        else { return nil }
        return javaString(env, reply)
    }

    /// Releases the finished Android owner.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroClose")
    public func gyroCloseJNI(_ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?) {
        if let owner = swiftString(env, owner) { GyroLoggingWire.shared.close(owner: owner) }
    }

    /// Starts one streaming partial-file recovery owner.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroRecoveryCreate")
    public func gyroRecoveryCreateJNI(_ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?) -> jstring?
    {
        javaString(env, GyroLoggingWire.shared.recoveryCreate())
    }

    /// Validates bounded file bytes and returns the valid prefix length, or -1 on failure.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroRecoveryAccept")
    public func gyroRecoveryAcceptJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        bytes: jbyteArray?
    ) -> jlong {
        guard let owner = swiftString(env, owner),
            let bytes = swiftBytes(env, bytes, maximumCount: 65_536),
            let length = GyroLoggingWire.shared.recoveryAccept(owner: owner, bytes: bytes)
        else { return -1 }
        return length
    }

    /// Completes recovery with the original descriptor and releases its owner.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroRecoveryFinish")
    public func gyroRecoveryFinishJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?,
        descriptor: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let descriptor = swiftString(env, descriptor),
            let reply = GyroLoggingWire.shared.recoveryFinish(
                owner: owner, descriptorJSON: descriptor)
        else { return nil }
        return javaString(env, reply)
    }
#endif
