import SwiftUI

/// Shared visual constants used by the startup and live-monitor design systems.
enum DesignTokens {
    /// Primary corner radius for panels, cards, buttons, popups, and media cells.
    ///
    /// **Exceptions (intentionally not this value):**
    /// - `Capsule()` / `Circle()` — fully round pills and icon buttons
    /// - `RecordingBorderModule.displayCornerRadius` — physical display bezel (~52 pt)
    /// - Micro radii (≤5 pt) on histogram dashes, waveform ticks, and duration badges
    /// - Record-button stop square — distinct rounded-square stop icon
    static let cornerRadius: CGFloat = 16
}

struct ZCBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.065, green: 0.06, blue: 0.055),
                Color(red: 0.13, green: 0.12, blue: 0.105),
                Color(red: 0.035, green: 0.04, blue: 0.05),
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }
}

struct PrimaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.vertical, 13)
            .background(.blue.opacity(configuration.isPressed ? 0.52 : 0.72), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.25), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

struct SecondaryGlassButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.vertical, 13)
            .background(.white.opacity(configuration.isPressed ? 0.10 : 0.07), in: Capsule())
            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 1))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
    }
}

/// Plain button style that pads the label's hit-test region to Apple's 44×44pt HIG minimum without
/// growing controls that are already larger.
struct ZCTapTargetButtonStyle: ButtonStyle {
    var minSize: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .minTapTarget(minSize)
            .opacity(configuration.isPressed ? 0.6 : 1)  // standard press confirmation
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == ZCTapTargetButtonStyle {
    static var zcTapTarget: ZCTapTargetButtonStyle { ZCTapTargetButtonStyle() }
}

extension View {
    func startupContentWidth(_ layout: StartupContentLayout) -> some View {
        frame(width: CGFloat(layout.contentWidth), alignment: .topLeading)
    }

    func glassCapsule(interactive: Bool = false) -> some View {
        liquidGlass(in: Capsule(), interactive: interactive)
    }

    func glassCircle(interactive: Bool = false) -> some View {
        liquidGlass(in: Circle(), interactive: interactive)
    }

    /// Pads this view's hit-test region to at least `minSize`×`minSize` pt (default 44, per Apple
    /// HIG) without growing the drawn control. Required on small round buttons: interactive Liquid
    /// Glass ripples beyond a small icon button's bounds, making it *look* tappable where SwiftUI's
    /// strict content shape doesn't register — this closes that gap.
    func minTapTarget(_ minSize: CGFloat = 44) -> some View {
        modifier(MinTapTargetModifier(minSize: minSize))
    }

    /// Alias for `minTapTarget`.
    func fatFingerHitTarget(_ minSize: CGFloat = 44) -> some View {
        minTapTarget(minSize)
    }

    /// Applies SwiftUI's native Liquid Glass (iOS 26+) in `shape`, falling back to the app's
    /// manual glass treatment on earlier systems. The single entry point for chrome glass styling.
    @ViewBuilder
    func liquidGlass(in shape: some Shape, tint: Color? = nil, interactive: Bool = false)
        -> some View
    {
        if #available(iOS 26.0, *) {
            glassEffect(ZCGlass.make(tint: tint, interactive: interactive), in: shape)
        } else {
            background(LiveDesign.glass, in: shape)
                .overlay(shape.stroke(LiveDesign.hairline, lineWidth: 1))
                .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        }
    }
}

/// Builds the native Liquid Glass descriptor for chrome surfaces (iOS 26+).
@available(iOS 26.0, *)
enum ZCGlass {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var glass = Glass.regular
        if let tint { glass = glass.tint(tint) }
        if interactive { glass = glass.interactive() }
        return glass
    }
}

/// Measures a view for layout-neutral tap-target expansion.
private struct MinTapTargetSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero

    static func reduce(value: inout CGSize, nextValue: () -> CGSize) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

/// Expands hit testing to at least `minSize` without growing the layout box — positive padding
/// widens `contentShape`, then matching negative padding restores sibling spacing.
private struct MinTapTargetModifier: ViewModifier {
    var minSize: CGFloat
    @State private var measuredSize: CGSize = .zero

    func body(content: Content) -> some View {
        let horizontalPad = measuredSize == .zero ? 0 : max(0, (minSize - measuredSize.width) / 2)
        let verticalPad = measuredSize == .zero ? 0 : max(0, (minSize - measuredSize.height) / 2)

        content
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MinTapTargetSizeKey.self, value: proxy.size)
                }
            }
            .onPreferenceChange(MinTapTargetSizeKey.self) { measuredSize = $0 }
            .padding(.horizontal, horizontalPad)
            .padding(.vertical, verticalPad)
            .contentShape(Rectangle())
            .padding(.horizontal, -horizontalPad)
            .padding(.vertical, -verticalPad)
    }
}

extension GeometryProxy {
    var monitorEdgeInsets: MonitorEdgeInsets {
        MonitorEdgeInsets(
            top: Double(safeAreaInsets.top),
            leading: Double(safeAreaInsets.leading),
            bottom: Double(safeAreaInsets.bottom),
            trailing: Double(safeAreaInsets.trailing)
        )
    }
}

extension OperatorPreferences.StreamPreset {
    var next: OperatorPreferences.StreamPreset {
        switch self {
        case .fast: .balanced
        case .balanced: .quality
        case .quality: .fast
        }
    }
}

extension OperatorPreferences.QualityBias {
    var next: OperatorPreferences.QualityBias {
        switch self {
        case .latency: .balanced
        case .balanced: .detail
        case .detail: .latency
        }
    }
}

extension OperatorPreferences.StreamPreset {
    /// `LiveViewImageSize` (0xD1AC) — UINT8 1 QVGA / 2 VGA / 3 XGA, per libgphoto2's Nikon table.
    /// Bigger preview = more bandwidth, so Fast streams the smallest size.
    var liveViewImageSize: UInt8 {
        switch self {
        case .fast: 1
        case .balanced: 2
        case .quality: 3
        }
    }
}

extension OperatorPreferences.QualityBias {
    /// `LiveViewImageCompression` (0xD1BC). The ZR runtime-enumerates this (no documented table), so
    /// the mapping is best-effort and **verify-on-HW** — flip the order if the camera reports the
    /// opposite sense. Higher = lighter compression = more detail.
    var liveViewImageCompression: UInt8 {
        switch self {
        case .latency: 1
        case .balanced: 2
        case .detail: 3
        }
    }
}
