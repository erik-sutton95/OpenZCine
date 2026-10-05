import UIKit
import OpenCineApple
import OpenCineMedia
import OpenZCineCore

/// Source value adapter; shared native actor owns decode/downsample and the one pixel walk.
actor FrameScopeSampler {
    private let native = MonitorUIImageScopeSampler()
    func sample(from image: UIImage, maxWidth: Int, stride: Int,
        includePoints: Bool = true) async -> OpenZCineCore.ScopeSamples {
        let raw = await native.sample(from: image, maxWidth: maxWidth, stride: stride,
            includePoints: includePoints, transfer: .rec709, includeSampleCoordinates: true)
        return sourceSamples(raw)
    }
    func sample(_ jpeg: Data, maxWidth: Int, stride: Int,
        includePoints: Bool = true) async -> OpenZCineCore.ScopeSamples {
        let raw = await native.sample(jpeg, maxWidth: maxWidth, stride: stride,
            includePoints: includePoints, transfer: .rec709, includeSampleCoordinates: true)
        return sourceSamples(raw)
    }
    private func sourceSamples(_ raw: OpenCineMedia.ScopeSamples) -> OpenZCineCore.ScopeSamples {
        OpenZCineCore.ScopeSampler.sourceSamples(raw)
    }
}
