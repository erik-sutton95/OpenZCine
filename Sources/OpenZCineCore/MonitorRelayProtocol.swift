import Foundation

/// Wire protocol for the monitor relay: one device holds the single camera session and serves the
/// picture plus the camera's readings to other devices on set.
///
/// ## Why a relay exists at all
///
/// PTP-IP serves ONE initiator at a time — the handshake has a dedicated `busy` refusal for a
/// second one — and every install presents the same initiator identity, so the camera cannot even
/// tell two of the operator's devices apart. Multiple screens therefore cannot each hold their own
/// session; one device has to hold it and re-serve what it sees.
///
/// ## Why it works on every camera transport
///
/// The relay link is deliberately independent of the camera link, so the two never compete for the
/// same radio:
/// - **Router / phone hotspot** — host and viewers share a network; the service resolves over it.
/// - **Camera access point** — the camera's own AP typically accepts a single client, so viewers
///   cannot join it. The host stays on the camera's network and serves viewers over the
///   peer-to-peer interface *alongside* that association.
/// - **Cable link** — the host is wired to the camera, so its radio is entirely free. This is the
///   easiest case, not the hardest.
///
/// One Bonjour listener/browser pair covers all of it, because peer-to-peer is a parameter on the
/// same API rather than a separate transport.
public enum MonitorRelayProtocol {
    /// Bonjour service type. Must also appear in the app's `NSBonjourServices`, or the browser is
    /// silently denied on iOS.
    public static let serviceType = "_openzcine-mon._tcp"

    /// Wire version. A viewer refuses a host it cannot speak to rather than rendering nonsense.
    /// Version 2: frames carry a codec discriminator — HEVC with in-band parameter sets, or JPEG.
    public static let version = 2

    /// Frame codec discriminators. Numeric on the wire, like the focus result: an added codec
    /// must never shift the meaning of a value already in flight.
    public enum FrameCodec {
        public static let jpeg = 0
        public static let hevc = 1
    }

    /// Message tag, the first byte of every framed payload.
    public enum Kind: UInt8, Sendable {
        /// Host → viewer, once per connection, before anything else.
        case hello = 0x01
        /// Host → viewer: the slow-moving camera readouts.
        case state = 0x02
        /// Host → viewer: one picture, plus the per-frame readings that ride with it.
        case frame = 0x03
        /// Host → viewer: who currently holds the camera.
        case controlToken = 0x04
        /// Viewer → host: asking for the camera.
        case requestControl = 0x10
        /// Viewer → host: handing it back.
        case releaseControl = 0x11
        /// Viewer → host: a camera command, honoured only from the control holder.
        case command = 0x12
        /// Host → viewer: the join was refused (wrong or missing passcode). Sent instead of
        /// state/frames; the viewer surfaces the reason and, when `passcodeRequired`, asks for
        /// the code and rejoins.
        case joinDenied = 0x05
    }

    /// Maximum payload a single message may carry.
    ///
    /// A monitor frame is a live-view JPEG, tens of kilobytes; this is far above anything the
    /// protocol produces and exists purely so a desynchronised or hostile stream cannot make the
    /// reader allocate without bound.
    public static let maximumPayloadBytes = 8 * 1024 * 1024

    /// Bonjour TXT key carrying the camera host this broadcast serves. The body accepts one
    /// initiator, so every device that can SEE a broadcast must keep its own discovery probes
    /// off that address — a foreign Init against a served camera drops the broadcaster's
    /// session. Advertised (rather than sent in-session) so the exclusion protects the camera
    /// from devices that merely have the camera list open, not only from joined watchers.
    public static let servedCameraTXTKey = "ch"

    /// Bonjour TXT key distinguishing a joinable broadcast from a "camera in use" beacon.
    /// Absent or any value other than `"0"` means watchable (older builds advertise no key).
    /// A beacon exists so the `ch=` probe shield protects a held camera even when the operator
    /// is not sharing — the sharing-off knock storm.
    public static let watchableTXTKey = "w"

    /// Fixed unicast presence port: any device holding or sharing a camera answers one TCP
    /// connection here with a single ``RelayPresence`` JSON line and closes. Discovery's
    /// subnet sweep checks it beside the camera probe — unicast survives the multicast
    /// filtering managed networks apply between wireless clients (which silently eats mDNS),
    /// so presence keeps the broadcast list and the probe shield alive there. It is also the
    /// detector: a presence answer from a device Bonjour never reported is PROOF the network
    /// filters discovery, and the operator is told.
    public static let presenceTCPPort: UInt16 = 15741
}

/// One-line unicast answer from a device holding or sharing a camera (see
/// `MonitorRelayProtocol.presenceTCPPort`). Keys are deliberately terse and contract-pinned on
/// both platforms: `v` version, `n` device name, `w` 1 = joinable broadcast / 0 = in-use
/// beacon, `ch` served camera host, `p` relay listener port when joinable.
public struct RelayPresence: Codable, Equatable, Sendable {
    public var v: Int
    public var n: String
    public var w: Int
    public var ch: String?
    public var p: Int?

