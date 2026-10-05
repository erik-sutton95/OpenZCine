import Foundation
import OpenCineApple
import UIKit

/// Source choices over the native decode/filter/lease owner.
final class FrameDecoder: Sendable {
    private let native = MonitorJPEGImageDecoder(
        logSubsystem: "OpenZCine",
        denoiseStrength: {
            LiveDenoiseSwitch.decoderReadsEnabled ? LiveDenoiseSwitch.decoderReadsStrength : nil
        },
        unavailable: { LiveDenoiseSwitch.decoderReportsUnavailable = $0 }
    )

    func source(_ owner: AnyObject) -> MonitorJPEGDecodeSource? { native.source(owner) }
    func retireSource() -> MonitorJPEGDecodeSource { native.retireSource() }

    func resetProcessors(source: MonitorJPEGDecodeSource) async {
        await native.resetProcessors(source: source)
    }

    func decode(_ jpeg: Data, source: MonitorJPEGDecodeSource) async -> sending UIImage? {
        await native.decode(jpeg, source: source, preferHardware: !DemoHarness.forcesCPUJPEGDecode)
    }
}
