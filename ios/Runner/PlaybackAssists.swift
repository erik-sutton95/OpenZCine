import AVFoundation
import Accelerate
import MediaToolbox
import OSLog
import os

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
        onSamples: @escaping @MainActor (ScopeSamples) async -> Void
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

// MARK: - Playback audio metering

/// Lock-guarded per-channel linear peak accumulator shared between the `MTAudioProcessingTap`
/// render-thread callbacks and the main-actor polling loop. The tap's C callbacks touch nothing
/// but this box (retained via the tap's storage) — no MainActor state crosses that boundary.
final class AudioLevelTapBox: @unchecked Sendable {
    /// Processing format captured by the tap's `prepare` callback (float32 check + interleaving).
    private struct State {
        var leftPeak: Float = 0
        var rightPeak: Float = 0
        var isFloat32 = false
        var isInterleaved = false
        var channelCount = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func setFormat(_ description: AudioStreamBasicDescription) {
        state.withLock {
            $0.isFloat32 =
                description.mFormatID == kAudioFormatLinearPCM
                && description.mFormatFlags & kAudioFormatFlagIsFloat != 0
                && description.mBitsPerChannel == 32
            $0.isInterleaved = description.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
            $0.channelCount = Int(description.mChannelsPerFrame)
        }
    }

    var format: (isFloat32: Bool, isInterleaved: Bool, channelCount: Int) {
        state.withLock { ($0.isFloat32, $0.isInterleaved, $0.channelCount) }
    }

    func ingest(left: Float, right: Float) {
        state.withLock {
            $0.leftPeak = max($0.leftPeak, left)
            $0.rightPeak = max($0.rightPeak, right)
        }
    }

    /// Returns and clears the loudest linear amplitudes observed since the previous read.
    func readAndReset() -> (left: Float, right: Float) {
        state.withLock { current in
            let peaks = (current.leftPeak, current.rightPeak)
            current.leftPeak = 0
            current.rightPeak = 0
            return peaks
        }
    }
}

/// Creates the audio-mix tap that meters playback levels. Isolated in a nonisolated enum so the
/// C-function-pointer callbacks can never infer actor isolation or capture context — they reach
/// the shared `AudioLevelTapBox` exclusively through the tap's storage pointer.
enum AudioLevelTapFactory {
    /// Builds an `MTAudioProcessingTap` that passes source audio through untouched while recording
    /// per-channel peak amplitudes into `box`. Returns `nil` if tap creation fails (playback then
    /// simply runs unmetered).
    static func makeTap(box: AudioLevelTapBox) -> MTAudioProcessingTap? {
        var callbacks = MTAudioProcessingTapCallbacks(
            version: kMTAudioProcessingTapCallbacksVersion_0,
            clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(box).toOpaque()),
            init: { _, clientInfo, tapStorageOut in
                tapStorageOut.pointee = clientInfo
            },
            finalize: { tap in
                // Balances the `passRetained` above — AVFoundation calls this exactly once when
                // the mix releases the tap, so the box cannot leak or dangle across clip switches.
                Unmanaged<AudioLevelTapBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .release()
            },
            prepare: { tap, _, processingFormat in
                Unmanaged<AudioLevelTapBox>.fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                    .setFormat(processingFormat.pointee)
            },
            unprepare: nil,
            process: { tap, numberFrames, _, bufferListInOut, numberFramesOut, flagsOut in
                // Pull source audio through unchanged — metering must never alter the output.
                let status = MTAudioProcessingTapGetSourceAudio(
                    tap, numberFrames, bufferListInOut, flagsOut, nil, numberFramesOut)
                guard status == noErr else { return }
                let box = Unmanaged<AudioLevelTapBox>
                    .fromOpaque(MTAudioProcessingTapGetStorage(tap))
                    .takeUnretainedValue()
                let format = box.format
                guard format.isFloat32 else { return }
                let buffers = UnsafeMutableAudioBufferListPointer(bufferListInOut)
                var left: Float = 0
                var right: Float = 0
                if format.isInterleaved, let buffer = buffers.first, let data = buffer.mData {
                    let channels = max(1, format.channelCount)
                    let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                    let frames = sampleCount / channels
                    guard frames > 0 else { return }
                    let samples = data.assumingMemoryBound(to: Float.self)
                    vDSP_maxmgv(samples, vDSP_Stride(channels), &left, vDSP_Length(frames))
                    if channels > 1 {
                        vDSP_maxmgv(
                            samples + 1, vDSP_Stride(channels), &right, vDSP_Length(frames))
                    } else {
                        right = left
                    }
                } else {
                    // Deinterleaved: one buffer per channel (AVPlayer's canonical tap format).
                    for (index, buffer) in buffers.enumerated() where index < 2 {
                        guard let data = buffer.mData else { continue }
                        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                        guard count > 0 else { continue }
                        var peak: Float = 0
                        vDSP_maxmgv(
                            data.assumingMemoryBound(to: Float.self), 1, &peak,
                            vDSP_Length(count))
                        if index == 0 { left = peak } else { right = peak }
                    }
                    if buffers.count < 2 { right = left }
                }
                box.ingest(left: left, right: right)
            }
        )
        var tap: MTAudioProcessingTap?
        let status = MTAudioProcessingTapCreate(
            kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PostEffects, &tap)
        guard status == noErr, let tap else {
            // Creation failed before AVFoundation took ownership — `finalize` will never run, so
            // release the retained box here to balance `passRetained`.
            Unmanaged.passUnretained(box).release()
            playbackAudioLogger.error("MTAudioProcessingTapCreate failed: \(status)")
            return nil
        }
        return tap
    }
}

