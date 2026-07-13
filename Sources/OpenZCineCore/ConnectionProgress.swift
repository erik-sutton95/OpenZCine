import Foundation

/// Phased connection lifecycle shown in the startup connection progress sheet.
public enum CameraConnectionPhase: Equatable, Sendable {
    case idle
    case readyToJoin
    case joiningWiFi
    case discovering
    case handshaking
    case pairing
    /// Pairing accepted in-app; the operator must now confirm on the camera body, which then
    /// restarts its access point. Held until discovery sees the camera leave and return.
    case confirmOnCamera
    case preparingLiveView
    case connected
    case failed
}

/// Resolves operator-facing copy for the connection progress sheet.
public enum ConnectionProgressCopy {
    /// Builds the device title shown on the progress card.
    public static func resolveDisplayName(
        rawName: String,
        savedCamera: PTPIPSavedCameraRecord?
    ) -> String {
        if let savedCamera {
            let custom =
                savedCamera.presentation?.customName?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !custom.isEmpty {
                return savedCamera.displayTitle
            }
        }

        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "Nikon camera" }
        if trimmed.uppercased().hasPrefix("ZR_") {
            return "Nikon ZR"
        }
        return trimmed
    }

    /// Primary status line for the active connection phase.
    public static func statusTitle(phase: CameraConnectionPhase, isUSB _: Bool) -> String {
        switch phase {
        case .idle:
            return ""
        case .readyToJoin:
            return "Ready to connect"
        case .joiningWiFi:
            return "Connecting…"
        case .discovering:
            return "Searching…"
        case .handshaking:
            return "Connecting…"
        case .pairing:
            return "Pairing…"
        case .confirmOnCamera:
            return "Confirm on camera"
        case .preparingLiveView:
            return "Starting live view…"
        case .connected:
            return "Connected"
        case .failed:
            return "Couldn't connect"
        }
    }

    /// Secondary detail line beneath the status title.
    public static func statusDetail(
        phase: CameraConnectionPhase,
        deviceName: String,
        friendlyError: String?
    ) -> String {
        switch phase {
        case .idle:
            return ""
        case .readyToJoin:
            return "Join \(deviceName)'s Wi‑Fi network to continue."
        case .joiningWiFi:
            return "Tap Join when iOS asks to switch networks."
        case .discovering:
            return "Looking for \(deviceName) on your network."
        case .handshaking:
            return "Establishing a secure link with \(deviceName)."
        case .pairing:
            return "Confirm the pairing request on \(deviceName)."
        case .confirmOnCamera:
            return
                "Tap “Confirm” on \(deviceName). It will restart its Wi‑Fi — we'll reconnect automatically."
        case .preparingLiveView:
            return "Opening the live monitor for \(deviceName)."
        case .connected:
            return "\(deviceName) is ready."
        case .failed:
            if let friendlyError, !friendlyError.isEmpty {
                return friendlyError
            }
            return "Check your network and try again."
        }
    }

    /// Maps the app connection state plus progress flags to a sheet phase.
    public static func resolvePhase(
        isProgressPresented: Bool,
        explicitPhase: CameraConnectionPhase,
        isEstablishingConnection: Bool,
        isPairing: Bool,
        isPreparingLiveView: Bool,
        isConnected: Bool,
        showsFailure: Bool
    ) -> CameraConnectionPhase {
        guard isProgressPresented else { return .idle }
        if showsFailure { return .failed }
        if explicitPhase == .readyToJoin { return .readyToJoin }
        if explicitPhase == .joiningWiFi { return .joiningWiFi }
        if isPreparingLiveView { return .preparingLiveView }
        if isConnected, explicitPhase == .connected { return .connected }
        if isPairing { return .pairing }
        if isEstablishingConnection { return .handshaking }
        if explicitPhase == .discovering { return .discovering }
        return explicitPhase == .idle ? .handshaking : explicitPhase
    }
}