    public init(name: String, watchable: Bool, servedCameraHost: String?, relayPort: Int?) {
        self.v = 1
        self.n = name
        self.w = watchable ? 1 : 0
        self.ch = servedCameraHost
        self.p = relayPort
    }

    public var isWatchable: Bool { w != 0 }

    /// Encodes the single wire line, newline-terminated.
    public func encodedLine() -> Data {
        // Codable JSON of this flat struct cannot fail; the newline is the frame delimiter.
        var data = (try? JSONEncoder().encode(self)) ?? Data()
        data.append(0x0A)
        return data
    }

    /// Decodes a received line (with or without the trailing newline); nil for garbage or a
    /// version this build does not speak.
    public static func decode(_ data: Data) -> RelayPresence? {
        let trimmed = data.last == 0x0A ? data.dropFirst(0).dropLast() : data[...]
        guard let presence = try? JSONDecoder().decode(RelayPresence.self, from: Data(trimmed)),
            presence.v == 1, !presence.n.isEmpty
        else { return nil }
        return presence
    }
}

/// Host → viewer introduction — and viewer → host, where it may carry the watcher passcode.
public struct MonitorRelayHello: Codable, Equatable, Sendable {
    public init(
        version: Int, hostName: String, cameraName: String?, passcode: String? = nil,
        codecs: [String]? = nil
    ) {
        self.version = version
        self.hostName = hostName
        self.cameraName = cameraName
        self.passcode = passcode
        self.codecs = codecs
    }

    public let version: Int
    /// The broadcasting device's name, as the viewer's picker shows it.
    public let hostName: String
    /// The camera the host is holding, when it has one.
    public let cameraName: String?
    /// Viewer → host only: the watcher passcode, when the broadcast requires one. Optional on
    /// the wire so payloads from before the field decode unchanged.
    public let passcode: String?
    /// Viewer → host only: frame codecs this viewer can decode (`"hevc"`, `"jpeg"`). Absent —
    /// including every payload from before the field — means everything, so old watchers keep
    /// their HEVC stream. A device whose HEVC decoders reject the stream (low-end hardware
    /// without Main10, software decoders that error on it) rejoins declaring `["jpeg"]` and
    /// the host serves it JPEG instead: codec negotiation, not per-chipset whack-a-mole.
    public let codecs: [String]?

    /// Whether this viewer accepts HEVC frames (absent codec list = yes, legacy behavior).
    public var acceptsHEVC: Bool { codecs?.contains("hevc") ?? true }
}

/// Host → viewer join refusal.
public struct MonitorRelayJoinDenied: Codable, Equatable, Sendable {
    public init(reason: String, passcodeRequired: Bool) {
        self.reason = reason
        self.passcodeRequired = passcodeRequired
    }
    public let reason: String
    public let passcodeRequired: Bool
}

/// Host → viewer camera readouts. Mirrors the fields the monitor chrome renders rather than
/// re-using `CameraDisplayState`, which is not `Codable` and carries UI-shaped helpers a viewer
/// derives for itself.
public struct MonitorRelayState: Codable, Equatable, Sendable {
    public struct Value: Codable, Equatable, Sendable {
        public init(label: String, value: String) {
            self.label = label
            self.value = value
        }
        public let label: String
        public let value: String
    }

    public init(
        recordState: RecordState,
        resolutionFrameRate: String,
        codec: String,
        media: String,
        liveFPS: String,
        cameraBatteryPercent: Int,
        cameraName: String,
        lens: String,
        temperature: String,
        values: [Value],
        mediaStatus: MediaStatus?,
        isRecording: Bool,
        allowsControlRequests: Bool? = nil
    ) {
        self.recordState = recordState
        self.resolutionFrameRate = resolutionFrameRate
        self.codec = codec
        self.media = media
        self.liveFPS = liveFPS
        self.cameraBatteryPercent = cameraBatteryPercent
        self.cameraName = cameraName
        self.lens = lens
        self.temperature = temperature
        self.values = values
        self.mediaStatus = mediaStatus
        self.isRecording = isRecording
        self.allowsControlRequests = allowsControlRequests
    }

    public let recordState: RecordState
    public let resolutionFrameRate: String
    public let codec: String
    public let media: String
    public let liveFPS: String
    public let cameraBatteryPercent: Int
    public let cameraName: String
    public let lens: String
    public let temperature: String
    public let values: [Value]
    public let mediaStatus: MediaStatus?
    public let isRecording: Bool
    /// Whether the host accepts watcher control requests. Optional on the wire (older hosts
    /// don't send it); absent means allowed — the pre-policy behavior.
    public var allowsControlRequests: Bool?
}

