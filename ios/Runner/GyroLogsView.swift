import OpenZCineCore
import SwiftUI

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
                MultiShareSheet(urls: [item.url], metadataText: nil) {
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
            Text(entry.descriptor.mount.detail)
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
                }
                .disabled(entry.active || entry.summary == nil)
                Button(role: .destructive) {
                    deleting = entry
                } label: {
                    Label("Delete", systemImage: "trash")
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
                Section {
                    Text(
                        "Directions are viewed from behind the upright camera. These presets assume the phone is parallel to the camera's rear screen. An angled holder still needs IMU rotation in Gyroflow."
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
            .navigationTitle("Phone mount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .preferredColorScheme(.dark)
    }

    private func presetRow(_ preset: GyroMountPreset) -> some View {
        Button {
            coordinator.mountPreset = preset
        } label: {
            HStack {
                Text(preset.title).foregroundStyle(.primary)
                Spacer()
                if coordinator.mountPreset == preset {
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
            }.accessibilityIdentifier("monitor.gyroStatus")
        }
    }
}
