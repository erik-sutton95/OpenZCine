import Foundation

/// Operation selection for a connected Z-series body, driven by the operation codes the
/// body advertises in `GetDeviceInfo` rather than by model-name tables.
///
/// The lineup splits into three vendor-surface generations:
/// - Gen 1 (Z 5 / Z 6 / Z 7 / Z 50): app-control mode is entered by writing the
///   `ApplicationMode` property (0xD1F0); vendor property discovery is
///   `GetVendorPropCodes` (0x90CA); no Ex property ops, no open-capture ops.
/// - Gen 2 (Z 6II / Z 7II / Z fc / Z 30): adds the `ChangeApplicationMode` operation
///   (0x9435) and drops the property path; still 0x90CA, still no Ex property ops.
/// - Gen 3 (Z 8 / Z 9 / Z 6III / Z f / Z 5II / Z 50II / ZR): adds `GetVendorCodes`
///   (0x9439, replacing 0x90CA), the Ex property ops (0x943A–0x943C) for 4-byte extended
///   property codes, and the open-capture ops (0x9445–0x9447).
///
/// `GetLiveViewImageEx` (0x9428), `GetEventEx` (0x941C), `DeviceReady` (0x90C8),
/// `ChangeCameraMode` (0x90C2) and `InitiateCaptureRecInMedia` (0x9207) are advertised
/// across the whole lineup, so the app carries no fallback paths for those. The PTP-IP
/// pairing ops are a network-transport surface and never appear in the USB op set; gate
/// pairing on the live DeviceInfo ops list, not on generation.
public struct ZCameraOperationPolicy: Equatable, Sendable {
    public let operations: Set<UInt16>

    public init(operations: Set<UInt16>) {
        self.operations = operations
    }

    public init(deviceInfo: PTPDeviceInfo) {
        self.init(operations: deviceInfo.operationsSupported)
    }

    /// True when an ops list was actually delivered. An empty list means DeviceInfo was
    /// not (yet) fetched — callers then assume the modern surface and rely on
    /// per-operation error handling.
    public var isKnown: Bool { !operations.isEmpty }

    public func supports(_ operation: PTPOperationCode) -> Bool {
        operations.contains(operation.rawValue)
    }

    /// Still release op: media-destination capture everywhere it is advertised, standard
    /// `InitiateCapture` as the defensive fallback.
    public var stillCaptureOperation: PTPOperationCode {
        !isKnown || supports(.initiateCaptureRecInMedia)
            ? .initiateCaptureRecInMedia : .initiateCapture
    }

    /// Whether app-control mode is entered with the `ChangeApplicationMode` operation.
    /// Gen-1 bodies instead accept a write of 1 to the `ApplicationMode` property (0xD1F0).
    public var appModeViaOperation: Bool {
        !isKnown || supports(.changeApplicationMode)
    }

    /// Whether the network pairing handshake (`GetPairingInfo`/`ConfirmPairing`) exists on this
    /// body. Gen-1 bodies don't implement it — joining their access point IS the trust boundary —
    /// and polling an op a body never advertised is how a Z 5 ends up showing a wireless error on
    /// its own screen while the app spins. Unknown ops keep today's behaviour (attempt pairing),
    /// so a failed DeviceInfo fetch can never lock a gen-3 body out of first pairing.
    /// [verify-on-HW: Z 5 over camera AP]
    public var supportsPairing: Bool {
        !isKnown || supports(.getPairingInfo)
    }

    /// Vendor code discovery: `GetVendorCodes` (ops + props) on gen-3 bodies,
    /// `GetVendorPropCodes` (props only) before that, nil when neither is advertised.
    public var vendorCodeDiscoveryOperation: PTPOperationCode? {
        if !isKnown || supports(.getVendorCodes) { return .getVendorCodes }
        if supports(.getVendorPropCodes) { return .getVendorPropCodes }
        return nil
    }

    /// Ex property ops exist only on gen-3 bodies. 2-byte property codes always use the
    /// standard PIMA ops regardless of generation; the Ex ops exist solely for the 4-byte
    /// `0x0001_xxxx` extended codes.
    public var supportsExtendedPropertyOps: Bool {
        !isKnown || supports(.getDevicePropValueEx)
    }

    /// Interval / focus-shift open capture (gen-3 bodies).
    public var supportsOpenCapture: Bool {
        isKnown && supports(.initiateOpenCaptureV)
    }

    /// Parameter for `GetVendorCodes` selecting the vendor DevicePropCode array.
    public static let vendorCodesPropertyListParameter: UInt32 = 0x0D

    /// Conservative gen-1 OperationsSupported used only when DeviceInfo did not
    /// arrive and the handshake / USB product name is an original Z 5 / Z 6 / Z 7 / Z 50.
    ///
    /// This is not a model table for op selection on a live body — advertised ops still
    /// win. It exists so a failed probe cannot fall through to GetPairingInfo /
    /// ChangeApplicationMode, which is how a gen-1 body shows a wireless error (#292)
    /// and how an original Z 6 fails to connect (#348).
    public static let generation1FallbackOperations: Set<UInt16> = [
        0x90CA, 0x90C2, 0x9201, 0x9202, 0x9203, 0x9428, 0x90C7, 0x941C, 0x90C8,
        0x100E, 0x9207, 0x90C0, 0x90CB, 0x920C,
    ]

    /// When DeviceInfo was not fetched, use a gen-1 surface if the camera name is an
    /// original Z 5 / Z 6 / Z 7 / Z 50. Later bodies and unknown names keep the
    /// modern-surface default so a failed probe cannot lock a gen-3 body out of pairing.
    public func resolvingUnknown(cameraName: String?) -> ZCameraOperationPolicy {
        guard !isKnown else { return self }
        guard let cameraName, ZCameraBodyGeneration.inferred(fromCameraName: cameraName) == .one
        else { return self }
        return ZCameraOperationPolicy(operations: Self.generation1FallbackOperations)
    }
}

