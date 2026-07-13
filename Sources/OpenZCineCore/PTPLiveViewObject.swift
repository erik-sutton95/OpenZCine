import Foundation

/// A decoded Nikon `GetLiveViewImageEx` object.
public struct PTPLiveViewFrame: Equatable, Sendable {
    public init(
        jpeg: Data, timecode: Timecode, focus: PTPLiveViewFocusInfo? = nil,
        isRecording: Bool = false, level: PTPLevelAngles? = nil,
        sound: PTPLiveViewSoundIndicator? = nil
    ) {
        self.jpeg = jpeg
        self.timecode = timecode
        self.focus = focus
        self.isRecording = isRecording
        self.level = level
        self.sound = sound
    }

    public let jpeg: Data
    public let timecode: Timecode  // from the frame header
    /// AF / subject-detection boxes parsed from the header, for drawing the camera's focus and
    /// face/eye tracking frames over the feed. `nil` when the header is too short to parse.
    public let focus: PTPLiveViewFocusInfo?
    /// Whether the body is recording — header byte 828 (0 = live view, 1 = recording). The camera is
    /// the source of truth, so this catches a recording started on the body itself.
    public let isRecording: Bool
    /// The camera's virtual-horizon angles (degrees), or nil when the body reports them unreliable.
    public let level: PTPLevelAngles?
    /// The camera's stereo sound-level indicator, or nil when the header is too short to carry it.
    public let sound: PTPLiveViewSoundIndicator?
}

/// The camera's audio-level readout from the LiveViewObject header — the same segmented meter the
/// body draws on its own display. Four one-byte fields at header offsets 824–827: peak-hold then
/// current value, left and right, each `0…14` (15 display segments, 0 = silence).
public struct PTPLiveViewSoundIndicator: Equatable, Sendable {
    /// Highest indicator segment (inclusive) the camera reports.
    public static let maxSegment = 14

    public init(peakLeft: Int, peakRight: Int, currentLeft: Int, currentRight: Int) {
        self.peakLeft = peakLeft
        self.peakRight = peakRight
        self.currentLeft = currentLeft
        self.currentRight = currentRight
    }

    /// Peak-hold segment, left channel (`0…14`).
    public let peakLeft: Int
    /// Peak-hold segment, right channel (`0…14`).
    public let peakRight: Int
    /// Current-level segment, left channel (`0…14`).
    public let currentLeft: Int
    /// Current-level segment, right channel (`0…14`).
    public let currentRight: Int
}

/// The camera's virtual-horizon reading from the LiveViewObject header — `roll` is the side tilt
/// (0–360°, 0 = level, counter-clockwise positive per the spec), `pitch` the fore/aft lean, `yaw`
/// the grip-axis lean. Each is a signed 16.16 fixed-point angle decoded as `value / 65536`.
public struct PTPLevelAngles: Equatable, Sendable {
    public init(roll: Double, pitch: Double, yaw: Double) {
        self.roll = roll
        self.pitch = pitch
        self.yaw = yaw
    }
    public let roll: Double
    public let pitch: Double
    public let yaw: Double

    /// Wraps a 0–360° angle to a signed tilt about level (−180…180), e.g. 359.5 → −0.5, 270 → −90.
    public static func signedDegrees(_ degrees: Double) -> Double {
        let wrapped = degrees.truncatingRemainder(dividingBy: 360)
        let positive = wrapped < 0 ? wrapped + 360 : wrapped
        return positive > 180 ? positive - 360 : positive
    }

    /// Roll as a signed tilt about level (−180…180) — what the horizon overlay rotates by.
    public var signedRoll: Double { Self.signedDegrees(roll) }
    /// Pitch as a signed tilt about level (−180…180).
    public var signedPitch: Double { Self.signedDegrees(pitch) }
}

/// One AF / subject-detection box from the LiveViewObject header, expressed in the header's
/// "whole size" coordinate space (so it maps onto the feed regardless of zoom/crop).
public struct PTPLiveViewAFBox: Equatable, Sendable {
    public init(centerX: Int, centerY: Int, width: Int, height: Int) {
        self.centerX = centerX
        self.centerY = centerY
        self.width = width
        self.height = height
    }
    public let centerX: Int
    public let centerY: Int
    public let width: Int
    public let height: Int
}

