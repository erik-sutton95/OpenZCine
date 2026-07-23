import SwiftUI

/// Compact photography capture chrome when the body reports photo mode.
///
/// Single GlassPanel row matching cinema capture-strip height so it sits cleanly in the
/// landscape bottom bar without stacking over View Assist / record chrome. The system-rail
/// shutter replaces the red record button; this strip is exposure/drive readouts only.
struct PhotographyCaptureStrip: View {
    let properties: PTPCameraPropertySnapshot
    let onSelectDrive: () -> Void
    let onSelectMode: () -> Void
    let onSelectISO: () -> Void
    let onSelectShutter: () -> Void
    let onSelectIris: () -> Void
    let onSelectMetering: () -> Void
    let onSelectFlash: () -> Void
    let onSelectQuality: () -> Void
    let onSelectFocus: () -> Void
    let onInstantPlayback: () -> Void

    var body: some View {
        GlassPanel(
            padding: EdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        ) {
            HStack(spacing: 6) {
                PhotographyModeBadge()

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
                    title: "FOCUS",
                    value: properties.focusMode ?? "—",
                    action: onSelectFocus
                )
                PhotographyTile(
                    title: "QUAL",
                    value: properties.compression ?? properties.imageSize ?? "—",
                    action: onSelectQuality
                )
                PhotographyTile(
                    title: "FLASH",
                    value: properties.flashMode ?? "—",
                    action: onSelectFlash
                )
                PhotographyTile(
                    title: "METER",
                    value: properties.meteringMode ?? "—",
                    action: onSelectMetering
                )

                Button(action: onInstantPlayback) {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiveDesign.text.opacity(0.9))
                        .frame(width: 36, height: 36)
                        .background(LiveDesign.glassBright, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Instant playback")
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct PhotographyTile: View {
    let title: String
    let value: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold, design: .rounded))
                    .tracking(0.5)
                    .foregroundStyle(LiveDesign.muted)
                Text(value)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(LiveDesign.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.65)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                LiveDesign.glassBright,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
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
            .font(.system(size: 9, weight: .bold, design: .rounded))
            .tracking(1.0)
            .foregroundStyle(LiveDesign.text)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(LiveDesign.accent.opacity(0.92), in: Capsule())
            .accessibilityLabel("Photography mode")
    }
}

/// System-rail still shutter (replaces the red record control in photography mode).
struct PhotographyShutterButton: View {
    let isCapturing: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Color.white.opacity(0.92), lineWidth: 3)
                .frame(width: 54, height: 54)
            Circle()
                .fill(isCapturing ? Color.white.opacity(0.5) : Color.white)
                .frame(width: 42, height: 42)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isCapturing ? "Capturing" : "Shutter")
    }
}
