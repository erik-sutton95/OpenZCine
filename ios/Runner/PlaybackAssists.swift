import AVFoundation
import MetalKit
import MonitorPresentation
import MonitorUI
import OSLog
import Observation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineMedia
import OpenZCineCore
import SwiftUI

private let playbackAudioLogger = Logger(subsystem: "OpenZCine", category: "media-playback-audio")
private let playbackFeedLogger = Logger(subsystem: "OpenZCine", category: "media-playback-feed")

/// Nikon values for the shared playback engine. The picture, scopes, audio meter, backdrop and
/// inspector are the shared ones; Nikon supplies its calibration (the clip mapping and looks).
extension MonitorAssistConfiguration {
    /// The live scope looks plus the Nikon profile's read-through-display curves, which false
    /// colour's Rec.709 read uses on the shared playback feed.
    static let nikonPlayback = MonitorAssistConfiguration(
        lookCurves: NikonMonitorColorProfile.rec709LookCurves,
        defaultScopeLook: { NikonScopeLook.display(for: $0) }, logSubsystem: "OpenZCine")
}

/// The shared playback feed with Nikon's clip calibration: the recording mapping declares the
/// clip that zebra, false colour and the scopes read.
final class NikonPlaybackFeedSession: MonitorPlaybackFeedSession, @unchecked Sendable {
    @MainActor init(model: NativeAppModel? = nil) {
        super.init(
            configuration: .nikonPlayback, hdrDisplay: { false },
            journal: { line in playbackFeedLogger.debug("\(line, privacy: .public)") },
            declaredClip: { [weak model] transfer in
                guard let mapping = model?.playbackExposureSignalMapping,
                    mapping.curve.monitorTransfer == transfer
                else { return nil }
                return mapping.clipByte
            })
    }
}

