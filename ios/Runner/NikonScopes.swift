import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit

/// The shared Pocket / Insta scope panel stores (options, size and place per orientation) under
/// Nikon keys. The crush/clip compensation stays on the shared assist state, which the Nikon
/// traffic-lights meter reads.
@MainActor
final class NikonScopePanels {
    static let waveformKey = "OpenZCine.WaveformAssist.v1"
    static let paradeKey = "OpenZCine.ParadeAssist.v1"
    static let vectorscopeKey = "OpenZCine.VectorscopeAssist.v1"
    static let histogramKey = "OpenZCine.HistogramAssist.v1"
    static let trafficLightsKey = "OpenZCine.TrafficLightsAssist.v1"
    /// The Nikon blobs this replaced: scope options inside the assist configuration, and the
    /// floating panel centres.
    static let legacyConfigurationKey = "assistConfiguration.v1"
    static let legacyPositionsKey = "movablePanelPositions.v1"
    /// The Nikon floating panel ids, still accepted by the demo harness.
    static let legacyPanelIDs: [String: MonitorAssistTool] = [
        "wave": .waveform, "parade": .parade, "vector": .vectorscope, "histo": .histogram,
        "traffic-lights": .trafficLights,
    ]

    let waveform: MonitorScopePanelStore<MonitorWaveformOptions>
    let parade: MonitorScopePanelStore<MonitorParadeOptions>
    let vectorscope: MonitorScopePanelStore<MonitorVectorscopeOptions>
    let histogram: MonitorScopePanelStore<MonitorHistogramOptions>
    let trafficLights: MonitorTrafficLightsPreferenceStore

    /// A first launch on the shared stores copies the operator's Nikon scope settings once.
    init(storage: UserDefaults = .standard) {
        let firstRun = storage.data(forKey: Self.waveformKey) == nil
        let legacy = firstRun ? Self.legacy(storage) : nil
        waveform = MonitorScopePanelStore(
            options: legacy?.waveform, storage: storage, key: Self.waveformKey)
        parade = MonitorScopePanelStore(
            options: legacy?.parade, storage: storage, key: Self.paradeKey)
        vectorscope = MonitorScopePanelStore(
            options: legacy?.vectorscope, storage: storage, key: Self.vectorscopeKey)
        histogram = MonitorScopePanelStore(
            options: legacy?.histogram, storage: storage, key: Self.histogramKey)
        trafficLights = MonitorTrafficLightsPreferenceStore(
            storage: storage, key: Self.trafficLightsKey, histogram: histogram)
        guard let legacy else { return }
        trafficLights.scale = legacy.trafficLightsScale
        trafficLights.position = legacy.trafficLightsCenter
        for store in [waveform, parade, vectorscope, histogram] as [any NikonScopePanelSlot] {
            store.persist()
        }
        trafficLights.persist()
    }

    private struct Legacy {
        var waveform: MonitorWaveformOptions
        var parade: MonitorParadeOptions
        var vectorscope: MonitorVectorscopeOptions
        var histogram: MonitorHistogramOptions
        var trafficLightsScale: Double
        var trafficLightsCenter: MonitorScopeStoredCenter?
    }

