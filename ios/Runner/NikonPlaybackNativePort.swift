import AVFoundation
import Foundation
import OpenCineAppKit
import OpenCineMedia

/// Native file IO stays in the app: Nikon plays a growing cache before transfer completion.
/// Logical item, transport, conform and pointer lifetimes belong to MonitorMediaPlaybackModel.
@MainActor final class NikonPlaybackNativePort: MonitorPlaybackPort {
    let player: AVPlayer
    var onEvent: (@MainActor @Sendable (MonitorPlaybackItemToken, MonitorPlaybackEvent) -> Void)?
    var beforeItemRetirement: (@MainActor () -> Void)?
    var afterItemInstallation: (@MainActor (AVPlayerItem) -> Void)?
    var afterPlaybackEnd: (@MainActor (MonitorPlaybackItemToken) -> Void)?
    private(set) var token: MonitorPlaybackItemToken?
    var isScrubbing: @MainActor () -> Bool = { false }
    private var claimedOwner: UUID?
    private var source: Source?
    private var stream: NativeAppModel.MediaClipStreamTicket?
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var probeAsset: AVURLAsset?
    private var metadataTask: Task<Void, Never>?
    private var enteredTransfer: Task<Void, Never>?
    private var preparationBarrier: (@MainActor () async -> Void)?
    private var facts = MonitorPlaybackMetadata()
    private let playable: @MainActor (AVURLAsset) async -> Bool
    private let poll: @MainActor () async throws -> Void
    private let captureBeforePrepare: @MainActor () -> (@MainActor () async -> Void)

    /// Immutable actual clip/address/native primitive binding captured before preparation suspends.
    private struct Source {
        let clip: MediaClip
        let item: MonitorPlaybackItem
        let downloaded: @MainActor () -> Bool
        let start: @MainActor () -> NativeAppModel.MediaClipStreamTicket?
        let cancel: @MainActor (NativeAppModel.MediaClipStreamTicket) -> Void
    }

    init(
        player: AVPlayer = AVPlayer(),
        playable: @escaping @MainActor (AVURLAsset) async -> Bool = {
            (try? await $0.load(.isPlayable)) == true
        },
        poll: @escaping @MainActor () async throws -> Void = {
            try await Task.sleep(for: .milliseconds(400))
        },
        captureBeforePrepare: @escaping @MainActor () -> (@MainActor () async -> Void) = { {} }
    ) {
        self.player = player
        self.playable = playable
        self.poll = poll
        self.captureBeforePrepare = captureBeforePrepare
    }

    func candidates(for clip: MediaClip, model: NativeAppModel) -> [MonitorPlaybackCandidate] {
        guard let url = model.clipLocalURL(clip), token != nil else { return [] }
        let item = MonitorPlaybackItem(
            url: url, mimeType: clip.fileExtension == "mov" ? "video/quicktime" : "video/mp4",
            sourceKey: clip.id)
        source = Source(
            clip: clip, item: item,
            downloaded: { model.isClipDownloaded(clip) },
            start: { model.startClipStream(clip) },
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
        let transfer = enteredTransfer, barrier = preparationBarrier
        // Join only the outgoing native operation and delivery run captured at retirement.
        // A later coordinator run must never become cleanup for this item.
        await transfer?.value
        await barrier?()
        guard current(admitted), !Task.isCancelled, source?.item == captured.item else {
            throw MonitorPlaybackError.retired
        }
        if !captured.downloaded() {
            stream = captured.start()
            while current(admitted), !Task.isCancelled, !captured.downloaded() {
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
        let asset = AVURLAsset(
            url: item.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let nativeItem = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: nativeItem)
        player.automaticallyWaitsToMinimizeStalling = false
        observe(nativeItem, admitted: admitted)
        afterItemInstallation?(nativeItem)
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
        return facts
    }

    private func observe(_ item: AVPlayerItem, admitted: MonitorPlaybackItemToken) {
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

    /// Actual notification callback entry, also exercised with captured native items in the fixture.
    func nativeDidEnd(_ item: AVPlayerItem, admitted: MonitorPlaybackItemToken) {
        guard current(admitted), player.currentItem === item else { return }
        publishDuration(item, admitted: admitted)
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
        player.rate = Float(rate)
        onEvent?(admitted, .playing(true))
    }

    func pause(token admitted: MonitorPlaybackItemToken) {
        guard current(admitted) else { return }
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
        beforeItemRetirement = nil
        afterItemInstallation = nil
        afterPlaybackEnd = nil
    }

    private func current(_ admitted: MonitorPlaybackItemToken) -> Bool { token == admitted }

    /// Back joins the actual entered native task after the shared item owner retires it.
    func captureEnteredTransferCleanup() -> (@MainActor () async -> Void) {
        let captured = enteredTransfer
        return { await captured?.value }
    }

    private func retireNativeItem() {
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
        beforeItemRetirement?()
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        player.pause()
        if let item = player.currentItem {
            item.videoComposition = nil
            (item.asset as? AVURLAsset)?.cancelLoading()
        }
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
