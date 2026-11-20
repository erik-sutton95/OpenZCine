import CoreGraphics
import OpenCineAppKitApple
import OpenCineApple
import OpenCineStreaming

/// Live streaming's host values: the keychain service, the route (`liveStreamRoute`), the live
/// picture's size and the clean picture tap fed from `publishNativeFrame`. Nothing here sends a
/// camera command.
extension NativeAppModel {
    func makeLiveStream() -> LiveStreamCoordinator {
        LiveStreamCoordinator(
            host: LiveStreamHost(
                keychainService: "com.opencapture.openzcine.live-stream",
                route: { [weak self] in self?.liveStreamRoute },
                source: { [weak self] in self?.liveStreamSource },
                attachPicture: { [weak self] in self?.liveStreamTap = $0 }))
    }

    /// The picture as it arrives: the live view JPEG (up to 1024x768) or the capture card's frame.
    /// Neither states a rate.
    var liveStreamSource: StreamSourceFormat? {
        guard liveStreamRoute != nil, let size = liveFrameImage?.size, size.width >= 2,
            size.height >= 2
        else {
            return nil
        }
        let scale = liveFrameImage?.scale ?? 1
        return StreamSourceFormat(
            width: Int((size.width * scale).rounded()),
            height: Int((size.height * scale).rounded()),
            frameRate: nil)
    }

    /// The monitor's look for the clean picture: its LUT when the LUT tool is on, with the signal
    /// mapping the LUT reads. The tap ignores every assist.
    var liveStreamEffects: MonitorImageEffects {
        var effects = MonitorImageEffects()
        let mapping = exposureSignalMapping
        effects.transfer = mapping.curve.monitorTransfer
        effects.clipByte = mapping.clipByte
        if let armed = armedLUT(visibleTools: renderedLiveAssistTools) {
            let packed = Self.packedForRenderer(armed)
            effects.lutDimension = packed.size
            effects.lutRGBA = packed.rgba
        }
        return effects
    }
}
