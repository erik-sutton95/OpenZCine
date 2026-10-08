import Foundation
import OpenCineNikon
import OpenCineRelay

// Deployed v2 wire schemas belong to the Nikon integration. These compatibility names preserve
// actual app/watch/test call sites while generic shared relay owners consume the typed codec.
public typealias MonitorRelayProtocol = NikonMonitorRelayProtocol
public typealias RelayPresence = NikonRelayPresence
public typealias MonitorRelayHello = NikonMonitorRelayHello
public typealias MonitorRelayJoinDenied = NikonMonitorRelayJoinDenied
public typealias MonitorRelayState = NikonMonitorRelayState
public typealias MonitorRelayFrameMetadata = NikonMonitorRelayFrameMetadata
public typealias MonitorRelayCommand = NikonMonitorRelayCommand
public typealias MonitorRelayControlToken = NikonMonitorRelayControlToken
public typealias RelayControlLease = RelayParkedControlLease

/// The deployed wire's only runtime adapter: immutable profile facts and typed frame projection.
/// No framing, authorization, control, retry, queue or camera command policy lives here.
public struct DeployedMonitorRelayCodec: RelayWireCodec {
    public typealias State = MonitorRelayState
    public typealias FrameMetadata = MonitorRelayFrameMetadata
    public typealias Command = MonitorRelayCommand
    public typealias ControlToken = MonitorRelayControlToken
    public typealias JoinDenied = MonitorRelayJoinDenied
    public let profile = RelayWireProfile(
        serviceType: MonitorRelayProtocol.serviceType, version: MonitorRelayProtocol.version,
        maximumPayloadBytes: MonitorRelayProtocol.maximumPayloadBytes,
        servedCameraTXTKey: MonitorRelayProtocol.servedCameraTXTKey,
        watchableTXTKey: MonitorRelayProtocol.watchableTXTKey,
        presenceTCPPort: MonitorRelayProtocol.presenceTCPPort,
        jpegCodec: MonitorRelayProtocol.FrameCodec.jpeg,
        hevcCodec: MonitorRelayProtocol.FrameCodec.hevc,
        acceptsPeerCodecDeclaration: true)

    public init() {}

    public func videoDescription(of metadata: FrameMetadata) -> RelayVideoDescription {
        RelayVideoDescription(
            codec: metadata.codec, isKeyframe: metadata.isKeyframe,
            parameterSets: metadata.parameterSets)
    }
    public func controlToken(holderName: String, holderIsRecipient: Bool) -> ControlToken {
        ControlToken(holderName: holderName, holderIsRecipient: holderIsRecipient)
    }
    public func joinDenied(reason: String, passcodeRequired: Bool) -> JoinDenied {
        JoinDenied(reason: reason, passcodeRequired: passcodeRequired)
    }
}

/// Compatibility tag/error shape, delegating every byte operation to the shared owner.
public enum MonitorRelayFraming {
    public static let headerBytes = RelayStreamFraming.headerBytes
    public struct Decoded: Equatable, Sendable {
        public let kind: MonitorRelayProtocol.Kind
        public let payload: Data
        public let consumedBytes: Int
        public init(kind: MonitorRelayProtocol.Kind, payload: Data, consumedBytes: Int) {
            self.kind = kind
            self.payload = payload
            self.consumedBytes = consumedBytes
        }
    }
    public enum DecodeError: Error, Equatable, Sendable {
        case payloadTooLarge(declared: Int)
        case unknownKind(UInt8)
    }
    public static func encode(kind: MonitorRelayProtocol.Kind, payload: Data) -> Data {
        RelayStreamFraming.encode(kind: kind.rawValue, payload: payload)
    }
    public static func decode(from buffer: Data) throws -> Decoded? {
        do {
            guard
                let decoded = try RelayStreamFraming.decode(
                    from: buffer, profile: DeployedMonitorRelayCodec().profile)
            else { return nil }
            guard let kind = MonitorRelayProtocol.Kind(rawValue: decoded.kind) else {
                throw DecodeError.unknownKind(decoded.kind)
            }
            return Decoded(
                kind: kind, payload: decoded.payload, consumedBytes: decoded.consumedBytes)
        } catch let error as RelayStreamFraming.DecodeError {
            switch error {
            case .payloadTooLarge(let declared):
                throw DecodeError.payloadTooLarge(declared: declared)
            case .unknownKind(let kind): throw DecodeError.unknownKind(kind)
            }
        }
    }
}

public enum MonitorRelayFramePayload {
    public struct Decoded: Equatable, Sendable {
        public let metadata: MonitorRelayFrameMetadata
        public let image: Data
        public init(metadata: MonitorRelayFrameMetadata, image: Data) {
            self.metadata = metadata
            self.image = image
        }
    }
    public enum DecodeError: Error, Equatable, Sendable { case truncated }
    public static func encode(metadata: MonitorRelayFrameMetadata, image: Data) throws -> Data {
        try RelayFrameBlob.encode(metadata: metadata, image: image)
    }
    public static func decode(_ payload: Data) throws -> Decoded {
        do {
            let decoded = try RelayFrameBlob.decode(MonitorRelayFrameMetadata.self, from: payload)
            return Decoded(metadata: decoded.metadata, image: decoded.image)
        } catch is RelayFrameBlob.DecodeError { throw DecodeError.truncated }
    }
}
