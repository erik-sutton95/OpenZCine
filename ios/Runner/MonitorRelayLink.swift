import Foundation
import Network
import OpenCineRelay
import OpenCineRelayApple
import OpenZCineCore

// Deployed wire/profile and host persistence adapters only. Socket/browser/control/source
// lifetime, admission, recovery and delivery are shared owners.
typealias MonitorRelayDiscovery = RelayAppleDiscovery
typealias MonitorRelayHost = RelayAppleHost<DeployedMonitorRelayCodec>
typealias MonitorRelayClient = RelayAppleClient<DeployedMonitorRelayCodec>
typealias MonitorRelayBrowser = RelayAppleBrowser
typealias CameraInUseBeacon = RelayAppleInUseBeacon

extension RelayAppleHost where Codec == DeployedMonitorRelayCodec {
    convenience init(profile: RelayEncoderProfile = .lowLatency) {
        self.init(
            codec: DeployedMonitorRelayCodec(), profile: profile,
            network: .init(prohibitsCellular: false),
            versionMismatchReason:
                "That device is running a different version of OpenZCine \u{2014} update both to connect.",
            requiresVersionMatch: false, journal: { logConnection($0) })
    }
}
extension RelayAppleClient where Codec == DeployedMonitorRelayCodec {
    convenience init() {
        self.init(
            codec: DeployedMonitorRelayCodec(), network: .init(prohibitsCellular: false),
            racePeerToPeer: true, watcherID: Self.savedWatcherID,
            versionMismatchReason:
                "That device is running a different version of OpenZCine \u{2014} update both to connect.",
            unreachableSuffix: " Make sure OpenZCine is open on it.", journal: { logConnection($0) }
        )
    }
    // Existing saved approvals/control identity namespace; it remains an explicit app store.
    static var savedWatcherID: String {
        let key = "relay.watcherID"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let minted = UUID().uuidString
        UserDefaults.standard.set(minted, forKey: key)
        return minted
    }
}
extension RelayAppleBrowser {
    convenience init() {
        self.init(
            profile: DeployedMonitorRelayCodec().profile,
            network: .init(prohibitsCellular: false), usesPlainListing: true,
            journal: { logConnection($0) })
    }
}
extension RelayAppleInUseBeacon {
    convenience init() {
        self.init(
            profile: DeployedMonitorRelayCodec().profile,
            network: .init(prohibitsCellular: false), journal: { logConnection($0) })
    }
}

// The integration owns these exact presence JSON fields. The shared SDK owner accepts bytes,
// owns passive TCP listener/source windows, and never opens a camera connection.
@MainActor final class RelayPresenceServer {
    private let owner = RelayApplePresenceServer(
        port: MonitorRelayProtocol.presenceTCPPort,
        journal: { logConnection($0) })
    func update(_ presence: RelayPresence?) {
        if let presence {
            logConnection(
                "presence responder on (w=\(presence.w) ch=\(presence.ch ?? "nil") p=\(presence.p.map(String.init) ?? "nil"))"
            )
        }
        owner.update(encodedLine: presence?.encodedLine())
    }
}

/// Exact wire facts and native endpoint construction; the passive ledger is shared.
enum MonitorRelayNearbyComposition {
    static func make() -> RelayNearbyOwner<MonitorRelayDiscovery, RelayPresence> {
        .init(
            policy: .init(
                hiddenIdentity: .sourceAddress, duplicateIdentity: .allListings,
                removesPresenceOnListingRemoval: true, confirmation: .watchableAnswers),
            listingFacts: { .init(name: $0.name, isWatchable: $0.isWatchable) },
            presenceFacts: { .init(name: $0.n, isWatchable: $0.isWatchable, relayPort: $0.p) },
            presenceListing: { host, rawPort, presence in
                guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: rawPort)) else {
                    return nil
                }
                return MonitorRelayDiscovery(
                    id: "presence:\(host)", name: presence.n,
                    endpoint: .hostPort(host: NWEndpoint.Host(host), port: port),
                    servedCameraHost: presence.ch, isWatchable: true)
            })
    }
}
