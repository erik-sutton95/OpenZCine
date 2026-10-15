import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineMedia
import OpenZCineCore
import SwiftUI

/// Nikon's looks for the shared assist state. The Nikon image graph resolves and caches cubes by
/// `LUTSelection.cacheKey` itself, so the shared state never prepares one here.
@MainActor @Observable
final class NikonMonitorLooks: MonitorLookProvider {
    /// Mirrors `AssistConfiguration.selectedLUT` (the model keeps them in step).
    var selection: LUTSelection = .builtIn(.log3G10Rec709)
    /// The shared preview borrows the calibrated native image; controls do not prepare its cube.
    var cube: CubeLUT? { nil }
    /// The calibrated native graph does not apply the shared input-exposure option.
    var appliesLUTExposure: Bool { false }
    var transfer: MonitorTransfer { .rec709 }
    var referenceClipByte: Int { 255 }
    func lutExposureTransfer(for transfer: MonitorTransfer) -> MonitorTransfer { transfer }
}

/// The shared Pocket / Insta assist state, owned by the Nikon app model.
typealias NikonAssistState = MonitorAssistState<NikonMonitorLooks>

/// The anamorphic correction one surface presents. Nikon shrinks the picture inside its frame
/// rather than stretching it: `horizontal` (the shared direction, a widened image) letterboxes,
/// otherwise the image pillarboxes. A factor of 1 is no correction.
struct NikonDesqueeze: Equatable, Sendable {
    var factor: Double = 1
    var horizontal = true
    static let off = NikonDesqueeze()
}

extension MonitorFalseColorSelection {
    /// Native image processing uses the same four shared monitor scales.
    var nikonScale: FalseColorScale {
        switch self {
        case .sceneStops: .stops
        case .stops: .video
        case .ire: .ire
        case .limits: .limits
        }
    }
}

extension MonitorAssistCapabilities {
    /// What a Nikon body adds to the shared list: PLAY and the body's EV needle are stills tools,
    /// the level draws as a horizon or a gauge, and there is no ND source.
    static let nikon = MonitorAssistCapabilities(
        photographyOnly: [.instantReview, .evMeter], levelStyles: [.horizon, .gauge],
        unavailable: [.ndMeter])
}

extension MonitorAssistTool {
    /// The shared selection with the same saved name. Every Nikon raw value is a shared one.
    var selection: MonitorAssistSelection { MonitorAssistSelection(rawValue: rawValue)! }

    /// Tools DISP 2 can keep on screen. The camera EV meter belongs to DISP 1 only.
    static var nikonCleanPinCases: [MonitorAssistSelection] {
        activeCases.filter { $0 != .evMeter }.map(\.selection)
    }
}

extension MonitorAssistState where Looks == NikonMonitorLooks {
    static let nikonKeys = MonitorAssistPreferenceKeys(
        assist: "OpenZCine.Assist.v1", cleanPins: "OpenZCine.CleanViewPins.v1",
        playback: "OpenZCine.PlaybackAssists.v1")
    /// The Nikon blobs the shared state replaced. Read once, on the first launch without a shared
    /// snapshot; the app still owns `assistConfiguration.v1` for its Nikon-only settings.
    static let legacyPreferencesKey = "operatorPreferences.v1"
    static let legacyConfigurationKey = "assistConfiguration.v1"

    /// The app's assist state. A first launch on the shared state seeds it from the Nikon blobs;
    /// a fresh install takes the shared defaults with the LUT off.
    static func restore(storage: UserDefaults = .standard) -> NikonAssistState {
        let firstRun = storage.data(forKey: nikonKeys.assist) == nil
        let state = NikonAssistState(
            looks: NikonMonitorLooks(), storage: storage, keys: nikonKeys,
            cleanPinCases: MonitorAssistTool.nikonCleanPinCases)
        if firstRun { state.migrateNikonAssists(from: storage) }
        return state
    }

    /// Live tools switched on (unfiltered by DISP mode).
    var liveTools: Set<MonitorAssistTool> {
        Set(MonitorAssistTool.activeCases.filter { isOn($0.selection) })
    }

    var playbackTools: Set<MonitorAssistTool> {
        Set(MonitorAssistTool.activeCases.filter { isPlaybackVisible($0.selection) })
    }

    /// The correction a surface shows when the tool is visible there.
    func desqueeze(visible: Bool) -> NikonDesqueeze {
        visible ? NikonDesqueeze(factor: desqueezeFactor, horizontal: desqueezeHorizontal) : .off
    }

    func tools(for context: ViewAssistContext) -> Set<MonitorAssistTool> {
        context == .liveView ? liveTools : playbackTools
    }

