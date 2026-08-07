import CryptoKit
import Foundation
import Network
import SwiftUI
import os

/// Peer-to-peer transport for ``CameraCredentialHandoff`` on Apple devices.
///
/// Runs over `includePeerToPeer`, which is AWDL — no shared subnet, which is the whole point: the
/// donor is associated to the camera's access point and the requester is not. The Bluetooth path
/// for cross-platform handoff is a separate transport speaking the same payloads.
///
/// **The link is authenticated, not merely encrypted.** A Wi‑Fi key crossing AWDL in the clear is
/// readable by anything nearby, and a prompt on the donor only proves a human approved *something*
/// — not that the device that receives it is the one they meant. Both ends derive TLS keying from
/// a six-digit passcode the requester displays and the donor's operator confirms, so a peer that
/// cannot show the same digits cannot complete the handshake at all.
enum CredentialHandoffTransport {
    /// Message framing: a kind byte, a big-endian length, then the JSON payload.
    static let headerSize = 5

    /// What the advertisement carries, so a donor can render a prompt naming who is asking and
    /// about which camera *before* it has a link to ask over — the link needs the passcode, and
    /// the operator cannot supply that without knowing what they are being asked.
    ///
    /// Display strings only. The serial and the SSID that decide the match travel inside the
    /// authenticated link, never on the air.
    static let txtRequesterKey = "requester"
    static let txtCameraKey = "camera"

    static func frame(kind: CameraCredentialHandoff.Kind, payload: Data) -> Data {
        var out = Data([kind.rawValue])
        var length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Splits one framed message off the front of `buffer`, or nil while it is still arriving.
    static func nextMessage(
        from buffer: inout Data
    ) -> (kind: CameraCredentialHandoff.Kind, payload: Data)? {
        guard buffer.count >= headerSize else { return nil }
        let header = buffer.prefix(headerSize)
        guard let kind = CameraCredentialHandoff.Kind(rawValue: header[header.startIndex]) else {
            // An unknown tag means the stream is not what we think it is; drop it rather than
            // hunting for a resync point in a security-relevant channel.
            buffer.removeAll()
            return nil
        }
        let length = header.dropFirst().withUnsafeBytes {
            UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self))
        }
        // A grant is a few hundred bytes. Anything claiming more is not one of ours.
        guard length <= 64 * 1024 else {
            buffer.removeAll()
            return nil
        }
        let total = headerSize + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = buffer.dropFirst(headerSize).prefix(Int(length))
        buffer = Data(buffer.dropFirst(total))
        return (kind, Data(payload))
    }

    /// A six-digit code the operator can read off one screen and recognise on the other.
    ///
    /// Short because a human compares it; safe to be short because it is a pre-shared key for a
    /// single connection attempt, not a secret at rest — an attacker gets one guess per handshake
    /// against a listener that is only up while the card is open.
    static func makePasscode() -> String {
        String(format: "%06u", UInt32.random(in: 0..<1_000_000))
    }

    /// TLS parameters keyed by the shared passcode, over peer-to-peer.
    ///
    /// The passcode is stretched with SHA-256 before it becomes PSK material so the six digits are
    /// not the key itself, and tagged with the service type so keying from this feature can never
    /// be replayed against another of the app's peer-to-peer links.
    static func parameters(passcode: String) -> NWParameters {
        let options = NWProtocolTLS.Options()
        var digest = SHA256()
        digest.update(data: Data(CameraCredentialHandoff.serviceType.utf8))
        digest.update(data: Data(passcode.utf8))
        let key = Data(digest.finalize())

        let keyDispatch = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identityDispatch = Data(CameraCredentialHandoff.serviceType.utf8)
            .withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(
            options.securityProtocolOptions,
            keyDispatch as __DispatchData,
            identityDispatch as __DispatchData
        )
        sec_protocol_options_append_tls_ciphersuite(
            options.securityProtocolOptions,
            tls_ciphersuite_t(rawValue: TLS_PSK_WITH_AES_128_GCM_SHA256)!
        )
        let parameters = NWParameters(tls: options)
        parameters.includePeerToPeer = true
        return parameters
    }
}