/// Coarse Z-lineup generation inferred from a PTP-IP friendly name, USB product
/// name, or camera-AP SSID. Used only when DeviceInfo is missing.
public enum ZCameraBodyGeneration: Equatable, Sendable {
    /// Z 5 / Z 6 / Z 7 / Z 50 — property app-mode, no pairing handshake.
    case one
    /// Z 6II / Z 7II / Z fc / Z 30 — ChangeApplicationMode, still no Ex ops.
    case two
    /// Z 8 / Z 9 / Z 6III / Z f / Z 5II / Z 50II / ZR — modern vendor + pairing surface.
    case three

    /// Longest-token match so "Z 6III" is not classified as the original Z 6.
    ///
    /// USB product strings mark generation with an underscore digit (`Z6_3`, `Z 6_2`)
    /// rather than roman numerals. Those marks are rewritten before punctuation is
    /// stripped, otherwise `Z6_3` collapses to `Z63` and matches the original Z 6.
    public static func inferred(fromCameraName raw: String) -> ZCameraBodyGeneration? {
        matchedToken(fromCameraName: raw)?.generation
    }

    /// The model token that won the longest-match, such as `Z6III` or `Z6`. Nil when
    /// the name does not look like a Z body. Safe for a diagnostics export: it never
    /// includes a serial.
    public static func matchedToken(fromCameraName raw: String) -> (
        token: String, generation: ZCameraBodyGeneration
    )? {
        let compact = compactName(raw)
        guard !compact.isEmpty else { return nil }
        for entry in modelTokens where compact.contains(entry.token) {
            return entry
        }
        return nil
    }

    /// USB product / PTP-IP names reduced to alphanumerics after generation marks
    /// such as `Z6_3` / `Z5_2` / `Z50_2` have been rewritten to roman-numeral tokens.
    public static func compactName(_ raw: String) -> String {
        var compact = raw.uppercased()
        compact = compact.replacingOccurrences(of: "NIKON", with: "")
        compact = compact.replacingOccurrences(of: "DSC", with: "")
        compact = applyingUsbGenerationMarks(compact)
        return compact.filter { $0.isLetter || $0.isNumber }
    }

    private static let modelTokens: [(token: String, generation: ZCameraBodyGeneration)] = [
        ("Z6III", .three), ("Z7III", .three),
        ("Z50II", .three), ("Z5II", .three),
        ("Z6II", .two), ("Z7II", .two),
        ("ZFC", .two), ("Z30", .two),
        ("Z50", .one),
        ("ZR", .three), ("Z8", .three), ("Z9", .three), ("ZF", .three),
        ("Z5", .one), ("Z6", .one), ("Z7", .one),
    ]

    /// Nikon USB iProduct generation marks. Longest needles first so `Z50_2` is
    /// not eaten as `Z5_2`. A following digit means this underscore starts a
    /// serial (`Z 6_1234567`), not a generation suffix.
    private static let usbGenerationMarks: [(needle: String, token: String)] = [
        ("Z50_2", "Z50II"), ("Z 50_2", "Z50II"),
        ("Z7_3", "Z7III"), ("Z 7_3", "Z7III"),
        ("Z6_3", "Z6III"), ("Z 6_3", "Z6III"),
        ("Z5_2", "Z5II"), ("Z 5_2", "Z5II"),
        ("Z7_2", "Z7II"), ("Z 7_2", "Z7II"),
        ("Z6_2", "Z6II"), ("Z 6_2", "Z6II"),
    ]

    private static func applyingUsbGenerationMarks(_ raw: String) -> String {
        var result = raw
        for (needle, token) in usbGenerationMarks {
            var searchStart = result.startIndex
            while let range = result.range(of: needle, range: searchStart..<result.endIndex) {
                let after = range.upperBound
                if after < result.endIndex, result[after].isNumber {
                    searchStart = after
                    continue
                }
                result.replaceSubrange(range, with: token)
                searchStart = result.index(range.lowerBound, offsetBy: token.count)
            }
        }
        return result
    }
}

/// Decodes the vendor property-code array returned by the vendor discovery ops:
/// a UINT32 element count followed by 4-byte codes (`GetVendorCodes`) or 2-byte
/// codes (`GetVendorPropCodes`). Vendor properties never appear in the standard
/// DeviceInfo array, so this list is the only advertisement they get.
public enum PTPVendorPropertyCodeList {
    /// Returns the advertised codes, or an empty set when the payload is malformed
    /// or implausibly small (callers treat empty as "discovery unavailable" and
    /// never skip vendor polls on it).
    public static func decode(_ data: Data, fourByteCodes: Bool) -> Set<UInt32> {
        let bytes = Array(data)
        guard bytes.count >= 4 else { return [] }
        let count = Int(ByteCoding.readUInt32LE(bytes, at: 0))
        let width = fourByteCodes ? 4 : 2
        guard count > 0, bytes.count >= 4 + count * width else { return [] }
        var codes: Set<UInt32> = []
        codes.reserveCapacity(count)
        for index in 0..<count {
            let offset = 4 + index * width
            codes.insert(
                fourByteCodes
                    ? ByteCoding.readUInt32LE(bytes, at: offset)
                    : UInt32(ByteCoding.readUInt16LE(bytes, at: offset)))
        }
        // A real body advertises dozens of vendor properties; a near-empty list is
        // a garbled payload and must not become a poll veto.
        return codes.count >= 8 ? codes : []
    }
}