    /// Switches one Nikon tool through the shared toggles, so persistence stays the shared one.
    func set(_ tool: MonitorAssistTool, visible: Bool, context: ViewAssistContext) {
        let selection = tool.selection
        switch context {
        case .liveView:
            if isOn(selection) != visible { toggle(selection) }
        case .playback:
            if isPlaybackVisible(selection) != visible { togglePlayback(selection) }
        }
    }

    /// A binding that writes through and persists, as the shared option menus expect.
    func binding<Value>(_ keyPath: ReferenceWritableKeyPath<NikonAssistState, Value>)
        -> Binding<Value>
    {
        Binding(
            get: { self[keyPath: keyPath] },
            set: {
                self[keyPath: keyPath] = $0
                self.persist()
            })
    }

    /// Grid line sets that are on, for the shared grid menu.
    var gridOptions: Set<MonitorGridOption> {
        var options: Set<MonitorGridOption> = []
        if gridThirds { options.insert(.thirds) }
        if gridPhi { options.insert(.phi) }
        if gridDiagonal { options.insert(.diagonal) }
        return options
    }

    func toggleGrid(_ option: MonitorGridOption) {
        switch option {
        case .thirds: gridThirds.toggle()
        case .phi: gridPhi.toggle()
        case .diagonal: gridDiagonal.toggle()
        }
        persist()
    }

    func selectDesqueezePreset(_ preset: MonitorDesqueezePreset) {
        desqueezeCustom = false
        desqueezeFactor = preset.factor
        persist()
    }

    func selectDesqueezeCustom() {
        desqueezeCustom = true
        desqueezeFactor = MonitorAnamorphicDesqueeze.snap(desqueezeCustomFactor)
        persist()
    }

    /// Slider drags update the picture live; the menu persists on release.
    func updateDesqueezeCustom(_ value: Double) {
        desqueezeCustom = true
        desqueezeCustomFactor = MonitorAnamorphicDesqueeze.snap(value)
        desqueezeFactor = desqueezeCustomFactor
    }

    /// Restores one tool's shared options to the shared defaults (View Assist resets).
    func resetOptions(_ tool: MonitorAssistTool) {
        switch tool {
        case .falseColor:
            falseColorScale = .sceneStops
            falseColorReference = true
        case .zebra:
            zebraHighlight = true
            zebraMidtone = true
            zebraHighlightIRE = LiveZebra.highlightIRE
            zebraMidtoneIRE = LiveZebra.midtoneIRE
            zebraHighlightColor = .white
            zebraMidtoneColor = .amber
        case .histogram, .trafficLights:
            crushClipCompensation = .zero
        case .peaking:
            peakingColor = .red
            peakingSensitivity = .medium
        default:
            return
        }
        persist()
    }

