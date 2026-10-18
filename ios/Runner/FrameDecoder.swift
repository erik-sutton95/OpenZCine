import Foundation
import OpenCineApple
import UIKit

/// Source choices over the native decode/filter/lease owner.
final class FrameDecoder: Sendable {
    private let native: MonitorJPEGImageDecoder

    init(
        native: MonitorJPEGImageDecoder = MonitorJPEGImageDecoder(
            logSubsystem: "OpenZCine",
            denoiseStrength: {
                LiveDenoiseSwitch.decoderReadsEnabled ? LiveDenoiseSwitch.decoderReadsStrength : nil
            },
            unavailable: { LiveDenoiseSwitch.decoderReportsUnavailable = $0 }
        )
    ) { self.native = native }

    func source(_ owner: AnyObject) -> MonitorJPEGDecodeSource? { native.source(owner) }
    func retireSource() -> MonitorJPEGDecodeSource { native.retireSource() }

    func resetProcessors(source: MonitorJPEGDecodeSource) async {
        await native.resetProcessors(source: source)
    }

    func decode(
        _ jpeg: Data, source: MonitorJPEGDecodeSource,
        incident: NikonFeedIncidentProducer.Preview? = nil
    ) async -> sending UIImage? {
        incident?.submitted()
        let image = await native.decode(
            jpeg, source: source, preferHardware: !DemoHarness.forcesCPUJPEGDecode)
        if image != nil { incident?.decoded() }
        return image
    }
}
