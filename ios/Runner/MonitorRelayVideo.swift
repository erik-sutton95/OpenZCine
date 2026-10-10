import CoreGraphics
import Foundation
import OpenCineRelay
import OpenCineRelayApple
import OpenZCineCore
import UIKit

typealias MonitorRelayVideoEncoder = RelayAppleImageEncoder
typealias MonitorRelayBroadcastPipeline = RelayAppleBroadcastPipeline<DeployedMonitorRelayCodec>

// The SDK image is retained immutably for the bounded off-actor JPEG fallback.
final class MonitorRelayJPEGImage: @unchecked Sendable {
    private let image: UIImage
    init(_ image: UIImage) { self.image = image }
    func encode() -> Data? { image.jpegData(compressionQuality: 0.6) }
}

// Immutable source policy facts and bounded OS image conversion. Shared owns rate/queue,
// adaptation, keyframe, source/peer/encoder retirement and HEVC/JPEG fallback scheduling.
extension RelayAppleBroadcastPipeline where Codec == DeployedMonitorRelayCodec {
    convenience init(
        host: MonitorRelayHost, profile: RelayEncoderProfile, frameInterval: TimeInterval
    ) {
        self.init(
            host: host, codec: DeployedMonitorRelayCodec(), profile: profile,
            starvation: .init(
                absoluteFloorFPS: RelayCameraStarvePolicy.absoluteFloorFPS,
                baselineFraction: RelayCameraStarvePolicy.baselineFraction),
            frameInterval: frameInterval,
            projectVideo: { metadata, video in
                metadata.carryingVideo(
                    codec: video.codec, isKeyframe: video.isKeyframe,
                    parameterSets: video.parameterSets)
            },
            jpeg: { UIImage(cgImage: $0).jpegData(compressionQuality: 0.6) },
            journal: { logConnection($0) },
            makeEncoder: {
                RelayAppleImageEncoder(profile: $0, logSubsystem: "com.opencapture.openzcine")
            })
    }
}

// The common native decoder returns a CGImage. UIKit conversion is a thin app SDK leaf;
// parameter sets, reference chain, queue/session invalidation and stale output are shared.
final class MonitorRelayVideoDecoder: @unchecked Sendable {
    private let owner = RelayAppleImageDecoder(logSubsystem: "com.opencapture.openzcine")
    func invalidate() { owner.invalidate() }
    func decode(
        _ data: Data, isKeyframe: Bool, parameterSets: [Data]?,
        completion: @escaping @Sendable (UIImage?) -> Void
    ) {
        owner.decode(data, isKeyframe: isKeyframe, parameterSets: parameterSets) { image in
            completion(image.map { UIImage(cgImage: $0) })
        }
    }
}
