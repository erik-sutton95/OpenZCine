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
        /// Watch → phone: which part of the picture the wrist is actually showing.
        case viewport = 0x12
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
    /// The watch came back to the foreground: resend a state snapshot and restart the frame pump.
    ///
    /// A dimmed display suspends the watch app, and any frames in flight at that moment are never
    /// acked — so the phone's pump can be left holding a permit that will not come back while the
    /// watch shows a stale picture. The watch asking on wake is what clears both sides (#187).
    case resume
}

/// Watch → phone: the region of the frame the wrist is currently displaying.
///
/// The crown zoom happens entirely on the watch, but the ENCODE should not: magnifying a 416 px
/// frame magnifies its blocks. Reporting the region lets the phone crop the source to it before
/// the downscale, so every encoded pixel lands on screen and detail scales with the zoom at no
/// extra bandwidth. The phone's own view never zooms — it only learns which rectangle to send.
///
/// The centre is normalized (0...1) rather than an offset in points, so the phone needs to know
/// nothing about the watch's frame size or its pan clamping.
public struct WatchViewportRegion: Codable, Equatable, Sendable {
    public init(zoom: Double, centerX: Double, centerY: Double) {
        // A zoom below 1 has no meaning here and would invert the crop.
        self.zoom = max(1, zoom)
        self.centerX = min(max(centerX, 0), 1)
        self.centerY = min(max(centerY, 0), 1)
    }

    public let zoom: Double
    public let centerX: Double
    public let centerY: Double

    /// The whole picture — what an unzoomed watch reports, and the phone's default.
    public static let full = WatchViewportRegion(zoom: 1, centerX: 0.5, centerY: 0.5)

    public var isFullFrame: Bool { zoom <= 1.001 }

    /// The source rectangle to crop, in unit coordinates of the frame.
    ///
    /// Clamped so the window stays inside the picture: the watch bounds its pan the same way, but
    /// the phone must not trust a stale or rounded centre to keep the crop in range.
    public var unitCrop: (x: Double, y: Double, width: Double, height: Double) {
        let side = 1.0 / zoom
        let half = side / 2
        let x = min(max(centerX - half, 0), 1 - side)
        let y = min(max(centerY - half, 0), 1 - side)
        return (x, y, side, side)
    }
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

public enum CameraBatteryGauge: Equatable, Sendable {
    /// Filled bars out of ``barCount``, 1…5.
    case bars(Int)
    /// The body's critical step: one bar, blinking, shutter release disabled.
    case critical
    /// No battery reading yet (or no camera).
    case unknown

    /// Bars in a full gauge, matching the body's own display.
    public static let barCount = 5

    /// Maps a raw `BatteryLevel` value to the gauge the body is showing.
    ///
    /// Values between the documented steps are rounded UP to the step they sit under, so a body
    /// that reports a finer value than the ZR spec allows still never overstates its charge.
    public static func gauge(rawBatteryLevel raw: Int) -> CameraBatteryGauge {
        guard raw > 0 else { return .unknown }
        guard raw > 1 else { return .critical }
        let clamped = min(100, raw)
        // 20/40/60/80/100 -> 1…5. A value inside a step keeps that step's bar count.
        return .bars(max(1, min(barCount, Int(ceil(Double(clamped) / 20.0)))))
    }

    /// Filled bars for rendering, with `critical` drawn as its single blinking bar.
    public var filledBars: Int {
        switch self {
        case .bars(let count): return count
        case .critical: return 1
        case .unknown: return 0
        }
    }

    /// Whether the body has disabled the shutter for exhaustion.
    public var isCritical: Bool { self == .critical }

    /// How urgently the gauge should read, in one definition both shells transcribe.
    ///
    /// The steps are the operator's, not the body's: three bars or more is "fine, carry on", two
    /// is "find a spare", one is "swap now". Splitting it here rather than in each shell is what
    /// stops the two platforms drifting into different warning points for the same charge.
    public enum Urgency: Equatable, Sendable {
        /// 3/5 and above.
        case nominal
        /// 2/5 — a warning, not yet a failure.
        case low
        /// 1/5, including the body's blinking exhaustion step.
        case depleted
    }

    public var urgency: Urgency {
        switch filledBars {
        case ...0: return .nominal  // No reading yet: an unknown gauge must not cry wolf.
        case 1: return .depleted
        case 2: return .low
        default: return .nominal
        }
    }

    /// Whether the gauge should pulse. Only the body's own blinking step does.
    ///
    /// A steady red bar and a pulsing red bar mean different things: the first is "nearly out",
    /// the second is the body reporting the shutter is already disabled. Pulsing everything at one
    /// bar would erase that difference at the moment it matters most.
    public var pulses: Bool { isCritical }
}
