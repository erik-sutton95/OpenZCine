import OpenCineRelay
import OpenCineWatch
import OpenZCineCore
import SwiftUI

/// Nikon report meanings stay in this adapter; layout and crown lifetime have one shared owner.
struct WatchMonitorView: View {
    @Environment(WatchSessionController.self) private var controller

    var body: some View {
        WatchOperatorScreen(value: presentation, image: controller.feedImage, action: send)
    }

    private var presentation: WatchMonitorPresentation {
        let state = controller.state
        let photography = state?.isPhotography == true
        let shots = (state?.shotsRemaining).flatMap { $0.isEmpty ? nil : $0 } ?? "\u{2014}"
        // A body with its timecode off still reports 00:00:00:00; that reads as absent (A5-05).
        let timecode = (controller.frameTimecode ?? state?.timecode).flatMap {
            $0.on ? $0.label : nil
        }
        let header = photography ? shots : timecode ?? "--:--:--:--"
        return WatchMonitorPresentation(
            sourceRevision: controller.presentationRevision,
            header: header, headerAccessibility: photography ? "Shots remaining \(shots)" : nil,
            media: state?.mediaStatus?.capacityLabel ?? state?.media, battery: battery,
            recording: state?.isRecording, photography: state?.isPhotography,
            feedAspectRatio: state?.feedAspectRatio,
            canCapture: controller.isReachable && state?.connection == .connected
                && !controller.isSendingCommand,
            placeholder: placeholder, commandMessage: controller.commandMessage)
    }

    private var battery: WatchMonitorBattery? {
        guard let state = controller.state else { return nil }
        let gauge = CameraBatteryGauge.gauge(rawBatteryLevel: state.cameraBatteryPercent)
        guard gauge != .unknown else { return nil }
        let urgency: WatchMonitorBattery.Urgency
        switch gauge.urgency {
        case .nominal: urgency = .nominal
        case .low: urgency = .low
        case .depleted: urgency = .depleted
        }
        return WatchMonitorBattery(
            filledBars: gauge.filledBars, barCount: CameraBatteryGauge.barCount,
            urgency: urgency,
            accessibilityLabel:
                "Camera battery \(gauge.filledBars) of \(CameraBatteryGauge.barCount) bars")
    }

    private var placeholder: String? {
        if !controller.isReachable { return WatchRelayCopy.openOnIPhone(appName: "OpenZCine") }
        if controller.state?.connection == .noCamera { return WatchRelayCopy.noCamera }
        if controller.state?.feedLive == false { return "Feed paused (Command mode)" }
        return nil
    }

    private func send(_ action: WatchMonitorAction) {
        guard presentation.admits(action) else { return }
        switch action.intent {
        case .capture: controller.sendCapture()
        case .record: controller.sendToggleRecord()
        }
    }
}
