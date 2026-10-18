import MonitorUI
import OpenCineAppKit
import OpenCineAppKitApple
import OpenZCineCore
import SwiftUI
import UniformTypeIdentifiers

/// Phone-motion takes remain separate from the camera's media catalog.
struct GyroLogsView: View {
    @Bindable var coordinator: GyroCaptureCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var sharing: GyroShareItem?
    @State private var deleting: GyroLogEntry?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(
                        "Mount the phone firmly to the camera. Export a log, then synchronize it and select your lens in Gyroflow."
                    )
                    .font(.subheadline)
                    if let warning = coordinator.storageWarning {
                        Label(warning, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    if let failure = coordinator.failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                if coordinator.logs.isEmpty {
                    Section {
                        ContentUnavailableView(
                            "No gyro logs yet", systemImage: "gyroscope",
                            description: Text(
                                "Enable gyro logging in Settings → Controls, then record with a connected Nikon camera."
                            ))
                    }
                } else {
                    Section("Takes") {
                        ForEach(coordinator.logs) { entry in row(entry) }
                    }
                }
            }
            .navigationTitle("Gyro logs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .sheet(item: $sharing) { item in
                MonitorActivityShareSheet(items: [
                    MonitorDeliveryShareItem(fileURL: item.url, contentType: .data)
                ])
                .onDisappear {
                    try? FileManager.default.removeItem(at: item.url.deletingLastPathComponent())
                    sharing = nil
                }
            }
            .confirmationDialog(
                "Delete gyro log?",
                isPresented: Binding(
                    get: { deleting != nil }, set: { if !$0 { deleting = nil } }
                ), titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) {
                    guard let entry = deleting else { return }
                    deleting = nil
                    Task { await coordinator.delete(entry) }
                }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func row(_ entry: GyroLogEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(entry.descriptor.cameraLabel).font(.headline)
            Text(
                entry.descriptor.startDate,
                format: .dateTime.month(.abbreviated).day().hour().minute().second()
            )
            .font(.subheadline).foregroundStyle(.secondary)
            Text(entry.descriptor.alignmentDetail)
                .font(.caption).foregroundStyle(.secondary)
            if let summary = entry.summary {
                Text(
                    String(
                        format: "%.1f s · %.1f Hz · %d samples", summary.duration,
                        summary.measuredRate, summary.sampleCount)
                )
                .font(.subheadline.monospacedDigit())
                Text(
                    String(
                        format: "Approx. REC offset %+.2f s · Largest gap %.0f ms",
                        summary.approximateStartOffset, summary.largestGap * 1_000)
                )
                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack(spacing: 20) {
                Label(health(entry), systemImage: entry.active ? "record.circle" : "gyroscope")
                    .font(.caption).foregroundStyle(entry.active ? Color.red : Color.secondary)
                Spacer(minLength: 8)
                Button {
                    Task {
                        if let url = await coordinator.share(entry) {
                            sharing = GyroShareItem(url: url)
                        }
                    }
                } label: {
                    Label("Share", systemImage: "square.and.arrow.up")
                        .minTapTarget()
                }
                .disabled(entry.active || entry.summary == nil)
                Button(role: .destructive) {
                    deleting = entry
                } label: {
                    Label("Delete", systemImage: "trash")
                        .minTapTarget()
                }.disabled(entry.active)
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }

    private func health(_ entry: GyroLogEntry) -> String {
        if entry.active {
            return coordinator.hasGapWarning ? "Gaps detected · recording" : "Recording / post-roll"
        }
        guard let summary = entry.summary else { return "Incomplete file" }
        if summary.termination == .recovered { return "Recovered · partial" }
        if summary.termination != .normal { return "Interrupted · partial" }
        if summary.hasGapWarning { return "Gaps detected · partial" }
        return summary.isPartial ? "Partial coverage" : "Complete"
    }
}

/// Selects the phone's fixed physical alignment for future motion logs.
struct GyroMountView: View {
    @Bindable var coordinator: GyroCaptureCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if coordinator.calibrationInProgress {
                    calibrationSteps
                } else {
                    automaticCalibration
                    manualPresets
                }
            }
            .navigationTitle("Phone mount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
        .onDisappear { coordinator.cancelMountCalibration() }
    }

    private var automaticCalibration: some View {
        Section("Automatic calibration") {
            Text(
                "Keep the phone firmly fixed to the camera. Capture three still poses to align angled mounts automatically."
            )
            .font(.subheadline)
            if let calibration = coordinator.mountCalibration {
                Label(
                    String(
                        format: "Verified calibration · check error %.1f°",
                        calibration.validationErrorDegrees),
                    systemImage: "checkmark.circle")
                Button("Reset calibration", role: .destructive) {
                    coordinator.clearMountCalibration()
                }
                .accessibilityIdentifier("gyro.calibration.reset")
            } else {
                Text("No saved calibration").foregroundStyle(.secondary)
            }
            Button("Calibrate phone mount") { coordinator.beginMountCalibration() }
                .disabled(!coordinator.canBeginMountCalibration)
                .accessibilityIdentifier("gyro.calibration.begin")
            if !coordinator.canBeginMountCalibration {
                Text("Connect a camera with live view and stop recording to calibrate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            calibrationMessage
        }
    }

    private var calibrationSteps: some View {
        Section("Pose \(coordinator.calibrationPoseCount + 1) of 3") {
            Text(calibrationInstruction).font(.headline)
            Text(
                "Keep the phone fixed to the camera. Hold both still for at least two seconds before capturing."
            )
            .font(.subheadline)
            Text(
                coordinator.calibrationPoseCount == 2
                    ? "This independent mixed pose must verify the alignment before it is saved."
                    : "Nothing is saved until the third pose verifies the alignment."
            )
            .font(.caption).foregroundStyle(.secondary)
            if !coordinator.canCaptureMountCalibration {
                Text("Waiting for fresh camera roll and pitch readings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            calibrationMessage
            HStack(spacing: 24) {
                Button {
                    coordinator.captureMountCalibration()
                } label: {
                    Text(coordinator.calibrationPoseCount == 2 ? "Verify and save" : "Capture pose")
                        .minTapTarget()
                }
                .disabled(!coordinator.canCaptureMountCalibration)
                .accessibilityIdentifier("gyro.calibration.capture")
                Button {
                    coordinator.beginMountCalibration()
                } label: {
                    Text("Start again").minTapTarget()
                }
                .accessibilityIdentifier("gyro.calibration.restart")
                Button(role: .cancel) {
                    coordinator.cancelMountCalibration()
                } label: {
                    Text("Cancel").minTapTarget()
                }
                .accessibilityIdentifier("gyro.calibration.cancel")
            }
            .buttonStyle(.borderless)
        }
    }

    private var calibrationInstruction: String {
        switch coordinator.calibrationPoseCount {
        case 0: "Hold the camera roughly level."
        case 1: "Tilt the lens up 25–35° and keep the roll level."
        default: "Point the lens up 35–45° and lean the camera's top 40–45° left or right."
        }
    }

    @ViewBuilder private var calibrationMessage: some View {
        if let message = coordinator.calibrationMessage {
            Text(message).font(.subheadline).foregroundStyle(.orange)
                .accessibilityIdentifier("gyro.calibration.message")
        }
    }

    private var manualPresets: some View {
        Group {
            Section("Manual presets") {
                Text(
                    "Directions are viewed from behind the upright camera. Manual presets assume the phone screen is parallel to the camera's back, perpendicular to the lens axis. Use automatic calibration for angled mounts."
                )
                .font(.subheadline)
                Text(
                    "Keep the phone fixed relative to the camera during each take. Changes apply to new takes."
                )
                .font(.subheadline)
                presetRow(.unconfigured)
            }
            ForEach(["Screen toward you", "Screen toward lens"], id: \.self) { group in
                Section(group) {
                    ForEach(GyroMountPreset.allCases.filter { $0.group == group }) { preset in
                        presetRow(preset)
                    }
                }
            }
        }
    }

    private func presetRow(_ preset: GyroMountPreset) -> some View {
        Button {
            coordinator.mountPreset = preset
        } label: {
            HStack {
                Text(preset.title).foregroundStyle(.primary)
                Spacer()
                if coordinator.mountCalibration == nil && coordinator.mountPreset == preset {
                    Image(systemName: "checkmark").foregroundStyle(.tint)
                }
            }
        }
        .accessibilityIdentifier("gyro.mount.\(preset.rawValue)")
    }
}

private struct GyroShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

/// A small, reachable status above the monitor image; full details live in the dedicated list.
struct GyroMonitorStatus: View {
    @Bindable var coordinator: GyroCaptureCoordinator
    var body: some View {
        if coordinator.enabled || coordinator.statusIsFailure {
            Button {
                coordinator.openLogs()
            } label: {
                Label(
                    coordinator.statusIsFailure
                        ? "GYRO ERROR"
                        : coordinator.motionRunning ? coordinator.statusText : "GYRO OFFLINE",
                    systemImage: coordinator.statusIsFailure
                        ? "exclamationmark.triangle" : "gyroscope"
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(
                    coordinator.statusIsFailure || coordinator.hasGapWarning
                        ? Color.orange : Color.white
                )
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(.black.opacity(0.65), in: Capsule())
            }
            .buttonStyle(.monitorTapTarget)
            .accessibilityIdentifier("monitor.gyroStatus")
        }
    }
}
