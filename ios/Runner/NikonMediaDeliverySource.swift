import Foundation
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineFrameIO
import OpenCineMedia
import OpenZCineCore
import os

/// Original library/canonical claim and immutable native export facts for one presentation.
@MainActor final class NikonMediaDeliveryCapture {
    weak var model: NativeAppModel?
    let action: NikonMediaLibraryAction
    let clips: [MediaClip]
    let store: MediaClipStore
    let cube: CubeLUT?
    let camera: NativeCameraIdentity?
    let lutLabel: String?
    let account: NikonFrameioAccount.Receipt
    let frameioConfiguration: FrameioConfiguration?
    var frameioDestination: FrameioDestination?
    /// The internet hop this delivery holds; once the camera session has gone, it is the source.
    var internetLease: NikonHopToken?
    private let originalURLs: [String: URL]
    init?(model: NativeAppModel, clips: [MediaClip], action: NikonMediaLibraryAction? = nil) {
        guard let action = action ?? model.captureMediaLibraryAction(clips), action.sourceIsCurrent
        else { return nil }
        self.model = model
        self.action = action
        self.clips = clips.map(action.capturedClip)
        store = model.mediaClipStore
        cube = model.currentLUTCube()
        camera = model.connectedIdentity
        switch model.assistConfiguration.selectedLUT {
        case .builtIn(let look): lutLabel = look.rawValue
        case .stored(_, let name): lutLabel = (name as NSString).deletingPathExtension
        }
        account = model.frameioAccount.capture()
        frameioConfiguration = model.frameioConfiguration
        frameioDestination = NikonFrameio.destinations.loaded
        originalURLs = Dictionary(
            clips.compactMap { clip in
                (try? model.mediaClipStore.localURL(
                    cameraID: clip.cameraID, filename: clip.filename)).map { (clip.id, $0) }
            }, uniquingKeysWith: { original, _ in original })
    }
    var isCurrent: Bool {
        guard let model, action.contentIsCurrent else { return false }
        if let route = internetLease, model.internetHop.owns(route) { return true }
        return action.sourceIsCurrent
    }
    func localURL(_ clip: MediaClip) -> URL? { originalURLs[clip.id] }
    func isCached(_ clip: MediaClip) -> Bool {
        guard let url = localURL(clip),
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
            attrs[.type] as? FileAttributeType == .typeRegular,
            let size = (attrs[.size] as? NSNumber)?.uint64Value, size > 0,
            FileManager.default.isReadableFile(atPath: url.path),
            (try? MonitorMediaShareStaging.validateShareableFile(at: url)) != nil
        else { return false }
        return clip.sizeBytes == 0 || size >= clip.sizeBytes
    }
    var originals: MonitorDeliveryOriginalService<MediaClip> {
        .init(
            available: { [self] in isCached($0) },
            acquire: { [self] clip in
                guard action.sourceIsCurrent, let owner = action.owner,
                    let record = owner.records.first(where: {
                        $0.payload.id == clip.id
                            && NikonMediaLibraryAction.sameContent($0.payload, clip)
                    })
                else { return }
                _ = try? await owner.cacheOriginal(record.asset.id)
            },
            progress: { [self] clip in
                guard let owner = action.owner,
                    let record = owner.records.first(where: { $0.payload.id == clip.id })
                else { return nil }
                return owner.progress[record.asset.id]
            })
    }
    func update(_ clip: MediaClip, _ change: (inout MediaClip) -> Void) {
        guard isCurrent else { return }
        store.update(cameraID: clip.cameraID, filename: clip.filename) { row in
            guard NikonMediaLibraryAction.sameContent(action.capturedClip(clip), row), isCurrent
            else { return }
            change(&row)
        }
        if action.sourceIsCurrent { action.publish() }
    }
    func metadata(_ clip: MediaClip, configuration: NikonDeliveryConfiguration)
        -> MediaClipDeliveryMetadata?
    {
        configuration.includeMetadata
            ? .from(clip, camera: camera, lutName: configuration.bakeLUT ? lutLabel : nil) : nil
    }
    func frameioClient(admission: MonitorDeliveryAdmission) throws -> FrameioClient {
        guard let config = frameioConfiguration else { throw FrameioError.notConfigured }
        guard account.isCurrent, admission.isCurrent() else { throw CancellationError() }
        return FrameioClient(
            config: config,
            transport: NikonFrameioAdmittedTransport(
                native: FrameioURLSessionTransport.interactive,
                admission: .init { admission.isCurrent() && self.account.isCurrent }),
            tokens: NikonFrameioCapturedTokens(account: account))
    }
    /// The output name: the camera original, re-extended only when a LUT bake transcodes it.
    func filename(_ clip: MediaClip, configuration: NikonDeliveryConfiguration) -> String {
        MonitorDeliveryFileNaming.filename(
            original: clip.filename, configuration: configuration,
            formatExtension: configuration.exportFormat.rawValue)
    }
    /// Exports one clip into the shared delivery store (A2-58); the run releases it.
    func export(
        _ clip: MediaClip, configuration: NikonDeliveryConfiguration,
        store exports: MonitorDeliveryExportStore, admission: MonitorDeliveryAdmission,
        progress: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> URL {
        guard admission.isCurrent(), let source = localURL(clip) else { throw CancellationError() }
        guard isCached(clip) else { throw MonitorClipDeliveryError.notCached(clip.filename) }
        if configuration.bakeLUT, cube == nil { throw MonitorClipDeliveryError.noLook }
        let output = try exports.outputURL(filename: filename(clip, configuration: configuration))
        do {
            let exported = try await MonitorReaderWriterMediaExporter.export(
                sourceURL: source, outputURL: output, format: configuration.exportFormat,
                cube: configuration.bakeLUT ? cube?.preparedForRenderer() : nil,
                metadata: metadata(clip, configuration: configuration),
                diagnostics: { NikonDelivery.logger.info("\($0, privacy: .public)") },
                timecodeDiagnostics: NikonDelivery.traceTimecode
            ) { fraction in
                Task { @MainActor in if admission.isCurrent() { progress(fraction) } }
            }
            guard admission.isCurrent() else { throw CancellationError() }
            if configuration.bakeLUT { update(clip) { $0.exportStatus = .exported } }
            return exported.videoURL
        } catch {
            exports.release(output)
            if admission.isCurrent() {
                let ns = error as NSError
                NikonDelivery.logger.error(
                    "clip failed \(clip.filename, privacy: .public): \(ns.domain, privacy: .public) code=\(ns.code) \(ns.localizedDescription, privacy: .public)"
                )
                if configuration.bakeLUT { update(clip) { $0.exportStatus = .failed } }
            }
            throw error
        }
    }
}
