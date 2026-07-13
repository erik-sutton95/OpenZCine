import Foundation

/// Extracts Nikon camera access-point credentials from OCR text captured off the camera's
/// on-screen **Connection wizard** (the screen showing `SSID:` and `Key:`).
///
/// The wizard's format is tightly constrained — SSID is `NIKON_ZR_` + a 5-digit serial, and the
/// key is 8 lowercase-hex characters — which is what makes screen OCR reliable: any character the
/// recognizer confuses (`O`/`0`, `l`/`1`, `S`/`5`) can be corrected because only one interpretation
/// is legal in each field. Returns credentials only when BOTH fields validate; otherwise `nil` and
/// the caller falls back to manual entry.
public enum CameraWiFiScreenParser {
    public struct Credentials: Equatable, Sendable {
        public let ssid: String
        public let key: String

        public init(ssid: String, key: String) {
            self.ssid = ssid
            self.key = key
        }
    }

    /// Parses recognized text lines (e.g. one per `RecognizedItem.text` transcript).
    public static func parse(lines: [String]) -> Credentials? {
        // Split on whitespace and the label separators the wizard uses ("SSID:", "Key:"), so a
        // recognizer that merges label and value ("Key:a1b2c3d4") still yields clean tokens.
        let separators: Set<Character> = [" ", "\t", "\n", ":", "|", "\u{00A0}"]
        let tokens =
            lines
            .flatMap { $0.split(whereSeparator: { separators.contains($0) }) }
            .map(String.init)
        guard let ssid = tokens.lazy.compactMap(correctedSSID).first else { return nil }
        guard let key = tokens.lazy.compactMap(correctedKey).first else { return nil }
        return Credentials(ssid: ssid, key: key)
    }

    public static func parse(_ transcript: String) -> Credentials? {
        parse(lines: transcript.components(separatedBy: .newlines))
    }

    /// A token that reads as `NIKON_<model>_<5 serial>` → the canonical camera AP SSID.
    /// Anchors on the known prefix so only the 5 serial digits need OCR correction.
    static func correctedSSID(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: Self.punctuation)
        let parts = token.split(separator: "_").map(String.init)
        guard parts.count >= 3 else { return nil }
        guard isNikonBrand(parts[0]) else { return nil }
        let model = correctModel(parts[1])
        guard !model.isEmpty, model.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        let serial = correctDigits(parts[parts.count - 1])
        guard serial.count == 5, serial.allSatisfy(\.isNumber) else { return nil }
        return "NIKON_\(model)_\(serial)"
    }

    /// An 8-character token that reads as lowercase hex → the WPA key.
    // ponytail: assumes the ZR's 8-hex-char key; any other key format fails validation and
    // the operator types it in the field instead. Widen if a longer/ASCII key ever appears.
    static func correctedKey(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: Self.punctuation)
        guard token.count == 8 else { return nil }
        let corrected = String(token.lowercased().map(hexCorrect))
        guard corrected.allSatisfy(isLowerHex) else { return nil }
        return corrected
    }

    private static let punctuation = CharacterSet(charactersIn: "\"'|[](){}:;,. ")

    private static func isNikonBrand(_ s: String) -> Bool {
        let mapped = String(
            s.uppercased().map { c -> Character in
                switch c {
                case "0": return "O"
                case "1", "L": return "I"
                case "5": return "S"
                case "8": return "B"
                default: return c
                }
            })
        return mapped == "NIKON"
    }

    private static func correctModel(_ s: String) -> String {
        String(
            s.uppercased().map { c -> Character in
                switch c {
                case "0": return "O"
                case "1": return "I"
                case "5": return "S"
                case "8": return "B"
                case "2": return "Z"  // ZR misread as 2R
                default: return c
                }
            })
    }

    private static func correctDigits(_ s: String) -> String {
        String(
            s.map { c -> Character in
                switch c {
                case "O", "o", "Q", "D": return "0"
                case "I", "l", "i": return "1"
                case "S", "s": return "5"
                case "B": return "8"
                case "Z", "z": return "2"
                case "G": return "6"
                default: return c
                }
            })
    }

    /// Maps clearly-non-hex letters to their hex look-alike; leaves valid hex (a–f) untouched.
    private static func hexCorrect(_ c: Character) -> Character {
        switch c {
        case "o": return "0"
        case "i", "l": return "1"
        case "s": return "5"
        case "z": return "2"
        case "g", "q": return "9"
        default: return c
        }
    }

    private static func isLowerHex(_ c: Character) -> Bool {
        c.isNumber || ("a"..."f").contains(c)
    }
}