    /// Reads the Nikon blobs as raw JSON, so a malformed value only loses itself. Saved centres
    /// were landscape (portrait fit stacks its scopes), so they fill the landscape slot.
    private static func legacy(_ storage: UserDefaults) -> Legacy {
        func object(_ key: String) -> [String: Any] {
            storage.data(forKey: key)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let configuration = object(legacyConfigurationKey)
        let scopes = configuration["scopes"] as? [String: Any] ?? [:]
        let positions = object(legacyPositionsKey)
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
        }
        // A saved scale stays explicit, as on Pocket; an unsaved one takes the shared auto size.
        func scale(_ key: String) -> Double? { number(scopes[key]) }
        func guides(_ key: String) -> MonitorScopeGuides {
            let lines = scopes[key] as? [String: Any] ?? [:]
            return MonitorScopeGuides(
                clip: lines["clip"] as? Bool ?? true, crush: lines["crush"] as? Bool ?? true,
                middle: lines["middle"] as? Bool ?? true)
        }
        // Waveform and parade brightness saved before calibration version 2 was a quarter of
        // today's scale.
        let calibrated = (scopes["waveformParadeBrightnessCalibrationVersion"] as? Int ?? 0) >= 2
        func traceBrightness(_ key: String) -> Int {
            guard let stored = number(scopes[key]) else {
                return MonitorWaveformOptions.defaultBrightness
            }
            return Int(min(max(calibrated ? stored : stored * 4, 0), 200))
        }
        func center(_ id: String) -> MonitorScopeStoredCenter? {
            guard let stored = positions[id] as? [String: Any],
                let x = number(stored["xFraction"]), let y = number(stored["yFraction"])
            else { return nil }
            return MonitorScopeStoredCenter(xFraction: x, yFraction: y)
        }
        return Legacy(
            waveform: MonitorWaveformOptions(
                mode: (scopes["waveformMode"] as? String).flatMap(MonitorWaveformMode.init) ?? .rgb,
                brightness: traceBrightness("waveformBrightness"),
                guides: guides("waveformGuides"), scale: scale("waveformScale") ?? 1,
                hasCustomScale: scale("waveformScale") != nil, storedCenter: center("wave")),
            parade: MonitorParadeOptions(
                mode: (scopes["paradeMode"] as? String).flatMap(MonitorParadeMode.init) ?? .rgb,
                brightness: traceBrightness("paradeBrightness"),
                guides: guides("paradeGuides"), scale: scale("paradeScale") ?? 1,
                hasCustomScale: scale("paradeScale") != nil, storedCenter: center("parade")),
            vectorscope: MonitorVectorscopeOptions(
                zoom: (scopes["vectorscopeZoom"] as? String).flatMap(MonitorVectorscopeZoom.init)
                    ?? .x1,
                brightness: number(scopes["vectorscopeBrightness"]).map { Int($0) }
                    ?? MonitorVectorscopeOptions.defaultBrightness,
                scale: scale("vectorscopeScale") ?? 1,
                hasCustomScale: scale("vectorscopeScale") != nil,
                storedCenter: center("vector")),
            histogram: MonitorHistogramOptions(
                trafficLights: scopes["histogramTrafficLights"] as? Bool ?? true,
                scale: scale("histogramScale") ?? 1, hasCustomScale: scale("histogramScale") != nil,
                storedCenter: center("histo")),
            trafficLightsScale: min(
                max(number((configuration["trafficLights"] as? [String: Any])?["scale"]) ?? 1, 0.6),
                1.6),
            trafficLightsCenter: center("traffic-lights"))
    }
}

/// A floating scope's saved size and place, per orientation.
@MainActor
protocol NikonScopePanelSlot: AnyObject {
    func scale(in canvas: CGRect) -> Double
    func setScale(_ scale: Double)
    func storedCenter(in canvas: CGRect) -> MonitorScopeStoredCenter?
    func store(center: CGPoint, in canvas: CGRect)
    func persist()
}

extension MonitorScopePanelStore: NikonScopePanelSlot {
    func scale(in canvas: CGRect) -> Double { presentationScale(in: canvas) }

    func store(center: CGPoint, in canvas: CGRect) {
        var next = options
        let stored = MonitorScopeStoredCenter(center: center, in: canvas)
        if MonitorScopeCanvasSlot.forBounds(canvas) == .portrait {
            next.storedCenterPortrait = stored
        } else {
            next.storedCenter = stored
        }
        options = next
    }
}

extension MonitorTrafficLightsPreferenceStore: NikonScopePanelSlot {
    func scale(in _: CGRect) -> Double { scale }

    func setScale(_ value: Double) {
        scale = min(max(value, 0.6), 1.6)
        persist()
    }

    func storedCenter(in canvas: CGRect) -> MonitorScopeStoredCenter? {
        MonitorScopeCanvasSlot.pick(position, positionPortrait, in: canvas)
    }

    func store(center: CGPoint, in canvas: CGRect) {
        MonitorScopeCanvasSlot.assign(
            &position, &positionPortrait, in: canvas,
            MonitorScopeStoredCenter(center: center, in: canvas))
        persist()
    }
}

/// The shared movable scope panel (direct drag, hold for options, corner resize) over one
/// shared store. Unplaced panels start at the canvas centre, as on Pocket.
struct NikonScopePanel<Content: View>: View {
    @Environment(NativeAppModel.self) private var model
    let slot: any NikonScopePanelSlot
    let tool: MonitorAssistTool
    let base: CGSize
    let canvas: CGRect
    var clearance = EdgeInsets()
    let onOptions: (MonitorAssistTool) -> Void
    @ViewBuilder let content: (CGSize) -> Content
    @State private var session: CGPoint?

    var body: some View {
        let bounds = MonitorScopePanelPlacement.bounds(in: canvas, clearance: clearance)
        let scale = slot.scale(in: canvas)
        let layout = MonitorScopePanelLayout(
            baseSize: base,
            preferredSize: CGSize(
                width: (base.width * scale).rounded(), height: (base.height * scale).rounded()),
            center: session ?? slot.storedCenter(in: canvas)?.center(in: canvas)
                ?? CGPoint(x: canvas.midX, y: canvas.midY),
            scale: scale, canvas: canvas, movementBounds: bounds)
        MonitorMovableScopePanel(
            layout: layout, enabled: !model.interfaceLocked,
            resizeLabel: "Resize \(tool.title.lowercased())",
            onMove: { event in
                switch event {
                case .began(let point), .changed(let point): session = point
                case .ended:
                    if let session { slot.store(center: session, in: canvas) }
                    session = nil
                case .cancelled: session = nil
                }
            },
            onResize: { slot.setScale($0) },
            onOpenOptions: { _ in onOptions(tool) },
            onConfirm: {
                guard model.preferences.hapticsEnabled else { return }
                UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 1)
            },
            content: { content(layout.size) })
    }
}

