import Foundation
import Network
import os

private let relayLogger = Logger(subsystem: "com.opencapture.openzcine", category: "relay")

/// Accumulates bytes off a stream and yields whole protocol messages.
///
/// TCP delivers a byte stream, not messages: one read can hold half a frame, or three frames and
/// the start of a fourth. Every consumer needs this, so it lives once rather than being
/// re-improvised at each call site — re-improvising it is how relays end up desynchronised in a
/// way that only shows up as corrupt pictures minutes later.
final class MonitorRelayStreamReader {
    private var buffer = Data()

    /// Appends a read and returns every whole message it completed.
    func append(_ data: Data) throws -> [MonitorRelayFraming.Decoded] {
        buffer.append(data)
        var messages: [MonitorRelayFraming.Decoded] = []
        while let decoded = try MonitorRelayFraming.decode(from: buffer) {
            messages.append(decoded)
            buffer.removeFirst(decoded.consumedBytes)
        }
        return messages
    }

    func reset() { buffer.removeAll(keepingCapacity: false) }
}

/// Shared connection parameters.
///
/// `includePeerToPeer` lets the same Bonjour service resolve over a shared network *and* over
/// Apple's peer-to-peer radio — what lets viewers reach a host which is itself occupying its
/// Wi-Fi association on the camera's own access point, the case with no infrastructure path at
/// all. It is NOT free: an active AWDL advertisement time-slices the same radio the
/// infrastructure stream rides (measured elsewhere at 30–100 ms locks about once a second), so
/// the host only includes it when the camera actually occupies its Wi-Fi — see
/// `MonitorRelayHost.start(hostName:cameraName:includePeerToPeer:)`.
private func relayParameters(includePeerToPeer: Bool = true) -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = includePeerToPeer
    // The relay is the picture someone is pulling focus against: interactive-video class puts
    // our own transmit queue — the broadcaster's uplink, the hop that carries every viewer's
    // flow — into the Wi-Fi video access category. Past the router it helps exactly where DSCP
    // survives, which costs nothing to attempt.
    parameters.serviceClass = .interactiveVideo
    // A monitor feed is a stream of small, latency-sensitive writes. Nagle would coalesce them
    // into fewer, later packets, which is exactly the wrong trade for a picture someone is
    // pulling focus against.
    if let tcp = parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options {
        tcp.noDelay = true
    }
    return parameters
}

/// A discovered broadcasting device.
struct MonitorRelayDiscovery: Identifiable, Equatable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    /// The camera host this broadcast is serving, from the advertisement's TXT record. Any
    /// device that can SEE the broadcast must not PTP-probe this address: the body accepts one
    /// initiator, and a foreign Init against a served camera is exactly the "main device drops
    /// when a watcher comes or goes" failure — the watcher's own camera-list scan knocking the
    /// broadcaster's session over.
    let servedCameraHost: String?

    init(id: String, name: String, endpoint: NWEndpoint, servedCameraHost: String? = nil) {
        self.id = id
        self.name = name
        self.endpoint = endpoint
        self.servedCameraHost = servedCameraHost
    }

    static func == (lhs: MonitorRelayDiscovery, rhs: MonitorRelayDiscovery) -> Bool {
        lhs.id == rhs.id && lhs.servedCameraHost == rhs.servedCameraHost
    }
}

// MARK: - Host

/// Serves the picture and the camera's readings to viewer devices.
///
/// The host is whichever device holds the single PTP session; everything here is a fan-out of what
/// it already has, so broadcasting costs it no extra camera traffic.
@MainActor
final class MonitorRelayHost {
    /// Number of connected viewers, for the host's own readout.
    private(set) var peerCount = 0
    var onPeerCountChanged: (@MainActor (Int) -> Void)?
    private(set) var isBroadcasting = false
    var onFailure: (@MainActor (String) -> Void)?

