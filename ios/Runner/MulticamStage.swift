import MonitorPresentation
import MonitorUI
import OpenCineCore
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

/// The multicam stage: four fixed tiles laid out by the shared `MultiviewPresentationLayout`
/// (Grid / Center stage), drawn with the shared MonitorUI chrome. State and camera actions come
/// from `MulticamCoordinator`; the app model supplies the saved-camera list, Live View and exit.
struct MulticamStage: View {
    @Bindable var coordinator: MulticamCoordinator
    let confirmsRecord: Bool
    let pickerRows: () -> [MulticamPickerRow]
    let openLiveView: (MonitorEntryID) -> Void
    let close: () -> Void

    @State private var addingSlot: Int?
    @State private var clean = false
    @State private var confirming: RecordPlan?
    @State private var leaving = false

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            let layout = MultiviewPresentationLayout(
                width: proxy.size.width, height: proxy.size.height,
                safeArea: MonitorSafeArea(
                    top: insets.top, leading: insets.leading, bottom: insets.bottom,
                    trailing: insets.trailing),
                arrangement: coordinator.arrangement, selected: coordinator.focusedSlot)
            ZStack(alignment: .topLeading) {
                MonitorTheme.canvas
                let strip = layout.secondaryViewport.map { _ in layout.secondaryIndices } ?? []
                ForEach(0..<MulticamCoordinator.tileCount, id: \.self) { slot in
                    if !strip.contains(slot) {
                        let frame = layout.tiles[slot]
                        tile(slot, layout: layout)
                            .frame(width: frame.width, height: frame.height)
                            .position(x: frame.midX, y: frame.midY)
                    }
                }
                if let viewport = layout.secondaryViewport {
                    // Center stage's trailing strip scrolls inside its viewport.
                    let height =
                        (strip.map { layout.tiles[$0].maxY }.max() ?? viewport.y) - viewport.y
                    ScrollView(showsIndicators: false) {
                        ZStack(alignment: .topLeading) {
                            ForEach(strip, id: \.self) { slot in
                                let frame = layout.tiles[slot]
                                tile(slot, layout: layout)
                                    .frame(width: frame.width, height: frame.height)
                                    .offset(x: frame.x - viewport.x, y: frame.y - viewport.y)
                            }
                        }
                        .frame(
                            width: viewport.width, height: max(height, 1), alignment: .topLeading)
                    }
                    .monitorScrollFade()
                    .frame(width: viewport.width, height: viewport.height)
                    .position(x: viewport.midX, y: viewport.midY)
                }
                if !clean {
                    chromeButton("Close multicam", icon: .x, rect: layout.sessionControls) {
                        leaving = true
                    }
                    chromeButton(
                        coordinator.arrangement == .grid ? "Center stage" : "Grid",
                        icon: coordinator.arrangement == .grid ? .layoutList : .layoutGrid,
                        rect: layout.network
                    ) {
                        coordinator.arrangement =
                            coordinator.arrangement == .grid ? .centerStage : .grid
                    }
                    if let program = coordinator.program, program.isLive {
                        MulticamValues(member: program, coordinator: coordinator)
                            .frame(width: layout.readouts.width, height: layout.readouts.height)
                            .position(x: layout.readouts.midX, y: layout.readouts.midY)
                    }
                }
                chromeButton(
                    "DISP", icon: clean ? .eyeOff : .eye, rect: layout.display, active: clean
                ) {
                    clean.toggle()
                }
                recordButton(diameter: layout.record.width)
                    .position(x: layout.record.midX, y: layout.record.midY)
                if let toast = coordinator.toast {
                    MulticamToast(text: toast) { coordinator.toast = nil }
                        .frame(maxWidth: min(420, proxy.size.width - 40))
                        .position(x: proxy.size.width / 2, y: insets.top + 40)
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
            .overlay {
                if let slot = addingSlot {
                    MulticamPicker(
                        rows: pickerRows(),
                        pick: { record in
                            addingSlot = nil
                            coordinator.add(record, reachable: true, slot: slot)
                        },
                        dismiss: { addingSlot = nil })
                }
            }
        }
        .ignoresSafeArea()
        .background(MonitorTheme.canvas.ignoresSafeArea())
        .foregroundStyle(MonitorTheme.text)
        .preferredColorScheme(.dark)
        .confirmationDialog(
            confirming.map { MulticamCopy.confirm($0.direction, names: coordinator.names($0)) }
                ?? "",
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
            titleVisibility: .visible
        ) {
            Button(confirming?.direction == .stop ? "Stop recording" : "Start recording") {
                if let plan = confirming { Task { await coordinator.run(plan) } }
                confirming = nil
            }
        }
        .confirmationDialog(
            "Close multicam? Recording continues on every camera.", isPresented: $leaving,
            titleVisibility: .visible
        ) {
            Button("Close multicam", role: .destructive, action: close)
        }
    }

