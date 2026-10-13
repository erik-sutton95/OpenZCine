import Foundation
import OpenCineRelay
import OpenCineWatch
import OpenZCineCore
import UIKit

import class OpenCineCameraVocabulary.CustomLUTStore

/// Bounded native picture facts. The shared owner controls admission, encoding and SDK delivery;
/// the existing native renderer retains the integration's calibrated look projection.
private struct WatchNativePreview: @unchecked Sendable {
    let image: UIImage
    let effects: LiveImageEffects?
    let renderer: LiveFrameRenderer?
    let timecode: Timecode
    let isRecording: Bool
}

@MainActor final class WatchRelay {
    var onToggleRecord: (@MainActor () -> OpenZCineCore.WatchCommandResult)?
    var onCapture: (@MainActor () -> OpenZCineCore.WatchCommandResult)?
    var onAdmittedToggleRecord:
        (@MainActor (RelayWatchCommandAdmission) -> OpenZCineCore.WatchCommandResult)?
    var onAdmittedCapture:
        (@MainActor (RelayWatchCommandAdmission) -> OpenZCineCore.WatchCommandResult)?
    var onReachabilityChanged: (@MainActor @Sendable () -> Void)? {
        get { relay.onReachabilityChanged }
        set { relay.onReachabilityChanged = newValue }
    }
    private var frameRenderer: LiveFrameRenderer?
    private let relay: WatchPhoneRelay<DeployedWatchRelayCodec, WatchNativePreview>
    init() {
        relay = WatchPhoneRelay(
            codec: DeployedWatchRelayCodec(),
            policy: .init(
                pacing: .init(
                    profiles: [
                        .init(maximumWidth: 832, qualityPercent: 50),
                        .init(maximumWidth: 672, qualityPercent: 45),
                        .init(maximumWidth: 512, qualityPercent: 40),
                    ], roundTripThresholds: [0.20, 0.35], initialIndex: 0,
                    initialRoundTripHint: 0.15, maximumSampleSeconds: 5),
                stateDelivery: .reachableMessage, releasesOutstandingOnRetirement: true),
            encode: { preview, profile in
                guard
                    let bytes = await WatchRelay.thumbnailJPEG(
                        from: preview.image, applying: preview.effects, renderer: preview.renderer,
                        maxWidth: CGFloat(profile.maximumWidth),
                        quality: CGFloat(profile.qualityPercent) / 100)
                else { return nil }
                return OpenZCineCore.WatchRelayFrame(
                    jpeg: bytes, timecode: preview.timecode,
                    isRecording: preview.isRecording)
            })
        relay.onAdmittedCommand = { [weak self] action, admission in
            let fallback = OpenZCineCore.WatchCommandResult(
                accepted: false, isRecording: false, error: "unavailable")
            switch action {
            case .toggleRecord:
                return self?.onAdmittedToggleRecord?(admission) ?? self?.onToggleRecord?()
                    ?? fallback
            case .capture:
                return self?.onAdmittedCapture?(admission) ?? self?.onCapture?() ?? fallback
            case .resume: return fallback  // Resume recovery is owned by the shared runtime.
            }
        }
    }
    var isReady: Bool { relay.isReady }
    func activate() { relay.activate() }
    func ingestState(_ state: OpenZCineCore.WatchRelayState) { relay.ingestState(state) }
    func retireSource() { relay.retireSource() }
    func close() { relay.close() }
    func ingestFrame(
        image: UIImage, applying effects: LiveImageEffects? = nil,
        timecode: Timecode, isRecording: Bool
    ) {
        guard isReady else { return }
        let renderer: LiveFrameRenderer?
        if let effects, !effects.isIdentity {
            if frameRenderer == nil {
                frameRenderer = LiveFrameRenderer(fileStore: CustomLUTStore.nikon)
            }
            renderer = frameRenderer
        } else {
            renderer = nil
        }
        relay.ingestPreview(
            WatchNativePreview(
                image: image, effects: effects, renderer: renderer,
                timecode: timecode, isRecording: isRecording))
    }

    // Preserve the original exercised static selectors as bounded native adapters.
    nonisolated static func encodedFrameData(_ image: UIImage, quality: CGFloat) -> Data? {
        WatchUIImagePreviewEncoder.encodedFrameData(
            image, quality: quality, format: .heifWithJPEGFallback)
    }
    nonisolated static func thumbnailJPEG(
        from image: UIImage, applying effects: LiveImageEffects? = nil,
        renderer: LiveFrameRenderer? = nil, maxWidth: CGFloat, quality: CGFloat
    ) async -> Data? {
        let render: (@Sendable (UIImage) async -> UIImage)?
        if let effects, !effects.isIdentity {
            guard let renderer else { return nil }
            render = { await renderer.renderStaticFrame($0, effects: effects) }
        } else {
            render = nil
        }
        return await WatchUIImagePreviewEncoder.thumbnail(
            from: image, maxWidth: maxWidth,
            quality: quality, format: .heifWithJPEGFallback, render: render)
    }
}