    /// A connected viewer, and how it introduced itself.
    private struct Peer {
        let connection: NWConnection
        /// This peer's framing state. Owned HERE, on the main actor, so the socket callback
        /// ships only bytes — a reader captured across both isolation domains is a data-race
        /// diagnostic on newer compilers (and they are right: nothing proved the regions apart).
        let reader = MonitorRelayStreamReader()
        var name: String
        /// False while a required passcode has not been presented. An unauthorized peer
        /// receives the host hello and NOTHING else — no state, no frames — until its own
        /// hello carries the right code.
        var authorized: Bool
        /// Frames handed to the socket and not yet reported processed. The backpressure signal:
        /// a peer that stops draining stops being sent to, rather than being queued for.
        var inFlightFrames = 0
        /// HEVC frames reference their predecessors, so a peer that joined or skipped under
        /// backpressure cannot resume on a predicted frame — it would decode into smearing.
        /// True until this peer has been sent a keyframe.
        var needsKeyframe = true
    }

    /// Fired when some peer is waiting on a keyframe the current stream position cannot give it.
    /// The model routes this to the encoder; JPEG streams never fire it (every frame is a
    /// keyframe there).
    var onKeyframeNeeded: (@MainActor () -> Void)?

    /// The viewer currently allowed to drive the camera; nil means the host itself does.
    private(set) var controlHolder: ObjectIdentifier?
    private(set) var controlHolderName: String?
    /// A viewer that has asked and not yet been answered.
    private(set) var pendingRequestName: String?
    private var pendingRequest: ObjectIdentifier?
    var onControlChanged: (@MainActor () -> Void)?
    /// Called with a command the holder issued, for the model to execute on its own session.
    var onCommand: (@MainActor (MonitorRelayCommand) -> Void)?

    private var listener: NWListener?
    private var peers: [ObjectIdentifier: Peer] = [:]
    /// Watchers must present this to receive anything beyond the hello; empty means open.
    var watcherPasscode = ""
    /// Whether watcher control requests are entertained at all. Broadcast in the state payload
    /// so watchers hide the ask instead of sending requests into a void.
    var allowsControlRequests = true
    private let queue = DispatchQueue(label: "com.opencapture.openzcine.relay-host")
    /// Sent to every viewer that connects, so a late joiner is not staring at nothing until the
    /// next state change happens to come along.
    private var latestState: MonitorRelayState?
    private var hostName = ""
    private var cameraName: String?
    private var servedCameraHost: String?
    /// The port actually bound, reported once the listener is ready. The model remembers it
    /// across host instances and asks for it back: watchers resolve this host through Bonjour
    /// SRV records that outlive a listener by their TTL, so a restart that moves the port
    /// strands every watcher dialing the corpse (measured as a minutes-long RST storm).
    private(set) var boundPort: UInt16?
    var onListening: (@MainActor (UInt16?) -> Void)?