/// One connection's framing and read loop, confined to its own queue.
///
/// Separate from the coordinator because `NWConnection`'s handlers arrive off the main actor and
/// the reassembly buffer must not be touched from two places. Everything it reports hops to the
/// main actor at the boundary; nothing inside here is main-actor state.
private final class HandoffLink: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "OpenZCine.credential-handoff.link")
    private var buffer = Data()
    private let onMessage: @Sendable (CameraCredentialHandoff.Kind, Data) -> Void
    private let onFailure: @Sendable (String) -> Void

    init(
        connection: NWConnection,
        onMessage: @escaping @Sendable (CameraCredentialHandoff.Kind, Data) -> Void,
        onFailure: @escaping @Sendable (String) -> Void
    ) {
        self.connection = connection
        self.onMessage = onMessage
        self.onFailure = onFailure
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: receive()
            case .failed(let error): onFailure(error.localizedDescription)
            // A cancelled peer is the normal end of a completed handoff, not a failure.
            case .cancelled: break
            case .waiting(let error):
                // TLS refuses before it reports ready when the passcodes disagree, which is the
                // single most likely thing to go wrong here — say so in those words.
                onFailure(error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: queue)
    }

    func send(kind: CameraCredentialHandoff.Kind, payload: Data) {
        connection.send(
            content: CredentialHandoffTransport.frame(kind: kind, payload: payload),
            completion: .contentProcessed { _ in })
    }

    func cancel() {
        connection.stateUpdateHandler = nil
        connection.cancel()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                onFailure(error.localizedDescription)
                return
            }
            if let data, !data.isEmpty {
                buffer.append(data)
                while let message = CredentialHandoffTransport.nextMessage(from: &buffer) {
                    onMessage(message.kind, message.payload)
                }
            }
            if isComplete { return }
            receive()
        }
    }
}

/// Drives both ends of the camera-credential handoff: the requester's advertisement and the
/// donor's watch for one.
///
/// Both roles live in one object because a device is routinely both — it holds setups for cameras
/// it has paired with, and is standing up a new one for a camera it has not. Keeping them apart
/// would duplicate the connection handling to no benefit.
@MainActor
@Observable
final class CredentialHandoffCoordinator {
    /// What the requester's card is showing.
    enum RequesterState: Equatable {
        case idle
        /// Advertising, with the digits the donor's operator has to confirm.
        case waiting(passcode: String, cameraDisplayName: String)
        case received(ssid: String, donorName: String)
        case declined(reason: CredentialHandoffDecline.Reason, donorName: String)
        case failed(String)
    }

    /// A nearby device asking, as the donor's prompt renders it. Everything here comes off the
    /// advertisement, so it is display text only — the identity that decides the match arrives
    /// after the link is authenticated.
    struct IncomingRequest: Identifiable, Equatable {
        let id: String
        let requesterName: String
        let cameraDisplayName: String
        let endpoint: NWEndpoint
    }

    static let shared = CredentialHandoffCoordinator()

    private(set) var requesterState: RequesterState = .idle
    /// The request the donor is being asked about, if any. One at a time: a queue of these is a
    /// pestering machine, and the declined latch below is what keeps the second one away.
    private(set) var incomingRequest: IncomingRequest?

    /// Requesters this operator said no to, for the life of the session (`shouldPrompt`).
    private var declinedRequesters: Set<String> = []
    private var listener: NWListener?
    private var listenerLink: HandoffLink?
    private var donorLink: HandoffLink?
    private var browser: NWBrowser?
    private var pendingRequest: CredentialHandoffRequest?
    private var timeout: Task<Void, Never>?
    private let log = Logger(subsystem: "OpenZCine", category: "CredentialHandoff")

    private init() {}

    // MARK: - Requester