    private func tile(_ slot: Int, layout: MultiviewPresentationLayout) -> some View {
        let frame = layout.tiles[slot]
        let selected = slot == coordinator.focusedSlot
        return MulticamTile(
            member: coordinator.member(atSlot: slot), slot: slot, selected: selected,
            compact: frame.width < 200 || frame.height < 136,
            // The program values sit inside the selected tile in landscape and Grid: its footer
            // rides above them.
            footerInset: selected && layout.readoutsOverlay && !clean
                ? max(0, frame.maxY - layout.readouts.y) : 0,
            coordinator: coordinator, openLiveView: openLiveView,
            add: { addingSlot = slot })
    }

    private func recordButton(diameter: Double) -> some View {
        Button {
            let plan = coordinator.groupPlan()
            guard plan.isExecutable else {
                coordinator.toast = MulticamCopy.couldntRec
                return
            }
            if confirmsRecord {
                confirming = plan
            } else {
                Task { await coordinator.run(plan) }
            }
        } label: {
            MonitorRecordLamp(diameter: diameter, recording: coordinator.anyRecording)
        }
        .buttonStyle(.plain)
        .disabled(!coordinator.canRecord)
        .opacity(coordinator.canRecord ? 1 : 0.45)
        .accessibilityLabel(coordinator.anyRecording ? "Stop recording on all" : "Record on all")
        .accessibilityIdentifier("multicam.record")
    }

    private func chromeButton(
        _ title: String, icon: MonitorIcon, rect: MonitorRect, active: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        MonitorChromeButton(
            title, size: CGSize(width: rect.width, height: rect.height), active: active,
            action: action
        ) {
            icon.frame(width: 20, height: 20)
        }
        .position(x: rect.midX, y: rect.midY)
    }
}

/// A stage tile: the member's picture and identity chrome (name, battery, timecode, tally) on
/// every live tile, or Add camera on an empty one.
private struct MulticamTile: View {
    let member: MulticamMember?
    let slot: Int
    let selected: Bool
    let compact: Bool
    let footerInset: Double
    let coordinator: MulticamCoordinator
    let openLiveView: (MonitorEntryID) -> Void
    let add: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            MonitorTheme.surface
            if let member {
                if let frame = member.frame {
                    Image(uiImage: frame).resizable().aspectRatio(contentMode: .fit)
                }
                chrome(member)
            } else {
                Button(action: add) {
                    VStack(spacing: 6) {
                        MonitorIcon.plus.frame(width: 18, height: 18)
                        Text("Add camera").font(
                            MonitorTheme.font(compact ? 11 : 13, weight: .semibold))
                    }
                    .foregroundStyle(MonitorTheme.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("multicam.add.\(slot)")
            }
        }
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                selected ? MonitorTheme.accent : MonitorTheme.border, lineWidth: selected ? 1.5 : 1)
        }
        .contentShape(shape)
        .onTapGesture(count: 2) { if let member { openLiveView(member.id) } }
        .onTapGesture { coordinator.select(slot: slot) }
        .contextMenu {
            if let member { menu(member) }
        }
        .accessibilityIdentifier("multicam.tile.\(slot)")
    }

    @ViewBuilder
    private func chrome(_ member: MulticamMember) -> some View {
        let font = MonitorTheme.font(compact ? 10 : 12, weight: .semibold)
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(member.letter)  \(member.displayName)").font(font).lineLimit(1)
                    if let note = member.note {
                        Text(note).font(MonitorTheme.font(compact ? 9 : 11, weight: .medium))
                            .foregroundStyle(MonitorTheme.recording)
                    }
                }
                Spacer(minLength: 4)
                if let battery = member.batteryPercent {
                    Text("\(battery)%").font(font).monospacedDigit()
                        .foregroundStyle(
                            battery <= 20
                                ? MonitorTheme.recording
                                : battery <= 40 ? MonitorTheme.digitalCrop : MonitorTheme.text)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                if let timecode = member.timecode, timecode.on {
                    Text(
                        String(
                            format: "%02d:%02d:%02d", timecode.hour, timecode.minute,
                            timecode.second)
                    )
                    .font(font).monospacedDigit()
                }
                Spacer(minLength: 4)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(tally(member)).font(font).monospacedDigit()
                        .foregroundStyle(
                            member.recording == true ? MonitorTheme.recording : MonitorTheme.text)
                }
            }
            .padding(.bottom, footerInset)
        }
        .monitorReadoutShadow()
        .padding(compact ? 6 : 10)
        if case .live = member.status {
        } else {
            status(member)
        }
    }

    @ViewBuilder
    private func status(_ member: MulticamMember) -> some View {
        VStack(spacing: 8) {
            switch member.status {
            case .connecting:
                ProgressView().tint(MonitorTheme.secondary)
                Text("Connecting…").font(MonitorTheme.font(12, weight: .medium))
            case .failed(let reason):
                Text(reason).font(MonitorTheme.font(12, weight: .semibold))
                Button("Retry") { coordinator.retry(member.id) }
                    .font(MonitorTheme.font(12, weight: .semibold))
                    .foregroundStyle(MonitorTheme.accent)
                    .accessibilityIdentifier("multicam.retry.\(member.slot)")
            case .live:
                EmptyView()
            }
        }
        .foregroundStyle(MonitorTheme.secondary)
    }

    @ViewBuilder
    private func menu(_ member: MulticamMember) -> some View {
        if member.isLive {
            Button("Open Live View") { openLiveView(member.id) }
            Button(member.recording == true ? "Stop recording" : "Start recording") {
                Task { await coordinator.run(coordinator.plan(for: member.id)) }
            }
        }
        Button("Reconnect") { coordinator.retry(member.id) }
        Button("Remove camera", role: .destructive) { coordinator.remove(member.id) }
    }

    /// `REC mm:ss` while rolling (timed from the take's first recording frame), else STBY.
    private func tally(_ member: MulticamMember) -> String {
        if coordinator.groupBusy { return "WAIT" }
        guard member.isLive, let recording = member.recording else {
            return CameraDisplayState.unavailableValue
        }
        guard recording else { return "STBY" }
        guard let since = member.recordingSince else { return "REC" }
        let seconds = max(0, Int(Date().timeIntervalSince(since)))
        return String(format: "REC %02d:%02d", seconds / 60, seconds % 60)
    }
}