    /// `includePeerToPeer` should be true only when the camera occupies this device's Wi-Fi
    /// (camera-AP session) — that is the case peer-to-peer exists for. Everywhere else the AWDL
    /// advertisement would time-slice the very radio the camera stream and every viewer flow
    /// ride, for a path no viewer needs.
    func start(
        hostName: String, cameraName: String?, servedCameraHost: String? = nil,
        includePeerToPeer: Bool, preferredPort: UInt16? = nil
    ) {
        stop()
        self.hostName = hostName
        self.cameraName = cameraName
        self.servedCameraHost = servedCameraHost
        do {
            let listener = try makeListener(
                includePeerToPeer: includePeerToPeer, preferredPort: preferredPort)
            listener.service = advertisedService()
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self, weak listener] state in
                switch state {
                case .ready:
                    let port = listener?.port?.rawValue
                    Task { @MainActor in
                        guard let self, listener === self.listener else { return }
                        self.boundPort = port
                        self.onListening?(port)
                    }
                case .failed(let error):
                    Task { @MainActor in
                        self?.onFailure?("Sharing stopped: \(error.localizedDescription)")
                        self?.stop()
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            isBroadcasting = true
        } catch {
            onFailure?("Couldn't start sharing: \(error.localizedDescription)")
        }
    }

    /// Binds the remembered port when it is still free so redials against stale Bonjour records
    /// land on a LIVE listener; falls back to an ephemeral port rather than failing the whole
    /// broadcast over a squatter.
    private func makeListener(
        includePeerToPeer: Bool, preferredPort: UInt16?
    ) throws -> NWListener {
        if let preferredPort, let port = NWEndpoint.Port(rawValue: preferredPort) {
            if let listener = try? NWListener(
                using: relayParameters(includePeerToPeer: includePeerToPeer), on: port)
            {
                return listener
            }
        }
        return try NWListener(using: relayParameters(includePeerToPeer: includePeerToPeer))
    }

    /// The Bonjour advertisement, carrying the served camera's host in TXT so every device that
    /// can see the broadcast keeps its discovery probes off that address.
    private func advertisedService() -> NWListener.Service {
        var txt = NWTXTRecord()
        if let servedCameraHost, !servedCameraHost.isEmpty {
            txt[MonitorRelayProtocol.servedCameraTXTKey] = servedCameraHost
        }
        return NWListener.Service(
            name: hostName, type: MonitorRelayProtocol.serviceType, txtRecord: txt)
    }

    /// Re-registers the advertisement with a new camera name / served host — a TXT update, not a
    /// listener bounce, so connections, the port, and watching devices are untouched. Covers the
    /// broadcast-before-connect order, where the camera's identity arrives after `start`.
    func updateServedCamera(cameraName: String?, servedCameraHost: String?) {
        guard self.cameraName != cameraName || self.servedCameraHost != servedCameraHost else {
            return
        }
        self.cameraName = cameraName
        self.servedCameraHost = servedCameraHost
        listener?.service = advertisedService()
    }

    func stop() {
        stop(notifyingViewers: nil)
    }

    /// Ends the broadcast. With a reason, every connected viewer is told the broadcast ended
    /// (the same `joinDenied` frame a refused join gets) BEFORE its socket closes — a watcher
    /// must distinguish "the operator ended this" (leave to the camera list) from a dead
    /// network (keep the held frame and retry). The socket is cancelled once the send lands,
    /// the same flush the passcode refusal uses.
    func stop(notifyingViewers reason: String?) {
        listener?.cancel()
        listener = nil
        if let reason {
            let denial = encode(
                MonitorRelayJoinDenied(reason: reason, passcodeRequired: false))
            for peer in peers.values {
                let connection = peer.connection
                connection.send(
                    content: MonitorRelayFraming.encode(kind: .joinDenied, payload: denial),
                    completion: .contentProcessed { _ in connection.cancel() })
            }
        } else {
            for peer in peers.values { peer.connection.cancel() }
        }
        peers.removeAll()
        controlHolder = nil
        controlHolderName = nil
        pendingRequest = nil
        pendingRequestName = nil
        isBroadcasting = false
        updatePeerCount()
    }

    private func accept(_ connection: NWConnection) {
        relayLogger.info("relay host: viewer connected (\(self.peers.count + 1) total)")
        peers[ObjectIdentifier(connection)] = Peer(
            connection: connection, name: "A device", authorized: watcherPasscode.isEmpty)
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let connection else { return }
            switch state {
            case .failed, .cancelled:
                Task { @MainActor in self?.drop(connection) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        updatePeerCount()

        // Greet immediately, then hand over the last state so a viewer joining mid-take has the
        // readouts populated before the next frame rather than after the next change.
        send(
            kind: .hello,
            payload: encode(
                MonitorRelayHello(
                    version: MonitorRelayProtocol.version, hostName: hostName,
                    cameraName: cameraName)),
            to: connection)
        if let latestState, peers[ObjectIdentifier(connection)]?.authorized == true {
            send(kind: .state, payload: encode(latestState), to: connection)
        }
        receive(on: connection)
    }

    private func drop(_ connection: NWConnection) {
        relayLogger.info("relay host: viewer left (\(max(0, self.peers.count - 1)) remain)")
        connection.cancel()
        let key = ObjectIdentifier(connection)
        peers.removeValue(forKey: key)
        // A viewer that disappears cannot keep the camera hostage: control returns to the host,
        // which is the device that actually holds the session and can always act.
        if controlHolder == key { reclaimControl() }
        if pendingRequest == key {
            pendingRequest = nil
            pendingRequestName = nil
            onControlChanged?()
        }
        updatePeerCount()
    }

    private func updatePeerCount() {
        let count = peers.count
        guard count != peerCount else { return }
        peerCount = count
        onPeerCountChanged?(count)
    }

    /// Viewer → host traffic. Only the control handshake travels this way today. All framing
    /// happens on the main actor against the peer's own reader; a dropped peer ends its loop
    /// by its reader disappearing with it. (The previous shape captured the reader across both
    /// isolation domains — a data-race diagnostic on newer compilers, and they were right that
    /// nothing proved the regions apart.)
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            Task { @MainActor in
                guard let self,
                    let reader = self.peers[ObjectIdentifier(connection)]?.reader
                else { return }
                var messages: [MonitorRelayFraming.Decoded] = []
                if let data, !data.isEmpty {
                    do {
                        messages = try reader.append(data)
                    } catch {
                        // A desynchronised stream cannot be recovered by reading further.
                        self.drop(connection)
                        return
                    }
                }
                for message in messages { self.handle(message, from: connection) }
                if isComplete || error != nil {
                    self.drop(connection)
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ message: MonitorRelayFraming.Decoded, from connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        switch message.kind {
        case .hello:
            // The viewer introduces itself so a request can name who is asking. "Someone wants
            // control" is not a question an operator can answer.
            guard
                let hello = try? JSONDecoder().decode(
                    MonitorRelayHello.self, from: message.payload)
            else { return }
            peers[key]?.name = hello.hostName
            if controlHolder == key { controlHolderName = hello.hostName }
            if peers[key]?.authorized == false {
                if hello.passcode == watcherPasscode {
                    peers[key]?.authorized = true
                    if let latestState {
                        send(kind: .state, payload: encode(latestState), to: connection)
                    }
                } else {
                    // Refused, with the reason on the wire — a watcher staring at a silent
                    // black feed cannot tell a passcode from a broken network. Dropped after
                    // the send lands so the refusal is not cancelled with the socket.
                    relayLogger.info("relay host: viewer refused (passcode)")
                    let denial = encode(
                        MonitorRelayJoinDenied(
                            reason: "This broadcast asks for a passcode.",
                            passcodeRequired: true))
                    connection.send(
                        content: MonitorRelayFraming.encode(kind: .joinDenied, payload: denial),
                        completion: .contentProcessed { [weak self] _ in
                            Task { @MainActor in self?.drop(connection) }
                        })
                }
            }
        case .requestControl:
            guard let peer = peers[key], peer.authorized else { return }
            // Policy off → the request is not entertained; the state payload already told the
            // watcher, so anything landing here is a stale UI racing the policy change.
            guard allowsControlRequests else { return }
            pendingRequest = key
            pendingRequestName = peer.name
            onControlChanged?()
        case .releaseControl:
            if controlHolder == key { reclaimControl() }
        case .command:
            // Honoured only from the holder. A stale command from a device that has just lost
            // control must not land on the camera.
            guard controlHolder == key,
                let command = try? JSONDecoder().decode(
                    MonitorRelayCommand.self, from: message.payload)
            else { return }
            onCommand?(command)
        case .state, .frame, .controlToken, .joinDenied:
            break  // Host → viewer only.
        }
    }

    /// Grants the outstanding request.
    func grantPendingControl() {
        guard let pendingRequest, let peer = peers[pendingRequest] else { return }
        controlHolder = pendingRequest
        controlHolderName = peer.name
        self.pendingRequest = nil
        pendingRequestName = nil
        publishControlToken()
        onControlChanged?()
    }

    func declinePendingControl() {
        pendingRequest = nil
        pendingRequestName = nil
        onControlChanged?()
    }

    /// Takes the camera back. Always available: the host owns the session, so this can never fail
    /// or need the viewer's cooperation — which is what makes handing control out safe.
    func reclaimControl() {
        controlHolder = nil
        controlHolderName = nil
        publishControlToken()
        onControlChanged?()
    }

    /// Tells every viewer who holds control, each from its own point of view.
    private func publishControlToken() {
        for (key, peer) in peers {
            let token = MonitorRelayControlToken(
                holderName: controlHolderName ?? hostName, holderIsRecipient: controlHolder == key)
            send(kind: .controlToken, payload: encode(token), to: peer.connection)
        }
    }

    // MARK: Broadcasting

    func broadcast(state: MonitorRelayState) {
        latestState = state
        broadcast(kind: .state, payload: encode(state))
    }

    /// Frames a peer may have queued but not yet drained before new ones stop being offered.
    /// Low latency: two = one on the wire and one behind it. Quality: four rides out link
    /// jitter instead of skipping — every skip avoided is a broken reference chain and a
    /// forced keyframe avoided, which is where the profile's quality actually comes from.
    /// Mutable so a live profile change adopts the new window without tearing the listener
    /// down — a listener bounce moves the port and strands every watcher on a stale Bonjour
    /// SRV record for its TTL.
    private var maxInFlightFramesPerPeer: Int

    init(profile: RelayEncoderProfile = .lowLatency) {
        maxInFlightFramesPerPeer = profile.maxInFlightFramesPerPeer
    }

    /// Adopts a new profile's per-peer window on the LIVE broadcast; the encoder swap beside it
    /// carries the rest of the profile. Connections and the advertisement stay up.
    func adoptProfile(_ profile: RelayEncoderProfile) {
        maxInFlightFramesPerPeer = profile.maxInFlightFramesPerPeer
    }

    /// Whether at least one viewer could accept a frame right now. Checked BEFORE the encode:
    /// when every peer is saturated, encoding would burn the hardware block on a frame nobody
    /// receives — and because nothing is encoded, the encoder's reference chain stays exactly
    /// where every viewer's is, so resuming needs no keyframe.
    var hasPeerReadyForFrame: Bool {
        peers.values.contains { $0.inFlightFrames < maxInFlightFramesPerPeer }
    }

    func broadcast(frameMetadata: MonitorRelayFrameMetadata, image: Data) {
        guard !peers.isEmpty else { return }
        guard
            let payload = try? MonitorRelayFramePayload.encode(
                metadata: frameMetadata, image: image)
        else { return }
        let framed = MonitorRelayFraming.encode(kind: .frame, payload: payload)
        var keyframeWanted = false
        for (key, peer) in peers where peer.authorized {
            // A monitor shows the newest frame or it is not a monitor. A peer that has not
            // drained is SKIPPED, never queued for: fire-and-forget sends buffer without bound,
            // so a link slower than the source accumulates minutes of latency that presents as
            // "no picture at all". The state and control messages stay unconditional — they are
            // tiny, and a late reading is better than none.
            guard peer.inFlightFrames < maxInFlightFramesPerPeer else {
                // Skipping breaks this peer's reference chain; it resumes on the next keyframe.
                peers[key]?.needsKeyframe = true
                keyframeWanted = true
                continue
            }
            // A joining or resuming peer waits for a frame it can actually decode. JPEG frames
            // are all keyframes, so this never withholds anything on the fallback path.
            if peer.needsKeyframe && !frameMetadata.isKeyframe {
                keyframeWanted = true
                continue
            }
            peers[key]?.needsKeyframe = false
            peers[key]?.inFlightFrames += 1
            peer.connection.send(
                content: framed,
                completion: .contentProcessed { [weak self] _ in
                    Task { @MainActor in self?.peers[key]?.inFlightFrames -= 1 }
                })
        }
        if keyframeWanted { onKeyframeNeeded?() }
    }

    private func broadcast(kind: MonitorRelayProtocol.Kind, payload: Data) {
        for peer in peers.values where peer.authorized {
            send(kind: kind, payload: payload, to: peer.connection)
        }
    }

    private func send(kind: MonitorRelayProtocol.Kind, payload: Data, to connection: NWConnection) {
        connection.send(
            content: MonitorRelayFraming.encode(kind: kind, payload: payload),
            completion: .contentProcessed { _ in })
    }

    private func encode<T: Encodable>(_ value: T) -> Data {
        (try? JSONEncoder().encode(value)) ?? Data()
    }
}

// MARK: - Browser

/// Finds broadcasting devices, over the local network and peer-to-peer alike.
@MainActor
final class MonitorRelayBrowser {
    private(set) var results: [MonitorRelayDiscovery] = []
    var onResults: (@MainActor ([MonitorRelayDiscovery]) -> Void)?

    private var listBrowser: NWBrowser?
    private var txtBrowser: NWBrowser?
    /// Rows per browser, keyed by service name; a broadcast lists if EITHER browser sees it.
    private var rowsByDescriptor: [String: [String: MonitorRelayDiscovery]] = [:]
    private let queue = DispatchQueue(label: "com.opencapture.openzcine.relay-browser")

    /// `includePeerToPeer` browses over AWDL as well — which time-slices the radio the browsing
    /// device's own streams ride. The camera list browses with it (nothing to protect, and an
    /// AP-session broadcast is only visible that way); a viewer session browsing to keep its
    /// rejoin watchdog sighted does NOT — it only needs to re-find a broadcast it could already
    /// reach, and AWDL under a decoding watcher costs the same fps it costs a broadcaster.
    ///
    /// TWO browsers on purpose. Listing must never hinge on `.bonjourWithTXTRecord`: that
    /// descriptor is the only way to RECEIVE the served-camera `ch=` key (plain `.bonjour`
    /// never delivers TXT — the original drop-storm hole), but a live report has a broadcast
    /// missing from a watcher's list since the descriptor swap, so the battle-tested plain
    /// browse runs alongside it. Rows come from either; `ch=` enriches from whichever browser
    /// delivered metadata. Both log state and results — a silent browser is how "not in the
    /// list, and the camera keeps dropping" went undiagnosable.
    func start(includePeerToPeer: Bool = true) {
        stop()
        listBrowser = makeBrowser(
            label: "list",
            descriptor: .bonjour(type: MonitorRelayProtocol.serviceType, domain: nil),
            includePeerToPeer: includePeerToPeer)
        txtBrowser = makeBrowser(
            label: "txt",
            descriptor: .bonjourWithTXTRecord(type: MonitorRelayProtocol.serviceType, domain: nil),
            includePeerToPeer: includePeerToPeer)
    }

    private func makeBrowser(
        label: String, descriptor: NWBrowser.Descriptor, includePeerToPeer: Bool
    ) -> NWBrowser {
        let browser = NWBrowser(
            for: descriptor,
            using: relayParameters(includePeerToPeer: includePeerToPeer))
        browser.stateUpdateHandler = { state in
            // `.failed`/`.waiting` carry the network's own reason — PolicyDenied here is the
            // Local Network permission signal (TN3179: there is no query API, only this).
            switch state {
            case .failed(let error), .waiting(let error):
                logConnection("relay browse[\(label)] state=\(state) error=\(error)")
            default:
                break
            }
        }
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discoveries = results.compactMap { result -> MonitorRelayDiscovery? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                var servedCameraHost: String?
                if case .bonjour(let txt) = result.metadata {
                    servedCameraHost = txt[MonitorRelayProtocol.servedCameraTXTKey]
                }
                return MonitorRelayDiscovery(
                    id: name, name: name, endpoint: result.endpoint,
                    servedCameraHost: servedCameraHost)
            }
            let listing = discoveries.map { "\($0.name)(ch=\($0.servedCameraHost ?? "nil"))" }
                .joined(separator: " ")
            logConnection("relay browse[\(label)] results=\(discoveries.count) [\(listing)]")
            Task { @MainActor in
                self?.mergeResults(discoveries, from: label)
            }
        }
        browser.start(queue: queue)
        return browser
    }

    private func mergeResults(_ discoveries: [MonitorRelayDiscovery], from label: String) {
        rowsByDescriptor[label] = Dictionary(
            uniqueKeysWithValues: discoveries.map { ($0.name, $0) })
        var merged: [String: MonitorRelayDiscovery] = [:]
        for rows in rowsByDescriptor.values {
            for (name, row) in rows {
                let existing = merged[name]
                // Insert if new; upgrade only to a row that carries the probe shield.
                if existing == nil
                    || (existing?.servedCameraHost == nil && row.servedCameraHost != nil)
                {
                    merged[name] = row
                }
            }
        }
        let sorted = merged.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        results = sorted
        onResults?(sorted)
    }

    func stop() {
        listBrowser?.cancel()
        listBrowser = nil
        txtBrowser?.cancel()
        txtBrowser = nil
        rowsByDescriptor = [:]
        results = []
    }
}

// MARK: - Client

/// Receives a relayed monitor feed.
@MainActor
final class MonitorRelayClient {
    enum State: Equatable {
        case idle
        case connecting
        /// The route to the host is not coming up — Wi-Fi isolation, a blocked port, a stale
        /// Bonjour record. Distinct from `connecting` because it carries the network's own reason,
        /// and from `failed` because the connection is still retrying underneath.
        case waiting(String)
        case connected(hostName: String, cameraName: String?)
        case failed(String)
    }

    private(set) var state: State = .idle
    var onStateChanged: (@MainActor (State) -> Void)?
    var onRelayState: (@MainActor (MonitorRelayState) -> Void)?
    var onFrame: (@MainActor (MonitorRelayFrameMetadata, Data) -> Void)?
    var onControlToken: (@MainActor (MonitorRelayControlToken) -> Void)?

    private var connection: NWConnection?
    /// The adopted session's framing state; nil outside a session. Main-actor-owned on purpose —
    /// see `receive(on:)`.
    private var streamReader: MonitorRelayStreamReader?
    /// The host refused the join (wrong or missing passcode). Fires INSTEAD of a failure state
    /// so the model can ask for the code rather than showing a dead-link error.
    var onJoinDenied: (@MainActor (MonitorRelayJoinDenied) -> Void)?
    /// Both candidate transports while the race runs; empty once one is adopted.
    private var racingConnections: [NWConnection] = []
    /// Messages issued before a transport won the race — `introduce` fires immediately after
    /// `connect`, so there is always at least one.
    private var pendingSends: [Data] = []
    private var connectTimeout: Task<Void, Never>?
    /// The most recent reason a candidate gave for waiting, for the timeout's failure message.
    private var lastWaitingReason: String?
    private let queue = DispatchQueue(label: "com.opencapture.openzcine.relay-client")

    /// A join that has produced no transport by now is not going to; report it rather than let
    /// "connecting" stand in for "stuck". On a healthy network adoption takes well under a second.
    private static let connectTimeoutSeconds: Double = 15

    func connect(to endpoint: NWEndpoint) {
        stop()
        update(.connecting)
        // RACE two transports rather than letting one connection choose internally. With
        // `includePeerToPeer` the single-connection path can spend 30–45 s trying to bring up the
        // peer-to-peer radio — which time-slices against the very Wi-Fi link the host is
        // streaming the camera over — before settling on the infrastructure route that was ready
        // all along. Racing an infrastructure-only candidate against a peer-to-peer-enabled one
        // and adopting whichever is READY first makes the same-network case instant while keeping
        // the no-network case working; the loser is cancelled.
        let candidates = [
            NWConnection(to: endpoint, using: relayParameters(includePeerToPeer: false)),
            NWConnection(to: endpoint, using: relayParameters(includePeerToPeer: true)),
        ]
        racingConnections = candidates
        for candidate in candidates {
            candidate.stateUpdateHandler = { [weak self, weak candidate] state in
                guard let candidate else { return }
                switch state {
                case .ready:
                    Task { @MainActor in self?.adopt(candidate) }
                case .waiting(let error):
                    relayLogger.info("relay client: waiting — \(error.localizedDescription)")
                    Task { @MainActor in
                        guard let self, self.connection == nil else { return }
                        self.lastWaitingReason = error.localizedDescription
                        self.update(.waiting(error.localizedDescription))
                    }
                case .failed(let error):
                    Task { @MainActor in self?.candidateFailed(candidate, error: error) }
                default:
                    break
                }
            }
            candidate.start(queue: queue)
        }
        connectTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.connectTimeoutSeconds))
            guard !Task.isCancelled, let self, self.connection == nil else { return }
            let reason = self.lastWaitingReason.map { " (\($0))" } ?? ""
            self.update(
                .failed(
                    "Couldn't reach the broadcasting device\(reason). "
                        + "Make sure OpenZCine is open on it."))
            self.stop()
        }
    }

