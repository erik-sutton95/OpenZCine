import OpenCineMedia

/// The calibrated source endpoint arrives from Nikon; Media owns the display transform.
typealias MonitorDisplayToneMap = MonitorSceneToneMap

extension MonitorSceneToneMap {
    init(mapping: ExposureSignalMapping) {
        self.init(sceneWhite: mapping.curve.decode(encodedValue: mapping.clipNative / 255))
    }
}
