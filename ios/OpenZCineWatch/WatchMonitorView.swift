import SwiftUI
import WatchKit

/// Wrist monitor: a full-width timecode top bar, a 16:9 preview feed with a REC tally border, and
/// a bottom row with storage · Record button · camera battery. All camera control stays on the
/// iPhone; this view only relays a Record toggle.
struct WatchMonitorView: View {
    @Environment(WatchSessionController.self) private var controller

    private var state: WatchRelayState? { controller.state }
    private var isRecording: Bool { state?.isRecording ?? false }

    /// Crown-driven magnification of the preview, 1 = the whole frame.
    @State private var zoom: Double = 1
    /// Live pan offset while a drag is in flight, and where the last drag left it.
    @State private var pan: CGSize = .zero
    @State private var panAnchor: CGSize = .zero
    /// The rendered feed box, needed to bound the pan when a drag ends.
    @State private var feedSize: CGSize = .zero

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

    /// The camera's gauge. `BatteryLevel` is a five-bar gauge, not a percentage — it only ever
    /// carries 1/20/40/60/80/100 — so the wrist shows bars for the same reason the phone does
    /// (#303). Printing "60%" claimed a precision the body never sent.
    private var cameraGauge: CameraBatteryGauge? {
        state.map { CameraBatteryGauge.gauge(rawBatteryLevel: $0.cameraBatteryPercent) }
    }

    /// Colour before count: green from three bars, orange at two, red at one, matching the phone.
    private var batteryTint: Color {
        switch cameraGauge?.urgency ?? .nominal {
        case .nominal: Color(red: 0.42, green: 0.80, blue: 0.53)
        case .low: .orange
        case .depleted: .red
        }
    }

    /// Five segments, as the body itself shows. Sized for the wrist rather than the phone's rail.
    @ViewBuilder private var batteryGauge: some View {
        if let cameraGauge, cameraGauge != .unknown {
            HStack(spacing: 1) {
                ForEach(0..<CameraBatteryGauge.barCount, id: \.self) { index in
                    RoundedRectangle(cornerRadius: 0.8, style: .continuous)
                        .fill(
                            index < cameraGauge.filledBars
                                ? batteryTint : Color.white.opacity(0.22)
                        )
                        .frame(width: 2.5, height: 7)
                }
            }
            .accessibilityElement()
            .accessibilityLabel(
                "Camera battery \(cameraGauge.filledBars) of \(CameraBatteryGauge.barCount) bars")
        } else {
            Text("—").foregroundStyle(.secondary)
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
                    GeometryReader { proxy in
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            // Zoom about the box centre, then translate — the pan is already
                            // clamped to the magnified overhang, so the picture can never be
                            // dragged off its own frame.
                            .scaleEffect(zoom)
                            .offset(clampedPan(in: proxy.size))
                            .onAppear { feedSize = proxy.size }
                            .onChange(of: proxy.size) { _, size in feedSize = size }
                    }
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
            // Critical-focus check on the wrist: the crown magnifies, a drag moves the magnified
            // window. The crown is the only precise input a watch has, which is why zoom rides it
            // and pan rides the finger rather than the other way round.
            .focusable()
            .digitalCrownRotation(
                $zoom,
                from: 1,
                through: Self.maximumZoom,
                by: 0.05,
                sensitivity: .medium,
                isContinuous: false,
                isHapticFeedbackEnabled: true
            )
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Unzoomed the feed has no overhang to explore, so the drag stays out of
                        // the way of any system edge gesture.
                        guard zoom > 1 else { return }
                        pan = CGSize(
                            width: panAnchor.width + value.translation.width,
                            height: panAnchor.height + value.translation.height)
                    }
                    .onEnded { _ in panAnchor = clampedPan(in: feedSize) }
            )
            // Backing all the way out re-centres, so the next zoom starts from the whole frame
            // instead of wherever the last inspection left the window.
            .onChange(of: zoom) { _, level in
                if level <= 1 {
                    pan = .zero
                    panAnchor = .zero
                }
            }
    }

    /// Furthest the crown can magnify — enough to judge critical focus, short of the point where
    /// the relayed preview is only showing its own compression.
    private static let maximumZoom: Double = 4

    /// The pan, bounded to the overhang the current zoom actually creates: at 1× there is none, so
    /// this pins to centre no matter what the finger did.
    private func clampedPan(in size: CGSize) -> CGSize {
        let limitX = max(0, (size.width * zoom - size.width) / 2)
        let limitY = max(0, (size.height * zoom - size.height) / 2)
        return CGSize(
            width: min(max(pan.width, -limitX), limitX),
            height: min(max(pan.height, -limitY), limitY))
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
                // The camera glyph, not a battery glyph: the gauge beside it already says
                // "battery", so the icon's job is to say WHOSE — the phone's own charge never
                // appears on the wrist.
                Image(systemName: "camera")
                batteryGauge
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