/// The native playback picture: the shared feed host over the shared picture host, presenting
/// with the operator's feed upscaler.
final class NikonPlaybackPictureHost: MonitorPlaybackFeedHost {
    init(frame: CGRect = .zero) {
        super.init(
            frame: frame,
            picture: MonitorPictureHost(
                frame: frame,
                options: { _ in
                    MonitorPresentationOptions(
                        upscaler: FeedUpscaleSwitch.rendererReadsUpscaler,
                        previewSuperResolutionInput: FeedUpscaleSwitch
                            .presentsSuperResolutionInput)
                }, logSubsystem: "OpenZCine"))
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// The scope display of Nikon's playback scopes and inspector. Nikon has no HDR panel mode yet,
/// so the scopes draw SDR like the live ones.
@MainActor func nikonScopeDisplay(_ view: MTKView) -> MonitorScopeDisplayOptions { .sdr }

/// Playback audio session failures, as the app logs them.
enum NikonPlaybackAudio {
    static let tapFailure: @Sendable (Int32) -> Void = { status in
        playbackAudioLogger.error("MTAudioProcessingTapCreate failed: \(status)")
    }
    static let audioFailure: @Sendable (String) -> Void = { message in
        playbackAudioLogger.error(
            "Playback audio session failed: \(message, privacy: .public)")
    }
}

extension NativeAppModel {
    /// Nikon's calibration of the shared playback effects: the clip's transfer and clip from
    /// the recording mapping, and the operator's armed look as the cube (Nikon's looks resolve
    /// their cubes in the app, so the shared state carries none). `forceLook` arms the selected
    /// look for an inspector preview while the LUT tool is off on the picture.
    func nikonPlaybackEffects(_ effects: MonitorFrameEffects, forceLook: Bool = false)
        -> MonitorFrameEffects
    {
        var value = effects
        let mapping = playbackExposureSignalMapping
        value.transfer = mapping.curve.monitorTransfer
        value.clipByte = mapping.clipByte
        value.referenceClipByte = mapping.clipByte
        var tools = assist.playbackTools
        if forceLook { tools.insert(.lut) }
        if let armed = armedScopeLUT(visibleTools: tools) {
            let packed = Self.packed(armed, forRenderer: true)
            value.lutDimension = packed.size
            value.lutRGBA = packed.rgba
        } else {
            value.lutDimension = 0
            value.lutRGBA = Data()
            value.splitComparison = false
        }
        return value
    }

    /// The armed look's identity, so a re-imported cube with the same name refreshes previews.
    var nikonPlaybackLookIdentity: AnyHashable? {
        armedScopeLUT(visibleTools: assist.playbackTools.union([.lut])).map { AnyHashable($0.key) }
    }
}

/// The app state Nikon's playback page reads: the shared assists and delivery, and the page's
/// own playback bus, backdrop and inspector renderer.
@MainActor final class NikonPlaybackHost: MonitorMediaHost {
    private let model: NativeAppModel
    let delivery: MonitorDeliveryCoordinator
    let frameSamples = LiveFrameSampleBus()
    let playbackBackdrop = OpenCineAppKitApple.MonitorVideoBackdropRenderer(
        lookCurves: NikonMonitorColorProfile.rec709LookCurves)
    let inspectorRenderer = MonitorInspectorImageRenderer(
        lookCurves: NikonMonitorColorProfile.rec709LookCurves)

    init(model: NativeAppModel, delivery: MonitorDeliveryCoordinator) {
        self.model = model
        self.delivery = delivery
    }

    var assist: NikonAssistState { model.assist }
    var assistToolUsage: MonitorToolUsage {
        get { model.assistToolUsage }
        set { model.assistToolUsage = newValue }
    }
    var monitorSamples: LiveFrameSampleBus { frameSamples }
}

extension MonitorMediaPageValues where Palette == LiveDesign {
    /// Nikon's media page values.
    @MainActor static func nikon(_ model: NativeAppModel) -> Self {
        .init(
            stores: model.scopePanels.playbackStores, looks: .signal, palette: LiveDesign.self,
            haptics: .init(isEnabled: { [weak model] in model?.preferences.hapticsEnabled == true }
            ),
            cacheOriginal: { false }, configureDisplay: nikonScopeDisplay,
            remoteDisplayName: "Frame.io", makePictureHost: { NikonPlaybackPictureHost() })
    }
}

/// The playback inspector's preview: the shared preview over the page's playback bus, with
/// Nikon's calibration and the selected look.
struct NikonPlaybackInspectorPreview: View {
    let tool: MonitorAssistSelection
    let host: NikonPlaybackHost
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        MonitorLookInspectorPreview(
            tool: tool, assist: model.assist, stores: model.scopePanels.playbackStores,
            haptics: .init(isEnabled: { [weak model] in model?.preferences.hapticsEnabled == true }
            ),
            source: MonitorInspectorImageSource(
                renderer: host.inspectorRenderer, samples: host.frameSamples),
            readCustomName: { [weak model] in
                guard case .stored(_, let name)? = model?.assistConfiguration.selectedLUT else {
                    return nil
                }
                return name
            },
            prepareEffects: { [weak model] frame in
                guard let model else { return .init() }
                let mapping = model.playbackExposureSignalMapping
                let effects = model.assist.inspectorImageEffects(
                    tool: tool, transfer: frame.transfer,
                    clipByte: mapping.curve.monitorTransfer == frame.transfer
                        ? mapping.clipByte
                        : frame.exposureCeiling.clipByte(transfer: frame.transfer))
                return model.nikonPlaybackEffects(effects, forceLook: tool == .lut)
            }, readBundle: { host.frameSamples.displayBundle },
            configureDisplay: nikonScopeDisplay,
            readLookIdentity: { [weak model] in model?.nikonPlaybackLookIdentity })
    }
}

/// Loads the displayed video dimensions from an asset's primary video track.
func loadVideoDisplaySize(from asset: AVAsset) async -> CGSize? {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
    guard let naturalSize = try? await track.load(.naturalSize),
        let transform = try? await track.load(.preferredTransform)
    else { return nil }
    return videoDisplaySize(naturalSize: naturalSize, transform: transform)
}
