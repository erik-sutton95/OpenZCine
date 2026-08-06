import CryptoKit
import Foundation
import Network

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
