import MonitorUI
import OpenZCineCore
import SwiftUI

/// Stacked scope panels for the portrait v2 shell. Renders the first ≤2 enabled scope tools in
/// canonical order (`[.waveform, .parade, .histogram, .trafficLights]` ∩ visible), each panel
/// filling an equal vertical share of the zone. No tap-to-swap — what's enabled is what shows.
///
/// Reuses the exact plots the landscape floating panels use (`NikonScopePlot` for
/// waveform/parade/histogram, shared `MonitorTrafficLightsMeter` for traffic lights) and the same sample
/// sources (`model.scopeAssist`). Because the shown kinds are exactly
/// the live tools switched on in the shared assist state, the frame-loop sampler already meters
/// them, so no `portraitScopesFrameTool` seam is needed.
struct PortraitScopesStack: View {
    @Environment(NativeAppModel.self) private var model

    /// The scope kinds to render: the ≤2 most-recently-activated scopes (recency-based selection,
    /// R8), shown in canonical order. Older active scopes stay remembered and reappear in fill.
    /// Photography drops the cinema-only scopes (histogram survives — it applies to stills).
    private var kinds: [MonitorAssistTool] {
        model.renderedFitScopes
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
        if kind == .trafficLights {
            // The portrait stack is full-width, so spread and widen the bars.
            MonitorTrafficLightsMeter(reading: model.scopeAssist.traffic, fillsWidth: true)
        } else {
            GeometryReader { proxy in
                NikonScopePlot(
                    tool: kind, panels: model.scopePanels, bundle: model.scopeAssist,
                    mapping: model.exposureSignalMapping, size: proxy.size)
            }
        }
    }
}
