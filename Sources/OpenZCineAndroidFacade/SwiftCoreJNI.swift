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

    import Foundation
    import OpenCineJNISupport
    import OpenCineNikonAndroid
    import OpenZCineCore

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

    /// `SwiftCore.playbackAudioMeterStep(...)` — advances decoded-playback stereo
    /// peaks through the shared dBFS conversion and attack/decay/peak-hold policy.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_playbackAudioMeterStep")
    public func swiftCorePlaybackAudioMeterStep(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, previousPayload: jfloatArray?,
        leftPeakLinear: jfloat, rightPeakLinear: jfloat, deltaTimeSeconds: jfloat
    ) -> jfloatArray? {
        let previous =
            swiftFloats(
                env, previousPayload, maximumCount: PlaybackAudioMeterWire.scalarCount)
            ?? []
        let next = PlaybackAudioMeterWire.advance(
            previousPayload: previous,
            leftPeakLinear: leftPeakLinear,
            rightPeakLinear: rightPeakLinear,
            deltaTimeSeconds: deltaTimeSeconds
        )
        return javaFloatArray(env, next.payload)
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

    // MARK: - Scopes

    /// `SwiftCore.scopeLevelAxis(curve, clip): FloatArray`: the shared scopes'
    /// level axis for this camera per `ScopeFrameWire.levelAxis`. Called once
    /// per camera mapping, never per tick.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_scopeLevelAxis")
    public func swiftCoreScopeLevelAxis(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, curve: jint, clipNative: jfloat
    ) -> jfloatArray? {
        javaFloatArray(
            env, ScopeFrameWire.levelAxis(curveOrdinal: Int(curve), clipNative: Double(clipNative)))
    }

    /// `SwiftCore.scopeTrafficLights(histograms, curve, clip, compensation): FloatArray`
    /// returns the core Traffic Lights reading for the shared sampler's histograms
    /// per `ScopeFrameWire.trafficLights`. `compensation` is a persisted core
    /// enum raw value; Swift decodes and applies it.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_scopeTrafficLights")
    public func swiftCoreScopeTrafficLights(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, histograms: jfloatArray?,
        curve: jint, clipNative: jfloat, compensation: jint
    ) -> jfloatArray? {
        let bins =
            swiftFloats(env, histograms, maximumCount: 4 * ScopeFrameWire.histogramBins) ?? []
        return javaFloatArray(
            env,
            ScopeFrameWire.trafficLights(
                histograms: bins.map { Int($0) }, curveOrdinal: Int(curve),
                clipNative: Double(clipNative), crushClipCompensationRaw: Int(compensation)))
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

    /// `SwiftCore.exposureAssistMapping(codec, iso, baseIso, stillsToneMode): FloatArray`
    /// — camera-aware curve and code-value anchors. Kotlin forwards camera
    /// metadata but never selects a curve or clip endpoint itself; a non-null
    /// stills tone mode marks the photo selector active and swaps the movie
    /// codec's log mapping for the display-referred stills one.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_exposureAssistMapping")
    public func swiftCoreExposureAssistMapping(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, codec: jstring?, iso: jlong,
        baseISO: jstring?, stillsToneMode: jstring?
    ) -> jfloatArray? {
        javaFloatArray(
            env,
            FeedEffectsWire.cameraMappingPayload(
                codec: swiftString(env, codec), iso: Int64(iso),
                baseISO: swiftString(env, baseISO),
                stillsToneMode: swiftString(env, stillsToneMode))
        )
    }

    /// `SwiftCore.zebraEditorValue(...)` — converts a canonical monitor-percent
    /// threshold into the requested editor unit. `NaN` is a fail-closed result
    /// for an unsupported unit ordinal.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_zebraEditorValue")
    public func swiftCoreZebraEditorValue(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, codec: jstring?, iso: jlong,
        baseISO: jstring?, stillsToneMode: jstring?, unitOrdinal: jint, monitorPercent: jfloat
    ) -> jfloat {
        FeedEffectsWire.zebraEditorValue(
            codec: swiftString(env, codec), iso: Int64(iso), baseISO: swiftString(env, baseISO),
            stillsToneMode: swiftString(env, stillsToneMode),
            unitOrdinal: Int(unitOrdinal), monitorPercent: Double(monitorPercent)) ?? .nan
    }

    /// `SwiftCore.zebraMonitorPercent(...)` — converts an editor threshold to
    /// the canonical monitor axis. `NaN` makes malformed unit input fail closed.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_zebraMonitorPercent")
    public func swiftCoreZebraMonitorPercent(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, codec: jstring?, iso: jlong,
        baseISO: jstring?, stillsToneMode: jstring?, unitOrdinal: jint, editorValue: jfloat
    ) -> jfloat {
        FeedEffectsWire.zebraMonitorPercent(
            codec: swiftString(env, codec), iso: Int64(iso), baseISO: swiftString(env, baseISO),
            stillsToneMode: swiftString(env, stillsToneMode),
            unitOrdinal: Int(unitOrdinal), value: Double(editorValue)) ?? .nan
    }

    /// `SwiftCore.feedEffectsConfiguration(...)` — full source-measurement
    /// thresholds and overlay RGB for the Android shader. Every colour,
    /// threshold, and camera mapping stays owned by the Swift core.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_feedEffectsConfiguration")
    public func swiftCoreFeedEffectsConfiguration(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, codec: jstring?, iso: jlong,
        baseISO: jstring?, stillsToneMode: jstring?, peakingSensitivity: jint, peakingColor: jint,
        highlightEnabled: jboolean, highlightIRE: jfloat, highlightColor: jint,
        midtoneEnabled: jboolean, midtoneIRE: jfloat, midtoneColor: jint
    ) -> jfloatArray? {
        guard
            let values = FeedEffectsWire.renderConfiguration(
                codec: swiftString(env, codec), iso: Int64(iso), baseISO: swiftString(env, baseISO),
                stillsToneMode: swiftString(env, stillsToneMode),
                peakingSensitivityOrdinal: Int(peakingSensitivity),
                peakingColorOrdinal: Int(peakingColor),
                highlightEnabled: highlightEnabled != 0, highlightIRE: Double(highlightIRE),
                highlightColorOrdinal: Int(highlightColor), midtoneEnabled: midtoneEnabled != 0,
                midtoneIRE: Double(midtoneIRE), midtoneColorOrdinal: Int(midtoneColor))
        else { return nil }
        return javaFloatArray(env, values)
    }

    /// `SwiftCore.bakeFalseColorCube(scaleOrdinal, curveOrdinal, clipNative): ByteArray?` —
    /// the core's false-colour cube (64³) in the same packed-2D RGBA8 grid.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_bakeFalseColorCube")
    public func swiftCoreBakeFalseColorCube(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, scaleOrdinal: jint,
        curveOrdinal: jint, clipNative: jfloat
    ) -> jbyteArray? {
        guard
            let bytes = FeedEffectsWire.bakedFalseColor(
                scaleOrdinal: Int(scaleOrdinal), curveOrdinal: Int(curveOrdinal),
                clipNative: Double(clipNative))
        else { return nil }
        return javaByteArray(env, bytes)
    }

    /// `SwiftCore.bakeFalseColorLimitsPaint(curveOrdinal, clipNative): ByteArray?` —
    /// the Swift-owned colour paint for additive Limits false colour.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_bakeFalseColorLimitsPaint")
    public func swiftCoreBakeFalseColorLimitsPaint(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, curveOrdinal: jint, clipNative: jfloat
    ) -> jbyteArray? {
        guard
            let bytes = FeedEffectsWire.bakedFalseColorLimitsPaint(
                curveOrdinal: Int(curveOrdinal), clipNative: Double(clipNative))
        else { return nil }
        return javaByteArray(env, bytes)
    }

    /// `SwiftCore.bakeFalseColorLimitsWeight(curveOrdinal, clipNative): ByteArray?` —
    /// the Swift-owned weight mask for additive Limits false colour.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_bakeFalseColorLimitsWeight")
    public func swiftCoreBakeFalseColorLimitsWeight(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, curveOrdinal: jint, clipNative: jfloat
    ) -> jbyteArray? {
        guard
            let bytes = FeedEffectsWire.bakedFalseColorLimitsWeight(
                curveOrdinal: Int(curveOrdinal), clipNative: Double(clipNative))
        else { return nil }
        return javaByteArray(env, bytes)
    }

    /// `SwiftCore.falseColorReference(scaleOrdinal, curveOrdinal, clipNative): FloatArray?` —
    /// same palette bands as the baked false-colour payload.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_falseColorReference")
    public func swiftCoreFalseColorReference(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, scaleOrdinal: jint,
        curveOrdinal: jint, clipNative: jfloat
    ) -> jfloatArray? {
        guard
            let values = FeedEffectsWire.falseColorReference(
                scaleOrdinal: Int(scaleOrdinal), curveOrdinal: Int(curveOrdinal),
                clipNative: Double(clipNative))
        else { return nil }
        return javaFloatArray(env, values)
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

    // MARK: - Stored LUT library

    /// `SwiftCore.validateImportedLut(bytes, category, fileName): String?` — validates strict
    /// UTF-8 through the shared `CubeLUT` parser before Android copies a SAF document into
    /// app-private storage. The compact result is versioned by `LUTLibraryWire`; nil is a
    /// fail-closed import rejection.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_validateImportedLut")
    public func swiftCoreValidateImportedLut(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, utf8: jbyteArray?, category: jint,
        fileName: jstring?
    ) -> jstring? {
        guard let utf8 = swiftBytes(env, utf8, maximumCount: LUTLibraryWire.maximumSourceBytes),
            let fileName = swiftString(env, fileName),
            let record = LUTLibraryWire.validatedImport(
                utf8: utf8, categoryOrdinal: Int(category), fileName: fileName)
        else { return nil }
        return javaString(env, record)
    }

    /// `SwiftCore.packImportedLut(bytes): ByteArray?` — reparses an app-private cube and packs it
    /// into the existing feed-effects texture layout. Kotlin must render nil as unavailable rather
    /// than reimplementing cube parsing, interpolation, or colour math.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_packImportedLut")
    public func swiftCorePackImportedLut(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, utf8: jbyteArray?
    ) -> jbyteArray? {
        guard let utf8 = swiftBytes(env, utf8, maximumCount: LUTLibraryWire.maximumSourceBytes),
            let bytes = LUTLibraryWire.packedImportedLUT(utf8: utf8)
        else { return nil }
        return javaByteArray(env, bytes)
    }

    /// `SwiftCore.redLutDownloadAvailability(hasInternetPath, isOnCameraAccessPoint): String?` —
    /// the versioned shared RED network guard. The Android shell supplies reachability and current
    /// camera-AP state; `RedLUTDownloadPolicy` remains the single decision owner.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_redLutDownloadAvailability")
    public func swiftCoreRedLutDownloadAvailability(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, hasInternetPath: jboolean,
        isOnCameraAccessPoint: jboolean
    ) -> jstring? {
        javaString(
            env,
            LUTLibraryWire.redDownloadAvailability(
                hasInternetPath: hasInternetPath != 0,
                isOnCameraAccessPoint: isOnCameraAccessPoint != 0))
    }

    // MARK: - Link health and preview policy

    /// `SwiftCore.resolveLiveViewRequest(...)` — resolves persisted Android
    /// stream choices through `OperatorPreferences` plus
    /// `LiveViewLoadPolicy`. Kotlin receives a validated preview request but
    /// never maps choices to Nikon properties itself.
    @_cdecl("Java_com_opencapture_openzcine_bridge_SwiftCore_resolveLiveViewRequest")
    public func swiftCoreResolveLiveViewRequest(
        env: UnsafeMutablePointer<JNIEnv?>, this _: jobject?, streamPreset: jint,
        qualityBias: jint, thermalTier: jint, isRecording: jboolean,
        cameraOverheating: jboolean, recordingFrameRate: jint
    ) -> jstring? {
        // JNI cannot pass optional ints; non-positive means "unknown".
        let frameRate = Int(recordingFrameRate)
        guard
            let request = AndroidLiveViewPolicyWire.resolve(
                streamPresetRaw: Int(streamPreset),
                qualityBiasRaw: Int(qualityBias),
                thermalTierRaw: Int(thermalTier),
                isRecording: isRecording != 0,
                cameraOverheating: cameraOverheating != 0,
                recordingFrameRate: frameRate > 0 ? frameRate : nil)
        else { return nil }
        return javaString(env, AndroidLiveViewPolicyWire.encode(request))
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
            let method = optionalInstanceMethod(
                env, cls, "onPhase", "(Ljava/lang/String;Ljava/lang/String;)V")
        else {
            fns.ExceptionClear!(env)
            fns.DeleteGlobalRef!(env, global)
            return
        }

        let handle = ListenerHandle(vm: vm, listener: global, method: method)
        Thread.detachNewThread { pushDemoPhases(handle) }
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