/// Focus / subject-detection state parsed from the LiveViewObject header — what the camera draws as
/// its AF point and face/eye tracking frames.
///
/// `[ZR · verify-on-HW]` — the header is big-endian and the field offsets were confirmed against
/// raw ZR LiveViewObject dumps: whole-size 6048×3400 at 16/18, then the box array at offset 48.
/// Box 0 is the AF area; with subject detection on, box 1 is the face and box 2 the eye (a small
/// square). `areaCount` (44) gives the count and `selectedIndex` (45) the selected box.
public struct PTPLiveViewFocusInfo: Equatable, Sendable {
    /// Whether the camera reports the active AF point as in focus.
    public enum FocusResult: Equatable, Sendable {
        case unknown
        case notFocused
        case focused
    }

    public init(
        coordinateWidth: Int,
        coordinateHeight: Int,
        focusResult: FocusResult,
        subjectDetectionActive: Bool,
        trackingAFActive: Bool = false,
        selectedBoxIndex: Int?,
        boxes: [PTPLiveViewAFBox]
    ) {
        self.coordinateWidth = coordinateWidth
        self.coordinateHeight = coordinateHeight
        self.focusResult = focusResult
        self.subjectDetectionActive = subjectDetectionActive
        self.trackingAFActive = trackingAFActive
        self.selectedBoxIndex = selectedBoxIndex
        self.boxes = boxes
    }

    /// The coordinate space `boxes` are expressed in (the header's "whole size").
    public let coordinateWidth: Int
    public let coordinateHeight: Int
    /// Whether the selected AF point is focused (drives box colour: green when focused).
    public let focusResult: FocusResult
    /// True when subject/face detection is driving AF (the boxes are detected subjects, not a
    /// single AF point).
    public let subjectDetectionActive: Bool
    /// True when the body reports active target tracking —
    /// distinct from subject-detection boxes alone.
    public let trackingAFActive: Bool
    /// Index into `boxes` of the selected subject, when subject detection is active.
    public let selectedBoxIndex: Int?
    /// The active AF point / detected-subject boxes.
    public let boxes: [PTPLiveViewAFBox]

    /// True when the body reports an active subject-tracking lock — header tracking status and/or
    /// face/eye box selection while subject detection is on.
    public var isSubjectTrackingLatched: Bool {
        if trackingAFActive { return true }
        guard subjectDetectionActive else { return false }
        if boxes.count > 1 { return true }
        if let selectedBoxIndex, selectedBoxIndex > 0 { return true }
        return false
    }
}

/// Decides which property writes accompany a focus reset that must release subject tracking.
/// Uses live-view header state — not only the FOCUS picker — because polled area/subject values can
/// lag while TargetTracking is already engaged on hardware.
public enum FocusResetReleasePolicy: Equatable, Sendable {
    /// Demote Subject → Single when the picker or live-view header shows TargetTracking is engaged.
    public static func shouldDemoteSubjectArea(
        focusArea: String,
        liveViewFocus: PTPLiveViewFocusInfo?
    ) -> Bool {
        if focusArea == "Subject" { return true }
        guard let focus = liveViewFocus else { return false }
        if focus.trackingAFActive { return true }
        return focus.isSubjectTrackingLatched
    }

    /// Suspend subject detection when the picker or live-view header shows it is active.
    public static func shouldSuspendSubjectDetection(
        focusSubject: String,
        liveViewFocus: PTPLiveViewFocusInfo?
    ) -> Bool {
        if focusSubject != "Off" { return true }
        return liveViewFocus?.subjectDetectionActive == true
    }

    /// True when the live-view header still indicates an active tracking session.
    public static func isTrackingIndicatedOnHeader(_ focus: PTPLiveViewFocusInfo?) -> Bool {
        guard let focus else { return false }
        if focus.trackingAFActive { return true }
        return focus.isSubjectTrackingLatched
    }
}

/// Decides whether saved AF-area and subject-detection values should be written back after a focus
/// reset completes. Restoration is mode settings only — no `StartTracking`.
public enum FocusResetRestorePolicy: Equatable, Sendable {
    /// Interim AF-area label written while releasing subject tracking.
    public static let interimFocusArea = "Single"

    /// Interim subject-detection label written while releasing subject tracking.
    public static let interimFocusSubject = "Off"

    /// Restore AF-area when demotion succeeded and the user has not changed the picker during reset.
    public static func shouldRestoreFocusArea(
        demoted: Bool,
        currentFocusArea: String,
        savedFocusArea: String,
        focusMode: String?
    ) -> Bool {
        guard demoted else { return false }
        guard savedFocusArea != interimFocusArea else { return false }
        guard currentFocusArea == interimFocusArea else { return false }
        guard !PTPCameraPropertyDecoders.isMovieFocusManual(focusMode) else { return false }
        return true
    }

