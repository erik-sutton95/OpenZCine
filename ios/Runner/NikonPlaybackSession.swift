import Foundation
import Observation
import OpenCineAppKit
import OpenCineMedia

/// Borrows the actual gallery lifetime and immutable caller playlist. PTP/cache/rating stay
/// on NativeAppModel; the shared model owns the logical player instead of a second view state.
@MainActor final class NikonPlaybackSession {
    let owner: MonitorMediaPlaybackModel<MediaClip, String>
    let native: NikonPlaybackNativePort

    init(
        clips: [MediaClip], startingAt clip: MediaClip, model: NativeAppModel,
        native: NikonPlaybackNativePort = NikonPlaybackNativePort()
    ) throws {
        guard let library = model.mediaLibrary else { throw MonitorPlaybackError.unavailable }
        let codec = NikonMediaLibraryCodec(
            store: model.mediaClipStore, bucket: clip.cameraID, service: nil,
            downloaded: { model.isClipDownloaded($0) })
        let records = try clips.map(codec.record)
        guard let first = records.first(where: { $0.payload.id == clip.id }) else {
            throw MonitorPlaybackError.unavailable
        }
        self.native = native
        owner = MonitorMediaPlaybackModel<MediaClip, String>(
            library: library, native: native, readyTimeout: nil, retryNativeFailures: false,
            startTiming: .afterNativeItemInstallation,
            candidates: { record in native.candidates(for: record.payload, model: model) })
        native.isScrubbing = { [weak owner] in owner?.scrubbing ?? true }
        owner.load(first, playlist: records)
    }
    struct DeliveryPause {
        let item: MonitorPlaybackItemToken
        let resume: Bool
    }

    func pauseForDelivery(playing: Bool) -> DeliveryPause? {
        guard owner.isActive else { return nil }
        let captured = DeliveryPause(item: owner.token, resume: playing)
        owner.setPlaying(false)
        return captured
    }

    func resumeAfterDelivery(_ captured: DeliveryPause) {
        guard captured.resume, owner.isActive, owner.token == captured.item else { return }
        owner.setPlaying(true)
    }

    func navigate(to clip: MediaClip, clips: [MediaClip], model: NativeAppModel) {
        guard owner.isActive else { return }
        let codec = NikonMediaLibraryCodec(
            store: model.mediaClipStore, bucket: clip.cameraID, service: nil,
            downloaded: { model.isClipDownloaded($0) })
        guard let records = try? clips.map(codec.record),
            let next = records.first(where: { $0.payload.id == clip.id })
        else { return }
        owner.load(next, playlist: records)
    }

}

/// Exact retained Nikon presentation policy. This does not change shared transport seek math.
struct NikonPlaybackTailPresentation {
    private(set) var reachedEnd = false
    mutating func ended() { reachedEnd = true }
    mutating func reset() { reachedEnd = false }
    mutating func seeking(to time: Double, duration: Double) {
        guard duration > 0 else { return }
        if time < duration - 0.25 { reachedEnd = false }
    }
}

