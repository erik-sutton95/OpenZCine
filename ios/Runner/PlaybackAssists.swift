import AVFoundation
import OSLog
import OpenCineApple
import OpenCineMedia
import OpenZCineCore

private let playbackAudioLogger = Logger(subsystem: "OpenZCine", category: "media-playback-audio")

/// Configures `AVAudioSession` for in-app clip playback so audio plays through the mute switch.
enum MediaPlaybackAudioSession {
    /// Activates `.playback` (like YouTube and other media apps).
    static func activateForPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
        } catch {
            playbackAudioLogger.error(
                "Failed to activate playback audio session: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// Releases the playback session when clip playback ends.
    static func deactivateAfterPlayback() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            playbackAudioLogger.error(
                "Failed to deactivate playback audio session: \(error.localizedDescription, privacy: .public)"
            )
        }
    }
}

/// Polls scope samples produced by ``MediaLUT/PlaybackEffectsBox`` during clip playback.
///
/// Scopes must read the compositor *source* frame (pre-LUT / pre-false-colour), matching live view.
/// `AVPlayerItemVideoOutput` reflects the graded presentation, so sampling is done inside the
/// composition handler and exposed through the effects box.
@MainActor
final class PlaybackScopeController {
    private var sampleTask: Task<Void, Never>?
    private var lastPublishedRevision: UInt64?

    func startPolling(
        effectsBox: MediaLUT.PlaybackEffectsBox,
        isActive: @escaping @MainActor () -> Bool,
        onSamples: @escaping @MainActor (OpenCineMedia.ScopeSamples) async -> Void
    ) {
        sampleTask?.cancel()
        lastPublishedRevision = nil
        sampleTask = Task { @MainActor in
            while !Task.isCancelled {
                if isActive() {
                    let snapshot = effectsBox.readScopeSnapshot()
                    if snapshot.revision != lastPublishedRevision {
                        lastPublishedRevision = snapshot.revision
                        await onSamples(snapshot.samples)
                    }
                }
                try? await Task.sleep(for: .milliseconds(84))
            }
        }
    }

    func stop() {
        sampleTask?.cancel()
        sampleTask = nil
        lastPublishedRevision = nil
    }
}

/// Actual native tap, track-query and meter-poll owner. Audio-session policy stays above it.
typealias PlaybackAudioMeterController = MonitorPlaybackAudioMeterRuntime

/// Loads the displayed video dimensions from an asset's primary video track.
func loadVideoDisplaySize(from asset: AVAsset) async -> CGSize? {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
    guard let naturalSize = try? await track.load(.naturalSize),
        let transform = try? await track.load(.preferredTransform)
    else { return nil }
    return videoDisplaySize(naturalSize: naturalSize, transform: transform)
}
