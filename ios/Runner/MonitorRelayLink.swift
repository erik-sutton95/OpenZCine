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
/// `includePeerToPeer` is the whole reason one implementation covers every camera transport: with
/// it, the same Bonjour service resolves over a shared network *and* over Apple's peer-to-peer
/// radio. That is what lets viewers reach a host which is itself occupying its Wi-Fi association
/// on the camera's own access point — the case that otherwise has no path at all.
private func relayParameters() -> NWParameters {
    let parameters = NWParameters.tcp
    parameters.includePeerToPeer = true
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

    static func == (lhs: MonitorRelayDiscovery, rhs: MonitorRelayDiscovery) -> Bool {
        lhs.id == rhs.id
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
        var name: String
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
    private let queue = DispatchQueue(label: "com.opencapture.openzcine.relay-host")
    /// Sent to every viewer that connects, so a late joiner is not staring at nothing until the
    /// next state change happens to come along.
    private var latestState: MonitorRelayState?
    private var hostName = ""
    private var cameraName: String?

    func start(hostName: String, cameraName: String?) {
        stop()
        self.hostName = hostName
        self.cameraName = cameraName
        do {
            let listener = try NWListener(using: relayParameters())
            listener.service = NWListener.Service(
                name: hostName, type: MonitorRelayProtocol.serviceType)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard case .failed(let error) = state else { return }
                Task { @MainActor in
                    self?.onFailure?("Sharing stopped: \(error.localizedDescription)")
                    self?.stop()
                }
            }
            listener.start(queue: queue)
            self.listener = listener
            isBroadcasting = true
        } catch {
            onFailure?("Couldn't start sharing: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        for peer in peers.values { peer.connection.cancel() }
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
        peers[ObjectIdentifier(connection)] = Peer(connection: connection, name: "A device")
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
        if let latestState {
            send(kind: .state, payload: encode(latestState), to: connection)
        }
        receive(on: connection, reader: MonitorRelayStreamReader())
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

    /// Viewer → host traffic. Only the control handshake travels this way today.
    private func receive(on connection: NWConnection, reader: MonitorRelayStreamReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            var messages: [MonitorRelayFraming.Decoded] = []
            if let data, !data.isEmpty {
                do {
                    messages = try reader.append(data)
                } catch {
                    // A desynchronised stream cannot be recovered by reading further.
                    Task { @MainActor in self?.drop(connection) }
                    return
                }
            }
            Task { @MainActor in
                guard let self else { return }
                for message in messages { self.handle(message, from: connection) }
                if isComplete || error != nil {
                    self.drop(connection)
                    return
                }
                self.receive(on: connection, reader: reader)
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
        case .requestControl:
            guard let peer = peers[key] else { return }
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
        case .state, .frame, .controlToken:
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
    /// Two = one on the wire and one behind it; more is latency the viewer can never win back.
    private static let maxInFlightFramesPerPeer = 2

    /// Whether at least one viewer could accept a frame right now. Checked BEFORE the encode:
    /// when every peer is saturated, encoding would burn the hardware block on a frame nobody
    /// receives — and because nothing is encoded, the encoder's reference chain stays exactly
    /// where every viewer's is, so resuming needs no keyframe.
    var hasPeerReadyForFrame: Bool {
        peers.values.contains { $0.inFlightFrames < Self.maxInFlightFramesPerPeer }
    }

    func broadcast(frameMetadata: MonitorRelayFrameMetadata, image: Data) {
        guard !peers.isEmpty else { return }
        guard
            let payload = try? MonitorRelayFramePayload.encode(
                metadata: frameMetadata, image: image)
        else { return }
        let framed = MonitorRelayFraming.encode(kind: .frame, payload: payload)
        var keyframeWanted = false
        for (key, peer) in peers {
            // A monitor shows the newest frame or it is not a monitor. A peer that has not
            // drained is SKIPPED, never queued for: fire-and-forget sends buffer without bound,
            // so a link slower than the source accumulates minutes of latency that presents as
            // "no picture at all". The state and control messages stay unconditional — they are
            // tiny, and a late reading is better than none.
            guard peer.inFlightFrames < Self.maxInFlightFramesPerPeer else {
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
        for peer in peers.values { send(kind: kind, payload: payload, to: peer.connection) }
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

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.opencapture.openzcine.relay-browser")

    func start() {
        stop()
        let browser = NWBrowser(
            for: .bonjour(type: MonitorRelayProtocol.serviceType, domain: nil),
            using: relayParameters())
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let discoveries = results.compactMap { result -> MonitorRelayDiscovery? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return MonitorRelayDiscovery(
                    id: name, name: name, endpoint: result.endpoint)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            Task { @MainActor in
                self?.results = discoveries
                self?.onResults?(discoveries)
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    func stop() {
        browser?.cancel()
        browser = nil
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
        let infrastructureOnly = NWParameters.tcp
        if let tcp = infrastructureOnly.defaultProtocolStack.transportProtocol
            as? NWProtocolTCP.Options
        {
            tcp.noDelay = true
        }
        let candidates = [
            NWConnection(to: endpoint, using: infrastructureOnly),
            NWConnection(to: endpoint, using: relayParameters()),
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
        receive(reader: MonitorRelayStreamReader())
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

    /// Introduces this device so a control request can name who is asking.
    func introduce(deviceName: String) {
        guard
            let payload = try? JSONEncoder().encode(
                MonitorRelayHello(
                    version: MonitorRelayProtocol.version, hostName: deviceName, cameraName: nil))
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

    private func receive(reader: MonitorRelayStreamReader) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 1024 * 1024) {
            [weak self] data, _, isComplete, error in
            var messages: [MonitorRelayFraming.Decoded] = []
            if let data, !data.isEmpty {
                do {
                    messages = try reader.append(data)
                } catch {
                    Task { @MainActor in
                        self?.update(.failed("The relay stream desynchronised."))
                        self?.stop()
                    }
                    return
                }
            }
            Task { @MainActor in
                guard let self else { return }
                for message in messages { self.handle(message) }
                if isComplete || error != nil {
                    self.update(.failed("The broadcasting device disconnected."))
                    self.stop()
                    return
                }
                self.receive(reader: reader)
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
