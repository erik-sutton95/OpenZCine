import AVFoundation
import Foundation
import Observation
import OpenCineAppKit
import OpenCineApple
import OpenCineMedia

/// Native file IO stays in the app: Nikon plays a growing cache before transfer completion.
/// Logical item, transport, conform and pointer lifetimes belong to MonitorMediaPlaybackModel.
/// The picture, scopes, assists and backdrop are the shared playback engine's: this port is one
/// `MonitorPlaybackFrameSource` over the shared feed, like the plain file owner.
@MainActor final class NikonPlaybackNativePort: MonitorPlaybackFrameSource {
    let player: AVPlayer
    let feed: MonitorPlaybackFeedSession
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    /// The installed item after it became current, and nil before the current item is released
    /// (the audio tap must leave the item before AVFoundation releases it).
    var onItemChanged: (@MainActor (AVPlayerItem?) -> Void)?
    var afterPlaybackEnd: (@MainActor (MonitorPlaybackItemToken) -> Void)?
    private(set) var token: MonitorPlaybackItemToken?
    var isScrubbing: @MainActor () -> Bool = { false }
    private var claimedOwner: UUID?
    private var source: Source?
    private var stream: NativeAppModel.MediaClipStreamTicket?
    private var timeObserver: Any?
    private var transportObserver: NSKeyValueObservation?
    private var statusObserver: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var probeAsset: AVURLAsset?
    private var metadataTask: Task<Void, Never>?
    private var transferObservationTask: Task<Void, Never>?
    private var progressiveAsset: MonitorAppleProgressiveAsset?
    private var bufferRecovery: MonitorApplePlaybackBufferRecovery?
    private var transferCompleted = false
    private var reportedFailure = false
    private var enteredTransfer: Task<Void, Never>?
    private var preparationBarrier: (@MainActor () async -> Void)?
    private var facts = MonitorPlaybackMetadata()
    private weak var preparedBufferItem: AVPlayerItem?
    private let playable: @MainActor (AVURLAsset) async -> Bool
    private let poll: @MainActor () async throws -> Void
    private let captureBeforePrepare: @MainActor () -> (@MainActor () async -> Void)

    /// Immutable actual clip/address/native primitive binding captured before preparation suspends.
    private struct Source: Sendable {
        let clip: MediaClip
        let item: MonitorPlaybackItem
        let downloaded: @MainActor @Sendable () -> Bool
        let readableBytes: @MainActor @Sendable () -> UInt64
        let observeProgress: @MainActor @Sendable () -> Void
        let start: @MainActor @Sendable () -> NativeAppModel.MediaClipStreamTicket?
        let cancel: @MainActor @Sendable (NativeAppModel.MediaClipStreamTicket) -> Void
    }

