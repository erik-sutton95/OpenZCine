import AVFoundation
import OSLog
import Observation
import OpenCineAppKit
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

/// The measured source axis and selected monitor cube travel with each derivation.
struct NikonPlaybackScopeConfiguration: Equatable, Sendable {
    let trafficLightsCrushClip: MonitorCrushClipCompensation
    let mapping: ExposureSignalMapping
    let vectorscopeCube: CubeLUT?

    var transfer: MonitorTransfer {
        switch mapping.curve {
        case .redLog3G10: .log3G10
        case .nikonNLog: .nlog
        case .srgb: .srgb
        case .hlg: .hdr
        }
    }

    func bundle(samples: ScopeSamples, previous: ScopeAssistBundle) -> ScopeAssistBundle {
        var result = ScopeAssistSampling.bundle(
            samples: samples,
            trafficLightsCrushClip: trafficLightsCrushClip, mapping: mapping,
            vectorscopeCube: vectorscopeCube, previous: previous)
        result.transfer = transfer
        result.levelAxis = mapping.scopeLevelAxis
        return result
    }
}

/// Attaches Nikon's AVVideoComposition and audio tap to the one retained native item.
/// The shared scope session owns the read/derive loop; this adapter supplies calibrated values
/// and samples from the compositor source, before the display look and false color.
@MainActor @Observable final class NikonPlaybackAssistAdapter: MonitorPlaybackAssistService {
    private(set) var audioLevels: MonitorAudioMeterLevels?
    let scopes = MonitorPlaybackScopeSession<NikonPlaybackScopeConfiguration>(
        cadence: .milliseconds(84)
    ) {
        samples, configuration, previous in
        await Task.detached(priority: .utility) {
            configuration.bundle(samples: samples, previous: previous)
        }.value
    }
    @ObservationIgnored private weak var model: NativeAppModel?
    @ObservationIgnored private let native: NikonPlaybackNativePort
    @ObservationIgnored private let box = MediaLUT.PlaybackEffectsBox()
    @ObservationIgnored private let meter = MonitorPlaybackAudioMeterRuntime { status in
        playbackAudioLogger.error("MTAudioProcessingTapCreate failed: \(status)")
    }
    @ObservationIgnored private weak var installed: AVPlayerItem?
    @ObservationIgnored private var token: MonitorPlaybackItemToken?
    @ObservationIgnored private var admission: (@MainActor () -> Bool)?
    @ObservationIgnored private var revision = UUID()
    @ObservationIgnored private var request = UUID()
    @ObservationIgnored private var scopesVisible = false
    @ObservationIgnored private var audioVisible = false
    @ObservationIgnored private var polling = false
    @ObservationIgnored private var activated = false
    @ObservationIgnored private var closed = false

    var scopeBundle: ScopeAssistBundle {
        var value = scopes.bundle
        if value.levelAxis == nil, let model {
            let mapping = model.playbackExposureSignalMapping
            value.levelAxis = mapping.scopeLevelAxis
            value.transfer =
                NikonPlaybackScopeConfiguration(
                    trafficLightsCrushClip: model.assist.crushClipCompensation,
                    mapping: mapping, vectorscopeCube: nil
                ).transfer
            value.clipByte = Int(mapping.clipNative.rounded())
        }
        return value
    }

    init(model: NativeAppModel, native: NikonPlaybackNativePort) {
        self.model = model
        self.native = native
        native.beforeItemRetirement = { [weak self] in self?.retireNativeItem() }
        native.afterItemInstallation = { [weak self] item in self?.install(item) }
    }

    func activate() {
        guard !closed, !activated else { return }
        activated = true
        model?.setMediaPlaybackOwnsAudioSession(true)
        MediaPlaybackAudioSession.activateForPlayback()
    }