    /// One-time copy of the operator's Nikon assist settings. Reads raw JSON so a malformed or
    /// partial blob only loses the values it cannot read; everything else keeps the shared default.
    func migrateNikonAssists(from storage: UserDefaults) {
        func object(_ key: String) -> [String: Any] {
            storage.data(forKey: key)
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
        }
        let preferences = object(Self.legacyPreferencesKey)
        let configuration = object(Self.legacyConfigurationKey)
        func tools(_ key: String) -> Set<MonitorAssistSelection>? {
            (preferences[key] as? [String]).map {
                Set(
                    $0.compactMap(MonitorAssistTool.init(rawValue:)).filter { !$0.isRetired }
                        .map(\.selection))
            }
        }
        func finite(_ value: Any?) -> Double? {
            (value as? NSNumber).map(\.doubleValue).flatMap { $0.isFinite ? $0 : nil }
        }

        // Tool on/off. The LUT starts off unless the operator had it on.
        let live = tools("liveViewVisibleAssistTools") ?? tools("visibleAssistTools") ?? []
        for tool in MonitorAssistSelection.allCases where tool != .magnification {
            if isOn(tool) != live.contains(tool) { toggle(tool) }
        }
        if let pins = tools("cleanViewPinnedTools") {
            let kept = MonitorAssistTool.nikonCleanPinCases.filter { pins.contains($0) }
            cleanViewPinnedTools = Set(kept)
            storage.set(kept.map(\.rawValue), forKey: Self.nikonKeys.cleanPins)
        }
        if let playback = tools("playbackVisibleAssistTools") {
            playbackVisibleTools = playback.filter { $0 != .evMeter }
            storage.set(
                playbackVisibleTools.map(\.rawValue).sorted(), forKey: Self.nikonKeys.playback)
        }
        if let split = preferences["splitComparisonEnabled"] as? Bool { splitComparison = split }
        if let orientation = preferences["splitComparisonOrientation"] as? String {
            splitVertical = orientation != "Top / Bottom"
        }

        if let guides = configuration["guides"] as? [String: Any] {
            if let family = (guides["family"] as? String).flatMap(MonitorGuideFamily.init) {
                guideFamily = family
            }
            let stored =
                (guides["selectedRatios"] as? [String]) ?? (guides["aspectRatio"] as? String).map {
                    [$0]
                } ?? []
            let ratios = Set(stored.compactMap(MonitorGuideAspect.init(rawValue:)))
            if !ratios.isEmpty {
                selectedGuides = ratios
                guideAspect =
                    MonitorGuideAspect.ratios(for: guideFamily).first(where: ratios.contains)
                    ?? ratios.first ?? guideAspect
            }
            if let mask = guides["maskEnabled"] as? Bool { guideMask = mask }
        }
        if let grid = configuration["grid"] as? [String: Any] {
            if let thirds = grid["thirds"] as? Bool { gridThirds = thirds }
            if let phi = grid["phi"] as? Bool { gridPhi = phi }
            if let diagonal = grid["diagonal"] as? Bool { gridDiagonal = diagonal }
        }
        if let desqueeze = configuration["desqueeze"] as? [String: Any] {
            // A stored 1.0 is Nikon's "never chosen" default, so the shared default stays.
            let ratio = (desqueeze["ratio"] as? String).flatMap { Double($0.dropLast()) }
            if let factor = finite(desqueeze["factor"]) ?? ratio, factor > 1 {
                let snapped = MonitorAnamorphicDesqueeze.snap(factor)
                desqueezeFactor = snapped
                desqueezeCustom = MonitorDesqueezePreset.matching(snapped) == nil
                if desqueezeCustom { desqueezeCustomFactor = snapped }
            }
            // Nikon named the axis it shrank: "Horizontal" pillarboxed, which is the shared
            // vertical direction.
            if let orientation = desqueeze["orientation"] as? String {
                desqueezeHorizontal = orientation != "Horizontal"
            }
        }
        if let reference = configuration["falseColorReferenceEnabled"] as? Bool {
            falseColorReference = reference
        }
        switch configuration["falseColorScale"] as? String {
        case "Stops": falseColorScale = .sceneStops
        case "IRE": falseColorScale = .ire
        case "Limits": falseColorScale = .limits
        default: break
        }
        let zebra = configuration["zebra"] as? [String: Any]
        if let zebra {
            if let on = zebra["highlightEnabled"] as? Bool { zebraHighlight = on }
            if let on = zebra["midtoneEnabled"] as? Bool { zebraMidtone = on }
            if let ire = finite(zebra["highlightIRE"]) { zebraHighlightIRE = ire }
            if let ire = finite(zebra["midtoneIRE"]) { zebraMidtoneIRE = ire }
            if let paint = (zebra["highlightColor"] as? String).flatMap(MonitorZebraPaint.init) {
                zebraHighlightColor = paint
            }
            if let paint = (zebra["midtoneColor"] as? String).flatMap(MonitorZebraPaint.init) {
                zebraMidtoneColor = paint
            }
        } else if let ire = finite(configuration["zebraHighlightIRE"]) {
            zebraHighlightIRE = ire
        }
        if let color = (configuration["peakingColor"] as? String).flatMap(MonitorPeakingColor.init)
        {
            peakingColor = color
        }
        if let sense = (configuration["peakingSensitivity"] as? String).flatMap(
            MonitorPeakingSense.init)
        {
            peakingSensitivity = sense
        }
        if let compensation = Self.legacyCrushClip(configuration) {
            crushClipCompensation = compensation
        }
        persist()
    }

    /// The operator's crush/clip choice from any era of the Nikon blob. An explicit shared key
    /// wins; older per-surface copies count only when customized (non-zero), since zero was their
    /// stored default. Nothing customized leaves the shared default.
    private static func legacyCrushClip(_ configuration: [String: Any])
        -> MonitorCrushClipCompensation?
    {
        let scopes = configuration["scopes"] as? [String: Any] ?? [:]
        if let explicit = scopes["crushClipCompensation"] as? Int {
            return .fromRaw(explicit)
        }
        // The split-era traffic-lights copy outranks the pre-stops percent, as Nikon's decoder did.
        let candidates: [Int?] = [
            scopes["histogramCrushClipCompensation"] as? Int,
            scopes["histogramNoiseFloorCompensation"] as? Int,
            (configuration["trafficLights"] as? [String: Any])?["crushClipCompensation"] as? Int,
            scopes["histogramTrafficSensitivity"] as? Int,
        ]
        return candidates.lazy.compactMap { $0 }.map(MonitorCrushClipCompensation.fromRaw)
            .first { $0 != .zero }
    }
}