    init(
        player: AVPlayer = AVPlayer(),
        feed: MonitorPlaybackFeedSession = NikonPlaybackFeedSession(),
        playable: @escaping @MainActor (AVURLAsset) async -> Bool = {
            (try? await $0.load(.isPlayable)) == true
        },
        poll: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(400))
        },
        captureBeforePrepare: @escaping @MainActor () -> (@MainActor () async -> Void) = { {} }
    ) {
        self.player = player
        self.feed = feed
        self.playable = playable
        self.poll = poll
        self.captureBeforePrepare = captureBeforePrepare
    }

    func candidates(
        for clip: MediaClip, model: NativeAppModel,
        startStream: (@MainActor @Sendable () -> NativeAppModel.MediaClipStreamTicket?)? = nil
    ) -> [MonitorPlaybackCandidate] {
        guard let url = model.clipLocalURL(clip), token != nil else { return [] }
        let item = MonitorPlaybackItem(
            url: url, mimeType: clip.fileExtension == "mov" ? "video/quicktime" : "video/mp4",
            sourceKey: clip.id)
        source = Source(
            clip: clip, item: item,
            downloaded: { model.isClipDownloaded(clip) },
            readableBytes: {
                model.mediaClipStore.cachedByteCount(
                    cameraID: clip.cameraID, filename: clip.filename)
            },
            observeProgress: { _ = model.mediaDownloadProgress[clip.id] },
            start: startStream ?? { model.startClipStream(clip) },
            cancel: { model.cancelClipStream($0) })
        // This is the actual resolved cache path, which may still be growing. The generic
        // complete-download candidate would delay the first picture until the whole file arrives.
        return [.cached(item)]
    }

    func retireItem(for admitted: MonitorPlaybackItemToken) {
        guard claimedOwner == nil || claimedOwner == admitted.owner else { return }
        guard claimedOwner != nil || admitted.revision == 0 else { return }
        guard token == nil || admitted.revision >= token!.revision else { return }
        claimedOwner = admitted.owner
        token = admitted
        let barrier = captureBeforePrepare()
        guard current(admitted) else { return }
        retireNativeItem()
        guard current(admitted) else { return }
        preparationBarrier = barrier
        source = nil
        facts = .init()
    }

    func prepare(
        _ item: MonitorPlaybackItem, token admitted: MonitorPlaybackItemToken,
        readyTimeout: Duration?
    ) async throws -> MonitorPlaybackMetadata {
        guard current(admitted), let captured = source, captured.item == item else {
            throw MonitorPlaybackError.retired
        }
        let transfer = enteredTransfer
        let barrier = preparationBarrier
        // Join only the outgoing native operation and delivery run captured at retirement.
        // A later coordinator run must never become cleanup for this item.
        await transfer?.value
        await barrier?()
        guard current(admitted), !Task.isCancelled, source?.item == captured.item else {
            throw MonitorPlaybackError.retired
        }
        if !captured.downloaded() {
            guard captured.clip.sizeBytes > 0,
                captured.clip.sizeBytes != UInt64(UInt32.max),
                captured.clip.sizeBytes <= UInt64(Int64.max)
            else {
                throw MonitorPlaybackError.nativeFailure("The clip's full size is unavailable.")
            }
            guard let capturedStream = captured.start() else {
                throw MonitorPlaybackError.nativeFailure("The clip transfer is unavailable.")
            }
            stream = capturedStream
            // Observe only this existing transfer. Completion must also unblock a failed probe.
            transferObservationTask = Task { [weak self] in
                await capturedStream.task.value
                guard let self, !Task.isCancelled, self.current(admitted),
                    self.stream === capturedStream, self.source?.item == captured.item
                else { return }
                self.transferCompleted = true
                if let progressive = self.progressiveAsset {
                    if captured.downloaded() {
                        progressive.finish()
                    } else {
                        progressive.fail()
                    }
                }
            }
            while current(admitted), !Task.isCancelled, !captured.downloaded() {
                guard !transferCompleted else {
                    throw MonitorPlaybackError.nativeFailure("The clip transfer did not complete.")
                }
                if FileManager.default.fileExists(atPath: item.url.path) {
                    let probe = AVURLAsset(
                        url: item.url,
                        options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
                    probeAsset = probe
                    let canPlay = await playable(probe)
                    probe.cancelLoading()
                    guard current(admitted), !Task.isCancelled else {
                        throw MonitorPlaybackError.retired
                    }
                    if probeAsset === probe { probeAsset = nil }
                    if canPlay { break }
                }
                // Recreate each failed partial-file probe; AVFoundation may otherwise cache
                // an early unplayable answer for a file whose bytes subsequently arrive.
                try await poll()
            }
        }
        guard current(admitted), !Task.isCancelled else { throw MonitorPlaybackError.retired }
        guard !transferCompleted || captured.downloaded() else {
            throw MonitorPlaybackError.nativeFailure("The clip transfer did not complete.")
        }
        let asset: AVURLAsset
        if !captured.downloaded(), captured.clip.sizeBytes > 0,
            captured.clip.sizeBytes <= UInt64(Int64.max)
        {
            let progressive = try await MonitorAppleProgressiveAsset(
                file: item.url, contentLength: Int64(captured.clip.sizeBytes),
                contentType: captured.item.mimeType == "video/quicktime" ? .mov : .mp4,
                readableBytes: Int64(min(captured.readableBytes(), captured.clip.sizeBytes)))
            guard current(admitted), !Task.isCancelled, source?.item == captured.item else {
                progressive.close()
                throw MonitorPlaybackError.retired
            }
            // The captured transfer may end while the file descriptor opens off Main.
            guard !transferCompleted || captured.downloaded() else {
                progressive.close()
                throw MonitorPlaybackError.nativeFailure("The clip transfer did not complete.")
            }
            progressiveAsset = progressive
            asset = progressive.asset
            progressive.onFailure = { [weak self, weak progressive] error in
                guard let self, let progressive, self.current(admitted),
                    self.progressiveAsset === progressive, self.source?.item == captured.item,
                    let item = self.player.currentItem, item.asset === progressive.asset
                else { return }
                self.publishFailure(item, admitted: admitted, message: error.localizedDescription)
            }
            observeProgress(captured, progressive: progressive, admitted: admitted)
        } else {
            // Completed files retain the direct file path.
            asset = AVURLAsset(
                url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        }
        let nativeItem = AVPlayerItem(asset: asset)
        // The shared feed's output must be on the item before it becomes current.
        feed.prepare(nativeItem)
        player.replaceCurrentItem(with: nativeItem)
        player.automaticallyWaitsToMinimizeStalling = false
        if progressiveAsset != nil {
            bufferRecovery = MonitorApplePlaybackBufferRecovery(
                player: player, item: nativeItem,
                isCurrent: { [weak self] in
                    self?.current(admitted) == true && self?.player.currentItem === nativeItem
                },
                onTransport: { [weak self] state in
                    guard let self, self.current(admitted), self.player.currentItem === nativeItem
                    else { return }
                    self.onEvent?(admitted, .transport(state))
                })
        }
        observe(nativeItem, admitted: admitted)
        onItemChanged?(nativeItem)
        guard current(admitted), player.currentItem === nativeItem else {
            throw MonitorPlaybackError.retired
        }
        onEvent?(admitted, .itemInstalled)
        guard current(admitted), player.currentItem === nativeItem else {
            throw MonitorPlaybackError.retired
        }
        // The donor starts after attachment, without waiting for a finalized duration/header.
        // Native metadata is published independently and only for this exact attached item.
        metadataTask = Task { [weak self] in
            let size = await loadVideoDisplaySize(from: asset)
            let conform = await Self.loadConformSource(from: asset)
            guard let self, self.current(admitted), !Task.isCancelled,
                self.player.currentItem === nativeItem
            else { return }
            self.facts.width = size.map { Double($0.width) }
            self.facts.height = size.map { Double($0.height) }
            self.facts.conform = conform
            self.onEvent?(admitted, .metadata(self.facts))
        }
        preparedBufferItem = nativeItem
        return facts
    }

    private func observeProgress(
        _ captured: Source, progressive: MonitorAppleProgressiveAsset,
        admitted: MonitorPlaybackItemToken
    ) {
        guard current(admitted), progressiveAsset === progressive, source?.item == captured.item
        else { return }
        withObservationTracking {
            captured.observeProgress()
        } onChange: { [weak self, weak progressive] in
            Task { @MainActor in
                guard let self, let progressive, self.current(admitted),
                    self.progressiveAsset === progressive, self.source?.item == captured.item
                else { return }
                self.observeProgress(captured, progressive: progressive, admitted: admitted)
            }
        }
        let bytes = min(captured.readableBytes(), captured.clip.sizeBytes)
        guard current(admitted), progressiveAsset === progressive, source?.item == captured.item
        else { return }
        progressive.update(readableBytes: Int64(bytes))
        if captured.downloaded() { progressive.finish() }
    }

    private func observe(_ item: AVPlayerItem, admitted: MonitorPlaybackItemToken) {
        statusObserver = item.observe(\.status, options: [.initial, .new]) {
            [weak self] _, change in
            switch change.newValue {
            case .failed:
                Task { @MainActor in
                    self?.publishFailure(
                        item, admitted: admitted,
                        message: item.error?.localizedDescription ?? "Could not open that clip.")
                }
            case .readyToPlay:
                Task { @MainActor in
                    guard let self, self.current(admitted), self.player.currentItem === item
                    else { return }
                    self.feed.noteItemReady()
                }
            default: break
            }
        }
        if bufferRecovery == nil {
            transportObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) {
                [weak self] _, _ in
                Task { @MainActor in
                    guard let self, self.current(admitted), self.player.currentItem === item else {
                        return
                    }
                    let state: MonitorPlaybackTransportState?
                    if item.status != .readyToPlay {
                        state = nil
                    } else {
                        switch self.player.timeControlStatus {
                        case .paused: state = .paused
                        case .waitingToPlayAtSpecifiedRate: state = .waiting
                        case .playing: state = .playing
                        @unknown default: state = nil
                        }
                    }
                    guard self.current(admitted), self.player.currentItem === item else { return }
                    self.onEvent?(admitted, .transport(state))
                }
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.nativeDidEnd(item, admitted: admitted)
            }
        }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            Task { @MainActor in
                guard let self, self.current(admitted), self.player.currentItem === item else {
                    return
                }
                guard !self.isScrubbing() else { return }
                self.onEvent?(admitted, .position(time.seconds.isFinite ? time.seconds : nil))
                guard self.current(admitted), self.player.currentItem === item else { return }
                self.publishDuration(item, admitted: admitted)
            }
        }
    }

    private func publishFailure(
        _ item: AVPlayerItem, admitted: MonitorPlaybackItemToken, message: String
    ) {
        guard current(admitted), player.currentItem === item, !reportedFailure else { return }
        reportedFailure = true
        bufferRecovery?.pause()
        guard current(admitted), player.currentItem === item else { return }
        onEvent?(admitted, .failed(message))
    }

    /// Actual notification callback entry, also exercised with captured native items in the fixture.
    func nativeDidEnd(_ item: AVPlayerItem, admitted: MonitorPlaybackItemToken) {
        guard current(admitted), player.currentItem === item else { return }
        publishDuration(item, admitted: admitted)
        guard current(admitted), player.currentItem === item else { return }
        bufferRecovery?.pause()
        guard current(admitted), player.currentItem === item else { return }
        onEvent?(admitted, .playing(false))
        guard current(admitted), player.currentItem === item else { return }
        onEvent?(admitted, .ended)
        guard current(admitted), player.currentItem === item else { return }
        afterPlaybackEnd?(admitted)
    }

    private func publishDuration(_ item: AVPlayerItem, admitted: MonitorPlaybackItemToken) {
        let duration = item.duration.seconds
        guard duration.isFinite, duration > 0, facts.duration != duration else { return }
        facts.duration = duration
        onEvent?(admitted, .metadata(facts))
    }

    func play(rate: Double, token admitted: MonitorPlaybackItemToken) {
        guard current(admitted), player.currentItem != nil else { return }
        if let bufferRecovery {
            bufferRecovery.play(rate: rate)
            return
        }
        player.rate = Float(rate)
        onEvent?(admitted, .playing(true))
    }

    func pause(token admitted: MonitorPlaybackItemToken) {
        guard current(admitted) else { return }
        if let bufferRecovery {
            bufferRecovery.pause()
            return
        }
        player.pause()
        onEvent?(admitted, .playing(false))
    }

    func seek(seconds: Double, tolerance: Double, token admitted: MonitorPlaybackItemToken) async
        -> Bool
    {
        guard current(admitted), let item = player.currentItem else { return false }
        let completed = await withCheckedContinuation { continuation in
            player.seek(
                to: CMTime(seconds: seconds, preferredTimescale: 600),
                toleranceBefore: CMTime(seconds: tolerance, preferredTimescale: 600),
                toleranceAfter: CMTime(seconds: tolerance, preferredTimescale: 600)
            ) { completed in
                continuation.resume(returning: completed)
            }
        }
        return completed && current(admitted) && player.currentItem === item && !Task.isCancelled
    }

    func setMuted(_ muted: Bool, token admitted: MonitorPlaybackItemToken) {
        guard current(admitted) else { return }
        player.isMuted = muted
    }

    func close(token admitted: MonitorPlaybackItemToken) {
        guard let current = token, current.owner == admitted.owner,
            admitted.revision >= current.revision
        else { return }
        retireNativeItem()
        guard token == current else { return }
        token = nil
        source = nil
        onItemChanged = nil
        afterPlaybackEnd = nil
        feed.shutdown()
    }

    private func current(_ admitted: MonitorPlaybackItemToken) -> Bool { token == admitted }

    /// Current native temporal extent, independent of camera transfer byte completion.
    func bufferedThroughSeconds(token admitted: MonitorPlaybackItemToken) -> Double? {
        guard current(admitted), let captured = source, let item = preparedBufferItem,
            player.currentItem === item, item.status == .readyToPlay
        else { return nil }
        guard current(admitted), source?.item == captured.item,
            preparedBufferItem === item, player.currentItem === item
        else { return nil }
        let ranges = item.loadedTimeRanges
        guard current(admitted), source?.item == captured.item,
            preparedBufferItem === item, player.currentItem === item
        else { return nil }
        return ranges.map { CMTimeGetSeconds(CMTimeRangeGetEnd($0.timeRangeValue)) }
            .filter { $0.isFinite && $0 >= 0 }.max()
    }

    /// Back joins the actual entered native task after the shared item owner retires it.
    func captureEnteredTransferCleanup() -> (@MainActor () async -> Void) {
        let captured = enteredTransfer
        return { await captured?.value }
    }

    private func retireNativeItem() {
        preparedBufferItem = nil
        bufferRecovery?.close()
        bufferRecovery = nil
        progressiveAsset?.close()
        progressiveAsset = nil
        transferObservationTask?.cancel()
        transferObservationTask = nil
        transferCompleted = false
        reportedFailure = false
        metadataTask?.cancel()
        metadataTask = nil
        probeAsset?.cancelLoading()
        probeAsset = nil
        if let stream, let source {
            enteredTransfer = stream.task
            source.cancel(stream)
        }
        stream = nil
        // The actual audio tap must be detached before the AVPlayerItem is released.
        onItemChanged?(nil)
        feed.beginSourceChange()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        transportObserver = nil
        statusObserver = nil
        player.pause()
        (player.currentItem?.asset as? AVURLAsset)?.cancelLoading()
        player.replaceCurrentItem(with: nil)
    }

    private static func loadConformSource(from asset: AVURLAsset) async
        -> MonitorConformPreview.Source
    {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return .init()
        }
        guard let nominal = try? await track.load(.nominalFrameRate), nominal.isFinite, nominal > 0
        else { return .init() }
        let rate = Double(nominal)
        guard let minimum = try? await track.load(.minFrameDuration), minimum.isValid,
            minimum.seconds > 0
        else { return .init(captureRate: rate) }
        let impliedPeak = 1 / minimum.seconds
        return .init(captureRate: rate, isVariableFrameRate: impliedPeak > rate * 1.05)
    }
}