/// Installs an audio-level tap on each playback item and polls it into `AudioMeterLevels` for the
/// playback audio-meters panel. Attach/detach follow the player-item lifecycle; polling follows the
/// tool toggle. Ballistics (attack/decay/peak-hold) are `AudioMeterBallistics` in the core.
@MainActor
final class PlaybackAudioMeterController {
    private let box = AudioLevelTapBox()
    private var pollTask: Task<Void, Never>?
    private var attachGeneration = 0

    /// Builds an audio mix tapping the item's first audio track and installs it. Async (track
    /// loading) and generation-guarded so a superseded clip can't install onto a stale item.
    func attach(to item: AVPlayerItem) {
        attachGeneration += 1
        let generation = attachGeneration
        Task { @MainActor [weak self, weak item] in
            guard let self, let item else { return }
            guard let track = try? await item.asset.loadTracks(withMediaType: .audio).first
            else { return }
            guard generation == self.attachGeneration else { return }
            guard let tap = AudioLevelTapFactory.makeTap(box: self.box) else { return }
            let parameters = AVMutableAudioMixInputParameters(track: track)
            parameters.audioTapProcessor = tap
            let mix = AVMutableAudioMix()
            mix.inputParameters = [parameters]
            item.audioMix = mix
        }
    }

    /// Removes the tap before the item tears down (releasing an item with a live tap is the
    /// classic MTAudioProcessingTap crash), and invalidates any in-flight attach.
    func detach(from item: AVPlayerItem?) {
        attachGeneration += 1
        item?.audioMix = nil
        _ = box.readAndReset()
    }

    /// Starts publishing ballistics-smoothed levels ~24 Hz. Restarts cleanly if already polling.
    func startPolling(onLevels: @escaping @MainActor (AudioMeterLevels) -> Void) {
        pollTask?.cancel()
        pollTask = Task { @MainActor [box] in
            var levels = AudioMeterLevels.silent
            var lastTick = CFAbsoluteTimeGetCurrent()
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(42))
                if Task.isCancelled { return }
                let now = CFAbsoluteTimeGetCurrent()
                let dt = now - lastTick
                lastTick = now
                let peaks = box.readAndReset()
                levels = AudioMeterLevels(
                    left: AudioMeterBallistics.step(
                        levels.left, peakLinear: Double(peaks.left), dt: dt),
                    right: AudioMeterBallistics.step(
                        levels.right, peakLinear: Double(peaks.right), dt: dt))
                onLevels(levels)
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }
}

/// Loads the displayed video dimensions from an asset's primary video track.
func loadVideoDisplaySize(from asset: AVAsset) async -> CGSize? {
    guard let track = try? await asset.loadTracks(withMediaType: .video).first else { return nil }
    guard let naturalSize = try? await track.load(.naturalSize),
        let transform = try? await track.load(.preferredTransform)
    else { return nil }
    return videoDisplaySize(naturalSize: naturalSize, transform: transform)
}