/// The readings that belong to one specific frame, sent alongside it.
///
/// These come out of the camera's live-view header, which the host is pulling anyway. Carrying
/// them with the picture rather than in `MonitorRelayState` keeps the AF box locked to the frame
/// it was measured on — a box that arrives a message late sits visibly off its subject.
public struct MonitorRelayFrameMetadata: Codable, Equatable, Sendable {
    public struct Box: Codable, Equatable, Sendable {
        public init(centerX: Int, centerY: Int, width: Int, height: Int) {
            self.centerX = centerX
            self.centerY = centerY
            self.width = width
            self.height = height
        }
        public let centerX: Int
        public let centerY: Int
        public let width: Int
        public let height: Int
    }

    public struct Focus: Codable, Equatable, Sendable {
        public init(
            coordinateWidth: Int, coordinateHeight: Int, focusResult: Int,
            subjectDetectionActive: Bool, trackingAFActive: Bool, selectedBoxIndex: Int?,
            boxes: [Box]
        ) {
            self.coordinateWidth = coordinateWidth
            self.coordinateHeight = coordinateHeight
            self.focusResult = focusResult
            self.subjectDetectionActive = subjectDetectionActive
            self.trackingAFActive = trackingAFActive
            self.selectedBoxIndex = selectedBoxIndex
            self.boxes = boxes
        }
        public let coordinateWidth: Int
        public let coordinateHeight: Int
        /// 0 unknown, 1 not focused, 2 focused — kept numeric so the wire format does not move
        /// when the enum gains a case.
        public let focusResult: Int
        public let subjectDetectionActive: Bool
        public let trackingAFActive: Bool
        public let selectedBoxIndex: Int?
        public let boxes: [Box]
    }

    public struct Sound: Codable, Equatable, Sendable {
        public init(peakLeft: Int, peakRight: Int, currentLeft: Int, currentRight: Int) {
            self.peakLeft = peakLeft
            self.peakRight = peakRight
            self.currentLeft = currentLeft
            self.currentRight = currentRight
        }
        public let peakLeft: Int
        public let peakRight: Int
        public let currentLeft: Int
        public let currentRight: Int
    }

    public init(
        timecode: Timecode?, isRecording: Bool, focus: Focus?, levelRoll: Double?,
        levelPitch: Double?, sound: Sound?, codec: Int = MonitorRelayProtocol.FrameCodec.jpeg,
        isKeyframe: Bool = true, parameterSets: [Data]? = nil, rotation: Int? = nil
    ) {
        self.timecode = timecode
        self.isRecording = isRecording
        self.focus = focus
        self.levelRoll = levelRoll
        self.levelPitch = levelPitch
        self.sound = sound
        self.codec = codec
        self.isKeyframe = isKeyframe
        self.parameterSets = parameterSets
        self.rotation = rotation
    }

    public let timecode: Timecode?
    public let isRecording: Bool
    public let focus: Focus?
    public let levelRoll: Double?
    public let levelPitch: Double?
    public let sound: Sound?
    /// `MonitorRelayProtocol.FrameCodec`. JPEG decodes standalone; HEVC frames reference earlier
    /// ones, which is where the keyframe machinery below comes from.
    public let codec: Int
    /// Whether this frame decodes without any predecessor. Always true for JPEG.
    public let isKeyframe: Bool
    /// HEVC parameter sets (VPS/SPS/PPS), present on keyframes so a joiner can build a decoder
    /// from the stream alone — there is no side channel to fetch them from.
    public let parameterSets: [Data]?
    /// The body's own orientation for this frame (`PTPLiveViewRotation` raw value), so a
    /// watcher rotates the picture upright exactly like the broadcaster. Optional on the wire —
    /// absent from older hosts means landscape, the historical behavior.
    public let rotation: Int?

    /// Returns a copy carrying the encoder's output description.
    public func carryingVideo(codec: Int, isKeyframe: Bool, parameterSets: [Data]?) -> Self {
        Self(
            timecode: timecode, isRecording: isRecording, focus: focus, levelRoll: levelRoll,
            levelPitch: levelPitch, sound: sound, codec: codec, isKeyframe: isKeyframe,
            parameterSets: parameterSets, rotation: rotation)
    }
}

/// A camera command issued by a viewer and executed by the host.
///
/// Control is proxied, never transferred: the camera serves one initiator, so the host keeps the
/// session and runs the command on the holder's behalf. A viewer "taking control" is the app
/// agreeing whose commands are honoured — nothing about the camera link moves.
public enum MonitorRelayCommand: Codable, Equatable, Sendable {
    case toggleRecording
    /// Already in the camera's own AF coordinate space. The viewer's feed is a different size
    /// from the host's, so a point in view coordinates would land somewhere else entirely.
    case focusPoint(cameraX: Int, cameraY: Int, coordinateWidth: Int, coordinateHeight: Int)
    /// `picker` is a `CameraPicker` raw value; the shells share that vocabulary already.
    case pickerValue(picker: String, value: String)
}