    /// First transport to become ready carries the session; the rest are cancelled.
    private func adopt(_ winner: NWConnection) {
        guard connection == nil else {
            if winner !== connection { winner.cancel() }
            return
        }
        relayLogger.info("relay client: transport ready, adopted")
        connection = winner
        for candidate in racingConnections where candidate !== winner { candidate.cancel() }
        racingConnections = []
        connectTimeout?.cancel()
        connectTimeout = nil
        // Post-adoption lifecycle: the race handler above stops mattering once adopted, so the
        // winner gets the plain session handler.
        winner.stateUpdateHandler = { [weak self] state in
            switch state {
            case .waiting(let error):
                Task { @MainActor in self?.update(.waiting(error.localizedDescription)) }
            case .failed(let error):
                Task { @MainActor in self?.update(.failed(error.localizedDescription)) }
            case .cancelled:
                Task { @MainActor in self?.update(.idle) }
            default:
                break
            }
        }
        for framed in pendingSends {
            winner.send(content: framed, completion: .contentProcessed { _ in })
        }
        pendingSends = []
        streamReader = MonitorRelayStreamReader()
        receive(on: winner)
    }

    private func candidateFailed(_ candidate: NWConnection, error: NWError) {
        guard connection == nil else { return }
        racingConnections.removeAll { $0 === candidate }
        // Only when EVERY candidate has failed is the join dead — one failing while the other is
        // still trying is the expected shape of the race.
        if racingConnections.isEmpty {
            update(.failed(error.localizedDescription))
            stop()
        }
    }

