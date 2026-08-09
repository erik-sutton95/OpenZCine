import Foundation

/// Handing a camera access point's Wi‑Fi credentials from a device that already has them to one
/// standing the same setup up on another device.
///
/// The two ends are on different networks by definition — the donor is associated to the camera's
/// access point, and the requester has not joined it, which is the entire reason it is asking. So
/// this never rides the relay's on-network browse; it runs over a peer-to-peer transport that
/// needs no shared subnet (AWDL where both ends are Apple devices, Bluetooth LE otherwise). The
/// payloads here are transport-agnostic on purpose: the same bytes cross either one.
///
/// **The requester advertises, not the donor.** The obvious shape — donors publishing what they
/// hold so a requester can pick one — would have every app instance sitting on a camera network
/// continuously broadcasting an inventory of the cameras it has keys for. Inverting it means the
/// only thing on the air is one device saying "I am setting up this camera", and only while its
/// operator is looking at that card. The camera itself already broadcasts that same identity in
/// its SSID, so this adds nothing that was not already in the room.
public enum CameraCredentialHandoff {
    /// Bonjour service type for the AWDL path, and the BLE service's advertised name.
    public static let serviceType = "_ozc-cred._tcp"

    /// Wire framing, matching ``WatchRelayProtocol``: a one-byte kind tag, then the JSON payload.
    public enum Kind: UInt8, Sendable {
        /// Requester → donor: which camera it is standing up.
        case request = 0x01
        /// Donor → requester: the credentials, sent only after the operator approves.
        case grant = 0x02
        /// Donor → requester: no credentials, with a reason the requester can render.
        case decline = 0x03
    }
}

/// What the requester puts on the air, and sends once a donor connects.
///
/// Identifies the CAMERA, not the network. A requester reaching for this option usually cannot
/// name the SSID — that is half of what it is asking for — but it always knows which saved camera
/// the operator tapped "Add setup" on.
public struct CredentialHandoffRequest: Codable, Equatable, Sendable {
    /// Correlates a grant or decline with the request that asked for it.
    public let requestID: String
    /// Rendered on the donor's approval prompt: the operator has to recognise who is asking.
    public let requesterName: String
    /// The camera's serial. The only identity that can be trusted to match — see ``matches``.
    public let cameraSerialNumber: String?
    /// Shown on the prompt so the donor's operator sees which body this is about.
    public let cameraDisplayName: String
    /// An SSID the requester already resolved, when it has one. A hint, never a requirement.
    public let knownSSID: String?

    public init(
        requestID: String,
        requesterName: String,
        cameraSerialNumber: String?,
        cameraDisplayName: String,
        knownSSID: String? = nil
    ) {
        self.requestID = requestID
        self.requesterName = requesterName
        self.cameraSerialNumber = cameraSerialNumber
        self.cameraDisplayName = cameraDisplayName
        self.knownSSID = knownSSID
    }
}

/// The credentials, travelling only after a human on the donor said yes.
public struct CredentialHandoffGrant: Codable, Equatable, Sendable {
    public let requestID: String
    public let ssid: String
    public let key: String
    /// Shown on the requester's card: "Received from Erik's iPad".
    public let donorName: String

    public init(requestID: String, ssid: String, key: String, donorName: String) {
        self.requestID = requestID
        self.ssid = ssid
        self.key = key
        self.donorName = donorName
    }
}

/// A refusal the requester can render, and act on.
public struct CredentialHandoffDecline: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable {
        /// A human tapped Don't Send. Latches on the requester — see ``CredentialHandoffPolicy``.
        case operatorDeclined
        /// The donor answered but holds nothing for this camera. Not a refusal, just an absence.
        case noCredentialsForCamera
    }

    public let requestID: String
    public let reason: Reason
    public let donorName: String

    public init(requestID: String, reason: Reason, donorName: String) {
        self.requestID = requestID
        self.reason = reason
        self.donorName = donorName
    }
}

/// Whether a donor holds what a request is asking for, and which network answers it.
///
/// Deliberately pure so both platforms decide identically and the rules can be pinned by tests
/// rather than discovered on a hotel Wi‑Fi at a shoot.
public enum CredentialHandoffMatch {
    /// One camera-AP setup a donor could offer: the network, and the serial of the body behind it.
    public struct Candidate: Equatable, Sendable {
        public let ssid: String
        public let serialNumber: String?

        public init(ssid: String, serialNumber: String?) {
            self.ssid = ssid
            self.serialNumber = serialNumber
        }
    }

    /// Picks the network that answers `request`, or nil when this donor has nothing for it.
    ///
    /// Two ways to match, and only two:
    ///
    /// - **Serial**, when both sides carry one. The only identity a camera actually owns.
    /// - **Exact SSID**, when the requester already resolved one and the donor holds that network.
    ///
    /// Never the display name. "Nikon ZR" is a resolved product name shared by every ZR on earth,
    /// so matching on it would hand one operator's camera key to whoever asked from across the
    /// room. A request carrying neither a serial nor an SSID is unanswerable, and says so.
    public static func candidate(
        for request: CredentialHandoffRequest,
        among candidates: [Candidate]
    ) -> Candidate? {
        if let serial = normalized(request.cameraSerialNumber) {
            if let bySerial = candidates.first(where: { normalized($0.serialNumber) == serial }) {
                return bySerial
            }
        }
        if let ssid = normalized(request.knownSSID) {
            if let bySSID = candidates.first(where: {
                $0.ssid.compare(ssid, options: .caseInsensitive) == .orderedSame
            }) {
                return bySSID
            }
        }
        return nil
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}

/// Rules that keep the handoff from becoming a way to pester an operator, or to fish for keys.
public enum CredentialHandoffPolicy {
    /// How long a request stays on the air before it gives up on its own.
    ///
    /// A request is a live broadcast of "I am setting this camera up", so it must not outlive the
    /// operator's attention. The card's Cancel ends it sooner; this is the backstop for a card
    /// left open on a bench.
    public static let requestTimeout: TimeInterval = 120

    /// Whether a donor should even show its approval prompt for this request.
    ///
    /// A `Don't Send` is a decision about that requester, not a transient failure: honouring it
    /// once and then prompting again on the requester's next attempt is how a refusal turns into
    /// a stream of alerts — the same shape as the camera-AP rejoin storm. The caller keeps the
    /// declined set for the life of the session.
    public static func shouldPrompt(
        requesterName: String,
        declinedRequesters: Set<String>
    ) -> Bool {
        !declinedRequesters.contains(requesterName)
    }
}
