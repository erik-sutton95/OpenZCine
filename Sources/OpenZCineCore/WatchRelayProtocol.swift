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
        liveFPS: String,
        isPhotography: Bool = false,
        shotsRemaining: String = "",
        feedAspectRatio: Double = 16.0 / 9.0
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
        self.isPhotography = isPhotography
        self.shotsRemaining = shotsRemaining
        // A non-positive ratio would collapse the wrist's feed box; fall back to cinema.
        self.feedAspectRatio = feedAspectRatio > 0 ? feedAspectRatio : 16.0 / 9.0
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
    /// Whether the body is in stills mode. Sourced on the phone from
    /// ``StillCapturePolicy/prefersPhotographyChrome(selector:)`` so the wrist and the phone can
    /// never disagree about which chrome to show.
    public let isPhotography: Bool
    /// The SHOTS counter, which takes the top bar that timecode vacates in stills. Carried rather
    /// than counted on the watch: two counts of the same captures would drift.
    public let shotsRemaining: String
    /// The feed's shape. Photography frames at the still IMAGE AREA — FX/DX 3:2, 1:1, 16:9 — so
    /// the ratio travels rather than a mode, and a crop change on the body reaches the wrist
    /// without a second table to keep in sync.
    public let feedAspectRatio: Double

    /// Decoded leniently for the three stills fields.
    ///
    /// A default on `init` does NOT reach Codable's synthesised decoder — it still demands every
    /// key — so a payload written before photo mode existed would fail to decode entirely rather
    /// than fall back. That is not hypothetical: the phone and the watch update independently, so
    /// a new watch build routinely reads an old phone's state and vice versa. The golden-fixture
    /// test pins exactly this.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recordState = try container.decode(RecordState.self, forKey: .recordState)
        timecode = try container.decode(Timecode.self, forKey: .timecode)
        mediaStatus = try container.decodeIfPresent(MediaStatus.self, forKey: .mediaStatus)
        media = try container.decode(String.self, forKey: .media)
        cameraBatteryPercent = try container.decode(Int.self, forKey: .cameraBatteryPercent)
        cameraName = try container.decode(String.self, forKey: .cameraName)
        isRecording = try container.decode(Bool.self, forKey: .isRecording)
        connection = try container.decode(WatchConnectionState.self, forKey: .connection)
        feedLive = try container.decode(Bool.self, forKey: .feedLive)
        liveFPS = try container.decode(String.self, forKey: .liveFPS)
        isPhotography =
            try container.decodeIfPresent(Bool.self, forKey: .isPhotography) ?? false
        shotsRemaining =
            try container.decodeIfPresent(String.self, forKey: .shotsRemaining) ?? ""
        let ratio = try container.decodeIfPresent(Double.self, forKey: .feedAspectRatio)
        feedAspectRatio = (ratio ?? 0) > 0 ? (ratio ?? 0) : 16.0 / 9.0
    }
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
    /// Release the shutter. Stills only; the phone routes it to the same still-release path its
    /// own shutter uses rather than a second implementation.
    case capture
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