    func stop() {
        streamReader = nil
        connectTimeout?.cancel()
        connectTimeout = nil
        for candidate in racingConnections { candidate.cancel() }
        racingConnections = []
        pendingSends = []
        lastWaitingReason = nil
        connection?.cancel()
        connection = nil
        if state != .idle { update(.idle) }
    }

    /// Introduces this device so a control request can name who is asking — and carries the
    /// watcher passcode when the broadcast requires one.
    func introduce(deviceName: String, passcode: String? = nil) {
        guard
            let payload = try? JSONEncoder().encode(
                MonitorRelayHello(
                    version: MonitorRelayProtocol.version, hostName: deviceName, cameraName: nil,
                    passcode: passcode))
        else { return }
        send(kind: .hello, payload: payload)
    }

    func requestControl() { send(kind: .requestControl, payload: Data()) }
    func releaseControl() { send(kind: .releaseControl, payload: Data()) }

    /// Issues a camera command. The host ignores it unless this device holds the token, so a
    /// command racing a revocation lands nowhere rather than on the camera.
    func send(command: MonitorRelayCommand) {
        guard let payload = try? JSONEncoder().encode(command) else { return }
        send(kind: .command, payload: payload)
    }

    private func send(kind: MonitorRelayProtocol.Kind, payload: Data) {
        let framed = MonitorRelayFraming.encode(kind: kind, payload: payload)
        guard let connection else {
            // The race has no winner yet; deliver on adoption so `introduce` is never lost.
            pendingSends.append(framed)
            return
        }
        connection.send(content: framed, completion: .contentProcessed { _ in })
    }

