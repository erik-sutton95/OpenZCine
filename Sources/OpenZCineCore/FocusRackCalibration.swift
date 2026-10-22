import Foundation

/// Configuration identity for reusable timing evidence, independent of session-local marks.
/// Camera identity stays in local persistence and is excluded from diagnostic exports.
public struct FocusRackCalibrationKey: Codable, Equatable, Sendable {
    public let cameraID: String
    public let transport: String
    public let lens: String
    public let focalLength: String
    public let focusMode: String
    public let focusArea: String
    public let focusSubject: String

    /// Identifies the reported body, control link and complete focus/lens configuration.
    public init(
        cameraID: String, transport: String, lens: String, focalLength: String,
        focusMode: String, focusArea: String, focusSubject: String
    ) {
        self.cameraID = cameraID
        self.transport = transport
        self.lens = lens
        self.focalLength = focalLength
        self.focusMode = focusMode
        self.focusArea = focusArea
        self.focusSubject = focusSubject
    }

    init?(cameraID: String?, transport: String?, context: FocusRackContext) {
        guard let cameraID, !cameraID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            let transport, ["usb", "ptpIP"].contains(transport), let lens = context.lens,
            let focalLength = context.focalLength, let focusMode = context.focusMode,
            let focusArea = context.focusArea, let focusSubject = context.focusSubject
        else { return nil }
        self.init(
            cameraID: cameraID, transport: transport, lens: lens, focalLength: focalLength,
            focusMode: focusMode, focusArea: focusArea, focusSubject: focusSubject)
    }

    func matches(_ context: FocusRackContext) -> Bool {
        context.movieMode && context.lens == lens && context.focalLength == focalLength
            && context.focusMode == focusMode && context.focusArea == focusArea
            && context.focusSubject == focusSubject
    }
}

/// Historical native command maxima only; never restores position, marks, safety or authority.
public struct FocusRackCalibration: Codable, Equatable, Sendable {
    public let version: Int
    public let pulsesPerStep: Int
    public let profile: String
    public let key: FocusRackCalibrationKey
    /// Actual pulse count to longest acknowledged native command duration in seconds.
    public let commandDurations: [Int: Double]

    /// Creates evidence for the current measured-size planning policy and fixed pulse scale.
    public init(key: FocusRackCalibrationKey, commandDurations: [Int: Double]) {
        version = 1
        pulsesPerStep = 16
        profile = FocusRackProfile.calibratedFineExperiment.rawValue
        self.key = key
        self.commandDurations = commandDurations
    }
}

/// Validates the same bounded local checkpoint on both native platforms.
public enum FocusRackCalibrationCodec {
    /// Encodes validated timing evidence for platform-owned storage.
    public static func encode(_ calibration: FocusRackCalibration) throws -> Data {
        try validate(calibration)
        return try JSONEncoder().encode(calibration)
    }

    /// Rejects incompatible schemas, pulse scales and malformed measurements before use.
    public static func decode(_ data: Data) throws -> FocusRackCalibration {
        guard data.count <= 16_384 else { throw FocusRackError.invalidConfiguration }
        let calibration = try JSONDecoder().decode(FocusRackCalibration.self, from: data)
        try validate(calibration)
        return calibration
    }

    static func validate(_ calibration: FocusRackCalibration) throws {
        let key = calibration.key
        let strings = [
            key.cameraID, key.transport, key.lens, key.focalLength,
            key.focusMode, key.focusArea, key.focusSubject,
        ]
        guard calibration.version == 1, calibration.pulsesPerStep == 16,
            calibration.profile == FocusRackProfile.calibratedFineExperiment.rawValue,
            strings.allSatisfy({
                !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && $0.utf8.count <= 256
            }),
            ["usb", "ptpIP"].contains(key.transport), key.focusMode == "AF-S",
            !calibration.commandDurations.isEmpty,
            calibration.commandDurations.allSatisfy({ pulses, seconds in
                (16...192).contains(pulses) && pulses.isMultiple(of: 16)
                    && seconds.isFinite && seconds > 0
            })
        else { throw FocusRackError.invalidConfiguration }
    }
}
