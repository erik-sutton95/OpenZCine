import Foundation
import Network

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

    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
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
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
        isBroadcasting = false
        updatePeerCount()
    }

    private func accept(_ connection: NWConnection) {
        connections[ObjectIdentifier(connection)] = connection
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
        connection.cancel()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        updatePeerCount()
    }

    private func updatePeerCount() {
        let count = connections.count
        guard count != peerCount else { return }
        peerCount = count
        onPeerCountChanged?(count)
    }

    /// Viewer → host traffic. Only the control handshake travels this way today.
    private func receive(on connection: NWConnection, reader: MonitorRelayStreamReader) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self, weak connection] data, _, isComplete, error in
            guard let connection else { return }
            if let data, !data.isEmpty {
                do {
                    _ = try reader.append(data)
                } catch {
                    // A desynchronised stream cannot be recovered by reading further.
                    Task { @MainActor in self?.drop(connection) }
                    return
                }
            }
            if isComplete || error != nil {
                Task { @MainActor in self?.drop(connection) }
                return
            }
            Task { @MainActor in self?.receive(on: connection, reader: reader) }
        }
    }

    // MARK: Broadcasting

    func broadcast(state: MonitorRelayState) {
        latestState = state
        broadcast(kind: .state, payload: encode(state))
    }

    func broadcast(frameMetadata: MonitorRelayFrameMetadata, image: Data) {
        guard !connections.isEmpty else { return }
        guard
            let payload = try? MonitorRelayFramePayload.encode(
                metadata: frameMetadata, image: image)
        else { return }
        broadcast(kind: .frame, payload: payload)
    }

    private func broadcast(kind: MonitorRelayProtocol.Kind, payload: Data) {
        for connection in connections.values { send(kind: kind, payload: payload, to: connection) }
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
        case connected(hostName: String, cameraName: String?)
        case failed(String)
    }

    private(set) var state: State = .idle
    var onStateChanged: (@MainActor (State) -> Void)?
    var onRelayState: (@MainActor (MonitorRelayState) -> Void)?
    var onFrame: (@MainActor (MonitorRelayFrameMetadata, Data) -> Void)?
    var onControlToken: (@MainActor (MonitorRelayControlToken) -> Void)?

    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "com.opencapture.openzcine.relay-client")

    func connect(to endpoint: NWEndpoint) {
        stop()
        update(.connecting)
        let connection = NWConnection(to: endpoint, using: relayParameters())
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error):
                Task { @MainActor in self?.update(.failed(error.localizedDescription)) }
            case .cancelled:
                Task { @MainActor in self?.update(.idle) }
            default:
                break
            }
        }
        connection.start(queue: queue)
        self.connection = connection
        receive(reader: MonitorRelayStreamReader())
    }

    func stop() {
        connection?.cancel()
        connection = nil
        if state != .idle { update(.idle) }
    }

    func requestControl() { send(kind: .requestControl, payload: Data()) }
    func releaseControl() { send(kind: .releaseControl, payload: Data()) }

    private func send(kind: MonitorRelayProtocol.Kind, payload: Data) {
        connection?.send(
            content: MonitorRelayFraming.encode(kind: kind, payload: payload),
            completion: .contentProcessed { _ in })
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
        case .requestControl, .releaseControl:
            break  // Viewer → host only.
        }
    }

    private func update(_ next: State) {
        guard state != next else { return }
        state = next
        onStateChanged?(next)
    }
}
