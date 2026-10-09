import OpenCineWatch
import OpenZCineCore
import UIKit

typealias WatchSessionController = WatchReceiver<DeployedWatchRelayCodec>

extension WatchReceiver where Codec == DeployedWatchRelayCodec {
    convenience init() {
        #if targetEnvironment(simulator)
            self.init(
                codec: DeployedWatchRelayCodec(), acceptsContext: false,
                simulatorImage: Self.simulatedFrame)
        #else
            self.init(codec: DeployedWatchRelayCodec(), acceptsContext: false)
        #endif
    }
    #if targetEnvironment(simulator)
        /// Existing native SIMULATED picture content; no runtime or presentation policy.
        private static var simulatedFrame: UIImage? {
            let size = CGSize(width: 320, height: 180)
            let space = CGColorSpaceCreateDeviceRGB()
            guard
                let context = CGContext(
                    data: nil, width: Int(size.width), height: Int(size.height),
                    bitsPerComponent: 8, bytesPerRow: 0, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
                let gradient = CGGradient(
                    colorsSpace: space,
                    colors: [
                        CGColor(srgbRed: 0.30, green: 0.20, blue: 0.60, alpha: 1),
                        CGColor(srgbRed: 0.20, green: 0.60, blue: 0.70, alpha: 1),
                    ] as CFArray, locations: [0, 1])
            else { return nil }
            context.drawLinearGradient(
                gradient, start: .zero,
                end: CGPoint(x: size.width, y: size.height), options: [])
            return context.makeImage().map { UIImage(cgImage: $0) }
        }
    #endif
}
