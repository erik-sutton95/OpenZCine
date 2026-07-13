import SwiftUI
import WatchKit

/// Wrist monitor: a full-width timecode top bar, a 16:9 preview feed with a REC tally border, and
/// a bottom row with storage · Record button · camera battery. All camera control stays on the
/// iPhone; this view only relays a Record toggle.
struct WatchMonitorView: View {
    @Environment(WatchSessionController.self) private var controller

    private var state: WatchRelayState? { controller.state }
    private var isRecording: Bool { state?.isRecording ?? false }

    var body: some View {
        // Stacked, not overlaid: the feed takes exactly the height left over by the two bars, so
        // the bars can never sit on the image. On the Ultra the leftover fits the full-width 16:9
        // box (edge-to-edge); the smallest watches trade a few points of feed width for that.
        VStack(spacing: 2) {
            timecodeBar
                .padding(.horizontal, 6)
            feed
                .frame(maxHeight: .infinity)
            bottomBar
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        // The feed must span the physical display width; only the top bar keeps a horizontal
        // inset (via its own padding — the Record button is centered, so it never nears an edge).
        .ignoresSafeArea(edges: [.horizontal, .bottom])
        .onChange(of: isRecording) { _, nowRecording in
            WKInterfaceDevice.current().play(nowRecording ? .success : .failure)
        }
    }

    // MARK: Top bar

    /// Timecode owns the whole top bar: large monospaced digits, auto-shrinking to fit the row on
    /// smaller watches so it never truncates.
    private var timecodeBar: some View {
        Text(timecodeLabel)
            .font(.system(size: 24, weight: .semibold, design: .monospaced))
            .minimumScaleFactor(0.5)
            .lineLimit(1)
            .foregroundStyle(isRecording ? .red : .primary)
            .frame(maxWidth: .infinity)
    }

    /// Live timecode from the frame stream (smooth, ack-paced); falls back to the state snapshot
    /// when no frames are flowing (feed paused / no camera).
    private var timecodeLabel: String {
        (controller.frameTimecode ?? state?.timecode)?.label ?? "--:--:--:--"
    }

    private var storageLabel: String {
        if let media = state?.mediaStatus { return media.capacityLabel }
        return state?.media ?? "—"
    }

    /// SF Symbol battery glyph matching the reported charge level.
    private var batterySymbol: String {
        switch state?.cameraBatteryPercent ?? 0 {
        case 88...: "battery.100"
        case 62..<88: "battery.75"
        case 37..<62: "battery.50"
        case 12..<37: "battery.25"
        default: "battery.0"
        }
    }

    // MARK: Feed

    /// The 16:9 box is sized by the black base alone; the image, placeholder, and tally border
    /// hang off it as overlays so nothing they render can inflate the box (a `scaledToFill` image
    /// inside a sizing container feeds its overflow back into the layout and breaks the ratio).
    private var feed: some View {
        Color.black
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .overlay {
                if let image = controller.feedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                }
            }
            .clipped()
            .overlay(overlay)
            .overlay {
                if isRecording {
                    Rectangle()
                        .strokeBorder(.red, lineWidth: 3)
                }
            }
            // Last, so the image/border stay pinned to the 16:9 box and this only centers it.
            .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var overlay: some View {
        if !controller.isReachable {
            placeholder("Open OpenZCine on iPhone")
        } else if state?.connection == .noCamera {
            placeholder("No camera connected")
        } else if state?.feedLive == false {
            placeholder("Feed paused (Command mode)")
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .minimumScaleFactor(0.7)
            .multilineTextAlignment(.center)
            .foregroundStyle(.white)
            .padding(6)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(6)
    }

    // MARK: Bottom bar

    /// Storage · Record · battery. The side slots mirror each other (equal flexible widths) so the
    /// Record button stays exactly centered under the feed.
    private var bottomBar: some View {
        HStack(spacing: 4) {
            Text(storageLabel)
                .frame(maxWidth: .infinity, alignment: .leading)
            recordButton
            HStack(spacing: 3) {
                Image(systemName: batterySymbol)
                Text("\(state?.cameraBatteryPercent ?? 0)%")
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    // MARK: Record

    private var canRecord: Bool {
        controller.isReachable && state?.connection == .connected && !controller.isSendingCommand
    }

    private var recordButton: some View {
        Button {
            WKInterfaceDevice.current().play(.click)
            controller.sendToggleRecord()
        } label: {
            ZStack {
                Circle()
                    .stroke(isRecording ? .red : .white.opacity(0.6), lineWidth: 3)
                    .frame(width: 34, height: 34)
                RoundedRectangle(cornerRadius: isRecording ? 3 : 11)
                    .fill(.red)
                    .frame(
                        width: isRecording ? 14 : 22,
                        height: isRecording ? 14 : 22)
            }
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!canRecord)
        .opacity(canRecord ? 1 : 0.4)
        .animation(.easeInOut(duration: 0.15), value: isRecording)
    }
}
