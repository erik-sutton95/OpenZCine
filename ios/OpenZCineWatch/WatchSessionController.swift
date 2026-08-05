import Foundation
import SwiftUI
import UIKit
import WatchConnectivity

/// watchOS-side WatchConnectivity client. Decodes the relay envelopes from the iPhone into an
/// observable model the UI renders, and sends the Record toggle command back with a reply handler.
@MainActor
@Observable
final class WatchSessionController: NSObject {
    /// Latest decoded preview frame, if any.
    private(set) var feedImage: UIImage?
    /// Timecode from the most recent frame — updates at frame rate, so the top bar reads this
    /// instead of the (discrete, low-rate) state snapshot for a live timecode.
    private(set) var frameTimecode: Timecode?
    /// Latest state snapshot from the phone, if any.
    private(set) var state: WatchRelayState?
    /// Whether the iPhone relay is currently reachable.
    private(set) var isReachable = false
    /// True while a Record toggle command is awaiting its reply.
    private(set) var isSendingCommand = false

    @ObservationIgnored private let session: WCSession? =
        WCSession.isSupported() ? .default : nil

    /// TEMPORARY (#141 diagnosis): bumped by hand each deploy, so the log proves which binary is
    /// actually on the wrist rather than which one Xcode believes it installed.
    static let buildStamp = "photo-mode-1"

    /// Activates the shared session. Safe to call from `onAppear`.
    func activate() {
        NSLog("[ZCWATCH] watch build=\(Self.buildStamp) activate")
        guard let session else { return }
        session.delegate = self
        if session.activationState != .activated {
            session.activate()
        }
        isReachable = session.isReachable
        #if targetEnvironment(simulator)
            if feedImage == nil { feedImage = Self.sampleFrame }
        #endif
    }

    /// Re-establishes the link after the app returns to the foreground (#187).
    ///
    /// A dimmed display suspends the watch app; `onAppear` does not run again on wake, so nothing
    /// re-armed the session and the wrist kept showing whatever frame it had when the screen went
    /// out. This re-asserts delegate and activation — both survive suspension, but re-asserting is
    /// cheap and covers a session torn down under memory pressure — refreshes reachability from the
    /// live value rather than trusting the last delegate callback (which may have fired while
    /// suspended), and asks the phone for a fresh snapshot and a restarted pump.
    func resume() {
        activate()
        guard let session, session.isReachable else { return }
        guard
            let data = try? WatchRelayEnvelope.encode(
                kind: .command, payload: WatchRelayCommand.resume)
        else { return }
        // The reply is discarded on purpose: the phone pushes a full state snapshot as soon as the
        // pump restarts, and that is the authority. Acting on the ack too would briefly paint the
        // phone's pre-resume record state over it. @Sendable for the same reason as the Record
        // reply below.
        session.sendMessageData(
            data, replyHandler: { @Sendable _ in }, errorHandler: { @Sendable _ in })
    }

    /// Releases the shutter on the phone's camera. Shares the Record toggle's in-flight guard so a
    /// double tap cannot queue two releases.
    func sendCapture() {
        guard let session, session.isReachable, !isSendingCommand else { return }
        guard
            let data = try? WatchRelayEnvelope.encode(
                kind: .command, payload: WatchRelayCommand.capture)
        else { return }
        isSendingCommand = true
        session.sendMessageData(
            data,
            replyHandler: { @Sendable reply in
                Task { @MainActor [weak self] in self?.handleCommandReply(reply) }
            },
            errorHandler: { @Sendable _ in
                Task { @MainActor [weak self] in self?.isSendingCommand = false }
            })
    }

    /// Sends a Record toggle to the phone. No-ops when not reachable.
    func sendToggleRecord() {
        guard let session, session.isReachable, !isSendingCommand else { return }
        guard
            let data = try? WatchRelayEnvelope.encode(
                kind: .command, payload: WatchRelayCommand.toggleRecord)
        else { return }
        isSendingCommand = true
        // @Sendable is load-bearing: without it these closures infer @MainActor isolation from
        // the enclosing context, and WatchConnectivity invoking them on its own reply queue trips
        // the Swift 6 dynamic isolation check (EXC_BREAKPOINT on the command reply).
        session.sendMessageData(
            data,
            replyHandler: { @Sendable reply in
                Task { @MainActor [weak self] in self?.handleCommandReply(reply) }
            },
            errorHandler: { @Sendable _ in
                Task { @MainActor [weak self] in self?.isSendingCommand = false }
            })
    }