/// One scope plot in the shared plate, drawn on this camera's exposure axis (the Nikon typed
/// extension: N-Log, Log3G10 and the ISO-dependent clip).
struct NikonScopePlot: View {
    let tool: MonitorAssistTool
    let panels: NikonScopePanels
    let bundle: ScopeAssistBundle
    let mapping: ExposureSignalMapping
    let size: CGSize

    /// Waveform and parade trace intensity: 100% draws at a quarter, as on Pocket.
    nonisolated static func traceIntensity(_ brightness: Int) -> Double {
        Double(MonitorWaveformOptions.clampedBrightness(brightness)) / 400
    }

    var body: some View {
        switch tool {
        case .waveform:
            let options = panels.waveform.options
            MonitorScopePanelPlate(
                title: "Wave", chip: options.mode.rawValue.uppercased(), size: size
            ) {
                MonitorWaveformScopePlot(
                    samples: bundle.samples, trail: bundle.trailSamples,
                    mode: .waveform(options.mode),
                    axis: mapping.scopeLevelAxis, revision: bundle.revision,
                    intensity: Self.traceIntensity(options.brightness), guides: options.guides,
                    size: size)
            }
        case .parade:
            let options = panels.parade.options
            MonitorScopePanelPlate(
                title: "Parade", chip: options.mode.rawValue.uppercased(), size: size
            ) {
                MonitorWaveformScopePlot(
                    samples: bundle.samples, trail: bundle.trailSamples,
                    mode: .parade(options.mode),
                    axis: mapping.scopeLevelAxis, revision: bundle.revision,
                    intensity: Self.traceIntensity(options.brightness), guides: options.guides,
                    size: size)
            }
        case .vectorscope:
            let options = panels.vectorscope.options
            MonitorScopePanelPlate(
                title: "Vector", chip: "MON · \(options.zoom.rawValue.uppercased())", size: size
            ) {
                MonitorVectorscopeScopePlot(
                    points: bundle.vectorscopePoints, trail: bundle.trailVectorscopePoints,
                    zoom: options.zoom, brightness: options.brightness, revision: bundle.revision)
            }
        case .histogram:
            MonitorScopePanelPlate(title: "Histo", chip: "RGBL", size: size) {
                MonitorHistogramScopePlot(
                    display: bundle.histogramDisplay, traffic: bundle.traffic,
                    showTrafficLights: panels.histogram.options.trafficLights)
            }
        case .trafficLights:
            MonitorTrafficLightsMeter(reading: bundle.traffic).frame(
                width: size.width, height: size.height)
        default:
            EmptyView()
        }
    }
}

/// The floating scopes for one picture, live or playback.
struct NikonScopeOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let tools: Set<MonitorAssistTool>
    let bundle: ScopeAssistBundle
    let mapping: ExposureSignalMapping
    let canvas: CGRect
    var clearance = EdgeInsets()
    let onOptions: (MonitorAssistTool) -> Void

    /// The floating scopes, in the order they stack.
    private static let floating: [MonitorAssistTool] = [
        .waveform, .parade, .vectorscope, .histogram, .trafficLights,
    ]

    var body: some View {
        let panels = model.scopePanels
        ForEach(Self.floating.filter(tools.contains), id: \.self) { tool in
            NikonScopePanel(
                slot: panels.slot(for: tool), tool: tool, base: Self.base(tool), canvas: canvas,
                clearance: clearance, onOptions: onOptions
            ) { size in
                NikonScopePlot(
                    tool: tool, panels: panels, bundle: bundle, mapping: mapping, size: size)
            }
        }
    }

    private static func base(_ tool: MonitorAssistTool) -> CGSize {
        switch tool {
        case .parade: MonitorScopePanelSize.parade
        case .vectorscope: MonitorScopePanelSize.vectorscope
        case .histogram: MonitorScopePanelSize.histogram
        case .trafficLights: MonitorScopePanelSize.trafficLights
        default: MonitorScopePanelSize.waveform
        }
    }
}

extension NikonScopePanels {
    func slot(for tool: MonitorAssistTool) -> any NikonScopePanelSlot {
        switch tool {
        case .parade: parade
        case .vectorscope: vectorscope
        case .histogram: histogram
        case .trafficLights: trafficLights
        default: waveform
        }
    }
}
