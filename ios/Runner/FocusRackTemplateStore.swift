import Foundation
import OpenZCineCore

/// Native persistence for timing templates. Lens marks and thumbnails never enter preferences.
@MainActor enum FocusRackTemplateStore {
    private static let key = "focusRack.timingTemplates.v1"

    static func load(from defaults: UserDefaults = .standard) throws -> [FocusRackTemplate] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return try FocusRackTemplateCodec.decode(data)
    }

    static func save(_ templates: [FocusRackTemplate], to defaults: UserDefaults = .standard) throws
    {
        defaults.set(try FocusRackTemplateCodec.encode(templates), forKey: key)
    }
}

/// Local timing evidence, stored separately from timing templates and session-local marks.
@MainActor enum FocusRackCalibrationStore {
    static var fileURL: URL {
        URL.documentsDirectory.appendingPathComponent("focus-rack-calibration.json")
    }

    static func load(from url: URL = fileURL) throws -> FocusRackCalibration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try FocusRackCalibrationCodec.decode(Data(contentsOf: url))
    }

    static func save(_ calibration: FocusRackCalibration, to url: URL = fileURL) throws {
        try FocusRackCalibrationCodec.encode(calibration).write(to: url, options: .atomic)
    }
}
