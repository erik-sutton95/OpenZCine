import OpenCineApple
import OpenCineMedia
import UIKit

/// Source value adapter; shared native actor owns decode/downsample and the one pixel walk.
actor FrameScopeSampler {
    private let native = MonitorUIImageScopeSampler()
    func sample(
        from image: UIImage, maxWidth: Int, stride: Int,
        includePoints: Bool = true
    ) async -> OpenCineMedia.ScopeSamples {
        await native.sample(
            from: image, maxWidth: maxWidth, stride: stride,
            includePoints: includePoints, transfer: .rec709, includeSampleCoordinates: true)
    }
}
