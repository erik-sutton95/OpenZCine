#if os(Android)
    import OpenCineJNISupport

    /// Allocates one transient calibration screen owner.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroCalibrationCreate")
    public func gyroCalibrationCreateJNI(_ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?)
        -> jstring?
    {
        javaString(env, GyroCalibrationWire.shared.create())
    }

    /// Delivers a paired phone/camera observation to the shared stillness policy.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroCalibrationAdd")
    public func gyroCalibrationAddJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, observation: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let observation = swiftString(env, observation),
            let reply = GyroCalibrationWire.shared.add(owner: owner, observationJSON: observation)
        else { return nil }
        return javaString(env, reply)
    }

    /// Captures the next pose or verifies the independent final pose.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroCalibrationCapture")
    public func gyroCalibrationCaptureJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?, timestamp: jdouble
    ) -> jstring? {
        guard let owner = swiftString(env, owner),
            let reply = GyroCalibrationWire.shared.capture(owner: owner, timestamp: timestamp)
        else { return nil }
        return javaString(env, reply)
    }

    /// Releases the transient owner without changing persisted calibration.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroCalibrationClose")
    public func gyroCalibrationCloseJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { GyroCalibrationWire.shared.close(owner: owner) }
    }

    /// Validates a persisted matrix and its held-out quality bounds through the shared core.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_gyroCalibrationValidate")
    public func gyroCalibrationValidateJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, calibration: jstring?
    ) -> jboolean {
        guard let calibration = swiftString(env, calibration) else { return 0 }
        return GyroCalibrationWire.shared.validate(calibration) ? 1 : 0
    }
#endif
