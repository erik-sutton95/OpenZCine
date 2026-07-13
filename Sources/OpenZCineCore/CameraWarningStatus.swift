import Foundation

/// Decoded view of the Nikon `WarningStatus` (0xD102) aggregate warning bitfield.
///
/// The property is a UINT8 whose individual bit positions are **runtime-enumerated by the body**
/// and are not published in any open source (see `PTPPropertyCode.warningStatus`). So this type
/// exposes only what can be stated honestly:
///
/// - ``isAnyWarningActive`` — reliable: any non-zero raw value means the body is flagging *some*
///   warning (battery / card / lens / temperature, per the aggregate's documented purpose).
/// - ``isOverheating`` — the *specific* temperature bit. Its position is unknown, so it is gated on
///   ``overheatBitMask``, a **verify-on-HW placeholder that defaults to 0 (disabled)**. Until the
///   real mask is filled in against a hot ZR, this is always `false` and the camera-driven
///   live-view step-down never fires on a guess — the phone's own thermal tier still drives it.
public struct CameraWarningStatus: Equatable, Sendable {
    /// The bit(s) that indicate a camera-temperature / overheat warning.
    ///
    /// **verify-on-HW:** unknown until measured against an overheating ZR. Kept 0 (disabled) so the
    /// overheat-driven stream downgrade never triggers on an unverified bit. When you have the
    /// value, set this single constant — everything downstream is already wired.
    public static let overheatBitMask: UInt8 = 0

    /// Raw 0xD102 byte, or nil when the property has not been polled (no camera / demo / sim).
    public let raw: UInt8?

    public init(raw: UInt8?) {
        self.raw = raw
    }

    /// True when the body is flagging any warning at all. False when unpolled or explicitly clear.
    public var isAnyWarningActive: Bool { (raw ?? 0) != 0 }

    /// True only when the (verify-on-HW) temperature bit is set. Always false while
    /// ``overheatBitMask`` is 0 — see the type doc.
    public var isOverheating: Bool {
        guard let raw, Self.overheatBitMask != 0 else { return false }
        return raw & Self.overheatBitMask != 0
    }

    /// Compact label for the monitor's TEMP tile. Never fabricates a temperature reading — reflects
    /// only real polled state.
    public var tileLabel: String {
        guard raw != nil else { return "OK" }
        if isOverheating { return "HOT" }
        return isAnyWarningActive ? "CHECK" : "OK"
    }

    /// Whether the tile should render in its healthy (green) style.
    public var isHealthy: Bool { !isAnyWarningActive }
}
