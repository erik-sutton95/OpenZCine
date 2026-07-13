import SwiftUI

/// Stacked scope panels for the portrait v2 shell. Renders the first ≤2 enabled scope tools in
/// canonical order (`[.waveform, .parade, .histogram, .trafficLights]` ∩ visible), each panel
/// filling an equal vertical share of the zone. No tap-to-swap — what's enabled is what shows.
///
/// Reuses the exact plots the landscape floating panels use (`ScopeMini` for
/// waveform/parade/histogram, `TrafficLightsMeterMini` for traffic lights) and the same sample
/// sources (`model.scopeAssist`). Because the shown kinds are exactly
/// the enabled `liveViewVisibleAssistTools`, the frame-loop sampler already meters them via
/// `visibleAssistTools(for: .liveView)` — no `portraitScopesFrameTool` seam needed.
struct PortraitScopesStack: View {
    @Environment(NativeAppModel.self) private var model

    /// The scope kinds to render: the ≤2 most-recently-activated scopes (recency-based selection,
    /// R8), shown in canonical order. Older active scopes stay remembered and reappear in fill.
    private var kinds: [MonitorAssistTool] {
        model.preferences.displayedFitScopes
    }

    var body: some View {
        VStack(spacing: 8) {
            ForEach(kinds) { kind in
                panel(for: kind)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    @ViewBuilder private func panel(for kind: MonitorAssistTool) -> some View {
        let scopes = model.assistConfiguration.scopes
        switch kind {
        case .waveform:
            ScopeMini(
                title: "Wave", systemImage: "waveform.path.ecg", style: .waveform,
                assist: model.scopeAssist, scopes: scopes,
                mapping: model.exposureSignalMapping)
        case .parade:
            ScopeMini(
                title: "Parade", systemImage: "chart.bar.xaxis", style: .parade,
                assist: model.scopeAssist, scopes: scopes,
                mapping: model.exposureSignalMapping)
        case .histogram:
            // Verbatim from the histogram `MovablePanel` (MonitorOverlays.swift:64) — no GPU path.
            ScopeMini(
                title: "Histo", systemImage: "chart.xyaxis.line", style: .histogram,
                assist: model.scopeAssist, scopes: scopes,
                mapping: model.exposureSignalMapping)
        case .vectorscope:
            // CbCr bins always accumulate from CPU point samples — no GPU scatter path.
            ScopeMini(
                title: "Vector", systemImage: "circle.grid.cross", style: .vectorscope,
                assist: model.scopeAssist,
                scopes: scopes,
                mapping: model.exposureSignalMapping)
        default:
            // `.trafficLights` — the portrait stack is full-width, so spread + widen the bars.
            TrafficLightsMeterMini(reading: model.scopeAssist.trafficLights, fillsWidth: true)
        }
    }
}

/// REC options quick-access for the portrait v2 shell: a glass button over the feed's top-right
/// (below the overlaid top bar) that opens a compact two-item popup — Resolution·Framerate and
/// Codec — each routing straight into the existing camera pickers via `model.showPicker`.
struct PortraitRecOptionsButton: View {
    @Environment(NativeAppModel.self) private var model
    @State private var popoverOpen = false

    var body: some View {
        Button {
            popoverOpen = true
        } label: {
            Image(systemName: "video.badge.waveform")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(LiveDesign.text.opacity(0.86))
                .frame(width: 40, height: 40)
                .liquidGlass(in: Circle())
        }
        .buttonStyle(.zcTapTarget)
        .popover(isPresented: $popoverOpen, attachmentAnchor: .point(.bottomTrailing)) {
            recOptionsMenu
                .presentationCompactAdaptation(.popover)
        }
    }

    private var recOptionsMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            menuItem(title: "Resolution · Framerate") {
                model.showPicker(.resolution)
            }
            Divider().overlay(LiveDesign.hairline)
            menuItem(title: "Codec") {
                model.showPicker(.codec)
            }
        }
        .frame(width: 220)
        .background(LiveDesign.glass)
    }

    private func menuItem(title: String, action: @escaping () -> Void) -> some View {
        Button {
            popoverOpen = false
            action()
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(LiveDesign.text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
    }
}
