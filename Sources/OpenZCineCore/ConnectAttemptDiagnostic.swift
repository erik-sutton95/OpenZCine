import Foundation

/// Privacy-safe connect-attempt facts for the on-device trace included in a Share
/// Diagnostics export. Nothing here is sent automatically; anonymous bug reports
/// never include this log.
///
/// Lines contain only closed keys and values (model token, generation, ops known
/// or not, pairing decision, join skip reason, PTP hex codes). Hosts, SSIDs,
/// serials, PINs, passwords, and free-form errors are dropped.
public enum ConnectAttemptDiagnostic {
    public static let maximumLineCount = 200

    /// One sanitized connect-trace line, or nil when nothing allowlisted remains.
    public static func line(
        event: String,
        cameraName: String? = nil,
        facts: [String: String] = [:]
    ) -> String? {
        var fields: [(String, String)] = []
        if let event = sanitizedToken(event) {
            fields.append(("event", event))
        }
        if let cameraName,
            let token = ZCameraBodyGeneration.matchedToken(fromCameraName: cameraName)
        {
            fields.append(("body", token.token.lowercased()))
            fields.append(("inferred", label(for: token.generation)))
        }
        for key in facts.keys.sorted() {
            guard let safeKey = sanitizedToken(key),
                let safeValue = sanitizedToken(facts[key] ?? "")
            else { continue }
            fields.append((safeKey, safeValue))
        }
        guard !fields.isEmpty else { return nil }
        return fields.map { "\($0.0)=\($0.1)" }.joined(separator: " ")
    }

    /// Handshake establishment summary reduced to `key=value` tokens whose values
    /// are hex codes or closed words. Localized error text is dropped.
    public static func sanitizedSummary(_ raw: String) -> String? {
        let kept = raw.split(whereSeparator: \.isWhitespace).compactMap { token -> String? in
            let parts = token.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            guard let key = sanitizedToken(String(parts[0])),
                let value = sanitizedToken(String(parts[1]))
            else { return nil }
            return "\(key)=\(value)"
        }
        guard !kept.isEmpty else { return nil }
        return kept.joined(separator: " ")
    }

    /// Closed pairing decision from the live operation policy.
    public static func pairingDecision(
        policy: ZCameraOperationPolicy,
        isUSB: Bool,
        requestPairing: Bool
    ) -> String {
        if isUSB { return "usb" }
        if !policy.supportsPairing { return "unadvertised" }
        return requestPairing ? "attempt" : "skipped"
    }

    public static func generationLabel(_ generation: ZCameraBodyGeneration?) -> String {
        guard let generation else { return "unknown" }
        return label(for: generation)
    }

    private static func label(for generation: ZCameraBodyGeneration) -> String {
        switch generation {
        case .one: return "one"
        case .two: return "two"
        case .three: return "three"
        }
    }

    /// Closed words, model tokens (`z6iii`), and PTP hex codes. Rejects SSIDs,
    /// hosts, serials, and sentences even when they are alphanumeric.
    private static func sanitizedToken(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 48 else { return nil }
        if trimmed.hasPrefix("0x") {
            let hex = trimmed.dropFirst(2)
            guard !hex.isEmpty, hex.allSatisfy(\.isHexDigit) else { return nil }
            return trimmed.lowercased()
        }
        if allowedValues.contains(trimmed) { return trimmed }
        if allowedValues.contains(trimmed.lowercased()) { return trimmed.lowercased() }
        return nil
    }

    private static let allowedValues: Set<String> = [
        "connect.gate", "connect.join", "connect.handshake", "connect.result",
        "event", "body", "inferred", "ops", "fallback", "pairing", "join", "ssid",
        "path", "transport", "result", "stage", "ptp",
        "gateOps", "gateFallback", "openSession", "appMode", "pairConfirm", "remoteMode",
        "recProhib",
        "gateops", "gatefallback", "opensession", "appmode", "pairconfirm", "remotemode",
        "recprohib",
        "known", "unknown", "none", "gen1-name",
        "attempt", "skipped", "unadvertised", "usb",
        "exact", "prefix", "skipped-on-ap", "skipped-path", "skipped-unresolvable",
        "skipped-declined", "skipped-wizard", "skipped-recovery",
        "resolved", "unresolvable", "unreadable", "on-ap", "non-nikon",
        "cameraAccessPoint", "infrastructure", "phoneHotspot", "usbC", "hdmiCapture",
        "ptpIP", "ok", "fail", "icc",
        "one", "two", "three",
        "open-session", "device-info", "app-mode", "identify", "capability",
        "z6", "z6ii", "z6iii", "z7", "z7ii", "z7iii", "z5", "z5ii", "z50", "z50ii",
        "zr", "z8", "z9", "zf", "zfc", "z30",
    ]
}