/// Who holds the camera. Exactly one device does at a time — the camera itself enforces that, so
/// the token is the app agreeing about it rather than the app deciding it.
public struct MonitorRelayControlToken: Codable, Equatable, Sendable {
    public init(holderName: String, holderIsRecipient: Bool) {
        self.holderName = holderName
        self.holderIsRecipient = holderIsRecipient
    }
    public let holderName: String
    /// True when the device receiving this message is the one holding control.
    public let holderIsRecipient: Bool
}

/// Length-prefixed framing over a stream.
///
/// `[4-byte big-endian payload length][1-byte kind][payload]`. TCP is a byte stream with no
/// message boundaries of its own, so the length prefix is what makes a partial read recoverable
/// instead of a desynchronised connection.
public enum MonitorRelayFraming {
    /// Bytes preceding every payload: the length prefix plus the kind tag.
    public static let headerBytes = 5

    public static func encode(kind: MonitorRelayProtocol.Kind, payload: Data) -> Data {
        var out = Data(capacity: headerBytes + payload.count)
        out.append(contentsOf: ByteCoding.uint32BE(UInt32(payload.count + 1)))
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    /// One decoded message plus how many bytes it consumed.
    public struct Decoded: Equatable, Sendable {
        public init(kind: MonitorRelayProtocol.Kind, payload: Data, consumedBytes: Int) {
            self.kind = kind
            self.payload = payload
            self.consumedBytes = consumedBytes
        }
        public let kind: MonitorRelayProtocol.Kind
        public let payload: Data
        public let consumedBytes: Int
    }

    public enum DecodeError: Error, Equatable, Sendable {
        /// The declared length exceeds `maximumPayloadBytes`, so the stream is desynchronised or
        /// hostile. Callers must drop the connection rather than try to resynchronise.
        case payloadTooLarge(declared: Int)
        case unknownKind(UInt8)
    }

    /// Decodes the first whole message in `buffer`, or `nil` when more bytes are needed.
    public static func decode(from buffer: Data) throws -> Decoded? {
        guard buffer.count >= headerBytes else { return nil }
        let base = buffer.startIndex
        let declared = Int(ByteCoding.readUInt32BE(Array(buffer[base..<base + 4]), at: 0))
        guard declared >= 1 else { throw DecodeError.payloadTooLarge(declared: declared) }
        guard declared - 1 <= MonitorRelayProtocol.maximumPayloadBytes else {
            throw DecodeError.payloadTooLarge(declared: declared - 1)
        }
        let total = 4 + declared
        guard buffer.count >= total else { return nil }
        let rawKind = buffer[base + 4]
        guard let kind = MonitorRelayProtocol.Kind(rawValue: rawKind) else {
            throw DecodeError.unknownKind(rawKind)
        }
        let payload = Data(buffer[(base + headerBytes)..<(base + total)])
        return Decoded(kind: kind, payload: payload, consumedBytes: total)
    }
}

/// A relayed frame: JSON metadata and the picture, in one message.
///
/// `[4-byte big-endian metadata length][metadata JSON][image bytes]`. The image is passed through
/// as the host received it wherever possible — re-encoding a live-view JPEG to send it would cost
/// a generation of quality for nothing.
public enum MonitorRelayFramePayload {
    public static func encode(metadata: MonitorRelayFrameMetadata, image: Data) throws -> Data {
        let json = try JSONEncoder().encode(metadata)
        var out = Data(capacity: 4 + json.count + image.count)
        out.append(contentsOf: ByteCoding.uint32BE(UInt32(json.count)))
        out.append(json)
        out.append(image)
        return out
    }

    public struct Decoded: Equatable, Sendable {
        public init(metadata: MonitorRelayFrameMetadata, image: Data) {
            self.metadata = metadata
            self.image = image
        }
        public let metadata: MonitorRelayFrameMetadata
        public let image: Data
    }

    public enum DecodeError: Error, Equatable, Sendable {
        case truncated
    }

    public static func decode(_ payload: Data) throws -> Decoded {
        guard payload.count >= 4 else { throw DecodeError.truncated }
        let base = payload.startIndex
        let jsonLength = Int(ByteCoding.readUInt32BE(Array(payload[base..<base + 4]), at: 0))
        guard payload.count >= 4 + jsonLength else { throw DecodeError.truncated }
        let json = Data(payload[(base + 4)..<(base + 4 + jsonLength)])
        let metadata = try JSONDecoder().decode(MonitorRelayFrameMetadata.self, from: json)
        return Decoded(
            metadata: metadata, image: Data(payload[(base + 4 + jsonLength)...]))
    }
}
