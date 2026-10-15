import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineCore
import OpenCineMedia
import OpenCineMulticam
import OpenZCineCore
import SwiftUI

/// One saved body offered by the stage's Add camera list.
struct MulticamPickerRow: Identifiable {
    let record: PTPIPSavedCameraRecord
    /// Operator copy for why it cannot join now; `nil` when it can.
    let refusal: String?
    var id: String { record.id }
}

/// The multicam stage: OpenCine's shared Multiview stage over this app's members. State and
/// camera actions come from `MulticamCoordinator` (membership, eligible-subset record, per-member
/// results and properties); the app model supplies the saved-camera list, Live View and exit.
struct MulticamStage: View {
    @Bindable var coordinator: MulticamCoordinator
    let confirmsRecord: Bool
    let pickerRows: () -> [MulticamPickerRow]
    let openLiveView: (MonitorEntryID) -> Void
    let close: () -> Void

    @State private var addingSlot: Int?
    @State private var leaving = false
    private var fill: Bool { coordinator.presentation.fill }

    var body: some View {
        MultiviewStageSurface(
            arrangement: coordinator.arrangement, selected: coordinator.focusedSlot
        ) { viewport in
            let insets = viewport.safeArea
            let layout = viewport.layout
            MultiviewStage(
                tiles: (0..<MulticamCoordinator.tileCount).map { slot in
                    coordinator.member(atSlot: slot).map(tile)
                },
                layout: layout, viewport: viewport.size,
                safeArea: EdgeInsets(
                    top: insets.top, leading: insets.leading, bottom: insets.bottom,
                    trailing: insets.trailing),
                arrangement: $coordinator.arrangement,
                selected: Binding(
                    get: { coordinator.focusedSlot }, set: { coordinator.select(slot: $0) }),
                fill: Binding(
                    get: { coordinator.presentation.fill },
                    set: { coordinator.presentation.fill = $0 }), tools: [.layout, .fit],
                readouts: coordinator.program.flatMap { $0.isLive ? readouts($0) : nil },
                recording: coordinator.anyRecording, groupBusy: coordinator.groupBusy,
                confirmsRecord: confirmsRecord,
                actions: MultiviewStageActions(
                    openLiveView: { slot in
                        if let member = coordinator.member(atSlot: slot) { openLiveView(member.id) }
                    },
                    add: { addingSlot = $0 }, perform: perform, choose: choose,
                    close: { leaving = true }, recordContext: recordContext,
                    record: { plan, _ in await coordinator.run(plan) })
            ) { slot in
                if let frame = coordinator.member(atSlot: slot)?.frame {
                    Image(uiImage: frame).resizable()
                        .aspectRatio(contentMode: fill ? .fill : .fit)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .multiviewStageState(coordinator.presentation)
            .overlay(alignment: .top) {
                if let toast = coordinator.toast {
                    MulticamToast(text: toast) { coordinator.toast = nil }
                        .frame(maxWidth: min(420, viewport.size.width - 40))
                        .padding(.top, insets.top + 20)
                }
            }
            .overlay {
                if let slot = addingSlot {
                    picker(slot)
                }
            }
        }
        .ignoresSafeArea()
        .background(MonitorTheme.canvas.ignoresSafeArea())
        .foregroundStyle(MonitorTheme.text)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            MultiviewNetworkRestore.none.closeQuestion, isPresented: $leaving,
            titleVisibility: .visible
        ) {
            Button(MultiviewNetworkRestore.closeAction, role: .destructive, action: close)
        }
    }

    /// The member's values as the shared stage shows them; unknown stays unknown.
    private func tile(_ member: MulticamMember) -> MultiviewTile {
        let rolling = member.isLive ? member.recording : nil
        let status: MultiviewTileStatus?
        let detail: String
        switch member.status {
        case .live:
            status = nil
            detail = "Connected"
        case .connecting:
            status = MultiviewTileStatus(text: "Connecting…", inProgress: true)
            detail = "Connecting…"
        case .failed(let reason):
            status = MultiviewTileStatus(
                text: reason, inProgress: false,
                actions: [
                    MultiviewCameraAction(MulticamTileAction.reconnect, "Reconnect"),
                    MultiviewCameraAction(
                        MulticamTileAction.remove, "Remove", kind: .destructive),
                ])
            detail = reason
        }
        let battery = MonitorOperatorPowerReading.camera(member.batteryReading)
        return MultiviewTile(
            name: member.displayName, model: SavedCameraPathGroups.pathLabel(for: member.record),
            // The body's five-step gauge (A5-01): bars, never a percent it did not report.
            batteryBars: battery?.bars,
            batteryBarCount: battery?.barCount ?? CameraBatteryGauge.barCount,
            storage: member.control?.session.refresh().storage.storageReadout?.free
                ?? MultiviewTally.unavailable,
            timecode: member.timecode?.monitorLabel,
            tally: MultiviewTally.text(recording: rolling, waiting: coordinator.groupBusy),
            // Nikon reports no take length: the tile times it from the first recording frame.
            recordingSince: rolling == true && !coordinator.groupBusy ? member.recordingSince : nil,
            recording: member.recording == true, note: member.note, tileNote: member.note,
            readouts: readouts(member), status: status, detail: detail,
            failure: { if case .failed(let reason) = member.status { reason } else { nil } }(),
            actions: [
                MultiviewCameraAction(
                    MultiviewCameraAction.liveView, "Live View", enabled: member.isLive),
                MultiviewCameraAction(
                    MulticamTileAction.record,
                    member.recording == true ? "Stop recording" : "Start recording",
                    kind: .record, enabled: member.isLive),
                MultiviewCameraAction(MulticamTileAction.reconnect, "Reconnect", closes: true),
                MultiviewCameraAction(
                    MulticamTileAction.remove, "Remove camera", kind: .destructive),
            ],
            accessibilityValue: detail)
    }

    private func perform(_ action: String, slot: Int) {
        guard let member = coordinator.member(atSlot: slot) else { return }
        switch action {
        case MulticamTileAction.reconnect: coordinator.retry(member.id)
        case MulticamTileAction.remove: coordinator.remove(member.id)
        default: break
        }
    }

    private func recordContext(_ slot: Int?) -> MultiviewRecordContext {
        let plan =
            slot.flatMap { coordinator.member(atSlot: $0) }.map { coordinator.plan(for: $0.id) }
            ?? coordinator.groupPlan()
        return MultiviewRecordContext(
            plan: plan, busy: coordinator.groupBusy,
            prompt: MulticamCopy.confirm(plan.direction, names: coordinator.names(plan)))
    }

    // MARK: Values

    /// ISO, shutter, white balance and focus as read back from the camera. ISO and white balance
    /// offer the camera's own advertised choices; picking one writes to that camera only.
    private func readouts(_ member: MulticamMember) -> [MultiviewReadout] {
        let properties = member.properties
        let shutter =
            properties.shutterMode == .speed
            ? properties.shutterSpeed ?? properties.shutterAngle
            : properties.shutterAngle ?? properties.shutterSpeed
        return [
            MultiviewReadout(
                title: "ISO", value: properties.iso.map(String.init) ?? MultiviewTally.unavailable,
                choices: choices(.iso, of: member).map(\.name)),
            MultiviewReadout(title: "SHUTTER", value: shutter ?? MultiviewTally.unavailable),
            MultiviewReadout(
                title: "WB",
                value: properties.wbKelvin.map { "\($0)K" } ?? properties.wbMode
                    ?? MultiviewTally.unavailable,
                choices: choices(.whiteBalance, of: member).map(\.name)),
            MultiviewReadout(
                title: "FOCUS", value: properties.focusMode ?? MultiviewTally.unavailable),
        ]
    }

    /// The value the operator picked, by the name shown: a choice the camera no longer
    /// advertises writes nothing.
    private func choose(slot: Int, readout: Int, choice: String) {
        guard readout == 0 || readout == 2, let member = coordinator.member(atSlot: slot) else {
            return
        }
        let key: SettingKey = readout == 0 ? .iso : .whiteBalance
        guard let value = choices(key, of: member).first(where: { $0.name == choice })?.value
        else { return }
        coordinator.set(value, on: member.id, label: readout == 0 ? "ISO" : "WB")
    }

    /// What the camera advertises for `key`, with the name the stage shows.
    private func choices(_ key: SettingKey, of member: MulticamMember) -> [(
        value: SettingValue, name: String
    )] {
        guard let descriptor = coordinator.descriptor(key, of: member),
            descriptor.availability == .available, let choices = descriptor.domain?.choices
        else { return [] }
        return choices.compactMap { choice in
            switch choice {
            case .iso(.manual(let iso)): (choice, String(iso))
            case .whiteBalance(.preset(let label)): (choice, label)
            case .whiteBalance(.auto): (choice, "Auto")
            default: nil
            }
        }
    }

    private func picker(_ slot: Int) -> some View {
        let rows = pickerRows()
        return MultiviewCameraPicker(
            rows: rows.map { row in
                MultiviewPickerRow(
                    id: row.id, title: row.record.displayTitle,
                    detail: row.refusal ?? SavedCameraPathGroups.pathLabel(for: row.record),
                    enabled: row.refusal == nil)
            },
            empty: MulticamCopy.emptyPicker, cancel: { addingSlot = nil },
            pick: { id in
                guard let row = rows.first(where: { $0.id == id }) else { return }
                addingSlot = nil
                coordinator.add(row.record, reachable: true, slot: slot)
            })
    }
}

/// This app's camera option ids beside the shared Live View id.
private enum MulticamTileAction {
    static let record = "record"
    static let reconnect = "reconnect"
    static let remove = "remove"
}

private struct MulticamToast: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        Text(text).font(MonitorTheme.font(13, weight: .medium)).multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .monitorGlass(in: Capsule())
            .onTapGesture(perform: dismiss)
            .task {
                try? await Task.sleep(for: .seconds(4))
                dismiss()
            }
            .accessibilityIdentifier("multicam.toast")
    }
}