    /// Restore subject detection when suspension succeeded and the user has not changed the picker.
    public static func shouldRestoreSubjectDetection(
        suspended: Bool,
        currentFocusSubject: String,
        savedFocusSubject: String,
        focusMode: String?
    ) -> Bool {
        guard suspended else { return false }
        guard savedFocusSubject != interimFocusSubject else { return false }
        guard currentFocusSubject == interimFocusSubject else { return false }
        guard !PTPCameraPropertyDecoders.isMovieFocusManual(focusMode) else { return false }
        return true
    }
}

/// When a focus reset must release subject tracking, wait until the live-view header shows the lock
/// has cleared (or a frame budget expires) before sending `ChangeAfArea`. The iOS shell demotes
/// Subject AF-area mode to Single and suspends subject detection only for the release sequence,
/// then restores the saved picker values after recenter.
public enum FocusResetSettlePolicy: Equatable, Sendable {
    public static let minimumFramesAfterRelease = 3
    public static let maximumWaitFrames = 15

    public static func shouldRecenter(
        framesSinceRelease: Int,
        isTrackingLatched: Bool,
        trackingAFActive: Bool = false
    ) -> Bool {
        guard framesSinceRelease >= minimumFramesAfterRelease else { return false }
        if !isTrackingLatched, !trackingAFActive { return true }
        return framesSinceRelease >= maximumWaitFrames
    }
}

extension PTPLiveViewFocusInfo {
    /// The index of the first box covering the point `(pointX, pointY)` in a feed of
    /// `feedWidth`×`feedHeight`, or `nil` if none do. Boxes are scaled from the camera coordinate
    /// space to the feed; `padding` (in feed points) enlarges each box's hit area for touch.
    public func boxIndex(
        containingX pointX: Double,
        y pointY: Double,
        feedWidth: Double,
        feedHeight: Double,
        padding: Double = 0
    ) -> Int? {
        guard coordinateWidth > 0, coordinateHeight > 0, feedWidth > 0, feedHeight > 0 else {
            return nil
        }
        let scaleX = feedWidth / Double(coordinateWidth)
        let scaleY = feedHeight / Double(coordinateHeight)
        for (index, box) in boxes.enumerated() {
            let halfWidth = Double(box.width) * scaleX / 2 + padding
            let halfHeight = Double(box.height) * scaleY / 2 + padding
            let centerX = Double(box.centerX) * scaleX
            let centerY = Double(box.centerY) * scaleY
            if abs(pointX - centerX) <= halfWidth, abs(pointY - centerY) <= halfHeight {
                return index
            }
        }
        return nil
    }
}

/// Parser for Nikon LiveViewObject payloads returned by `GetLiveViewImageEx`.
public enum PTPLiveViewObject {
    /// Fixed display-info header before the standalone JPEG.
    public static let headerLength = 1_024

    /// Extracts the JPEG image from a LiveViewObject.
    public static func jpeg(from liveViewObject: Data) throws -> Data {
        guard liveViewObject.count >= headerLength + 3 else {
            throw PTPLiveViewObjectError.tooShort(actualLength: liveViewObject.count)
        }

        let headerBytes = Array(liveViewObject.prefix(16))
        let declaredLength = Int(ByteCoding.readUInt32LE(headerBytes, at: 12))
        let imageEnd =
            declaredLength > 0 && headerLength + declaredLength <= liveViewObject.count
            ? headerLength + declaredLength
            : liveViewObject.count
        let jpeg = liveViewObject.subdata(in: headerLength..<imageEnd)
        guard jpeg.count >= 3,
            jpeg[0] == 0xFF,
            jpeg[1] == 0xD8,
            jpeg[2] == 0xFF
        else {
            throw PTPLiveViewObjectError.missingJPEGSoi(offset: headerLength)
        }
        return jpeg
    }

    /// Copies just the display-info header — never materialize the whole multi-MB LiveViewObject
    /// into an array per frame. `frame(from:)` slices this **once** and derives every header field
    /// from it, so the hot path pays a single ≤1 KB copy per frame.
    private static func headerBytes(from liveViewObject: Data) -> [UInt8] {
        Array(liveViewObject.prefix(headerLength))
    }

    /// Decodes movie timecode from the LiveViewObject header.
    public static func timecode(from liveViewObject: Data) -> Timecode {
        timecode(fromHeader: headerBytes(from: liveViewObject))
    }

    private static func timecode(fromHeader bytes: [UInt8]) -> Timecode {
        guard bytes.count >= 836 else {
            return Timecode(on: false, hour: 0, minute: 0, second: 0, frame: 0)
        }
        return Timecode(
            on: bytes[831] == 1,
            hour: Int(bytes[832]),
            minute: Int(bytes[833]),
            second: Int(bytes[834]),
            frame: Int(bytes[835])
        )
    }

