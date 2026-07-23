import SwiftUI

/// First-iteration photography monitor chrome when the body reports photo mode.
///
/// Mirrors the cinema monitor philosophy: warm dark tiles, compact capture strip,
/// long-press overflow for secondary controls. Wired to live property readouts;
/// capture actions call into the session when a still-release command is available.
struct PhotographyCaptureStrip: View {
    let properties: PTPCameraPropertySnapshot
    let isCapturing: Bool
    let onShutter: () -> Void
    let onSelectDrive: () -> Void
    let onSelectMode: () -> Void
    let onSelectISO: () -> Void
    let onSelectShutter: () -> Void
    let onSelectIris: () -> Void
    let onSelectMetering: () -> Void
    let onSelectFlash: () -> Void
    let onSelectQuality: () -> Void
    let onInstantPlayback: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PhotographyTile(
                title: "MODE",
                value: properties.exposureMode ?? "—",
                action: onSelectMode
            )
            PhotographyTile(
                title: "DRIVE",
                value: properties.stillCaptureMode ?? "Single",
                action: onSelectDrive
            )
            PhotographyTile(
                title: "ISO",
                value: properties.iso.map { "\($0)" } ?? "—",
                action: onSelectISO
            )
            PhotographyTile(
                title: "SHUTTER",
                value: properties.shutterSpeed ?? "—",
                action: onSelectShutter
            )
            PhotographyTile(
                title: "IRIS",
                value: properties.fNumber ?? "—",
                action: onSelectIris
            )

            Spacer(minLength: 4)

            Button(action: onInstantPlayback) {
                Image(systemName: "photo.on.rectangle")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(StartupColors.ink.opacity(0.85))
                    .frame(width: 40, height: 40)
                    .background(StartupColors.control.opacity(0.75), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Instant playback")

            Button(action: onShutter) {
                ZStack {
                    Circle()
                        .strokeBorder(Color.white.opacity(0.92), lineWidth: 3)
                        .frame(width: 58, height: 58)
                    Circle()
                        .fill(isCapturing ? Color.white.opacity(0.55) : Color.white)
                        .frame(width: 46, height: 46)
                }
            }
            .buttonStyle(.plain)
            .disabled(isCapturing)
            .accessibilityLabel(isCapturing ? "Capturing" : "Shutter")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            StartupColors.control.opacity(0.55),
            in: RoundedRectangle(cornerRadius: 18, style: .continuous)
        )
    }
}

/// Secondary stills options revealed by long-press / overflow (first iteration: always visible row).
struct PhotographySecondaryStrip: View {
    let properties: PTPCameraPropertySnapshot
    let onSelectMetering: () -> Void
    let onSelectFlash: () -> Void
    let onSelectQuality: () -> Void
    let onSelectFocus: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            PhotographyTile(
                title: "METER",
                value: properties.meteringMode ?? "—",
                compact: true,
                action: onSelectMetering
            )
            PhotographyTile(
                title: "FLASH",
                value: properties.flashMode ?? "—",
                compact: true,
                action: onSelectFlash
            )
            PhotographyTile(
                title: "QUAL",
                value: properties.compression ?? properties.imageSize ?? "—",
                compact: true,
                action: onSelectQuality
            )
            PhotographyTile(
                title: "FOCUS",
                value: properties.focusMode ?? "—",
                compact: true,
                action: onSelectFocus
            )
            if let bias = properties.exposureBias {
                PhotographyTile(title: "EV", value: bias, compact: true, action: {})
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
    }
}

struct PhotographyTile: View {
    let title: String
    let value: String
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: compact ? 8 : 9, weight: .semibold, design: .rounded))
                    .tracking(0.6)
                    .foregroundStyle(StartupColors.muted)
                Text(value)
                    .font(.system(size: compact ? 12 : 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(StartupColors.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 6 : 8)
            .background(
                StartupColors.control.opacity(0.82),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) \(value)")
    }
}

/// Badge shown when the body is in stills mode so the operator knows the strip switched.
struct PhotographyModeBadge: View {
    var body: some View {
        Text("PHOTO")
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(StartupColors.ink)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(StartupColors.accent.opacity(0.9), in: Capsule())
            .accessibilityLabel("Photography mode")
    }
}
