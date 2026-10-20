import Foundation
import Observation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineMedia

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

/// Nikon's camera source for the shared playback host. It borrows the original gallery
/// request; the page runtime (feed, picture, assists, backdrop) is the shared one, with
/// `NikonPlaybackNativePort` as its frame source for the growing camera cache.
@MainActor final class NikonOperatorPlaybackContext: MonitorPlaybackPresentationSource {
    typealias Delivery = NikonDeliveryRequest
    let initial: MonitorMediaGalleryOpen<MediaClip>
    let library: MonitorMediaLibraryModel<MediaClip>
    let presentation: MonitorApplePlaybackPresentation<MediaClip, String>
    /// The page's app state: assists, delivery and the playback bus, backdrop and inspector.
    let host: NikonPlaybackHost
    /// The gallery source this page opened on: same cache generation, root and camera source.
    let sourceAdmission: MonitorPlaybackAdmission
    /// The app-scoped delivery owner this page presents and covers for.
    let delivery: MonitorDeliveryCoordinator
    /// Waits while a delivery caches from the camera; never cancels it (A2-54).
    private let cameraTransferReleased: @MainActor () async -> Void
    private weak var app: NativeAppModel?
    private var closeCleanupRevision: UUID?
    private var openRevision = UUID()

    /// The current item's Nikon frame source.
    var native: NikonPlaybackNativePort? { presentation.native as? NikonPlaybackNativePort }
    var assists: MonitorPlaybackAssistSession? { presentation.assists }

    private(set) lazy var media: MonitorOperatorMediaModel<MediaClip, String> = makeMedia()

    private func makeMedia() -> MonitorOperatorMediaModel<MediaClip, String> {
        let library = library
        return presentation.makeOwner(
            library: library,
            recordAdmission: { [weak self] record in self?.admission(record) ?? .init { false } },
            makeNative: { [weak self] feed in
                // Join only the outgoing native operation and delivery run captured now.
                let previousTransfer = self?.native?.captureEnteredTransferCleanup()
                let cameraTransferReleased = self?.cameraTransferReleased
                self?.openRevision = UUID()
                return NikonPlaybackNativePort(
                    feed: feed,
                    captureBeforePrepare: {
                        {
                            await previousTransfer?()
                            await cameraTransferReleased?()
                        }
                    })
            },
            makePlayback: { [weak self] native in
                let owner = MonitorMediaPlaybackModel<MediaClip, String>(
                    library: library, native: native,
                    readyTimeout: nil, retryNativeFailures: false,
                    startTiming: .afterNativeItemInstallation,
                    candidates: { [weak app = self?.app] record in
                        guard let app else { return [] }
                        return native.candidates(for: record.payload, model: app)
                    }, seekEndClearance: 0.25)
                owner.setItemAdmission { [weak self] record in
                    self?.admission(record) ?? .init { false }
                }
                native.isScrubbing = { [weak owner] in owner?.scrubbing ?? true }
                if DemoHarness.mediaLUT { self?.app?.setAssist(.lut, visible: true) }
                return owner
            })
    }

    init?(
        model: NativeAppModel, initial: MonitorMediaGalleryOpen<MediaClip>,
        delivery: MonitorDeliveryCoordinator? = nil,
        cameraTransferReleased: (@MainActor () async -> Void)? = nil
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
        // Resolved here, not as a closure-literal default: RunnerTests' @testable copies of an
        // async default can disagree on context size with the app's (swiftlang/swift#92017).
        self.cameraTransferReleased = cameraTransferReleased ?? {}
        let delivery = delivery ?? model.delivery
        self.delivery = delivery
        let host = NikonPlaybackHost(model: model, delivery: delivery)
        self.host = host
        presentation = .init(
            makeFeed: { [weak model] in NikonPlaybackFeedSession(model: model) },
            audioSession: model.playbackAudioSession,
            samples: { host.frameSamples },
            projectEffects: { [weak model] effects in
                model?.nikonPlaybackEffects(effects) ?? effects
            },
            onTapFailure: NikonPlaybackAudio.tapFailure,
            onAudioFailure: NikonPlaybackAudio.audioFailure,
            audioOwnership: { [weak model] owned in
                model?.setMediaPlaybackOwnsAudioSession(owned)
            })
    }

    private func admission(_ record: MonitorMediaRecord<MediaClip>) -> MonitorPlaybackAdmission {
        guard let app, sourceAdmission.isCurrent() else { return .init { false } }
        let action = app.captureMediaLibraryAction([record.payload])
        let sourceAdmission = sourceAdmission
        return .init {
            sourceAdmission.isCurrent() && action?.sourceIsCurrent == true
                && sourceAdmission.isCurrent()
        }
    }

    func makeOwner() -> MonitorOperatorMediaModel<MediaClip, String> { media }

    /// What the operator may do with `record` now.
    func access(_ record: MonitorMediaRecord<MediaClip>) -> MonitorMediaGalleryAccess {
        guard let model = app else { return .init(download: false, share: false, delete: false) }
        // The app-scoped delivery covers playback while it runs or its share sheet is pending.
        return .init(
            download: model.isConnected && record.payload.handle != nil
                && !model.isClipDownloaded(record.payload),
            share: model.isClipDownloaded(record.payload) || model.isConnected,
            delete: model.canDeleteMedia([record.payload]) && model.mediaBrowserSource == .camera
                && record.payload.handle != nil && !delivery.coversPlayback
                && model.mediaDeletionProgress == nil)
    }

