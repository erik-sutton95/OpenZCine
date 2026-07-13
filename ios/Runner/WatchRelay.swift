import Foundation
import UIKit
import WatchConnectivity

/// A minimal `@unchecked Sendable` box for handing a non-`Sendable` value across an isolation hop.
/// Used only to carry a `WCSession` reply handler onto the main actor; the underlying closure is
/// invoked exactly once on the main actor.
private struct RelaySendableBox<Value>: @unchecked Sendable {
    let value: Value
}

/// iPhone-side WatchConnectivity relay for the OpenZCine watchOS companion.
///
/// The iPhone owns the single PTP control session. This relay forwards a downscaled preview feed
/// and a small state snapshot to a paired Apple Watch, and relays a Record toggle back. It is
/// foreground-only by design: it streams while the monitor is the foreground scene and no-ops
/// gracefully when no watch is paired or reachable.
@MainActor
final class WatchRelay: NSObject {
    // MARK: Tunables

    // Frame sizing is adaptive (see `adaptiveEncodingParams`): the send→ack round-trip picks a
    // smaller frame when the WatchConnectivity link is slow and a larger one when it's fast.

    /// Called when the watch requests a Record toggle. Returns the result to reply with. Bypasses
    /// the phone-side confirmation alert by design (an unseen phone dialog would strand the take).
    var onToggleRecord: (@MainActor () -> WatchCommandResult)?
    /// Called when watch reachability changes so the owner can re-publish the current state.
    var onReachabilityChanged: (@MainActor () -> Void)?

    private let session: WCSession?
    private var lastSentState: WatchRelayState?
    /// Latest frame awaiting send — drop-stale: every ingest overwrites this, so only the freshest
    /// frame ever ships. `effects` is nil when `image` is already display-baked; the Metal and demo
    /// paths provide their raw image plus the effects to apply after the frame wins a pipeline slot.
    private var pendingFrame:
        (
            image: UIImage, effects: LiveImageEffects?, timecode: Timecode, isRecording: Bool
        )?
    /// Dedicated small-frame renderer for raw Metal/demo frames. Allocated only once a reachable
    /// Watch actually needs effects, so an unused relay does not create an extra Core Image context.
    private var frameRenderer: LiveFrameRenderer?
    /// Frames concurrently in flight over WatchConnectivity. Strictly ack-paced (one in flight)
    /// caps throughput at 1/RTT — ~6 fps on a typical 150 ms link. A small pipeline hides link
    /// latency (throughput ≈ depth/RTT ≈ 20 fps) while the ack pacing still bounds the backlog,
    /// so a slow link degrades to fewer fps instead of growing latency.
    private var framesInFlight = 0
    /// Pipeline depth. 3 is enough to hide WC latency at live-view rates without letting frames
    /// queue on a stalled link.
    private static let maxFramesInFlight = 3
    /// Exponential moving average of the frame send→ack round-trip. Drives adaptive sizing: a slow
    /// link shrinks frames so they cross faster, a fast link enlarges them for quality.
    private var rttEMA: TimeInterval = 0.15

    override init() {
        session = WCSession.isSupported() ? .default : nil
        super.init()
    }

    /// Activates the shared session. Safe to call once on launch; a no-op when unsupported.
    func activate() {
        guard let session else { return }
        session.delegate = self
        session.activate()
    }

    private var isReady: Bool {
        guard let session else { return false }
        return session.activationState == .activated && session.isReachable
    }

    /// Sends the latest state snapshot, coalescing to only send on change. State is tiny, so every
    /// change is sent; when the watch is unreachable the send is skipped (the watch shows its own
    /// "open OpenZCine on iPhone" placeholder from reachability).
    func ingestState(_ state: WatchRelayState) {
        guard state != lastSentState else { return }
        guard isReady, let session,
            let data = try? WatchRelayEnvelope.encode(kind: .state, payload: state)
        else { return }
        // Recorded only after an actual send: marking a skipped-while-unreachable state as sent
        // would coalesce every identical re-publish away, and the watch would never get it.
        lastSentState = state
        session.sendMessageData(data, replyHandler: nil, errorHandler: nil)
    }

