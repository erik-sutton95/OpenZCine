import CoreImage
import OpenCineApple
import UIKit

// HDMI/UVC capture glue. The capture source itself (`UVCVideoSource`, its states and the
// format choice) lives in OpenCineCore's OpenCineApple and lends each frame as a
// `DecodedFrameLease`; this app keeps the operator copy and the render into `UIImage`.

/// A frame handed from a background renderer to the main actor.
///
/// `UIImage` is not formally `Sendable`. The instance inside is created off the main actor,
/// never read or mutated there again, and delivered exactly once — the same one-way transfer
/// `FrameDecoder.decode`'s `sending` return performs on the camera's own live-view path.
struct UVCFrameHandoff: @unchecked Sendable {
    let image: UIImage
}

/// Operator copy for the capture states OpenCineApple reports.
extension UVCVideoSourceState {
    /// Operator-facing one-liner. Deliberately says what to *do*, not what went wrong internally.
    var message: String {
        switch self {
        case .unsupportedDevice:
            "HDMI capture needs an iPad. iOS doesn't expose USB capture devices to apps."
        case .permissionDenied:
            "Allow camera access in Settings so the app can read the capture device."
        case .waitingForDevice:
            "Connect the HDMI capture device and the camera's HDMI output."
        case .starting:
            "Starting HDMI capture…"
        case .streaming(let deviceName, let format):
            format.map { "HDMI capture streaming from \(deviceName) at \($0)." }
                ?? "HDMI capture streaming from \(deviceName)."
        case .failed(let reason):
            reason
        }
    }

    /// Short form for a settings row, where `message` would wrap to three lines.
    var shortStatus: String {
        switch self {
        case .unsupportedDevice: "iPad only"
        case .permissionDenied: "No camera access"
        case .waitingForDevice: "Not connected"
        case .starting: "Starting…"
        case .streaming(let deviceName, let format):
            format.map { "\(deviceName) · \($0)" } ?? deviceName
        case .failed: "Failed"
        }
    }
}

/// Renders HDMI capture leases into the bitmaps the monitor's consumers expect.
///
/// ## Why frames become CGImage-backed `UIImage`s
///
/// The monitor's downstream consumers already assume a real bitmap: the scope tap in particular
/// hard-guards on `image.cgImage` (`LiveFrameProcessor.swift:176`) and silently produces nothing
/// without one. A `UIImage(ciImage:)` would render on screen and quietly kill every scope, so each
/// frame is rendered through a `CIContext` to a `CGImage` — the same shape the JPEG path produces
/// via `preparingForDisplay()`.
///
/// ponytail: one GPU→CGImage render per frame. That is the honest cost of matching the existing
/// `liveFrameImage: UIImage?` contract, and it replaces a JPEG decode rather than adding to it. If
/// 1080p60 proves too heavy on hardware, the upgrade is to route the `CVPixelBuffer` straight into
/// `MetalFeedFrameBaker` and leave `liveFrameImage` for the scope tap alone.
///
/// Leases arrive as YCbCr carrying the matrix OpenCineApple decided (BT.709 for an HD signal
/// whose dongle reports none or the UVC class default); `CIImage(cvPixelBuffer:)` decodes with
/// that attachment, so this render is where the HDMI picture becomes RGB.
///
/// An actor so the render runs off the main actor, one frame at a time, inside the consumer's
/// serial loop. Frames the newest-wins stream drops are never rendered.
actor UVCFrameRenderer {
    /// Intermediates are never reused across frames here, so caching them only grows the
    /// working set on a path that already runs alongside the Metal feed baker's own context.
    private let renderContext = CIContext(options: [.cacheIntermediates: false])

    /// Renders `lease` and releases it, returning the capture buffer to its pool. Nil when the
    /// lease was already released or the render failed.
    func image(from lease: DecodedFrameLease) -> UVCFrameHandoff? {
        defer { lease.release() }
        guard let pixelBuffer = lease.pixelBuffer else { return nil }
        let source = CIImage(cvPixelBuffer: pixelBuffer)
        guard
            let rendered = autoreleasepool(invoking: {
                renderContext.createCGImage(source, from: source.extent)
            })
        else { return nil }
        return UVCFrameHandoff(image: UIImage(cgImage: rendered))
    }
}