    /// All framing happens on the main actor against the session's own reader; the connection
    /// identity guard kills a stale loop the moment a rejoin replaces the session. (A reader
    /// captured across both isolation domains was a data-race diagnostic on newer compilers.)
    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
            [weak self] data, _, isComplete, error in
            Task { @MainActor in
                guard let self, self.connection === connection, let reader = self.streamReader
                else { return }
                var messages: [MonitorRelayFraming.Decoded] = []
                if let data, !data.isEmpty {
                    do {
                        messages = try reader.append(data)
                    } catch {
                        self.update(.failed("The relay stream desynchronised."))
                        self.stop()
                        return
                    }
                }
                for message in messages { self.handle(message) }
                if isComplete || error != nil {
                    self.update(.failed("The broadcasting device disconnected."))
                    self.stop()
                    return
                }
                self.receive(on: connection)
            }
        }
    }

    private func handle(_ message: MonitorRelayFraming.Decoded) {
        switch message.kind {
        case .hello:
            guard
                let hello = try? JSONDecoder().decode(
                    MonitorRelayHello.self, from: message.payload)
            else { return }
            // Refuse rather than render a payload whose shape we would be guessing at.
            guard hello.version == MonitorRelayProtocol.version else {
                update(
                    .failed(
                        "That device is running a different version of OpenZCine — update both to "
                            + "connect."))
                stop()
                return
            }
            update(.connected(hostName: hello.hostName, cameraName: hello.cameraName))
        case .state:
            guard
                let state = try? JSONDecoder().decode(
                    MonitorRelayState.self, from: message.payload)
            else { return }
            onRelayState?(state)
        case .frame:
            guard let frame = try? MonitorRelayFramePayload.decode(message.payload) else { return }
            onFrame?(frame.metadata, frame.image)
        case .controlToken:
            guard
                let token = try? JSONDecoder().decode(
                    MonitorRelayControlToken.self, from: message.payload)
            else { return }
            onControlToken?(token)
        case .joinDenied:
            let denial = try? JSONDecoder().decode(
                MonitorRelayJoinDenied.self, from: message.payload)
            onJoinDenied?(
                denial
                    ?? MonitorRelayJoinDenied(
                        reason: "The broadcasting device refused this join.",
                        passcodeRequired: false))
            stop()
        case .requestControl, .releaseControl, .command:
            break  // Viewer → host only.
        }
    }

    private func update(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChanged?(next)
    }
}