    /// Buffers the latest frame (drop-stale) and pumps the backpressure send loop. CPU live-view
    /// callers pass their already display-baked image with `effects == nil`. Metal/demo callers pass
    /// the raw source plus active effects; those are applied only after downscaling and only when a
    /// pipeline slot is available. Encoding therefore stays off the main actor and link-paced.
    func ingestFrame(
        image: UIImage, applying effects: LiveImageEffects? = nil,
        timecode: Timecode, isRecording: Bool
    ) {
        guard isReady else { return }
        pendingFrame = (
            image: image, effects: effects, timecode: timecode, isRecording: isRecording
        )
        pumpFrames()
    }

    /// Sends buffered frames with up to `maxFramesInFlight` outstanding: encode off-main, then
    /// `sendMessageData` with a reply handler. Each watch ack frees a pipeline slot; if the link is
    /// slow the acks space out and the rate drops naturally — always the freshest frame, never a
    /// backlog.
    private func pumpFrames() {
        guard framesInFlight < Self.maxFramesInFlight, isReady, let pending = pendingFrame else {
            return
        }
        pendingFrame = nil
        framesInFlight += 1
        let params = adaptiveEncodingParams()
        let renderer = rendererForEffects(pending.effects)
        Task { @MainActor [weak self] in
            let data = await Self.encodeFrame(
                image: pending.image,
                effects: pending.effects,
                renderer: renderer,
                timecode: pending.timecode,
                isRecording: pending.isRecording,
                width: params.width,
                quality: params.quality)
            guard let self else { return }
            self.dispatchFrame(data)
        }
    }

    private func rendererForEffects(_ effects: LiveImageEffects?) -> LiveFrameRenderer? {
        guard let effects, !effects.isIdentity else { return nil }
        if let frameRenderer { return frameRenderer }
        let renderer = LiveFrameRenderer(fileStore: LUTFileStore())
        frameRenderer = renderer
        return renderer
    }

    private func dispatchFrame(_ data: Data?) {
        guard let data, isReady, let session else {
            frameAcked(sentAt: nil)
            return
        }
        // Send time rides in the ack closure: with several frames in flight, a shared "last
        // dispatch" timestamp would measure the wrong frame's round-trip.
        let sentAt = CFAbsoluteTimeGetCurrent()
        let ack = RelaySendableBox(value: { [weak self] in self?.frameAcked(sentAt: sentAt) })
        // @Sendable is load-bearing: without it these closures infer @MainActor isolation from
        // the enclosing context, and WatchConnectivity invoking them on its own queue trips the
        // Swift 6 dynamic isolation check (EXC_BREAKPOINT the moment the watch acks a frame).
        session.sendMessageData(
            data,
            replyHandler: { @Sendable _ in Task { @MainActor in ack.value() } },
            errorHandler: { @Sendable _ in Task { @MainActor in ack.value() } })
    }

    /// Watch acked (or the send failed) — measure round-trip, free a pipeline slot, send the next
    /// frame. `sentAt` is nil when the frame never hit the wire (encode failure / link dropped).
    private func frameAcked(sentAt: CFAbsoluteTime?) {
        if let sentAt {
            let rtt = CFAbsoluteTimeGetCurrent() - sentAt
            if rtt > 0, rtt < 5 { rttEMA = rttEMA * 0.8 + rtt * 0.2 }
        }
        // Clamped: a reachability reset zeroes the counter while stale acks may still arrive.
        framesInFlight = max(0, framesInFlight - 1)
        pumpFrames()
    }

    /// Picks encode dimensions from the current round-trip estimate: a slow link gets small frames
    /// (they cross faster, raising sustainable fps), a fast link gets larger frames for clarity.
    /// The fast tier matches the widest watch display (Ultra: 410 px) so the edge-to-edge feed is
    /// rendered 1:1, not upscaled.
    private func adaptiveEncodingParams() -> (width: CGFloat, quality: CGFloat) {
        switch rttEMA {
        case 0.35...: (width: 256, quality: 0.24)
        case 0.20..<0.35: (width: 336, quality: 0.28)
        default: (width: 416, quality: 0.32)
        }
    }