    func synchronize(
        item: MonitorPlaybackItemToken, effects: MonitorFrameEffects,
        audioVisible: Bool, outputMuted: Bool, ifCurrent: @escaping @MainActor () -> Bool
    ) {
        guard !closed else { return }
        request = UUID()
        let invocation = request
        let before = revision
        guard ifCurrent(), !closed, request == invocation, revision == before else { return }
        if token != item { revision = UUID() }
        let captured = revision
        token = item
        admission = ifCurrent
        self.audioVisible = audioVisible
        scopesVisible = effects.needsScopes
        activate()
        guard current(item, revision: captured, request: invocation) else { return }
        if let nativeItem = native.player.currentItem, installed !== nativeItem {
            install(nativeItem)
        }
        guard current(item, revision: captured, request: invocation), let model else { return }
        let resolved = model.resolvedPlaybackEffects()
        guard current(item, revision: captured, request: invocation) else { return }
        let changed = box.set(effects: resolved)
        if changed, native.player.rate == 0, let nativeItem = installed,
            native.player.currentItem === nativeItem, nativeItem.videoComposition != nil
        {
            nativeItem.videoComposition = box.makeVideoComposition(for: nativeItem.asset)
        }
        guard current(item, revision: captured, request: invocation) else { return }
        synchronizeSamples(item: item, revision: captured)
    }

    private func install(_ item: AVPlayerItem) {
        guard !closed, let token, native.player.currentItem === item,
            current(token, revision: revision), let model
        else { return }
        let captured = revision
        if installed !== item {
            meter.stopPolling()
            polling = false
            meter.detach(from: installed)
            audioLevels = nil
            guard current(token, revision: captured), native.player.currentItem === item else {
                return
            }
            installed = item
            if DemoHarness.mediaLUT { model.setAssist(.lut, visible: true) }
            guard current(token, revision: captured), native.player.currentItem === item else {
                return
            }
            _ = box.set(effects: model.resolvedPlaybackEffects())
            guard current(token, revision: captured), native.player.currentItem === item else {
                return
            }
            item.videoComposition = box.makeVideoComposition(for: item.asset)
            meter.attach(to: item)
        }
        synchronizeSamples(item: token, revision: captured)
    }

    private func synchronizeSamples(item: MonitorPlaybackItemToken, revision captured: UUID) {
        guard current(item, revision: captured), let model else { return }
        let configuration = NikonPlaybackScopeConfiguration(
            trafficLightsCrushClip: model.assist.crushClipCompensation,
            mapping: model.playbackExposureSignalMapping,
            vectorscopeCube: model.vectorscopeMonitorCube(
                visibleTools: model.assist.playbackTools,
                curve: model.playbackExposureSignalMapping.curve))
        guard current(item, revision: captured) else { return }
        box.setScopesActive(scopesVisible)
        scopes.synchronize(
            item: item, enabled: scopesVisible, configuration: configuration,
            read: { [weak self] in
                guard let self, self.current(item, revision: captured),
                    let installed = self.installed, self.native.player.currentItem === installed
                else { return nil }
                let snapshot = self.box.readScopeSnapshot()
                return .init(revision: snapshot.revision, samples: snapshot.samples)
            }, ifCurrent: { [weak self] in self?.current(item, revision: captured) == true })
        guard current(item, revision: captured) else { return }
        // The tap reads the source audio independently of output mute and conform playback.
        if audioVisible && !polling {
            polling = true
            meter.startPolling { [weak self] levels in
                guard let self, self.polling, self.current(item, revision: captured) else { return }
                self.audioLevels = levels
            }
        } else if !audioVisible {
            polling = false
            meter.stopPolling()
            audioLevels = nil
        }
    }

    private func current(
        _ item: MonitorPlaybackItemToken, revision captured: UUID, request expected: UUID? = nil
    ) -> Bool {
        guard !closed, revision == captured, token == item, native.token == item,
            expected == nil || request == expected, let admission
        else { return false }
        let admitted = admission()
        return admitted && !closed && revision == captured && token == item && native.token == item
            && (expected == nil || request == expected)
    }

    private func retireNativeItem() {
        let previous = token
        revision = UUID()
        request = UUID()
        token = nil
        admission = nil
        box.invalidateScopeComposition()
        box.setScopesActive(false)
        if let previous { scopes.retire(item: previous) }
        polling = false
        meter.stopPolling()
        meter.detach(from: installed)
        installed = nil
        audioLevels = nil
    }

    func close() {
        guard !closed else { return }
        closed = true
        retireNativeItem()
        scopes.close()
        meter.close()
        native.beforeItemRetirement = nil
        native.afterItemInstallation = nil
        if activated {
            MediaPlaybackAudioSession.deactivateAfterPlayback()
            model?.setMediaPlaybackOwnsAudioSession(false)
        }
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