    private func handleCommandReply(_ data: Data) {
        isSendingCommand = false
        guard let kind = try? WatchRelayEnvelope.kind(of: data), kind == .result else { return }
        guard
            let result = try? WatchRelayEnvelope.decode(WatchCommandResult.self, from: data)
        else { return }
        if var current = state {
            current = WatchRelayState(
                recordState: result.isRecording ? .recording : .standby,
                timecode: current.timecode,
                mediaStatus: current.mediaStatus,
                media: current.media,
                cameraBatteryPercent: current.cameraBatteryPercent,
                cameraName: current.cameraName,
                isRecording: result.isRecording,
                connection: current.connection,
                feedLive: current.feedLive,
                liveFPS: current.liveFPS,
                // Carried, not defaulted: this rebuild runs on every command ack, and dropping
                // them would snap the wrist out of stills chrome on each shutter release.
                isPhotography: current.isPhotography,
                shotsRemaining: current.shotsRemaining,
                feedAspectRatio: current.feedAspectRatio)
            state = current
        }
    }

    private func ingest(_ data: Data) {
        guard let kind = try? WatchRelayEnvelope.kind(of: data) else { return }
        switch kind {
        case .state:
            if let decoded = try? WatchRelayEnvelope.decode(WatchRelayState.self, from: data) {
                // TEMPORARY (#141 diagnosis): what actually survived the wire, on change only.
                if decoded.isPhotography != state?.isPhotography
                    || decoded.shotsRemaining != state?.shotsRemaining
                {
                    NSLog(
                        "[ZCWATCH] watch build=\(Self.buildStamp)"
                            + " isPhotography=\(decoded.isPhotography)"
                            + " shots=\(decoded.shotsRemaining.isEmpty ? "-" : decoded.shotsRemaining)"
                            + " aspect=\(String(format: "%.4f", decoded.feedAspectRatio))")
                }
                state = decoded
            } else {
                NSLog("[ZCWATCH] watch build=\(Self.buildStamp) STATE DECODE FAILED")
            }
        case .frame:
            if let frame = try? WatchRelayEnvelope.decode(WatchRelayFrame.self, from: data) {
                frameTimecode = frame.timecode
                if let image = UIImage(data: frame.jpeg) {
                    feedImage = image
                }
            }
        case .command, .result:
            break
        }
    }
}

extension WatchSessionController: WCSessionDelegate {
    nonisolated func session(
        _ session: WCSession,
        activationDidCompleteWith activationState: WCSessionActivationState,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.isReachable = WCSession.default.isReachable
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        Task { @MainActor [weak self] in
            self?.isReachable = WCSession.default.isReachable
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessageData messageData: Data) {
        Task { @MainActor [weak self] in self?.ingest(messageData) }
    }

    /// Frame path: the phone paces sends off this ack, so reply immediately on WC's own queue —
    /// the ack must measure link time only. Waiting for the main-actor decode before acking would
    /// fold UI scheduling into the phone's RTT estimate and halve the frame rate for nothing
    /// (decode of a sub-500 px JPEG is milliseconds; the pipeline depth already bounds backlog).
    nonisolated func session(
        _ session: WCSession,
        didReceiveMessageData messageData: Data,
        replyHandler: @escaping (Data) -> Void
    ) {
        replyHandler(Data())
        Task { @MainActor [weak self] in self?.ingest(messageData) }
    }

    #if targetEnvironment(simulator)
        /// A synthetic 16:9 gradient so the monitor layout can be screenshot-verified in the simulator
        /// without a live phone session. Compiled out on hardware.
        private static let sampleFrame: UIImage? = {
            let size = CGSize(width: 320, height: 180)
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            guard
                let ctx = CGContext(
                    data: nil,
                    width: Int(size.width),
                    height: Int(size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                )
            else { return nil }
            let colors =
                [
                    CGColor(srgbRed: 0.30, green: 0.20, blue: 0.60, alpha: 1),
                    CGColor(srgbRed: 0.20, green: 0.60, blue: 0.70, alpha: 1),
                ] as CFArray
            guard
                let gradient = CGGradient(
                    colorsSpace: colorSpace, colors: colors, locations: [0, 1])
            else { return nil }
            ctx.drawLinearGradient(
                gradient,
                start: .zero,
                end: CGPoint(x: size.width, y: size.height),
                options: []
            )
            guard let cg = ctx.makeImage() else { return nil }
            return UIImage(cgImage: cg)
        }()
    #endif
}