    /// Puts "I am setting up this camera" on the air and waits for a donor to answer.
    ///
    /// The passcode is generated here and shown on the card; a donor that cannot reproduce it
    /// fails the TLS handshake, so the digits are the authentication and not merely a courtesy.
    func requestCredentials(
        cameraDisplayName: String,
        cameraSerialNumber: String?,
        knownSSID: String?,
        requesterName: String
    ) {
        stopRequesting()
        let passcode = CredentialHandoffTransport.makePasscode()
        let request = CredentialHandoffRequest(
            requestID: UUID().uuidString,
            requesterName: requesterName,
            cameraSerialNumber: cameraSerialNumber,
            cameraDisplayName: cameraDisplayName,
            knownSSID: knownSSID)
        pendingRequest = request

        do {
            let listener = try NWListener(
                using: CredentialHandoffTransport.parameters(passcode: passcode))
            var txt = NWTXTRecord()
            txt[CredentialHandoffTransport.txtRequesterKey] = requesterName
            txt[CredentialHandoffTransport.txtCameraKey] = cameraDisplayName
            listener.service = NWListener.Service(
                name: request.requestID, type: CameraCredentialHandoff.serviceType,
                domain: nil, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.acceptDonor(connection, request: request) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { @MainActor in
                    self?.finishRequesting(.failed(error.localizedDescription))
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            requesterState = .failed(error.localizedDescription)
            return
        }

        requesterState = .waiting(passcode: passcode, cameraDisplayName: cameraDisplayName)
        // The backstop for a card left open on a bench — the request is a live broadcast, so it
        // must not outlive the operator's attention.
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(CredentialHandoffPolicy.requestTimeout))
            guard !Task.isCancelled, let self, case .waiting = requesterState else { return }
            finishRequesting(.failed("No nearby device answered."))
        }
    }

    /// Ends the advertisement, leaving whatever the card is showing in place.
    func stopRequesting() {
        timeout?.cancel()
        timeout = nil
        listener?.newConnectionHandler = nil
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        listenerLink?.cancel()
        listenerLink = nil
        pendingRequest = nil
    }

    /// Clears the card back to nothing, ending the advertisement with it.
    func dismissRequest() {
        stopRequesting()
        requesterState = .idle
    }

    private func acceptDonor(_ connection: NWConnection, request: CredentialHandoffRequest) {
        guard case .waiting = requesterState else {
            connection.cancel()
            return
        }
        // First donor through the door wins; the listener stops so a second cannot arrive mid-grant.
        listener?.cancel()
        listener = nil
        let link = HandoffLink(
            connection: connection,
            onMessage: { [weak self] kind, payload in
                Task { @MainActor in self?.requesterReceived(kind: kind, payload: payload) }
            },
            onFailure: { [weak self] reason in
                Task { @MainActor in self?.finishRequesting(.failed(reason)) }
            })
        listenerLink = link
        link.start()
        if let payload = try? JSONEncoder().encode(request) {
            link.send(kind: .request, payload: payload)
        }
    }

    private func requesterReceived(kind: CameraCredentialHandoff.Kind, payload: Data) {
        switch kind {
        case .grant:
            guard let grant = try? JSONDecoder().decode(CredentialHandoffGrant.self, from: payload),
                grant.requestID == pendingRequest?.requestID
            else { return }
            // The key lands in the same store a scan or a typed key writes to, so everything
            // downstream — join, rejoin, the setup card — is the path it already knows.
            CameraWiFiCredentialStore.savePassword(grant.key, forSSID: grant.ssid)
            log.info("Credential handoff: received a key for a camera access point.")
            finishRequesting(.received(ssid: grant.ssid, donorName: grant.donorName))
        case .decline:
            guard
                let decline = try? JSONDecoder().decode(
                    CredentialHandoffDecline.self, from: payload),
                decline.requestID == pendingRequest?.requestID
            else { return }
            finishRequesting(.declined(reason: decline.reason, donorName: decline.donorName))
        case .request:
            // The requester never receives one; a donor sending it is not speaking this protocol.
            finishRequesting(.failed("The other device sent something unexpected."))
        }
    }

    private func finishRequesting(_ state: RequesterState) {
        stopRequesting()
        requesterState = state
    }

    // MARK: - Donor