    /// Byte offsets in the **big-endian** display-info header, confirmed against raw ZR dumps.
    private enum HeaderOffset {
        static let wholeWidth = 16  // BE uint16 — AF coordinate-space width  (e.g. 6048)
        static let wholeHeight = 18  // BE uint16 — AF coordinate-space height (e.g. 3400)
        static let focusResult = 42  // uint8 — 2 = focused, 1 = not focused
        static let subjectActive = 43  // uint8 — 1 = subject/face detection driving AF
        static let areaCount = 44  // uint8 — number of AF / subject boxes that follow
        static let trackingAFStatus = 46  // uint8 — 1 = target tracking active
        static let selectedIndex = 45  // uint8 — index of the selected box
        static let boxArray = 48  // [w, h, cx, cy] BE uint16 per box, 8 bytes each
        static let soundPeakLeft = 824  // uint8 0–14 — sound indicator peak value, L
        static let soundPeakRight = 825  // uint8 0–14 — sound indicator peak value, R
        static let soundCurrentLeft = 826  // uint8 0–14 — sound indicator current value, L
        static let soundCurrentRight = 827  // uint8 0–14 — sound indicator current value, R
        static let recordState = 828  // uint8 — 0 = live view, 1 = recording
        static let angleRolling = 840  // BE 16.16 fixed-point INT32 — roll (degrees = value/65536)
        static let anglePitching = 844  // BE 16.16 — pitch
        static let angleYawing = 848  // BE 16.16 — yaw
    }
    /// Maximum AF-frame slots in the header.
    private static let maxBoxes = 96

    /// Movie-recording state from the header (byte 828): `true` while the body is recording. The
    /// camera is the source of truth, so this reflects a recording started on the body itself.
    public static func recordingState(from liveViewObject: Data) -> Bool {
        recordingState(fromHeader: headerBytes(from: liveViewObject))
    }

    private static func recordingState(fromHeader bytes: [UInt8]) -> Bool {
        guard bytes.count > HeaderOffset.recordState else { return false }
        return bytes[HeaderOffset.recordState] == 1
    }

    /// The camera's stereo sound indicator from the header (offsets 824–827, one byte each, `0…14`
    /// segments). Values above the ceiling clamp to 14 so a misreported byte can't inflate the
    /// meter scale.
    public static func soundIndicator(from liveViewObject: Data) -> PTPLiveViewSoundIndicator? {
        soundIndicator(fromHeader: headerBytes(from: liveViewObject))
    }

    private static func soundIndicator(fromHeader bytes: [UInt8]) -> PTPLiveViewSoundIndicator? {
        guard bytes.count > HeaderOffset.soundCurrentRight else { return nil }
        func segment(at offset: Int) -> Int {
            min(Int(bytes[offset]), PTPLiveViewSoundIndicator.maxSegment)
        }
        return PTPLiveViewSoundIndicator(
            peakLeft: segment(at: HeaderOffset.soundPeakLeft),
            peakRight: segment(at: HeaderOffset.soundPeakRight),
            currentLeft: segment(at: HeaderOffset.soundCurrentLeft),
            currentRight: segment(at: HeaderOffset.soundCurrentRight))
    }

    /// The camera's virtual horizon from the header — Rolling/Pitching/Yawing at 840/844/848, each a
    /// big-endian signed 16.16 fixed-point angle (`degrees = value / 65536`). A raw `0xFFFFFFFF` means
    /// the body couldn't get a reliable reading; returns nil when roll (the horizon tilt) is missing.
    public static func levelAngles(from liveViewObject: Data) -> PTPLevelAngles? {
        levelAngles(fromHeader: headerBytes(from: liveViewObject))
    }

    private static func levelAngles(fromHeader bytes: [UInt8]) -> PTPLevelAngles? {
        guard bytes.count >= HeaderOffset.angleYawing + 4 else { return nil }
        func angle(at offset: Int) -> Double? {
            let raw = ByteCoding.readUInt32BE(bytes, at: offset)
            guard raw != 0xFFFF_FFFF else { return nil }
            return Double(Int32(bitPattern: raw)) / 65536.0
        }
        guard let roll = angle(at: HeaderOffset.angleRolling) else { return nil }
        return PTPLevelAngles(
            roll: roll,
            pitch: angle(at: HeaderOffset.anglePitching) ?? 0,
            yaw: angle(at: HeaderOffset.angleYawing) ?? 0)
    }

