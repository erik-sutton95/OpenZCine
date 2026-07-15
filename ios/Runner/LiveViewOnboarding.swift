import SwiftUI

enum LiveViewGuideStep: String, CaseIterable, Sendable {
    case cameraControls
    case viewAssist
    case systemControls

    var number: Int {
        Self.allCases.firstIndex(of: self).map { $0 + 1 } ?? 1
    }

    var next: LiveViewGuideStep? {
        guard let index = Self.allCases.firstIndex(of: self) else { return nil }
        let nextIndex = index + 1
        return Self.allCases.indices.contains(nextIndex) ? Self.allCases[nextIndex] : nil
    }

    var title: String {
        switch self {
        case .cameraControls: "Status & camera controls"
        case .viewAssist: "View Assist"
        case .systemControls: "System controls"
        }
    }

    func message(isPortrait: Bool, usesVerticalAssistRail: Bool) -> String {
        switch self {
        case .cameraControls:
            if isPortrait {
                return
                    "Status shows timecode, media, and camera health. Tap a camera tile or value to change it."
            }
            return
                "Status shows recording, timecode, format, media, and feed health. Tap ISO, shutter, iris, focus, or WB below to change it."
        case .viewAssist:
            if usesVerticalAssistRail {
                return
                    "Tap the slider to open View Assist. Tap a tool to turn it on, or press and hold a configurable tool for quick settings."
            }
            return
                "Tap a tool to turn it on. Press and hold a configurable tool for quick settings. Swipe for more."
        case .systemControls:
            return
                "Lock prevents accidental changes. DISP changes the monitor layout. Red records. Media opens clips. Gear opens Operator Setup."
        }
    }

    static func demoValue(_ value: String?) -> LiveViewGuideStep? {
        switch value {
        case "camera": .cameraControls
        case "assist": .viewAssist
        case "system": .systemControls
        default: nil
        }
    }
}

@MainActor
struct LiveViewGuideStore {
    static let currentVersion = 1
    private static let completedVersionKey = "liveViewGuide.completedVersion"

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var shouldPresent: Bool {
        defaults.integer(forKey: Self.completedVersionKey) < Self.currentVersion
    }

    func markCompleted() {
        defaults.set(Self.currentVersion, forKey: Self.completedVersionKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.completedVersionKey)
    }
}

enum LiveViewGuideTarget: Hashable {
    case infoBar
    case cameraControls
    case viewAssist
    case lock
    case display
    case record
    case media
    case settings
}

struct LiveViewGuideAnchorKey: PreferenceKey {
    static let defaultValue: [LiveViewGuideTarget: Anchor<CGRect>] = [:]

    static func reduce(
        value: inout [LiveViewGuideTarget: Anchor<CGRect>],
        nextValue: () -> [LiveViewGuideTarget: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func liveViewGuideAnchor(_ target: LiveViewGuideTarget) -> some View {
        anchorPreference(key: LiveViewGuideAnchorKey.self, value: .bounds) { [target: $0] }
    }
}

struct LiveViewGuideOverlay: View {
    @Environment(NativeAppModel.self) private var model
    let step: LiveViewGuideStep
    let anchors: [LiveViewGuideTarget: Anchor<CGRect>]
    let isPortrait: Bool

    var body: some View {
        GeometryReader { proxy in
            let verticalAssist = isPortrait && model.preferences.portraitFeedAspect == .fill
            ZStack {
                // Keep camera commands inert during the brief guide while the live feed continues.
                Color.clear
                    .contentShape(Rectangle())
                    .accessibilityHidden(true)

                ForEach(Array(targetFrames(in: proxy).enumerated()), id: \.offset) { _, frame in
                    RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                        .stroke(LiveDesign.accent, lineWidth: 2)
                        .shadow(color: .black.opacity(0.75), radius: 4)
                        .frame(width: frame.width + 10, height: frame.height + 10)
                        .position(x: frame.midX, y: frame.midY)
                        .allowsHitTesting(false)
                }

                guideCard(verticalAssist: verticalAssist)
                    .frame(maxWidth: min(isPortrait ? 390 : 430, proxy.size.width - 36))
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: cardAlignment
                    )
                    .padding(cardPadding)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .ignoresSafeArea()
        .accessibilityAddTraits(.isModal)
        .accessibilityIdentifier("liveGuide.card")
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
    }

    private func guideCard(verticalAssist: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Text("QUICK GUIDE")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .kerning(0.8)
                    .foregroundStyle(LiveDesign.accent)
                Spacer()
                Text("\(step.number) OF \(LiveViewGuideStep.allCases.count)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
            }
            Text(step.title)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(step.message(isPortrait: isPortrait, usesVerticalAssistRail: verticalAssist))
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(LiveDesign.muted)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Skip") { model.skipLiveViewGuide() }
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(LiveDesign.muted)
                    .buttonStyle(.zcTapTarget)
                    .accessibilityIdentifier("liveGuide.skip")
                Spacer()
                Button(step.next == nil ? "Done" : "Next") {
                    model.advanceLiveViewGuide()
                }
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(LiveDesign.background)
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(LiveDesign.accent, in: Capsule())
                .buttonStyle(.zcTapTarget)
                .accessibilityIdentifier("liveGuide.next")
            }
        }
        .padding(14)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous)
                .stroke(LiveDesign.hairlineStrong, lineWidth: 1)
        }
    }

    private var cardAlignment: Alignment {
        switch step {
        case .viewAssist: .top
        case .cameraControls, .systemControls: .center
        }
    }

    private var cardPadding: EdgeInsets {
        switch step {
        case .viewAssist:
            EdgeInsets(top: isPortrait ? 92 : 76, leading: 18, bottom: 18, trailing: 18)
        case .cameraControls, .systemControls:
            EdgeInsets(top: 18, leading: isPortrait ? 18 : 70, bottom: 18, trailing: 70)
        }
    }

    private func targetFrames(in proxy: GeometryProxy) -> [CGRect] {
        targets.compactMap { target in
            anchors[target].map { proxy[$0] }
        }
    }

    private var targets: [LiveViewGuideTarget] {
        switch step {
        case .cameraControls:
            [.infoBar, .cameraControls]
        case .viewAssist:
            [.viewAssist]
        case .systemControls:
            [.lock, .display, .record, .media, .settings]
        }
    }
}
