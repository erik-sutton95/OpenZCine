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

    /// Activates the shared session. Safe to call from `onAppear`.
    func activate() {
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
                liveFPS: current.liveFPS)
            state = current
        }
    }

    private func ingest(_ data: Data) {
        guard let kind = try? WatchRelayEnvelope.kind(of: data) else { return }
        switch kind {
        case .state:
            if let decoded = try? WatchRelayEnvelope.decode(WatchRelayState.self, from: data) {
                state = decoded
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