    /// Parses the AF / subject-detection boxes from the LiveViewObject header.
    ///
    /// The header is **big-endian** (the JPEG byte length is a BE uint32 at offset 12; the size/AF
    /// fields are BE uint16) — distinct from the little-endian PTP containers; reading it LE puts
    /// the boxes off-screen. Box 0 is the AF area; with subject detection on, further boxes are the
    /// detected face then eye (a small square), and `areaCount` (44) / `selectedIndex` (45) drive
    /// the count and selection. Offsets confirmed against raw ZR dumps — see `HeaderOffset`.
    public static func focusInfo(from liveViewObject: Data) -> PTPLiveViewFocusInfo? {
        focusInfo(fromHeader: headerBytes(from: liveViewObject))
    }

    private static func focusInfo(fromHeader bytes: [UInt8]) -> PTPLiveViewFocusInfo? {
        guard bytes.count >= HeaderOffset.boxArray + 8 else { return nil }

        let coordinateWidth = Int(ByteCoding.readUInt16BE(bytes, at: HeaderOffset.wholeWidth))
        let coordinateHeight = Int(ByteCoding.readUInt16BE(bytes, at: HeaderOffset.wholeHeight))
        guard coordinateWidth > 0, coordinateHeight > 0 else { return nil }

        let focusResult: PTPLiveViewFocusInfo.FocusResult =
            switch bytes[HeaderOffset.focusResult] {
            case 2: .focused
            case 1: .notFocused
            default: .unknown
            }
        let subjectActive = bytes[HeaderOffset.subjectActive] == 1
        let areaCount = Int(bytes[HeaderOffset.areaCount])
        let selectedIndex = Int(bytes[HeaderOffset.selectedIndex])
        let trackingAFActive =
            bytes.count > HeaderOffset.trackingAFStatus
            && bytes[HeaderOffset.trackingAFStatus] != 0

        // Read `areaCount` boxes (at least the one AF point), each `[w, h, cx, cy]` BE uint16, and
        // drop empty (zero-size) slots.
        let slots = min(max(areaCount, 1), maxBoxes)
        var boxes: [PTPLiveViewAFBox] = []
        for index in 0..<slots {
            let base = HeaderOffset.boxArray + index * 8
            guard base + 8 <= bytes.count else { break }
            let width = Int(ByteCoding.readUInt16BE(bytes, at: base))
            let height = Int(ByteCoding.readUInt16BE(bytes, at: base + 2))
            let centerX = Int(ByteCoding.readUInt16BE(bytes, at: base + 4))
            let centerY = Int(ByteCoding.readUInt16BE(bytes, at: base + 6))
            if width > 0, height > 0 {
                boxes.append(
                    PTPLiveViewAFBox(
                        centerX: centerX, centerY: centerY, width: width, height: height))
            }
        }

        let selected =
            subjectActive && selectedIndex < boxes.count && !boxes.isEmpty ? selectedIndex : nil
        return PTPLiveViewFocusInfo(
            coordinateWidth: coordinateWidth,
            coordinateHeight: coordinateHeight,
            focusResult: focusResult,
            subjectDetectionActive: subjectActive,
            trackingAFActive: trackingAFActive,
            selectedBoxIndex: selected,
            boxes: boxes
        )
    }

    /// Extracts the JPEG, header-derived timecode, AF/focus boxes, record state, and virtual-horizon
    /// angles — everything the camera reports per frame in the LiveViewObject header.
    public static func frame(from liveViewObject: Data) throws -> PTPLiveViewFrame {
        // One header slice shared by every field parser — this runs ~30×/s on the frame path.
        let header = headerBytes(from: liveViewObject)
        return try PTPLiveViewFrame(
            jpeg: jpeg(from: liveViewObject),
            timecode: timecode(fromHeader: header),
            focus: focusInfo(fromHeader: header),
            isRecording: recordingState(fromHeader: header),
            level: levelAngles(fromHeader: header),
            sound: soundIndicator(fromHeader: header)
        )
    }
}

/// Errors that can occur while parsing a LiveViewObject.
public enum PTPLiveViewObjectError: LocalizedError, Equatable, Sendable {
    /// The LiveViewObject data was too short.
    case tooShort(actualLength: Int)
    /// The JPEG SOI marker was missing at the expected offset.
    case missingJPEGSoi(offset: Int)

    public var errorDescription: String? {
        switch self {
        case .tooShort(let actualLength):
            "Live-view frame was too short to parse (\(actualLength) bytes)."
        case .missingJPEGSoi(let offset):
            "Live-view frame was missing the JPEG start marker at offset \(offset)."
        }
    }
}
