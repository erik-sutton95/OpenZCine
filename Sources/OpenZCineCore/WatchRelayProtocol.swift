import Foundation

/// Wire protocol shared by the iPhone relay and the watchOS companion.
///
/// The iPhone owns the single PTP control session and forwards a downscaled preview feed plus a
/// small state snapshot to the Watch; the Watch relays a Record toggle back. All payloads are
/// `Codable` + `Sendable` so both targets encode and decode them identically. Messages travel over
/// `WCSession.sendMessageData` framed by ``WatchRelayEnvelope``: a one-byte kind prefix followed by
/// a JSON payload.
public enum WatchRelayProtocol {
    /// Wire framing: a one-byte kind tag followed by the JSON-encoded payload.
    public enum Kind: UInt8, Sendable {
        /// Phone → watch: a ``WatchRelayState`` snapshot (sent on every change).
        case state = 0x01
        /// Phone → watch: a throttled ``WatchRelayFrame`` preview image.
        case frame = 0x02
        /// Watch → phone: a ``WatchRelayCommand``.
        case command = 0x10
        /// Phone → watch: a ``WatchCommandResult`` reply to a command.
        case result = 0x11
    }
}

/// Connection state the watch shows in its top bar / placeholders.
public enum WatchConnectionState: String, Codable, Equatable, Sendable {
    /// The iPhone relay is not reachable (app backgrounded, unpaired, or out of range).
    case disconnected
    /// The iPhone is connected to a camera and streaming.
    case connected
    /// The iPhone is foreground but has no camera session.
    case noCamera
}

/// Phone → watch state snapshot. Deliberately omits the heavy capture-settings strip; it carries
/// only what the watch monitor renders in its top bar and record control.
public struct WatchRelayState: Codable, Equatable, Sendable {
    public init(
        recordState: RecordState,
        timecode: Timecode,
        mediaStatus: MediaStatus?,
        media: String,
        cameraBatteryPercent: Int,
        cameraName: String,
        isRecording: Bool,
        connection: WatchConnectionState,
        feedLive: Bool,
        liveFPS: String
    ) {
        self.recordState = recordState
        self.timecode = timecode
        self.mediaStatus = mediaStatus
        self.media = media
        self.cameraBatteryPercent = cameraBatteryPercent
        self.cameraName = cameraName
        self.isRecording = isRecording
        self.connection = connection
        self.feedLive = feedLive
        self.liveFPS = liveFPS
    }

    public let recordState: RecordState
    public let timecode: Timecode
    public let mediaStatus: MediaStatus?  // structured media capacity, when the camera reports it
    public let media: String  // fallback media readout when no structured status is available
    public let cameraBatteryPercent: Int  // 0–100
    public let cameraName: String
    public let isRecording: Bool
    public let connection: WatchConnectionState
    public let feedLive: Bool  // false in Command mode
    public let liveFPS: String
}

/// Phone → watch preview frame. Throttled and drop-stale (only the latest matters).
public struct WatchRelayFrame: Codable, Equatable, Sendable {
    public init(jpeg: Data, timecode: Timecode, isRecording: Bool) {
        self.jpeg = jpeg
        self.timecode = timecode
        self.isRecording = isRecording
    }

    public let jpeg: Data  // downscaled, re-encoded JPEG preview payload
    public let timecode: Timecode  // timecode at capture, for overlay alignment
    public let isRecording: Bool  // record state when this frame was captured
}

/// Watch → phone command. Record-only by design.
public enum WatchRelayCommand: String, Codable, Equatable, Sendable {
    /// Toggle recording (start if stopped, stop if recording).
    case toggleRecord
}

/// Phone → watch reply acknowledging a ``WatchRelayCommand``.
public struct WatchCommandResult: Codable, Equatable, Sendable {
    public init(accepted: Bool, isRecording: Bool, error: String?) {
        self.accepted = accepted
        self.isRecording = isRecording
        self.error = error
    }

    public let accepted: Bool  // whether the phone accepted and acted on the command
    public let isRecording: Bool  // record state after the command was processed
    public let error: String?  // human-readable rejection reason when `accepted` is false
}

/// Errors raised while framing or parsing a relay envelope.
public enum WatchRelayEnvelopeError: Error, Equatable, Sendable {
    /// The envelope was empty (no kind byte).
    case empty
    /// The leading kind byte did not match a known ``WatchRelayProtocol/Kind``.
    case unknownKind(UInt8)
}

/// One-byte-tagged JSON framing over `WCSession.sendMessageData`.
public enum WatchRelayEnvelope {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Frames a payload as `[kind byte] + JSON`.
    public static func encode<Payload: Encodable>(
        kind: WatchRelayProtocol.Kind,
        payload: Payload
    ) throws -> Data {
        var data = Data([kind.rawValue])
        data.append(try encoder.encode(payload))
        return data
    }

    /// Reads the kind byte off an envelope without decoding its payload.
    public static func kind(of envelope: Data) throws -> WatchRelayProtocol.Kind {
        guard let first = envelope.first else { throw WatchRelayEnvelopeError.empty }
        guard let kind = WatchRelayProtocol.Kind(rawValue: first) else {
            throw WatchRelayEnvelopeError.unknownKind(first)
        }
        return kind
    }

    /// Decodes the JSON payload of an envelope as the requested type.
    public static func decode<Payload: Decodable>(
        _ type: Payload.Type,
        from envelope: Data
    ) throws -> Payload {
        guard !envelope.isEmpty else { throw WatchRelayEnvelopeError.empty }
        return try decoder.decode(Payload.self, from: envelope.dropFirst())
    }
}