/// The program camera's values. ISO and white balance open the camera's own advertised choices
/// and write to that camera only; the camera's readback decides what shows.
private struct MulticamValues: View {
    let member: MulticamMember
    let coordinator: MulticamCoordinator

    var body: some View {
        let properties = member.properties
        HStack(spacing: 18) {
            value("ISO", properties.iso.map(String.init), key: .iso) { setting in
                if case .iso(.manual(let iso)) = setting { return String(iso) }
                return nil
            }
            value("SHUTTER", shutter(properties))
            value(
                "WB", properties.wbKelvin.map { "\($0)K" } ?? properties.wbMode, key: .whiteBalance
            ) {
                setting in
                if case .whiteBalance(.preset(let label)) = setting { return label }
                if case .whiteBalance(.auto) = setting { return "Auto" }
                return nil
            }
            value("FOCUS", properties.focusMode)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(maxHeight: .infinity)
        .monitorGlass(in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func shutter(_ properties: PTPCameraPropertySnapshot) -> String? {
        properties.shutterMode == .speed
            ? properties.shutterSpeed ?? properties.shutterAngle
            : properties.shutterAngle ?? properties.shutterSpeed
    }

    @ViewBuilder
    private func value(
        _ title: String, _ text: String?, key: SettingKey? = nil,
        label: ((SettingValue) -> String?)? = nil
    ) -> some View {
        let readout = ViewThatFits(in: .vertical) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(MonitorTheme.font(8, weight: .bold)).tracking(1.2)
                    .foregroundStyle(MonitorTheme.faint)
                Text(text ?? CameraDisplayState.unavailableValue)
                    .font(MonitorTheme.font(13, weight: .semibold)).monospacedDigit().lineLimit(1)
            }
            // Grid's short in-tile row: title and value on one line.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(title).font(MonitorTheme.font(7, weight: .bold)).tracking(1)
                    .foregroundStyle(MonitorTheme.faint)
                Text(text ?? CameraDisplayState.unavailableValue)
                    .font(MonitorTheme.font(11, weight: .semibold)).monospacedDigit().lineLimit(1)
            }
        }
        if let key, let label,
            let descriptor = coordinator.descriptor(key, of: member),
            descriptor.availability == .available,
            let choices = descriptor.domain?.choices, !choices.isEmpty
        {
            Menu {
                ForEach(Array(choices.enumerated()), id: \.offset) { _, choice in
                    if let name = label(choice) {
                        Button(name) { coordinator.set(choice, on: member.id, label: title) }
                    }
                }
            } label: {
                readout
            }
            .accessibilityIdentifier("multicam.value.\(title.lowercased())")
        } else {
            readout
        }
    }
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

/// Saved bodies, one row per camera; the ones that cannot join say why.
private struct MulticamPicker: View {
    let rows: [MulticamPickerRow]
    let pick: (PTPIPSavedCameraRecord) -> Void
    let dismiss: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea().onTapGesture(perform: dismiss)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Add camera").font(MonitorTheme.font(16, weight: .semibold))
                    Spacer()
                    Button(action: dismiss) { MonitorIcon.x.frame(width: 16, height: 16) }
                        .buttonStyle(.plain).accessibilityLabel("Close")
                }
                if rows.isEmpty {
                    Text(MulticamCopy.emptyPicker).font(MonitorTheme.font(13))
                        .foregroundStyle(MonitorTheme.muted)
                }
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in
                            Button {
                                pick(row.record)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(row.record.displayTitle)
                                        .font(MonitorTheme.font(14, weight: .semibold))
                                    Text(
                                        row.refusal
                                            ?? SavedCameraPathGroups.pathLabel(for: row.record)
                                    )
                                    .font(MonitorTheme.font(12))
                                    .foregroundStyle(MonitorTheme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(12)
                                .background(
                                    MonitorTheme.raised, in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                            .disabled(row.refusal != nil)
                            .opacity(row.refusal == nil ? 1 : 0.5)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
            .padding(18)
            .frame(maxWidth: 420)
            .background(MonitorTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .padding(24)
        }
        .accessibilityAddTraits(.isModal)
    }
}
