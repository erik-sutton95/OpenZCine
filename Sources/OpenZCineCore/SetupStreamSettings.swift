/// What one camera setup asks the camera to send, and what it starts at before anyone asks.
///
/// Stream preset and quality bias were one global key per app. That reads fine until an operator
/// works two paths in a day: the camera's own access point is a genuinely narrower link than a
/// cable, so the bias they drop to survive it followed them onto USB-C the next morning and quietly
/// cost them detail on the path that had bandwidth to spare. The setting belongs to the setup,
/// because the constraint it answers to belongs to the path.
///
/// A stored value is the operator's; `nil` means they have never chosen one HERE, which is not the
/// same as choosing the default. Only the second case takes a default, and only the access point
/// gets one that differs — everything else starts from the app-wide seed, which is what the
/// settings rows edit while nothing is connected.
///
/// The Android shell carries a Kotlin twin of this rule in `SetupStreamSettings.kt`; both are
/// tested against the same table so a path can never mean one bias on iPhone and another on
/// Android. Change one, change both.
public enum SetupStreamSettings: Sendable {
    /// The bias a setup runs at: the operator's own choice, or what this path should start at.
    ///
    /// The access point starts Fast. It is the one path whose bandwidth is fixed by the camera's
    /// own radio rather than by the network someone built, and it is where dropped frames and
    /// stalls actually get reported from. Every other path — a router, a hotspot, a cable — starts
    /// from the seed, because nothing about them is known to be narrow.
    public static func qualityBias(
        stored: OperatorPreferences.QualityBias?,
        pathKind: CameraPath.Kind?,
        seed: OperatorPreferences.QualityBias
    ) -> OperatorPreferences.QualityBias {
        if let stored { return stored }
        return pathKind == .cameraAccessPoint ? .latency : seed
    }

    /// The preset a setup runs at: the operator's own choice, or the seed.
    ///
    /// No path override. The preset picks the frame SIZE, and the assists read that frame — the
    /// smallest preset is ~320×240, too little for focus and exposure detectors to read anything
    /// but compression structure. A narrow link is a reason to compress harder, not a reason to
    /// hand every detector a picture it cannot measure.
    public static func streamPreset(
        stored: OperatorPreferences.StreamPreset?,
        pathKind: CameraPath.Kind?,
        seed: OperatorPreferences.StreamPreset
    ) -> OperatorPreferences.StreamPreset {
        stored ?? seed
    }
}
