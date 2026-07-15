import Foundation
import OpenZCineCore

/// Android-facing wire for camera-screen OCR credentials.
///
/// The portable core remains the sole authority for recognizing and correcting
/// Nikon Connection-wizard text. The facade only turns a fully validated result
/// into a compact two-field JNI payload; it neither logs nor persists OCR text.
public enum AndroidCameraWiFiScreenParserWire {
    /// ASCII unit separator between the canonical SSID and WPA key.
    ///
    /// Both values are constrained by ``CameraWiFiScreenParser`` and cannot
    /// contain this control character, making the payload unambiguous without
    /// giving the Kotlin shell any camera-credential parsing policy.
    public static let fieldSeparator = "\u{001F}"

    /// Parses one ML Kit transcript through the shared Swift credential policy.
    ///
    /// - Parameter transcript: Ephemeral recognized text from the Android rear
    ///   camera. Callers must not persist or log it.
    /// - Returns: `SSID<unit-separator>key` only when both fields validate.
    public static func parse(_ transcript: String) -> String? {
        CameraWiFiScreenParser.parse(transcript).map(encode)
    }

    /// Encodes already-validated shared-core credentials for the JNI boundary.
    public static func encode(_ credentials: CameraWiFiScreenParser.Credentials) -> String {
        credentials.ssid + fieldSeparator + credentials.key
    }
}
