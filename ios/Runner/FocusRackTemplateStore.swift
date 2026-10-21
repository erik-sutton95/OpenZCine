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
