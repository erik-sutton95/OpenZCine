import OpenZCineCore
import SwiftUI

/// The same entry is used by the ladder picker and its native fallback.
struct FocusRackEntryRow: View {
    @Environment(NativeAppModel.self) private var model

    var body: some View {
        Button {
            model.openFocusRack()
        } label: {
            HStack(spacing: 4) {
                Text("Focus Rack")
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LiveDesign.text)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("focusRack.open")
    }
}

/// Native rack setup and transport. All movement and admission decisions come from the core.
struct FocusRackView: View {
    @Bindable var rack: FocusRackModel
    let maximumHeight: CGFloat
    var compact = false
    var allowsExpansion = true
    var allowsSetup = true
    var onMovePanel: (CGSize) -> Void = { _ in }
    var onResetPanel: () -> Void = {}
    @State private var entryText = ""
    @State private var editor = Editor.template
    @State private var editing = false
    @State private var optionsExpanded = false
    @State private var marksExpanded = false
    @State private var timedContentHeight = CGFloat.zero
    @State private var nativeContentHeight = CGFloat.zero
    @State private var closingRack = false
    @State private var templateToLoad: FocusRackTemplate?
    @State private var panelTranslation = CGSize.zero
    @GestureState private var draggingPanel = false

    private enum Editor {
        case template, duration, delay, nativeDelay
        var title: String {
            switch self {
            case .template: "Save timing template"
            case .duration: "Duration in seconds"
            case .delay, .nativeDelay: "Delay in seconds"
            }
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            header
            if rack.mode == .nativeAF {
                nativeAF
            } else {
                if !compact {
                    if let state = rack.state {
                        marks(state).disabled(
                            rack.afSettingsPending || rack.afSettingsFailure != nil)
                    }
                    if let instruction = rack.state?.recoveryInstruction {
                        recovery(instruction)
                    }
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 6) {
                                if let status = rack.afSettingsStatus {
                                    Text(status).font(.system(size: 12)).foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("focusControl.setupStatus")
                                }
                                if let state = rack.state {
                                    move(state)
                                    if let reason = state.admissionMessage {
                                        Text(reason).font(.system(size: 12)).foregroundStyle(
                                            .orange
                                        )
                                        .fixedSize(horizontal: false, vertical: true)
                                        .id("focusRack.admission")
                                        .accessibilityIdentifier("focusRack.admission")
                                    }
                                    if !state.message.isEmpty {
                                        Text(state.message)
                                            .font(.system(size: 12)).fixedSize(
                                                horizontal: false, vertical: true
                                            )
                                            .accessibilityIdentifier("focusRack.message")
                                    }
                                } else {
                                    Text("Connect a camera in movie AF-S mode to set focus marks.")
                                        .font(.system(size: 12))
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let notice = rack.notice {
                                    Text(notice).font(.system(size: 12))
                                        .foregroundStyle(.orange)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .accessibilityIdentifier("focusRack.notice")
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 4)
                            .id("focusRack.setup.top")
                            .onGeometryChange(for: CGFloat.self) {
                                $0.size.height
                            } action: {
                                timedContentHeight = $0
                            }
                        }
                        .onChange(of: marksExpanded) { _, _ in
                            proxy.scrollTo("focusRack.setup.top", anchor: .top)
                        }
                        .onChange(of: rack.state?.program.marks.count) { _, _ in
                            proxy.scrollTo("focusRack.setup.top", anchor: .top)
                        }
                        .onChange(of: rack.revealAdmission, initial: true) { _, requested in
                            if requested {
                                proxy.scrollTo("focusRack.admission", anchor: .top)
                                rack.revealAdmission = false
                            }
                        }
                        .disabled(
                            rack.stopPending || rack.afSettingsPending
                                || rack.afSettingsFailure != nil
                        )
                        .frame(
                            idealHeight: timedContentHeight > 0 ? timedContentHeight : nil,
                            maxHeight: timedContentHeight > 0 ? timedContentHeight : nil
                        )
                        .accessibilityIdentifier("focusRack.setup")
                    }
                }
                transport
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .frame(maxHeight: maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
        .background(LiveDesign.surface.opacity(0.97), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).stroke(LiveDesign.hairline, lineWidth: 1)
        }
        .foregroundStyle(LiveDesign.text)
        .onAppear {
            if rack.state?.nudgeProgress != nil, rack.state?.program.marks.count == 2 {
                marksExpanded = true
            }
        }
        .onChange(of: rack.state?.nudgeProgress) { _, progress in
            if progress != nil, rack.state?.program.marks.count == 2 { marksExpanded = true }
        }
        .onChange(of: draggingPanel) { _, active in
            if !active { panelTranslation = .zero }
        }
        .onChange(of: rack.state?.busy) { _, busy in
            if busy == true { dismissEditors() }
        }
        .onChange(of: rack.stopPending) { _, pending in
            if pending { dismissEditors() }
        }
        .onChange(of: allowsSetup) { _, allowed in
            if !allowed { dismissEditors() }
        }
        .alert(editor.title, isPresented: $editing) {
            TextField(editor == .template ? "Template name" : "Seconds", text: $entryText)
                .keyboardType(editor == .template ? .default : .decimalPad)
            Button(editor == .template ? "Save" : "Apply") {
                if editor == .template {
                    rack.saveTemplate(named: entryText)
                } else if editor == .nativeDelay {
                    rack.setNativeDelay(entryText)
                } else {
                    rack.setTimingText(entryText, isDelay: editor == .delay)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                editor == .template
                    ? "Saves timing only. Each use needs fresh focus marks."
                    : "Timing changes keep your current marks.")
        }
        .confirmationDialog(
            "Load timing template?",
            isPresented: Binding(
                get: { templateToLoad != nil }, set: { if !$0 { templateToLoad = nil } }
            ), titleVisibility: .visible
        ) {
            if let template = templateToLoad {
                Button("Load and reset marks", role: .destructive) {
                    rack.loadTemplate(template)
                    templateToLoad = nil
                }
            }
            Button("Cancel", role: .cancel) { templateToLoad = nil }
        } message: {
            Text("Loading timing clears the current marks. Capture A and B again.")
        }
        .confirmationDialog(
            "Close Focus Rack?", isPresented: $closingRack, titleVisibility: .visible
        ) {
            Button(
                rack.mode == .nativeAF ? "Close Focus Rack" : "Close and discard marks",
                role: rack.mode == .nativeAF ? nil : .destructive
            ) { rack.closePanel() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                (rack.mode == .nativeAF
                    ? "Saved picture targets are kept. " : "Session marks will be discarded. ")
                    + "Previous AF settings restore after recording and focus stop. Manual changes are kept."
            )
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(compact ? "focusRack.compact" : "focusRack.expanded")
    }

    private var modeSelector: some View {
        Menu {
            ForEach(FocusControlMode.allCases, id: \.self) { mode in
                Button {
                    rack.selectMode(mode)
                } label: {
                    Label(mode.title, systemImage: rack.mode == mode ? "checkmark" : "circle")
                }
                .accessibilityIdentifier("focusControl.mode." + mode.rawValue)
            }
        } label: {
            HStack(spacing: 3) {
                Text(rack.mode.title).font(.system(size: 12, weight: .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
            }
            .frame(width: 90, height: 44)
            .contentShape(Rectangle())
        }
        .disabled(!allowsSetup || !rack.canChangeMode)
        .accessibilityLabel("Focus mode")
        .accessibilityValue(rack.mode.title)
        .accessibilityIdentifier("focusControl.modePicker")
    }

    private var nativeAF: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact, rack.nativeAFBlocker != nil {
                Text(rack.nativeAFInstruction)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(rack.nativeAFBlocker == nil ? LiveDesign.text : .orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("focusControl.nativeAF.instruction")
            }
            if rack.nativeFocusPointLocked {
                Button {
                    rack.unlockNativeFocusPoint()
                } label: {
                    Label("Unlock focus point", systemImage: "lock.open")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(LiveDesign.accentDim, in: RoundedRectangle(cornerRadius: 8))
                .disabled(!allowsSetup || !rack.canUnlockNativeFocusPoint)
                .accessibilityIdentifier("focusControl.nativeAF.unlock")
            }
            if rack.nativeRack.selectingMark != nil {
                Button("Cancel target selection") {
                    rack.cancelNativeTarget()
                    rack.isExpanded = true
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .buttonStyle(.bordered)
                .accessibilityIdentifier("focusControl.nativeAF.cancelSelection")
            } else if !compact {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if rack.nativeAFBlocker == nil {
                            Text(rack.nativeAFInstruction)
                                .font(.system(size: 12, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("focusControl.nativeAF.instruction")
                        }
                        HStack(spacing: 8) {
                            nativeMark(.a)
                            nativeMark(.b)
                        }
                        HStack {
                            Label("Camera speed · g6", systemImage: "camera")
                                .font(.system(size: 11))
                                .foregroundStyle(LiveDesign.muted)
                            Spacer(minLength: 0)
                            optionsToggle
                        }
                        if optionsExpanded {
                            Button {
                                editor = .nativeDelay
                                entryText = rack.nativeRack.startDelay.formatted(.number)
                                editing = true
                            } label: {
                                HStack {
                                    Text("Start delay")
                                    Spacer(minLength: 0)
                                    Text("\(rack.nativeRack.startDelay.formatted(.number)) s")
                                        .monospacedDigit()
                                }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!allowsSetup || rack.nativeAFBusy)
                            .accessibilityIdentifier("focusControl.nativeAF.delay")
                            Text("Transition speed is set on the camera with g6.")
                                .foregroundStyle(LiveDesign.muted)
                            Text("Automatic setup: AF-F · Auto-area AF · Subject detection Off.")
                                .foregroundStyle(LiveDesign.muted)
                            Button("Focus settings") { rack.openFocusSettings() }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .buttonStyle(.bordered)
                                .disabled(
                                    !allowsSetup || rack.modeSwitchPending
                                        || rack.state?.busy == true
                                        || rack.nativeAFBusy
                                )
                                .accessibilityIdentifier("focusControl.nativeAF.settings")
                        }
                    }
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) {
                        $0.size.height
                    } action: {
                        nativeContentHeight = $0
                    }
                }
                .defaultScrollAnchor(.top)
                .id("focusControl.nativeAF.setup")
                .frame(
                    idealHeight: nativeContentHeight > 0 ? nativeContentHeight : nil,
                    maxHeight: nativeContentHeight > 0 ? nativeContentHeight : nil
                )
                .accessibilityIdentifier("focusRack.setup")
            }
            if rack.nativeRack.selectingMark == nil && !rack.nativeFocusPointLocked {
                nativeTransport
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityValue(rack.nativeAFInstruction)
        .accessibilityIdentifier("focusControl.nativeAF")
    }

    private func nativeMark(_ mark: NativeAFMark) -> some View {
        let saved = rack.nativeRack.target(for: mark) != nil
        let canSet = allowsSetup && rack.nativeAFBlocker == nil && !rack.nativeAFBusy
        let canGo = canSet && saved
        return VStack(spacing: 4) {
            Button {
                rack.armNativeTarget(mark)
            } label: {
                VStack(spacing: 1) {
                    HStack(spacing: 4) {
                        Text(mark.rawValue + (saved ? " set" : " not set"))
                            .fontWeight(.semibold)
                        if saved {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .accessibilityHidden(true)
                        }
                    }
                    Text(saved ? "Replace target" : "Set target").font(.system(size: 10))
                }
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .foregroundStyle(.white.opacity(canSet ? 1 : 0.35))
            .background(.white.opacity(canSet ? 0.1 : 0.03), in: RoundedRectangle(cornerRadius: 6))
            .disabled(!canSet)
            .accessibilityValue(saved ? "Target saved" : "Target not set")
            .accessibilityIdentifier("focusControl.nativeAF.set." + mark.rawValue)
            Button("Go to " + mark.rawValue) {
                rack.selectNativeTarget(mark, delayed: false)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(.white.opacity(canGo ? 1 : 0.3))
            .background(.white.opacity(canGo ? 0.16 : 0.03), in: RoundedRectangle(cornerRadius: 6))
            .disabled(!canGo)
            .accessibilityIdentifier("focusControl.nativeAF.go." + mark.rawValue)
        }
        .buttonStyle(.plain)
    }

    private var nativeTransport: some View {
        HStack(spacing: 6) {
            if rack.nativeRack.pendingRequest != nil {
                Button("Cancel delay") { rack.cancelNativeTarget() }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .background(.white.opacity(0.16), in: RoundedRectangle(cornerRadius: 7))
                    .accessibilityIdentifier("focusControl.nativeAF.cancelDelay")
            } else {
                nativePull("A→B", target: .b)
                nativePull("B→A", target: .a)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: 12, weight: .semibold))
    }

    private func nativePull(_ direction: String, target: NativeAFMark) -> some View {
        let enabled =
            allowsSetup && rack.nativeAFBlocker == nil && !rack.nativeAFBusy
            && rack.nativeRack.target(for: .a) != nil && rack.nativeRack.target(for: .b) != nil
        return Button {
            rack.selectNativeTarget(target, delayed: true)
        } label: {
            Text("\(rack.nativeIsRecording ? "Run" : "Rehearse") \(direction)")
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
        }
        .foregroundStyle(enabled ? Color.black : LiveDesign.muted)
        .background(
            enabled ? LiveDesign.accent : LiveDesign.glassBright.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .disabled(!enabled)
        .accessibilityHint("Selects the destination after the start delay. Recording is unchanged.")
        .accessibilityIdentifier("focusControl.nativeAF.pull." + (target == .b ? "aToB" : "bToA"))
    }

    private func dismissEditors() {
        editing = false
        templateToLoad = nil
        closingRack = false
    }

    private var header: some View {
        HStack(spacing: 4) {
            Button {
                if needsMoveAttention {
                    rack.setExpanded(true)
                    rack.revealAdmission = true
                }
            } label: {
                headerText.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                needsMoveAttention ? "Move needs attention" : "Move Focus Rack panel"
            )
            .accessibilityHint(
                "Drag this header to move the panel. Movement actions are also available."
            )
            .accessibilityIdentifier(
                needsMoveAttention ? "focusRack.moveAttention" : "focusRack.dragHandle"
            )
            .accessibilityAction(named: "Move panel left") {
                onMovePanel(.init(width: -80, height: 0))
            }
            .accessibilityAction(named: "Move panel right") {
                onMovePanel(.init(width: 80, height: 0))
            }
            .accessibilityAction(named: "Move panel up") {
                onMovePanel(.init(width: 0, height: -80))
            }
            .accessibilityAction(named: "Move panel down") {
                onMovePanel(.init(width: 0, height: 80))
            }
            .accessibilityAction(named: "Reset panel position", onResetPanel)
            .simultaneousGesture(
                DragGesture(minimumDistance: 8, coordinateSpace: .global)
                    .updating($draggingPanel) { _, state, _ in state = true }
                    .onChanged { value in
                        onMovePanel(
                            .init(
                                width: value.translation.width - panelTranslation.width,
                                height: value.translation.height - panelTranslation.height))
                        panelTranslation = value.translation
                    })
            modeSelector
            if !compact || allowsExpansion {
                Button {
                    rack.setExpanded(compact || !rack.isExpanded)
                } label: {
                    Image(systemName: compact ? "chevron.up" : "chevron.down")
                        .frame(width: 44, height: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(compact ? "Open focus rack setup" : "Hide focus rack setup")
                .disabled(rack.state?.nudgeProgress != nil)
                .accessibilityIdentifier("focusRack.expand")
            }
            Button {
                closingRack = true
            } label: {
                Image(systemName: "xmark").frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(
                !allowsSetup || rack.state?.busy == true || rack.stopPending
                    || rack.modeSwitchPending || rack.nativeAFBusy
            )
            .accessibilityLabel("Close Focus Rack")
            .accessibilityHint(
                rack.mode == .nativeAF
                    ? "Keeps saved picture targets. Restores previous AF settings when safe."
                    : "Discards session marks after confirmation."
            )
            .accessibilityIdentifier("focusRack.close")
        }
        .frame(minHeight: 44)
    }

    private var needsMoveAttention: Bool {
        rack.mode == .timedRack && rack.state?.admissionMessage != nil
            && rack.state?.capabilities.canEditTiming == true
            && !rack.stopPending
    }

    private var headerText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(
                rack.mode == .nativeAF
                    ? "⠿ FOCUS"
                    : compactPhase.map { "FOCUS RACK · \($0)" } ?? "⠿ FOCUS"
            )
            .font(.system(size: 11, weight: .bold))
            .accessibilityIdentifier("focusRack.phase")
            if rack.mode == .nativeAF {
                if compact {
                    Text(compactNativeStatus)
                        .font(.system(size: 11))
                        .accessibilityValue(rack.nativeAFInstruction)
                }
            } else if rack.afSettingsStatus != nil {
                Text(rack.afSettingsFailure == nil ? "Waiting for AF setup…" : "AF setup failed")
                    .font(.system(size: 11, weight: .medium))
                    .accessibilityIdentifier("focusRack.status")
            } else if compact, let instruction = rack.state?.recoveryInstruction {
                Text(instruction).font(.system(size: 11, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("focusRack.recovery")
            } else if compact, let warning = rack.state?.timingWarning {
                Text(compactTimingStatus)
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.orange)
                    .accessibilityValue(warning)
                    .accessibilityIdentifier("focusRack.timingWarning")
            } else if let state = rack.state,
                compact || state.busy || state.playbackInstruction != nil
            {
                Text(
                    rack.stopPending
                        ? "Stopping…"
                        : state.playbackInstruction
                            ?? (needsMoveAttention ? "Adjust timing" : status(state))
                )
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(needsMoveAttention ? .orange : .white)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("focusRack.status")
            }
        }
    }

    private var compactTimingStatus: String {
        guard let state = rack.state else { return "Timing warning" }
        if state.busy { return "Running late" }
        if state.phase == .complete, state.timingWarningIsEstimate != true,
            let actual = state.actualMovementDuration
        {
            return "Completed in \(actual.formatted(.number.precision(.fractionLength(0...2)))) s"
        }
        if state.timingWarningIsEstimate == true, let estimate = state.estimatedDuration {
            return "~\(estimate.formatted(.number.precision(.fractionLength(0...2)))) s expected"
        }
        return "Timing warning"
    }

    private var compactNativeStatus: String {
        if rack.nativeAFBlocker != nil { return "Needs attention" }
        if let mark = rack.nativeRack.selectingMark { return "Tap subject " + mark.rawValue }
        if rack.nativeRack.pendingRequest != nil { return "Start delay…" }
        if let request = rack.nativeRack.dispatchedRequest {
            return "Selecting " + request.mark.rawValue
        }
        if let mark = rack.nativeRack.lastSelectedMark {
            return "Target " + mark.rawValue + " selected"
        }
        return "Set targets"
    }

    private var compactPhase: String? {
        guard compact else { return nil }
        switch rack.state?.phase {
        case .uncertain: return "Reference uncertain"
        case .stopUnconfirmed: return "Stop unconfirmed"
        default: return nil
        }
    }

    private func recovery(_ instruction: String) -> some View {
        Text(instruction).font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("focusRack.recovery")
    }

    private var transport: some View {
        VStack(spacing: 4) {
            if !compact, let warning = rack.state?.timingWarning,
                rack.state?.busy == true || rack.state?.timingWarningIsEstimate != true
            {
                Text(warning).font(.system(size: 11)).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("focusRack.timingWarning")
            }
            if showsStop && !compact && rack.state?.nudgeProgress == nil {
                Text("Stop cancels focus movement only.")
                    .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                    .accessibilityIdentifier("focusRack.stopHint")
            }
            HStack(spacing: 6) {
                if compactPositioning, let state = rack.state {
                    reposition("A", enabled: state.capabilities.canGoToA)
                    reposition("B", enabled: state.capabilities.canGoToB)
                } else if showsTimedPulls {
                    pull(.aToB, action: rack.state?.pullAToB)
                    pull(.bToA, action: rack.state?.pullBToA)
                } else {
                    Button {
                        rack.performPrimary()
                    } label: {
                        VStack(spacing: 1) {
                            Text(
                                rack.stopPending
                                    ? "Stopping…" : rack.state?.primary.title ?? "Set marks"
                            )
                            .font(.system(size: 13, weight: .semibold))
                            if !rack.stopPending, rack.state?.preparingLens != true,
                                rack.state?.phase != .stopping,
                                let detail = rack.state?.primary.detail
                            {
                                Text(detail).font(.system(size: 11))
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    .disabled(
                        rack.stopPending || rack.state?.nudgeProgress != nil
                            || rack.state?.primary.enabled != true
                            || (!allowsSetup && rack.state?.primary.kind != "pause")
                    )
                    .accessibilityLabel(
                        rack.stopPending ? "Stopping…" : rack.state?.primary.title ?? "Set marks"
                    )
                    .accessibilityValue(
                        rack.state?.phase == .stopping
                            ? ""
                            : rack.state?.preparingLens == true
                                ? "Untimed lens preparation" : rack.state?.primary.detail ?? ""
                    )
                    .accessibilityIdentifier("focusRack.primary")
                }
                if showsStop {
                    Button(role: .destructive) {
                        rack.stop()
                    } label: {
                        Text(
                            rack.stopPending || rack.state?.phase == .stopping
                                ? "Stopping…" : "Stop"
                        )
                        .font(.system(size: 13, weight: .bold))
                        .frame(minWidth: 70, minHeight: 44).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).foregroundStyle(.white)
                    .background(.red.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
                    .disabled(rack.stopPending || rack.state?.capabilities.canStop != true)
                    .accessibilityLabel("Stop focus movement")
                    .accessibilityHint(
                        "Cancels the delay or movement. Recording continues; focus stays where it stops."
                    )
                    .accessibilityIdentifier("focusRack.stop")
                }
            }
        }
    }

    private var showsStop: Bool {
        rack.state?.capabilities.canStop == true || rack.stopPending
            || rack.state?.phase == .stopping
    }

    private var compactPositioning: Bool {
        compact && allowsSetup && showsTimedPulls
            && rack.state?.pullAToB?.enabled != true && rack.state?.pullBToA?.enabled != true
    }

    private var showsTimedPulls: Bool {
        guard let state = rack.state else { return false }
        return
            (state.nudgeProgress != nil
            || (!rack.stopPending && !state.busy && state.referenceValid))
            && state.program.marks.count == 2
    }

    private func pull(_ direction: FocusRackDirection, action: FocusRackPrimaryAction?) -> some View
    {
        Button {
            rack.run(direction)
        } label: {
            VStack(spacing: 1) {
                Text(action?.title ?? (direction == .aToB ? "A→B" : "B→A"))
                    .font(.system(size: 12, weight: .semibold))
                if compact, let detail = action?.detail { Text(detail).font(.system(size: 10)) }
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(
            action?.enabled == true
                ? (preparationIsPrimary ? LiveDesign.text : Color.black) : LiveDesign.muted
        )
        .background(
            action?.enabled == true && !preparationIsPrimary
                ? LiveDesign.accent : LiveDesign.glassBright.opacity(0.45),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8).stroke(LiveDesign.hairline, lineWidth: 1)
        }
        .disabled(
            !allowsSetup || action?.enabled != true || rack.afSettingsPending
                || rack.afSettingsFailure != nil
        )
        .accessibilityLabel(action?.title ?? "Set A and B")
        .accessibilityValue(action?.detail ?? "")
        .accessibilityHint(action?.disabledReason ?? "Uses the selected duration and delay.")
        .accessibilityIdentifier("focusRack.pull." + direction.rawValue)
    }

    private func reposition(_ id: String, enabled: Bool) -> some View {
        Button {
            rack.goTo(id)
        } label: {
            VStack(spacing: 1) {
                Text("Go to \(id)").font(.system(size: 12, weight: .semibold))
                Text("Fast reposition").font(.system(size: 10))
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .disabled(
            !enabled || rack.stopPending || rack.afSettingsPending || rack.afSettingsFailure != nil
        )
        .accessibilityLabel("Go to \(id)").accessibilityValue("Fast reposition")
        .accessibilityIdentifier("focusRack.go.\(id)")
    }

    private func positions(_ state: FocusRackState) -> some View {
        let summary: String
        if state.stepPosition == nil {
            summary = "Positions unknown · Reset marks"
        } else {
            let a = state.program.marks.first { $0.id == "A" }?.stepPosition.description ?? "—"
            let b = state.program.marks.first { $0.id == "B" }?.stepPosition.description ?? "—"
            let current = state.stepPosition.map(String.init) ?? "—"
            summary = "A \(a) · B \(b) · Now \(current)"
        }
        var accessibilityValue = "Relative focus steps"
        #if DEBUG
            if case .nudge(let near, let steps) = rack.simulatedNudgeIntents.last {
                accessibilityValue += " · Last \(near ? "Near" : "Far") \(steps)"
            }
        #endif
        return Text(summary)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(summary)
            .accessibilityValue(accessibilityValue)
            .accessibilityIdentifier("focusRack.positions")
    }

    private func marks(_ state: FocusRackState) -> some View {
        HStack(spacing: 8) {
            mark("A", state: state, enabled: state.capabilities.canCaptureA)
            mark("B", state: state, enabled: state.capabilities.canCaptureB)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("focusRack.marks")
    }

    private func mark(_ id: String, state: FocusRackState, enabled: Bool) -> some View {
        let captured = state.program.marks.first { $0.id == id }
        let title = captured == nil ? "Set \(id)" : "Go to \(id)"
        let canGo = id == "A" ? state.capabilities.canGoToA : state.capabilities.canGoToB
        return Button {
            if captured == nil { rack.capture(id) } else { rack.goTo(id) }
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.08))
                    if let image = rack.thumbnail(for: id) {
                        Image(uiImage: image).resizable().scaledToFill()
                    } else {
                        Text(id).font(.system(size: 18, weight: .semibold))
                    }
                }
                .frame(width: 36, height: 40).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(alignment: .bottomTrailing) {
                    if captured != nil {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12)).foregroundStyle(LiveDesign.good)
                            .background(.black, in: Circle()).padding(2)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityIdentifier("focusRack.thumbnail.\(id)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    if captured != nil {
                        Text("Fast reposition").font(.system(size: 10)).foregroundStyle(
                            .white.opacity(0.7))
                    }
                    if captured == nil {
                        Text("Not set").font(.system(size: 11)).foregroundStyle(LiveDesign.muted)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 6).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .disabled(
            !allowsSetup || (captured == nil ? !enabled : !canGo) || rack.stopPending
                || rack.capturingMark != nil
        )
        .accessibilityLabel(title)
        .accessibilityValue(captured == nil ? "Not set" : "Fast reposition")
        .accessibilityIdentifier("focusRack." + (captured == nil ? "capture." : "go.") + id)
    }

    private func nudgeControls(_ state: FocusRackState) -> some View {
        let near = state.nudgeProgress?.towardNear ?? rack.nudgeTowardNear
        return VStack(spacing: 4) {
            HStack(spacing: 4) {
                nudgeDirection("Near", towardNear: true, selected: near, state: state)
                nudgeDirection("Far", towardNear: false, selected: !near, state: state)
            }
            HStack(spacing: 4) {
                ForEach([1, 10, 100], id: \.self) { steps in
                    nudge(state, near: near, steps: steps)
                }
            }
        }
    }

    private func nudgeDirection(
        _ title: String, towardNear: Bool, selected: Bool, state: FocusRackState
    ) -> some View {
        Button {
            rack.nudgeTowardNear = towardNear
        } label: {
            Text(title).font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(selected ? 0.22 : 0.06), in: RoundedRectangle(cornerRadius: 6))
        .disabled(!allowsSetup || state.busy || state.nudgeProgress != nil)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(selected ? "Selected" : "")
        .accessibilityIdentifier("focusRack.direction." + (towardNear ? "near" : "far"))
    }

    private func nudge(_ state: FocusRackState, near: Bool, steps: Int) -> some View {
        let amount = near ? "−\(steps)" : "+\(steps)"
        let progress = state.nudgeProgress.flatMap {
            $0.towardNear == near && $0.steps == steps ? $0.percent : nil
        }
        return Button {
            rack.nudge(near: near, steps: steps)
        } label: {
            Text(progress.map { "\($0)%" } ?? amount)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .disabled(!allowsSetup || !state.capabilities.canNudge)
        .accessibilityLabel("\(near ? "Near" : "Far") \(amount)")
        .accessibilityValue(progress.map { "\($0)%" } ?? "")
        .accessibilityIdentifier("focusRack.nudge.\(steps)")
    }

    private func move(_ state: FocusRackState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if markEditorVisible(state) {
                VStack(alignment: .leading, spacing: 6) {
                    nudgeControls(state)
                    positions(state)
                    HStack(spacing: 8) {
                        ForEach(state.program.marks, id: \.id) { mark in
                            Button("Replace " + mark.id) { rack.capture(mark.id) }
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .disabled(
                                    !allowsSetup
                                        || !(mark.id == "A"
                                            ? state.capabilities.canCaptureA
                                            : state.capabilities.canCaptureB)
                                )
                                .accessibilityIdentifier("focusRack.capture." + mark.id)
                        }
                        Button(role: .destructive) {
                            rack.reset()
                        } label: {
                            Text("Reset marks").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .disabled(!allowsSetup || !state.capabilities.canReset)
                        .accessibilityIdentifier("focusRack.reset")
                    }
                }
                .padding(8)
                .background(
                    LiveDesign.glassBright.opacity(0.45), in: RoundedRectangle(cornerRadius: 8)
                )
            }
            HStack(spacing: 8) {
                timing(
                    "Target duration", seconds: state.transition.duration, id: "duration",
                    state: state)
                if let estimate = state.estimatedDuration,
                    abs(estimate - state.transition.duration) > 0.0005
                {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Expected").font(.system(size: 11)).foregroundStyle(LiveDesign.muted)
                        Text("~\(estimate.formatted(.number.precision(.fractionLength(0...2)))) s")
                            .font(.system(size: 15, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.orange)
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel(state.playbackDetail)
                    .accessibilityIdentifier("focusRack.duration.estimate")
                } else {
                    Label("Linear", systemImage: "arrow.right")
                        .font(.system(size: 11)).foregroundStyle(LiveDesign.muted)
                        .frame(maxWidth: .infinity)
                }
            }
            if state.preparationRecommended == true && (!state.busy || state.nudgeProgress != nil) {
                preparation(state, prominent: true)
            }
            HStack(spacing: 8) {
                Button {
                    marksExpanded.toggle()
                } label: {
                    Label(
                        markEditorVisible(state) ? "Hide marks" : "Edit marks",
                        systemImage: "slider.horizontal.3"
                    )
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(
                    state.nudgeProgress != nil || state.program.marks.count < 2
                        || !state.referenceValid
                )
                .accessibilityValue(markEditorVisible(state) ? "Expanded" : "Collapsed")
                .accessibilityIdentifier("focusRack.editMarks")
                optionsToggle
            }
            if optionsExpanded {
                VStack(alignment: .leading, spacing: 8) {
                    timing(
                        "Start delay", seconds: state.transition.delay, id: "delay", state: state)
                    if state.preparationRecommended != true {
                        preparation(state, prominent: false)
                    }
                    templates(state)
                    Button("Focus settings") { rack.openFocusSettings() }
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .disabled(!allowsSetup || state.busy)
                }
            }
        }
    }

    private var optionsToggle: some View {
        Button {
            optionsExpanded.toggle()
        } label: {
            HStack(spacing: 5) {
                Text("Options")
                Image(systemName: optionsExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 12, weight: .medium))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(rack.state?.nudgeProgress != nil)
        .accessibilityValue(optionsExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("focusRack.options")
    }

    private func markEditorVisible(_ state: FocusRackState) -> Bool {
        marksExpanded || state.program.marks.count < 2 || !state.referenceValid
            || state.nudgeProgress != nil
    }

    private var preparationIsPrimary: Bool {
        rack.state?.preparationRecommended == true && rack.state?.calibration?.enabled == true
            && rack.state?.busy != true && allowsSetup && !rack.stopPending
            && !rack.afSettingsPending && rack.afSettingsFailure == nil
    }

    @ViewBuilder private func preparation(_ state: FocusRackState, prominent: Bool) -> some View {
        if let calibration = state.calibration {
            Button {
                rack.calibrate()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 16, weight: .medium))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(
                            prominent ? calibration.title + " · measure timing" : calibration.title
                        )
                        .font(.system(size: 12, weight: .semibold))
                        Text(calibration.detail ?? "One pass between A and B")
                            .font(.system(size: 10))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    if prominent { Image(systemName: "arrow.right").font(.system(size: 11)) }
                }
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(
                prominent && preparationIsPrimary
                    ? Color.black : prominent ? LiveDesign.accent : LiveDesign.text
            )
            .background(
                prominent && preparationIsPrimary
                    ? LiveDesign.accent
                    : prominent ? LiveDesign.accentDim : LiveDesign.glassBright.opacity(0.45),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .disabled(
                !allowsSetup || !calibration.enabled || state.busy || rack.stopPending
                    || rack.afSettingsPending || rack.afSettingsFailure != nil
            )
            .accessibilityHint(
                "Measures this lens in one pass to the other mark. Recording is unchanged."
            )
            .accessibilityIdentifier("focusRack.calibrate")
        }
    }

    private func timing(
        _ title: String, seconds: Double, id: String, state: FocusRackState
    ) -> some View {
        Button {
            editor = id == "delay" ? .delay : .duration
            entryText = seconds.formatted(.number.precision(.fractionLength(0...6)))
            editing = true
        } label: {
            VStack(spacing: 3) {
                Text(title).font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Text("\(seconds.formatted(.number.precision(.fractionLength(0...3)))) s")
                    .font(.system(size: 15, weight: .semibold, design: .monospaced))
            }
            .frame(maxWidth: .infinity, minHeight: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
        .disabled(!allowsSetup || !state.capabilities.canEditTiming)
        .accessibilityLabel("Edit " + title.lowercased())
        .accessibilityValue("\(seconds) seconds")
        .accessibilityIdentifier("focusRack.\(id).value")
    }

    private func templates(_ state: FocusRackState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Menu {
                Button("Save current timing…") {
                    entryText = ""
                    editor = .template
                    editing = true
                }
                ForEach(Array(rack.templates.enumerated()), id: \.offset) { _, template in
                    Button(template.name) { templateToLoad = template }
                }
                if !rack.templates.isEmpty {
                    Menu("Delete template") {
                        ForEach(Array(rack.templates.enumerated()), id: \.offset) {
                            index, template in
                            Button(template.name, role: .destructive) {
                                rack.deleteTemplate(at: index)
                            }
                        }
                    }
                }
            } label: {
                Label("Timing templates", systemImage: "bookmark")
                    .font(.system(size: 13, weight: .medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(!allowsSetup || !state.capabilities.canEditTiming)
            .accessibilityIdentifier("focusRack.templates")
            Text("Templates save timing only. Capture fresh marks after loading.")
                .font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func status(_ state: FocusRackState) -> String {
        if state.phase == .countdown {
            return
                "Starts in \(state.remainingDelay.formatted(.number.precision(.fractionLength(1))))s"
        }
        if state.totalSteps > 0 {
            let percent = Int(
                (100 * Double(state.completedSteps) / Double(state.totalSteps)).rounded())
            let title =
                state.preparingLens == true && state.phase == .moving
                ? "Preparing lens" : state.phase.title
            return "\(title) · \(percent)%"
        }
        return state.phase.title
    }
}
