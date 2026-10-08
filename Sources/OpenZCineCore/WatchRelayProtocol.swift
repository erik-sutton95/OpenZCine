import Foundation
import OpenCineNikon
import OpenCineRelay

// Preserve the independently deployed Watch v1 fields. Pocket's Watch schema uses strings for
// different values and is not substituted for these original typed Nikon payloads.
public typealias WatchRelayProtocol = NikonWatchRelayProtocol
public typealias WatchConnectionState = NikonWatchConnectionState
public typealias WatchRelayState = NikonWatchRelayState
public typealias WatchRelayFrame = NikonWatchRelayFrame
public typealias WatchRelayCommand = NikonWatchRelayCommand
public typealias WatchCommandResult = NikonWatchCommandResult
public typealias CameraBatteryGauge = NikonCameraBatteryGauge

public enum WatchRelayEnvelopeError: Error, Equatable, Sendable {
    case empty
    case unknownKind(UInt8)
}

/// Compatibility shape over the common one-byte JSON envelope owner. Actual payload types and
/// error cases stay unchanged; no app-specific encoder/decoder or framing state remains.
public enum WatchRelayEnvelope {
    public static func encode<Payload: Encodable>(kind: WatchRelayProtocol.Kind, payload: Payload)
        throws -> Data
    {
        try RelayEnvelopeFraming.encode(kind: kind.rawValue, payload: payload)
    }
    public static func kind(of envelope: Data) throws -> WatchRelayProtocol.Kind {
        do {
            let raw = try RelayEnvelopeFraming.kind(
                of: envelope, admittedKinds: [0x01, 0x02, 0x10, 0x11])
            guard let kind = WatchRelayProtocol.Kind(rawValue: raw) else {
                throw WatchRelayEnvelopeError.unknownKind(raw)
            }
            return kind
        } catch let error as RelayEnvelopeFraming.DecodeError {
            switch error {
            case .empty: throw WatchRelayEnvelopeError.empty
            case .unknownKind(let raw): throw WatchRelayEnvelopeError.unknownKind(raw)
            }
        }
    }
    public static func decode<Payload: Decodable>(_ type: Payload.Type, from envelope: Data) throws
        -> Payload
    {
        do { return try RelayEnvelopeFraming.decode(type, from: envelope) } catch let error
            as RelayEnvelopeFraming.DecodeError
        {
            switch error {
            case .empty: throw WatchRelayEnvelopeError.empty
            case .unknownKind(let raw): throw WatchRelayEnvelopeError.unknownKind(raw)
            }
        }
    }
}

/// Exact deployed payload facts over the shared phone/Watch lifetime and envelope owners.
public struct DeployedWatchRelayCodec: RelayWatchCodec {
    public init() {}
    public func stateMatches(_ lhs: WatchRelayState, _ rhs: WatchRelayState) -> Bool {
        lhs.matchesIgnoringLiveReadouts(rhs)
    }
    public func sourceFacts(_ state: WatchRelayState) -> RelayWatchSourceFacts {
        let connection: RelayWatchSourceFacts.Connection
        switch state.connection {
        case .disconnected: connection = .disconnected
        case .connected: connection = .connected
        case .noCamera: connection = .noCamera
        }
        return .init(connection: connection, feedLive: state.feedLive)
    }
    public func isRecording(_ state: WatchRelayState) -> Bool { state.isRecording }
    public func replacing(_ state: WatchRelayState, with result: WatchCommandResult) -> WatchRelayState {
        .init(
            recordState: result.isRecording ? .recording : .standby,
            timecode: state.timecode, mediaStatus: state.mediaStatus, media: state.media,
            cameraBatteryPercent: state.cameraBatteryPercent, cameraName: state.cameraName,
            isRecording: result.isRecording, connection: state.connection, feedLive: state.feedLive,
            liveFPS: state.liveFPS, isPhotography: state.isPhotography,
            shotsRemaining: state.shotsRemaining, feedAspectRatio: state.feedAspectRatio)
    }
    public func imageBytes(_ frame: WatchRelayFrame) -> Data { frame.jpeg }
    public func timecode(_ frame: WatchRelayFrame) -> Timecode { frame.timecode }
    public func command(_ action: RelayWatchAction) -> WatchRelayCommand {
        switch action {
        case .toggleRecord: .toggleRecord
        case .capture: .capture
        case .resume: .resume
        }
    }
    public func action(_ command: WatchRelayCommand) -> RelayWatchAction {
        switch command {
        case .toggleRecord: .toggleRecord
        case .capture: .capture
        case .resume: .resume
        }
    }
    public func result(accepted: Bool, isRecording: Bool, error: String?) -> WatchCommandResult {
        .init(accepted: accepted, isRecording: isRecording, error: error)
    }
    public func error(_ result: WatchCommandResult) -> String? { result.error }
}
