#if os(Android)
    import OpenCineJNISupport

    /// Allocates a Swift execution owner. Kotlin never receives drive commands.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_focusRackCreate")
    public func focusRackCreateJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?,
        connectionOwner: jlong, templates: jstring?
    ) -> jstring? {
        guard let templates = swiftString(env, templates),
            let owner = FocusRackWire.shared.create(
                connectionOwner: connectionOwner, templatesJSON: templates)
        else { return nil }
        return javaString(env, owner)
    }

    /// Forwards observations/intents and reads the latest typed shared state.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_focusRackStep")
    public func focusRackStepJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?,
        owner: jstring?, request: jstring?
    ) -> jstring? {
        guard let owner = swiftString(env, owner), let request = swiftString(env, request),
            let reply = FocusRackWire.shared.step(owner: owner, requestJSON: request)
        else { return nil }
        return javaString(env, reply)
    }

    /// Cancels before releasing the controller's session-local state.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_focusRackClose")
    public func focusRackCloseJNI(
        _ env: UnsafeMutablePointer<JNIEnv?>, _: jobject?, owner: jstring?
    ) {
        if let owner = swiftString(env, owner) { FocusRackWire.shared.close(owner: owner) }
    }
#endif
