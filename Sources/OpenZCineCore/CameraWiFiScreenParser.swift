import Foundation

/// Extracts Nikon camera access-point credentials from OCR text captured off the camera's
/// on-screen **Connection wizard** (the screen showing `SSID:` and `Key:`).
///
/// SSID layouts vary by Z body, so the parser validates the shared Nikon Z access-point shape and
/// preserves unfamiliar model/serial segments instead of rebuilding them. The generated key remains
/// an 8-character lowercase-hex value, which permits safe correction of common OCR confusions. The
/// manual-entry path accepts the wider WPA passphrase contract when OCR cannot validate both fields.
public enum CameraWiFiScreenParser {
    public struct Credentials: Equatable, Sendable {
        public let ssid: String
        public let key: String

        public init(ssid: String, key: String) {
            self.ssid = ssid
            self.key = key
        }
    }

    /// Actionable outcome from one OCR frame.
    public enum Result: Equatable, Sendable {
        case credentials(Credentials)
        case needsKey
        case unsupportedSSID
        case noCredentials
    }

    /// Parses recognized text lines (e.g. one per `RecognizedItem.text` transcript).
    public static func parse(lines: [String]) -> Credentials? {
        guard case .credentials(let credentials) = result(lines: lines) else { return nil }
        return credentials
    }

    /// Classifies recognized text so the scanner can distinguish incomplete and unsupported frames.
    public static func result(lines: [String]) -> Result {
        // Split on whitespace and the label separators the wizard uses ("SSID:", "Key:"), so a
        // recognizer that merges any localized label and value still yields clean tokens.
        let separators: Set<Character> = [" ", "\t", "\n", ":", "|", "\u{00A0}"]
        let tokens =
            lines
            .flatMap { $0.split(whereSeparator: { separators.contains($0) }) }
            .map(String.init)
        guard let ssid = tokens.lazy.compactMap(correctedSSID).first else {
            return tokens.contains(where: isUnsupportedNikonSSIDCandidate)
                ? .unsupportedSSID : .noCredentials
        }
        guard let key = tokens.lazy.compactMap(correctedKey).first else { return .needsKey }
        return .credentials(Credentials(ssid: ssid, key: key))
    }

    public static func parse(_ transcript: String) -> Credentials? {
        parse(lines: transcript.components(separatedBy: .newlines))
    }

    /// Validates credentials typed from the camera screen when OCR cannot read its format.
    public static func manualCredentials(ssid rawSSID: String, key rawKey: String) -> Credentials? {
        guard !rawSSID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            rawSSID.utf8.count <= 32
        else { return nil }
        guard (8...63).contains(rawKey.utf8.count) else { return nil }
        guard rawKey.unicodeScalars.allSatisfy({ (0x20...0x7E).contains($0.value) }) else {
            return nil
        }
        return Credentials(ssid: rawSSID, key: rawKey)
    }

    /// A token with a conservative Nikon Z access-point shape, preserving its model layout.
    static func correctedSSID(_ raw: String) -> String? {
        let token = raw.trimmingCharacters(in: Self.punctuation)
        if let correctedZR = correctedLegacyZRSSID(token) { return correctedZR }
        return CameraWiFiSSID.normalizedScannedNikonZAccessPoint(token)
    }

    /// Retains the ZR-specific OCR recovery shipped before other Z-body SSID formats were observed.
    private static func correctedLegacyZRSSID(_ token: String) -> String? {
        let parts = token.split(separator: "_").map(String.init)
        guard parts.count >= 3 else { return nil }
        guard isNikonBrand(parts[0]) else { return nil }
        let model = correctModel(parts[1])
        guard model == "ZR" else { return nil }
        let serial = correctDigits(parts[parts.count - 1])
        guard serial.count == 5, serial.allSatisfy(\.isNumber) else { return nil }
        return "NIKON_\(model)_\(serial)"
    }

    private static func isUnsupportedNikonSSIDCandidate(_ raw: String) -> Bool {
        let token = raw.trimmingCharacters(in: Self.punctuation).uppercased()
        guard token.count >= 8 else { return false }
        let prefix = String(token.prefix(5))
        guard isNikonBrand(prefix) else { return false }
        return token.contains("Z")
            && token.contains(where: { $0.isNumber || "OILSBZG".contains($0) })
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