    /// Encodes a preview frame off the main actor (nonisolated async runs on the cooperative pool).
    private nonisolated static func encodeFrame(
        image: UIImage, effects: LiveImageEffects?, renderer: LiveFrameRenderer?,
        timecode: Timecode, isRecording: Bool,
        width: CGFloat, quality: CGFloat
    ) async -> Data? {
        guard
            let jpeg = await thumbnailJPEG(
                from: image, applying: effects, renderer: renderer,
                maxWidth: width, quality: quality)
        else {
            return nil
        }
        let frame = WatchRelayFrame(jpeg: jpeg, timecode: timecode, isRecording: isRecording)
        return try? WatchRelayEnvelope.encode(kind: .frame, payload: frame)
    }

    private func handleReachabilityChanged() {
        // Force the next state send even if the value is unchanged, so a freshly-reachable watch
        // gets a snapshot immediately.
        lastSentState = nil
        // A disconnect can strand in-flight frames (their acks never come); clear the pipeline so
        // the pump doesn't stall, then try to resume if the link came back up.
        framesInFlight = 0
        pendingFrame = nil
        onReachabilityChanged?()
        pumpFrames()
    }

    private func handleCommand(_ data: Data) -> Data {
        let fallback = WatchCommandResult(accepted: false, isRecording: false, error: "unavailable")
        guard let kind = try? WatchRelayEnvelope.kind(of: data), kind == .command else {
            return (try? WatchRelayEnvelope.encode(kind: .result, payload: fallback)) ?? Data()
        }
        let result: WatchCommandResult
        if let command = try? WatchRelayEnvelope.decode(WatchRelayCommand.self, from: data),
            command == .toggleRecord, let onToggleRecord
        {
            result = onToggleRecord()
        } else {
            result = fallback
        }
        return (try? WatchRelayEnvelope.encode(kind: .result, payload: result)) ?? Data()
    }

    /// Downscales to the preview width, optionally applies display effects, and encodes a small
    /// JPEG. Applying after the thumbnail is intentional: Metal's full-resolution bake stays on the
    /// GPU, while the Watch pays only for its adaptive 256/336/416-pixel frame. Internal so the
    /// actual LUT-to-JPEG path is regression-testable.
    nonisolated static func thumbnailJPEG(
        from image: UIImage, applying effects: LiveImageEffects? = nil,
        renderer: LiveFrameRenderer? = nil, maxWidth: CGFloat, quality: CGFloat
    ) async -> Data? {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return nil }
        // `UIImage.size` is points while the Watch payload budget is pixels. Marketing/demo images
        // can carry a 2x/3x scale, so size the prepared thumbnail in points that produce at most the
        // requested pixel width instead of accidentally sending a 1248 px JPEG for `maxWidth=416`.
        let imageScale = max(image.scale, 1)
        let pixelWidth = CGFloat(image.cgImage?.width ?? Int((size.width * imageScale).rounded()))
        let pixelHeight = CGFloat(
            image.cgImage?.height ?? Int((size.height * imageScale).rounded()))
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }
        let scale = min(1, maxWidth / pixelWidth)
        let target = CGSize(
            width: (pixelWidth * scale).rounded() / imageScale,
            height: (pixelHeight * scale).rounded() / imageScale)
        guard let thumb = await image.byPreparingThumbnail(ofSize: target) else { return nil }
        let displayImage: UIImage
        if let effects, !effects.isIdentity {
            guard let renderer else { return nil }
            displayImage = await renderer.renderStaticFrame(thumb, effects: effects)
        } else {
            displayImage = thumb
        }
        return displayImage.jpegData(compressionQuality: quality)
    }
}

extension WatchRelay: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // Re-activate to support switching between paired watches.
        WCSession.default.activate()
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in self?.handleReachabilityChanged() }
    }

    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        let reply = RelaySendableBox(value: replyHandler)
        Task { @MainActor [weak self] in
            let response = self?.handleCommand(messageData) ?? Data()
            reply.value(response)
        }
    }
}
