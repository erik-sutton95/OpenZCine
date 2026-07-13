import SwiftUI

/// OpenZCine brand palette — Nikon-inspired gold on charcoal (no third-party trademarks).
enum BrandColors {
    static let background = Color(red: 0.065, green: 0.055, blue: 0.047)
    static let backgroundDeep = Color(red: 0.038, green: 0.034, blue: 0.030)
    static let surface = Color(red: 0.114, green: 0.094, blue: 0.075)
    static let ink = Color(red: 0.949, green: 0.925, blue: 0.886)
    static let muted = Color(red: 0.655, green: 0.612, blue: 0.553)
    static let accent = Color(red: 1.0, green: 0.882, blue: 0.0)
    static let accentSoft = Color(red: 1.0, green: 0.882, blue: 0.0).opacity(0.18)
}

/// OZC monogram mark (legacy programmatic branding; superseded by `AppLogo` raster assets).
struct OZCMonogramMark: View {
    var size: CGFloat = 72
    var cornerRadius: CGFloat = DesignTokens.cornerRadius

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(BrandColors.surface)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(BrandColors.accent.opacity(0.55), lineWidth: max(1, size * 0.018))
            )
            .overlay {
                Text("OZC")
                    .font(.system(size: size * 0.34, weight: .heavy, design: .rounded))
                    .kerning(size * 0.02)
                    .foregroundStyle(BrandColors.accent)
            }
            .frame(width: size, height: size)
            .accessibilityLabel("OpenZCine")
    }
}

/// OpenZCine wordmark title.
struct OpenZCineWordmark: View {
    var fontSize: CGFloat = 34
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.18) {
            Text("OpenZCine")
                .font(.system(size: fontSize, weight: .bold, design: .rounded))
                .foregroundStyle(BrandColors.ink)
            if let subtitle {
                Text(subtitle)
                    .font(.system(size: fontSize * 0.38, weight: .medium, design: .rounded))
                    .foregroundStyle(BrandColors.muted)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// App icon image reused on the launch splash (sourced from `AppLogo` asset catalog entry).
struct AppLogoMark: View {
    var size: CGFloat = 88

    var body: some View {
        Image("AppLogo")
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
            .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.04)
            .accessibilityLabel("OpenZCine")
    }
}

/// How long the in-app launch splash stays fully visible before fading out.
enum LaunchSplashTiming {
    static let visibleDuration: Duration = .milliseconds(2_250)
    static let fadeOutDuration: TimeInterval = 0.35
}

/// Shared cinematic backdrop for the launch splash.
struct BrandBackdrop: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    BrandColors.backgroundDeep,
                    BrandColors.background,
                    Color(red: 0.09, green: 0.078, blue: 0.062),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            RadialGradient(
                colors: [
                    BrandColors.accentSoft,
                    .clear,
                ],
                center: .topTrailing,
                startRadius: 20,
                endRadius: 420
            )
            .blendMode(.screen)
        }
        .ignoresSafeArea()
    }
}

/// Landscape-friendly launch splash layout (solid storyboard backdrop + in-app boot overlay).
struct LaunchSplashContent: View {
    var compact: Bool = false

    var body: some View {
        GeometryReader { proxy in
            let landscape = proxy.size.width >= proxy.size.height
            let logoSize = min(proxy.size.width * (landscape ? 0.16 : 0.28), compact ? 72 : 96)

            ZStack {
                BrandBackdrop()

                if landscape {
                    HStack(spacing: max(32, proxy.size.width * 0.06)) {
                        AppLogoMark(size: logoSize)
                        OpenZCineWordmark(fontSize: compact ? 28 : 34)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, max(32, proxy.size.width * 0.08))
                } else {
                    VStack(spacing: 24) {
                        AppLogoMark(size: logoSize)
                        OpenZCineWordmark(fontSize: 30)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

/// Brief in-app splash shown on cold start to bridge the static launch screen.
struct LaunchSplashOverlay: View {
    @Binding var isVisible: Bool

    var body: some View {
        LaunchSplashContent()
            .opacity(isVisible ? 1 : 0)
            .animation(.easeOut(duration: LaunchSplashTiming.fadeOutDuration), value: isVisible)
            .allowsHitTesting(isVisible)
    }
}
