import OpenZCineCore

/// Platform-neutral live-audio payload for the Android JNI seam.
///
/// The shared core decodes Nikon's four sound-indicator bytes and maps them
/// onto its dBFS scale. This wire deliberately carries only that resolved
/// presentation data so Kotlin never learns camera-header layout or meter
/// conversion policy.
struct LiveAudioMeterWire: Equatable, Sendable {
    let hasLevels: Bool
    let leftLevelDB: Double
    let leftPeakDB: Double
    let rightLevelDB: Double
    let rightPeakDB: Double

    init(sound: PTPLiveViewSoundIndicator?) {
        guard let sound else {
            hasLevels = false
            leftLevelDB = AudioMeterBallistics.floorDB
            leftPeakDB = AudioMeterBallistics.floorDB
            rightLevelDB = AudioMeterBallistics.floorDB
            rightPeakDB = AudioMeterBallistics.floorDB
            return
        }

        let levels = AudioMeterLevels(cameraIndicator: sound)
        hasLevels = true
        leftLevelDB = levels.left.levelDB
        leftPeakDB = levels.left.peakDB
        rightLevelDB = levels.right.levelDB
        rightPeakDB = levels.right.peakDB
    }
}
