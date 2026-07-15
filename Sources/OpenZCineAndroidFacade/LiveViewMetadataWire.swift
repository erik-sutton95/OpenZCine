import OpenZCineCore

/// Platform-neutral AF / subject metadata for the Android live-frame callback.
///
/// The shared Swift core has already parsed Nikon's live-view header before
/// this value is built. Kotlin only receives bounded presentation primitives
/// and never learns header offsets, byte order, or focus-result decoding.
struct LiveViewFocusWire: Equatable, Sendable {
    static let unavailableSelectedBoxIndex: Int32 = -1

    let hasFocus: Bool
    let coordinateWidth: Int32
    let coordinateHeight: Int32
    let result: Int32
    let subjectDetectionActive: Bool
    let trackingAFActive: Bool
    let selectedBoxIndex: Int32
    /// `[centerX, centerY, width, height]` for each box, in camera coordinates.
    let boxes: [Int32]

    init(focus: PTPLiveViewFocusInfo?) {
        guard let focus else {
            hasFocus = false
            coordinateWidth = 0
            coordinateHeight = 0
            result = 0
            subjectDetectionActive = false
            trackingAFActive = false
            selectedBoxIndex = Self.unavailableSelectedBoxIndex
            boxes = []
            return
        }

        hasFocus = true
        coordinateWidth = Int32(clamping: focus.coordinateWidth)
        coordinateHeight = Int32(clamping: focus.coordinateHeight)
        result =
            switch focus.focusResult {
            case .unknown: 0
            case .notFocused: 1
            case .focused: 2
            }
        subjectDetectionActive = focus.subjectDetectionActive
        trackingAFActive = focus.trackingAFActive
        selectedBoxIndex =
            focus.selectedBoxIndex.map { Int32(clamping: $0) } ?? Self.unavailableSelectedBoxIndex
        boxes = focus.boxes.flatMap { box in
            [
                Int32(clamping: box.centerX),
                Int32(clamping: box.centerY),
                Int32(clamping: box.width),
                Int32(clamping: box.height),
            ]
        }
    }
}

/// Platform-neutral camera-level data for the Android live-frame callback.
///
/// Roll and pitch are normalized around level by the shared core. That keeps
/// Nikon's fixed-point parsing and angle-wrap policy out of the Kotlin shell.
struct LiveViewLevelWire: Equatable, Sendable {
    let hasLevel: Bool
    let rollDegrees: Double
    let pitchDegrees: Double
    let yawDegrees: Double

    init(level: PTPLevelAngles?) {
        guard let level else {
            hasLevel = false
            rollDegrees = 0
            pitchDegrees = 0
            yawDegrees = 0
            return
        }

        let roll = level.signedRoll
        let pitch = level.signedPitch
        let yaw = PTPLevelAngles.signedDegrees(level.yaw)
        guard roll.isFinite, pitch.isFinite, yaw.isFinite else {
            hasLevel = false
            rollDegrees = 0
            pitchDegrees = 0
            yawDegrees = 0
            return
        }

        hasLevel = true
        rollDegrees = roll
        pitchDegrees = pitch
        yawDegrees = yaw
    }
}
