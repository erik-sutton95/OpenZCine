import AVFoundation
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import OpenCineApple
import OpenCineMedia
import OpenZCineCore
import UIKit
import os

/// The display render context of the Nikon image graph: display-encoded sRGB working space and
/// 16-bit half-float intermediates, like the live view. Playback renders through the shared
/// playback feed and exports are the shared delivery owner's (`NikonMediaDeliveryCapture.export`).
enum MediaLUT {
    // Match `LiveFrameProcessor`: RGBAh working buffers in display-encoded sRGB so cube
    // trilinear interpolation doesn't posterize when AVFoundation composites 8-bit source frames.
    private static let displayColorSpace =
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    static let renderContext = CIContext(options: [
        .workingFormat: CIFormat.RGBAh,
        .workingColorSpace: displayColorSpace,
        .highQualityDownsample: true,
    ])
}
