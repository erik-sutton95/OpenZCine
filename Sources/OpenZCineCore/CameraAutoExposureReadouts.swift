import Foundation

/// Camera-owned exposure readouts that can change without a `DevicePropChanged` (`0x4006`).
///
/// Operator dials and lens rings announce themselves; auto-exposure does not. In A/P/S/Auto (and
/// Auto ISO) the body continuously recomputes shutter, iris, and/or working ISO as the scene
/// changes, and many Nikon bodies never put those values on the event queue. The original #268
/// fast path only accelerated announced changes, so A-mode stills could sit on a stale shutter
/// and ISO for the full ~20 s round-robin (TestFlight: body 1/30 · ISO 1000, app 1/125 · A900,
/// aperture already matching).
///
/// The shells re-read this set on a bounded cadence — one property per tick, rotating — and skip
/// it entirely in M + manual ISO, where the operator is the only writer and `0x4006` already
/// covers a dial. Recording keeps the compact health poll; this set is standby / live-view only.
public enum CameraAutoExposureReadouts: Sendable {
    /// Properties the body can change on its own for this snapshot, in ISO → shutter → iris order
    /// so a two-slot rotation hits the values the capture strip shows first.
    public static func polledProperties(
        from snapshot: PTPCameraPropertySnapshot
    ) -> [PTPPropertyCode] {
        let photography = StillCapturePolicy.prefersPhotographyChrome(
            selector: snapshot.captureSelector)
        let mode = effectiveExposureMode(snapshot)
        var properties: [PTPPropertyCode] = []

        if isoIsCameraOwned(snapshot: snapshot, photography: photography, mode: mode) {
            properties.append(.isoControlSensitivity)
        }
        if shutterIsCameraOwned(
            mode: mode, locked: snapshot.shutterLocked, photography: photography)
        {
            if photography {
                properties.append(.stillShutterSpeed)
            } else {
                switch snapshot.shutterMode {
                case .angle:
                    properties.append(.movieShutterAngle)
                case .speed:
                    properties.append(.movieShutterSpeed)
                case nil:
                    // Until `MovieShutterMode` has been polled, cover both circuits so a
                    // Z6III-on-angle and a Z5II-on-speed both refresh.
                    properties.append(.movieShutterSpeed)
                    properties.append(.movieShutterAngle)
                }
            }
        }
        if irisIsCameraOwned(mode: mode) {
            properties.append(photography ? .fNumber : .movieFNumber)
        }
        return properties
    }

    /// True when at least one exposure readout is camera-owned and needs the bounded poll.
    public static func needsPoll(from snapshot: PTPCameraPropertySnapshot) -> Bool {
        !polledProperties(from: snapshot).isEmpty
    }

    /// Next camera-owned property to re-read, or `nil` when the operator owns every exposure
    /// value (M + manual ISO). `pollIndex` rotates through ``polledProperties(from:)``.
    public static func nextProperty(
        pollIndex: Int,
        snapshot: PTPCameraPropertySnapshot
    ) -> PTPPropertyCode? {
        let properties = polledProperties(from: snapshot)
        guard !properties.isEmpty else { return nil }
        let wrapped = pollIndex % properties.count
        let index = wrapped >= 0 ? wrapped : wrapped + properties.count
        return properties[index]
    }

    /// U1–U4 follow the bank's stored P/A/S/M program when the body has reported it.
    private static func effectiveExposureMode(
        _ snapshot: PTPCameraPropertySnapshot
    ) -> String? {
        guard let mode = snapshot.exposureMode else { return nil }
        if mode.hasPrefix("U") { return snapshot.userModeProgram }
        return mode
    }

    /// Stills ISO is a different circuit from movie dual-base: a leftover R3D movie codec must
    /// not suppress A-mode stills ISO. Movie ISO keeps ``ISOPickerPolicy``.
    private static func isoIsCameraOwned(
        snapshot: PTPCameraPropertySnapshot,
        photography: Bool,
        mode: String?
    ) -> Bool {
        if photography {
            return snapshot.isoAuto == true || mode != "M"
        }
        return ISOPickerPolicy.isISOValueCameraOwned(
            codec: snapshot.fileType ?? "",
            isoAuto: snapshot.isoAuto,
            exposureMode: mode)
    }

    /// Shutter is operator-owned in S and M. A locked movie TV circuit is operator-owned too.
    /// Unknown / Auto / P / A (and a U-bank that has not reported its program) stay camera-owned.
    private static func shutterIsCameraOwned(
        mode: String?,
        locked: Bool?,
        photography: Bool
    ) -> Bool {
        if !photography, locked == true { return false }
        switch mode {
        case "S", "M": return false
        default: return true
        }
    }

    /// Iris is operator-owned in A and M. Unknown / Auto / P / S stay camera-owned.
    private static func irisIsCameraOwned(mode: String?) -> Bool {
        switch mode {
        case "A", "M": return false
        default: return true
        }
    }
}
