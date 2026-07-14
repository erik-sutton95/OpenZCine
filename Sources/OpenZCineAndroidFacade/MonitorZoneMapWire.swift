// Flat wire format for `MonitorZoneMap` crossing the JNI seam.
//
// Unlike the `@_cdecl` shims in SwiftCoreJNI.swift this file compiles on every
// platform, so the flattening is exercised by `just native-check` on macOS
// against the exact zone math the iOS shell consumes. The Kotlin mirror lives
// in `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/bridge/MonitorZones.kt`.

import OpenZCineCore

/// Flattens the core monitor zone map into a `[Float]` of fixed-stride records
/// so the Compose shell consumes the SAME frames the iOS shell does — no layout
/// math is re-derived in Kotlin.
///
/// Wire format: records of ``stride`` floats, `[kind, style, x, y, width, height]`,
/// appended in ascending-kind order. Optional zones are simply absent. Frames are
/// absolute full-physical-viewport coordinates in points (Android: dp).
///
/// Kind ordinals: 0 feed, 1 infoBar, 2 captureStrip, 3 assistStrip,
/// 4 systemCluster, 5 lock, 6 disp, 7 record, 8 media, 9 settings,
/// 10 batteryCluster, 11 scopes, 12 controlsGrid, 13 batteryPhone,
/// 14 batteryCamera. Kinds 13/14 are the per-indicator frames of the landscape
/// battery rail (`MonitorBatteryRailLayout.fit`), emitted only with a
/// `.batteryRail`-styled cluster — the iOS shell computes these inside
/// `BatteryRailModule`, which Compose cannot call.
///
/// Style ordinals mirror `MonitorZoneStyle` declaration order: 0 infoPill,
/// 1 infoBar, 2 axisHorizontal, 3 axisVertical, 4 scopesFloating,
/// 5 scopesStacked, 6 batteryRail, 7 batteryInline; `-1` for zones that carry
/// no style (feed, system slots, battery indicators).
public enum MonitorZoneMapWire {
    /// Floats per record.
    public static let stride = 6

    /// Builds the zone map via `MonitorZoneLayout.map` and flattens it.
    ///
    /// - Parameters:
    ///   - mode: `DispMode` ordinal — 0 live, 1 clean, 2 command.
    ///   - aspectFill: portrait feed aspect — `false` = fit16x9, `true` = fill.
    ///   - mirrored: `true` for the horizontally mirrored landscape-right chrome.
    ///   - Remaining parameters mirror `MonitorZoneLayout.map` directly.
    public static func flattened(
        viewportWidth: Double,
        viewportHeight: Double,
        safeTop: Double,
        safeLeading: Double,
        safeBottom: Double,
        safeTrailing: Double,
        mode: Int,
        isPortrait: Bool,
        aspectFill: Bool,
        scopeCount: Int,
        mirrored: Bool,
        bottomBarHeight: Double
    ) -> [Float] {
        let dispMode: DispMode =
            switch mode {
            case 1: .clean
            case 2: .command
            default: .live
            }
        let map = MonitorZoneLayout.map(
            viewportWidth: viewportWidth,
            viewportHeight: viewportHeight,
            safeArea: MonitorEdgeInsets(
                top: safeTop, leading: safeLeading, bottom: safeBottom, trailing: safeTrailing
            ),
            mode: dispMode,
            isPortrait: isPortrait,
            aspect: aspectFill ? .fill : .fit16x9,
            scopeCount: scopeCount,
            horizontalDirection: mirrored ? .mirrored : .standard,
            bottomBarHeight: bottomBarHeight
        )

        var out: [Float] = []
        func append(
            kind: Int, style: MonitorZoneStyle?, x: Double, y: Double, width: Double,
            height: Double
        ) {
            out.append(Float(kind))
            out.append(style.map(styleOrdinal) ?? -1)
            out.append(Float(x))
            out.append(Float(y))
            out.append(Float(width))
            out.append(Float(height))
        }
        func append(kind: Int, zone: MonitorZone?) {
            guard let zone else { return }
            append(
                kind: kind, style: zone.style, x: zone.frame.x, y: zone.frame.y,
                width: zone.frame.width, height: zone.frame.height)
        }
        func append(kind: Int, slot: MonitorModuleFrame) {
            append(
                kind: kind, style: nil, x: slot.x, y: slot.y, width: slot.width,
                height: slot.height)
        }

        append(
            kind: 0, style: nil, x: map.feed.x, y: map.feed.y, width: map.feed.width,
            height: map.feed.height)
        append(kind: 1, zone: map.infoBar)
        append(kind: 2, zone: map.captureStrip)
        append(kind: 3, zone: map.assistStrip)
        append(kind: 4, zone: map.systemCluster)
        append(kind: 5, slot: map.systemSlots.lock)
        append(kind: 6, slot: map.systemSlots.disp)
        append(kind: 7, slot: map.systemSlots.record)
        append(kind: 8, slot: map.systemSlots.media)
        append(kind: 9, slot: map.systemSlots.settings)
        append(kind: 10, zone: map.batteryCluster)
        append(kind: 11, zone: map.scopes)
        append(kind: 12, zone: map.controlsGrid)

        // Battery-rail indicator frames (iOS: BatteryRailModule + MonitorBatteryRailLayout.fit).
        if let battery = map.batteryCluster, battery.style == .batteryRail {
            let rail = MonitorBatteryRailLayout.fit(railHeight: battery.frame.height)
            let w = MonitorBatteryRailLayout.indicatorWidth
            let h = MonitorBatteryRailLayout.indicatorHeight
            append(
                kind: 13, style: nil,
                x: battery.frame.x + rail.phoneCenterX - w / 2,
                y: battery.frame.y + rail.phoneCenterY - h / 2,
                width: w, height: h)
            append(
                kind: 14, style: nil,
                x: battery.frame.x + rail.cameraCenterX - w / 2,
                y: battery.frame.y + rail.cameraCenterY - h / 2,
                width: w, height: h)
        }
        return out
    }

    private static func styleOrdinal(_ style: MonitorZoneStyle) -> Float {
        switch style {
        case .infoPill: 0
        case .infoBar: 1
        case .axisHorizontal: 2
        case .axisVertical: 3
        case .scopesFloating: 4
        case .scopesStacked: 5
        case .batteryRail: 6
        case .batteryInline: 7
        }
    }
}