/// Source factory for the complete shared player. It borrows the original gallery request;
/// native video and calibrated effects are the only retained application owners.
@MainActor @Observable final class NikonOperatorPlaybackContext {
    let initial: MonitorMediaGalleryOpen<MediaClip>
    let library: MonitorMediaLibraryModel<MediaClip>
    @ObservationIgnored private let sourceAdmission: MonitorPlaybackAdmission
    @ObservationIgnored private let captureDeliveryCleanup:
        @MainActor () -> (@MainActor () async -> Void)
    @ObservationIgnored private weak var app: NativeAppModel?
    private struct Installation {
        let id: UUID
        let native: NikonPlaybackNativePort
        let assists: NikonPlaybackAssistAdapter
    }
    @ObservationIgnored private var installation: Installation?
    @ObservationIgnored private var factoryRevision = UUID()
    @ObservationIgnored private var notifying = false
    @ObservationIgnored private var pendingNotifications: [Field] = []
    private enum Field: Equatable { case native, assists }
    var native: NikonPlaybackNativePort? {
        access(keyPath: \.native)
        return installation?.native
    }
    var assists: NikonPlaybackAssistAdapter? {
        access(keyPath: \.assists)
        return installation?.assists
    }
    private func notify(_ fields: [Field]) {
        for field in fields where !pendingNotifications.contains(field) {
            pendingNotifications.append(field)
        }
        // A successor commits synchronously, while notification waits for the outgoing one-shot
        // observation callback to unregister. Reentering willSet would call that callback again.
        guard !notifying else { return }
        notifying = true
        defer { notifying = false }
        while !pendingNotifications.isEmpty {
            let field = pendingNotifications.removeFirst()
            switch field {
            case .native: withMutation(keyPath: \.native) {}
            case .assists: withMutation(keyPath: \.assists) {}
            }
        }
    }
    @ObservationIgnored lazy var media = MonitorOperatorMediaModel<MediaClip, String>(
        library: library,
        recordAdmission: { [weak self] record in
            guard let self, let app = self.app, self.sourceAdmission.isCurrent() else {
                return .init { false }
            }
            let action = app.captureMediaLibraryAction([record.payload])
            return .init { [weak self] in
                self?.sourceAdmission.isCurrent() == true && action?.sourceIsCurrent == true
                    && self?.sourceAdmission.isCurrent() == true
            }
        },
        makeAdmittedPlayback: { [weak self] library, admission in
            guard let self else { return nil }
            let revision = UUID()
            self.factoryRevision = revision
            guard let app = self.app, admission.isCurrent(), self.factoryRevision == revision else {
                return nil
            }
            let outgoing = self.assists
            outgoing?.close()
            guard admission.isCurrent(), self.factoryRevision == revision else { return nil }
            let previousTransfer = self.native?.captureEnteredTransferCleanup()
            let captureDelivery = self.captureDeliveryCleanup
            let native = NikonPlaybackNativePort(captureBeforePrepare: {
                let delivery = captureDelivery()
                return {
                    await previousTransfer?()
                    await delivery()
                }
            })
            let assists = NikonPlaybackAssistAdapter(model: app, native: native)
            let owner = MonitorMediaPlaybackModel<MediaClip, String>(
                library: library, native: native, readyTimeout: nil, retryNativeFailures: false,
                startTiming: .afterNativeItemInstallation,
                candidates: { [weak app] record in
                    guard let app else { return [] }
                    return native.candidates(for: record.payload, model: app)
                }, seekEndClearance: 0.25)
            owner.setItemAdmission { [weak self, weak app] record in
                let action = app?.captureMediaLibraryAction([record.payload])
                return .init { [weak self] in
                    self?.sourceAdmission.isCurrent() == true && action?.sourceIsCurrent == true
                        && self?.sourceAdmission.isCurrent() == true
                }
            }
            native.isScrubbing = { [weak owner] in owner?.scrubbing ?? true }
            guard admission.isCurrent(), self.factoryRevision == revision else {
                owner.close()
                assists.close()
                return nil
            }
            // One observable value commits both adapters before a synchronous observer can reenter.
            self.installation = .init(id: revision, native: native, assists: assists)
            self.notify([.native])
            if self.factoryRevision == revision, self.installation?.id == revision,
                admission.isCurrent(),
                self.factoryRevision == revision, self.installation?.id == revision
            {
                self.notify([.assists])
            }
            guard self.factoryRevision == revision, admission.isCurrent(),
                self.factoryRevision == revision, self.installation?.id == revision
            else {
                owner.close()
                assists.close()
                if self.factoryRevision == revision, self.installation?.id == revision {
                    self.installation = nil
                    self.notify([.native])
                    if self.factoryRevision == revision, self.installation?.id == nil {
                        self.notify([.assists])
                    }
                }
                return nil
            }
            return owner
        })

    init?(
        model: NativeAppModel, initial: MonitorMediaGalleryOpen<MediaClip>,
        captureDeliveryCleanup: @escaping @MainActor () -> (@MainActor () async -> Void) = { {} }
    ) {
        guard let library = model.mediaLibrary, library.isCurrent(initial.admission),
            let source = model.captureMediaLibraryAction([initial.record.payload]),
            source.sourceIsCurrent
        else { return nil }
        let directory = library.cache.directory
        let generation = directory.generation
        let namespace = directory.root
        sourceAdmission = .init {
            directory.generation == generation && directory.root == namespace
                && source.sourceIsCurrent
                && directory.generation == generation && directory.root == namespace
        }
        self.initial = initial
        self.library = library
        app = model
        self.captureDeliveryCleanup = captureDeliveryCleanup
    }

    /// Captures Back's SDK cleanup before the page schedules its asynchronous dismissal.
    /// The shared media owner retires the item; this leaf only joins its entered native work.
    func captureCloseCleanup(run: MonitorDeliveryRunHandle?) -> (@MainActor () async -> Bool)? {
        guard let owner = media.playback, let native,
            media.playback === owner, self.native === native
        else { return nil }
        media.closePlayback()
        let transfer = native.captureEnteredTransferCleanup()
        return { [weak self] in
            await run?.cancelAndJoin()
            await transfer()
            guard let self, self.media.playback == nil, self.native === native else { return false }
            return true
        }
    }
}