    func operations(owner: MonitorOperatorMediaModel<MediaClip, String>)
        -> MonitorOperatorPlaybackOperations<MediaClip, String>
    {
        .init(
            captureDeletion: { [weak self] record in self?.captureDeletion(record) },
            favorite: { [weak self] record in self?.app?.toggleClipFavorite(record.payload) },
            access: { [weak self] record in
                self?.access(record) ?? .init(download: false, share: false, delete: false)
            },
            rating: .init(
                levels: [1, 2, 3, 4, 5], noticeDuration: .seconds(4),
                unavailableMessage: "Connect the camera to rate this clip",
                read: { [weak self] request in
                    guard request.isCurrent, let model = self?.app else { return nil }
                    return await model.mediaStarRating(for: request.record.payload)
                },
                commit: { [weak self] target, request in
                    guard request.isCurrent, let model = self?.app else { return .unavailable }
                    switch await model.setMediaStarRating(target, for: request.record.payload) {
                    case .confirmed(let value): return .confirmed(value)
                    case .refused(_, let message): return .refused(message)
                    case .offline: return .unavailable
                    }
                }))
    }

    /// Deleting removes the file a delivery may be reading, so this one action still ends the
    /// running delivery first.
    private func captureDeletion(_ record: MonitorMediaRecord<MediaClip>)
        -> MonitorOperatorPlaybackDeletionRequest?
    {
        guard let model = app, let owner = media.playback, let native,
            media.isCurrent(owner.token), owner.active?.asset.id == record.asset.id,
            access(record).delete == true
        else { return nil }
        let token = owner.token
        let run = delivery.capturedRun
        return model.capturePlaybackMediaDeletion(
            record.payload,
            cleanup: { [weak self] in
                guard let self, self.media.playback === owner, self.native === native,
                    self.media.isCurrent(token)
                else { return false }
                owner.close()
                let transfer = native.captureEnteredTransferCleanup()
                await run?.cancelAndJoin()
                await transfer()
                return self.media.playback === owner && self.native === native && owner.closed
                    && owner.token == .init(owner: token.owner, revision: token.revision &+ 1)
            })
    }

    func values(
        record: MonitorMediaRecord<MediaClip>, owner: MonitorOperatorMediaModel<MediaClip, String>
    ) -> MonitorPlaybackSourceValues {
        let clip = record.payload
        guard let model = app else { return .init(availability: .camera) }
        let mapping = model.playbackExposureSignalMapping
        var rows: [MonitorPlaybackMetadataValue] = []
        if let master = clip.linkedR3DFilename { rows.append(.init("Master", master)) }
        if let storage = clip.storageID { rows.append(.init("Storage", String(storage))) }
        return .init(
            availability: model.isClipDownloaded(clip) ? .original : .camera,
            progress: model.mediaDownloadProgress[clip.id],
            colorLabel: mapping.curve.rawValue,
            transfer: mapping.curve.monitorTransfer, clipByte: mapping.clipByte,
            metadata: rows,
            bufferedThroughSeconds: presentation.bufferedThroughSeconds(
                record: record, owner: owner))
    }

    /// The share popup's request: captured while this item and its camera source are current.
    func delivery(
        record: MonitorMediaRecord<MediaClip>, owner: MonitorOperatorMediaModel<MediaClip, String>
    ) -> NikonDeliveryRequest? {
        guard let model = app, let playback = owner.playback, owner.isCurrent(playback.token),
            access(record).share == true,
            let capture = NikonMediaDeliveryCapture(model: model, clips: [record.payload]),
            owner.isCurrent(playback.token), capture.isCurrent
        else { return nil }
        return .init(capture: capture)
    }

    /// Back joins the entered native transfer after the shared owner retired the item; an
    /// app-scoped delivery goes on (A2-54). A second Back while one joins never dismisses.
    func captureClose(owner: MonitorOperatorMediaModel<MediaClip, String>)
        -> (@MainActor () async -> Bool)?
    {
        guard let finish = captureCloseCleanup() else { return { false } }
        return finish
    }

    /// Captures Back's SDK cleanup before the page schedules its asynchronous dismissal.
    /// The shared media owner retires the item; this leaf only joins its entered native work.
    func captureCloseCleanup() -> (@MainActor () async -> Bool)? {
        let revision = openRevision
        guard closeCleanupRevision != revision else { return nil }
        let capturedNative = native
        guard media.playback == nil || capturedNative != nil else { return nil }
        closeCleanupRevision = revision
        // Shared retirement can clear the player before the unavailable surface offers Close.
        // Keep its native cleanup join, including the empty join of a refused first open.
        if media.playback != nil { media.closePlayback() }
        let transfer = capturedNative?.captureEnteredTransferCleanup()
        return { [weak self] in
            await transfer?()
            guard let self, self.openRevision == revision,
                self.media.playback == nil, self.native === capturedNative
            else { return false }
            return true
        }
    }
}
