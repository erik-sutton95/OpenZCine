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
}
