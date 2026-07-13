import Foundation

/// How thermally stressed the host device is, as a portable tier the core can reason about without
/// importing any platform thermal API. The iOS shell maps `ProcessInfo.ThermalState` onto this; an
/// Android shell can map its own signal.
///
/// Drives graceful, *cosmetic-only* load-shedding on the live monitor: under real thermal pressure a
/// phone running the feed in the sun for 30+ minutes will be force-throttled by the OS, giving a
/// random stutter at the worst possible moment. Deliberately slowing the feed-display and
/// scope-sampling refresh — the two heaviest per-frame CPU/GPU costs — sheds the heat that causes the
/// throttle *on our terms* while staying readable, and is a strict no-op until the device is genuinely
/// hot. This tier itself never changes the camera's recording resolution, codec, or take; the shell
/// may separately pass it to ``LiveViewLoadPolicy`` to reduce only the disposable preview stream.
public enum ThermalTier: Int, Sendable, CaseIterable, Comparable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalTier, rhs: ThermalTier) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Multiplier applied to a cosmetic refresh *interval* (feed display + scope sampling). Always
    /// `>= 1`, so it can only ever *slow* those refreshes — never speed them up, and never touch the
    /// camera stream, resolution, or networking.
    ///
    /// `.nominal`/`.fair` are a deliberate no-op: `.fair` is normal under sustained load, so the
    /// operator's monitor is left untouched until the device is genuinely hot (`.serious`+), where the
    /// OS is about to throttle anyway and a controlled, gentle slowdown beats a random OS-forced
    /// stutter.
    ///
    /// The values are a starting point tuned for "keep the feed usable while shedding heat"; they are
    /// the calibration knob to adjust after an on-device thermal-soak (a real ZR + a >= 30-min run in
    /// the sun). At the shipping base intervals (feed 1/24 s, scopes 1/12–1/8 s) `.critical`'s ×2
    /// floors the feed at 12 fps and scopes at 4–6 Hz — still readable. `ThermalLoadPolicyTests`
    /// guards that floor, so bumping a multiplier too high fails a test.
    public var cadenceMultiplier: Double {
        switch self {
        case .nominal, .fair: 1.0
        case .serious: 1.5
        case .critical: 2.0
        }
    }

    /// Whether this tier sheds any load (`cadenceMultiplier > 1`). Lets the shell surface a "thermal"
    /// badge so an operator knows a slowed feed is the phone shedding heat, not the camera dropping.
    public var isSheddingLoad: Bool { cadenceMultiplier > 1.0 }

    /// Applies the tier's multiplier to a base refresh interval (seconds). Returned interval is always
    /// `>= base`, so callers can substitute it wherever they used the fixed base interval.
    public func sheddingInterval(base: Double) -> Double {
        base * cadenceMultiplier
    }
}

/// Chooses the camera preview size under recording and thermal load without ever increasing the
/// operator's requested quality. This affects only the live-view JPEG stream; it never changes the
/// recording resolution, codec, or the take on the camera card.
public enum LiveViewLoadPolicy {
    /// Returns a supported `LiveViewImageSize` (`1` = QVGA, `2` = VGA, `3` = XGA) that bounds the
    /// requested preview size for the current load conditions.
    public static func effectiveImageSize(
        requested: UInt8,
        isRecording: Bool,
        thermalTier: ThermalTier,
        cameraOverheating: Bool
    ) -> UInt8 {
        var cap: UInt8 = isRecording ? 2 : 3
        switch thermalTier {
        case .critical:
            cap = 1
        case .serious:
            cap = min(cap, 2)
        case .nominal, .fair:
            break
        }
        if cameraOverheating { cap = 1 }
        return min(max(requested, 1), cap)
    }
}