    /// Starts watching for a nearby device standing up a camera this one may hold the key for.
    ///
    /// Browsing is passive — it puts nothing on the air — so this can run while the app is in
    /// front without turning every phone into a beacon. The advertisement is the only broadcast in
    /// the feature, and only the requester makes it.
    func startDonorWatch() {
        guard browser == nil else { return }
        let parameters = NWParameters()
        parameters.includePeerToPeer = true
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: CameraCredentialHandoff.serviceType, domain: nil),
            using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in self?.donorSaw(results) }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stopDonorWatch() {
        browser?.browseResultsChangedHandler = nil
        browser?.cancel()
        browser = nil
        incomingRequest = nil
        donorLink?.cancel()
        donorLink = nil
    }

    private func donorSaw(_ results: Set<NWBrowser.Result>) {
        guard incomingRequest == nil else { return }
        for result in results {
            guard case .bonjour(let txt) = result.metadata,
                let requesterName = txt[CredentialHandoffTransport.txtRequesterKey],
                let cameraDisplayName = txt[CredentialHandoffTransport.txtCameraKey],
                case .service(let name, _, _, _) = result.endpoint
            else { continue }
            // A refusal is a decision about that requester, not a transient failure. Prompting
            // again on its next attempt is how one "Don't Send" becomes a stream of alerts.
            guard
                CredentialHandoffPolicy.shouldPrompt(
                    requesterName: requesterName, declinedRequesters: declinedRequesters)
            else { continue }
            incomingRequest = IncomingRequest(
                id: name, requesterName: requesterName, cameraDisplayName: cameraDisplayName,
                endpoint: result.endpoint)
            return
        }
    }

    /// The operator typed the digits shown on the requester and tapped Send.
    ///
    /// Reading a code off the other device and typing it here IS the approval: it is a deliberate
    /// act that names both the device and the camera on the prompt, and a wrong code cannot even
    /// complete the handshake. A second "are you sure" after it would be ceremony.
    func approveIncoming(
        passcode: String, candidates: [CredentialHandoffMatch.Candidate],
        donorName: String
    ) {
        guard let incoming = incomingRequest else { return }
        incomingRequest = nil
        let connection = NWConnection(
            to: incoming.endpoint,
            using: CredentialHandoffTransport.parameters(passcode: passcode))
        let link = HandoffLink(
            connection: connection,
            onMessage: { [weak self] kind, payload in
                Task { @MainActor in
                    self?.donorReceived(
                        kind: kind, payload: payload, candidates: candidates,
                        donorName: donorName)
                }
            },
            onFailure: { [weak self] reason in
                Task { @MainActor in
                    self?.log.error(
                        "Credential handoff link failed: \(reason, privacy: .public)")
                    self?.donorLink?.cancel()
                    self?.donorLink = nil
                }
            })
        donorLink = link
        link.start()
    }

    /// Don't Send: refuse this one, and stop asking about this requester.
    func declineIncoming() {
        guard let incoming = incomingRequest else { return }
        declinedRequesters.insert(incoming.requesterName)
        incomingRequest = nil
    }

    private func donorReceived(
        kind: CameraCredentialHandoff.Kind, payload: Data,
        candidates: [CredentialHandoffMatch.Candidate], donorName: String
    ) {
        guard kind == .request,
            let request = try? JSONDecoder().decode(CredentialHandoffRequest.self, from: payload)
        else { return }
        defer {
            donorLink?.cancel()
            donorLink = nil
        }
        // The match runs on the payload, not on the advertisement: a display name is shared by
        // every ZR on earth, so only the authenticated serial or an exact SSID can answer.
        guard let match = CredentialHandoffMatch.candidate(for: request, among: candidates),
            let key = CameraWiFiCredentialStore.password(forSSID: match.ssid)
        else {
            send(
                decline: CredentialHandoffDecline(
                    requestID: request.requestID, reason: .noCredentialsForCamera,
                    donorName: donorName))
            return
        }
        let grant = CredentialHandoffGrant(
            requestID: request.requestID, ssid: match.ssid, key: key, donorName: donorName)
        if let encoded = try? JSONEncoder().encode(grant) {
            donorLink?.send(kind: .grant, payload: encoded)
            log.info("Credential handoff: sent a key to a nearby device.")
        }
    }

    private func send(decline: CredentialHandoffDecline) {
        if let encoded = try? JSONEncoder().encode(decline) {
            donorLink?.send(kind: .decline, payload: encoded)
        }
    }
}
