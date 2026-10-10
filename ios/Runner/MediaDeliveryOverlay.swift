import LinkPresentation
import MonitorPresentation
import MonitorUI
import OpenCineAppKit
import OpenCineFrameIO
import OpenCineMedia
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import os

/// What to do with exported clips when the destination is native share.
enum MediaDeliveryPostExportAction: Sendable {
    case systemShare
    case saveToPhotos
}

/// Parameters passed from the delivery popup when the operator confirms Share / Upload.
struct MediaDeliveryBeginRequest: Sendable {
    let clips: [MediaClip]
    let destination: MediaDeliveryDestination
    let configuration: MediaDeliveryConfiguration
    var postExportAction: MediaDeliveryPostExportAction = .systemShare
    var capture: NikonMediaDeliveryCapture? = nil
    var runAdmission: MonitorDeliveryAdmission? = nil
}

/// Outcome of a delivery run started from the overlay flow.
enum MediaDeliveryRunOutcome: Sendable {
    case share(urls: [URL], metadataText: String?, stagingCleanupURL: URL?)
    case savedToPhotos(count: Int)
    case frameio(summary: String)
    case failed(message: String)
}

/// Live progress for the on-clip delivery overlay.
struct MediaDeliveryOverlayState: Equatable, Sendable {
    /// Operator-visible step after export, when the determinate bar would otherwise freeze.
    enum Phase: Equatable, Sendable {
        case working
        case awaitingPhotosAccess
        case savingToPhotos
    }

    let destination: MediaDeliveryDestination
    let totalClips: Int
    var clipIndex: Int
    var clipFraction: Double
    /// True while on-camera clips are being pulled into the local cache before delivery.
    var isCaching = false
    /// True while the phone hops off the camera's Wi‑Fi to reach the internet (Frame.io on AP).
    var isSwitchingNetworks = false
    var postExportAction: MediaDeliveryPostExportAction = .systemShare
    var phase: Phase = .working

    var overallFraction: Double {
        guard totalClips > 0 else { return 0 }
        let completed = Double(max(0, clipIndex - 1))
        return min(1, (completed + clipFraction) / Double(totalClips))
    }

    var isPreparingClip: Bool { clipFraction <= 0 }

    /// Spinner stays up during permission and Photos ingest — the bar does not move then.
    var showsBusySpinner: Bool {
        isPreparingClip || isSwitchingNetworks || phase != .working
    }

    var percentText: String {
        guard !isPreparingClip, phase == .working else { return "" }
        return "\(Int((overallFraction * 100).rounded()))%"
    }

    var statusLine: String {
        if isSwitchingNetworks { return "Switching networks…" }
        switch phase {
        case .awaitingPhotosAccess:
            return "Waiting for Photos access…"
        case .savingToPhotos:
            return "Saving to Photos…"
        case .working:
            break
        }
        let verb: String
        if isCaching {
            verb = isPreparingClip ? "Caching from camera…" : "Caching from camera"
        } else {
            switch destination {
            case .nativeShare:
                if postExportAction == .saveToPhotos {
                    verb = isPreparingClip ? "Saving to Photos…" : "Saving to Photos"
                } else {
                    verb = isPreparingClip ? "Preparing…" : "Preparing to share"
                }
            case .frameio:
                verb = isPreparingClip ? "Preparing…" : "Uploading to Frame.io"
            }
        }
        if isPreparingClip { return verb }
        return "\(verb) \(percentText)"
    }

    var batchLine: String? {
        guard totalClips > 1 else { return nil }
        return "Clip \(min(clipIndex, totalClips)) of \(totalClips)"
    }
}

/// App-scoped delivery orchestration survives navigation through the shared run owner.
@MainActor
@Observable
final class MediaDeliveryCoordinator {
    private let lifetime:
        MonitorDeliveryModel<
            MediaDeliveryOwnedProgress, MediaDeliveryRunOutcome, MediaDeliveryShareResources
        >
    private let execute:
        @MainActor (
            MediaDeliveryBeginRequest, NativeAppModel,
            @escaping @MainActor (MediaDeliveryOverlayState) -> Void
        ) async -> MediaDeliveryRunOutcome

    init(
        sleep: @escaping @MainActor (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        },
        execute:
            @escaping @MainActor (
                MediaDeliveryBeginRequest, NativeAppModel,
                @escaping @MainActor (MediaDeliveryOverlayState) -> Void
            ) async -> MediaDeliveryRunOutcome = { request, model, progress in
                await MediaDeliveryRunner.execute(
                    request: request, model: model, onProgress: progress)
            }
    ) {
        self.execute = execute
        lifetime = .init(
            sleep: sleep,
            releaseShare: { resources in
                MediaShareStaging.cleanupStaging(at: resources.cleanupURL)
            })
    }

    var overlayState: MediaDeliveryOverlayState? { lifetime.state.progress?.overlay }
    var currentClipFilename: String? { lifetime.state.progress?.filename }
    var completionToast: String? { lifetime.state.toast }
    var isActive: Bool { lifetime.state.running }
    var showsLocalOverlay: Bool { lifetime.state.showsLocalOverlay }
    var showsGlobalChrome: Bool { isActive && !showsLocalOverlay }
    var isExpanded: Bool {
        get { lifetime.state.expanded }
        set { lifetime.setExpanded(newValue) }
    }
    var sharePayload: MediaSharePayload? {
        lifetime.state.share.map {
            .init(id: $0.id, urls: $0.payload.urls, metadataText: $0.payload.metadataText)
        }
    }
    /// A delayed nil setter belongs to the exact sheet built with this binding.
    var sharePresentation: Binding<MediaSharePayload?> {
        let presentedID = sharePayload?.id
        return Binding(
            get: { self.sharePayload },
            set: { value in
                if value == nil, let presentedID { self.clearSharePresentation(id: presentedID) }
            })
    }
    func enterLocalOverlayContext() { lifetime.enterLocalOverlayContext() }
    func exitLocalOverlayContext() { lifetime.exitLocalOverlayContext() }

    private(set) var capturedRun: MonitorDeliveryRunHandle?

    func begin(
        _ request: MediaDeliveryBeginRequest, model: NativeAppModel,
        onCancel: (() -> Void)? = nil,
        onComplete: ((MediaDeliveryRunOutcome) -> Void)? = nil
    ) {
        _ = beginCaptured(request, model: model, onCancel: onCancel, onComplete: onComplete)
    }

    @discardableResult func beginCaptured(
        _ request: MediaDeliveryBeginRequest, model: NativeAppModel,
        onCancel: (() -> Void)? = nil,
        onComplete: ((MediaDeliveryRunOutcome) -> Void)? = nil
    ) -> MonitorDeliveryRunHandle? {
        let outgoing = capturedRun
        let accepted = lifetime.beginCaptured(
            onCancel: onCancel,
            onComplete: { outcome in
                if request.capture?.completionIsCurrent != false { onComplete?(outcome) }
                return nil
            },
            operation: { progress, admission in
                await outgoing?.cancelAndJoin()
                guard admission.isCurrent() else { return .init(.failed(message: "Cancelled.")) }
                var captured = request
                captured.runAdmission = admission
                let outcome = await self.execute(captured, model) { overlay in
                    guard admission.isCurrent(), request.capture?.isCurrent != false else { return }
                    let index = min(max(overlay.clipIndex, 1), request.clips.count) - 1
                    let filename =
                        request.clips.indices.contains(index) ? request.clips[index].filename : nil
                    progress(.init(overlay: overlay, filename: filename))
                }
                guard request.capture?.completionIsCurrent != false else {
                    if case .share(_, _, let cleanup) = outcome {
                        MediaShareStaging.cleanupStaging(at: cleanup)
                    }
                    return .init(.failed(message: "Cancelled."))
                }
                switch outcome {
                case .share(let urls, let metadataText, let cleanup):
                    return .init(
                        outcome,
                        share: .init(urls: urls, metadataText: metadataText, cleanupURL: cleanup))
                case .savedToPhotos(let count):
                    return .init(
                        outcome, toast: "Saved \(count) \(count == 1 ? "clip" : "clips") to Photos")
                case .frameio(let summary): return .init(outcome, toast: summary)
                case .failed(let message): return .init(outcome, toast: message)
                }
            })
        capturedRun = accepted
        return accepted
    }

    /// Preflight is a captured run of the same delivery owner, joined before the route leaves.
    func cacheSelectionForDelivery(
        _ capture: NikonMediaDeliveryCapture,
        onStarted: (MonitorDeliveryRunHandle) -> Void
    ) async throws {
        let outgoing = capturedRun
        var cached: MonitorDeliveryCachedOriginals<MediaClip>?
        let accepted = lifetime.beginCaptured { progress, run in
            await outgoing?.cancelAndJoin()
            let admission = MonitorDeliveryAdmission {
                run.isCurrent() && capture.action.sourceIsCurrent && run.isCurrent()
            }
            cached = await MonitorDeliveryModel<
                MediaDeliveryOwnedProgress, MediaDeliveryRunOutcome, MediaDeliveryShareResources
            >.cacheOriginals(
                records: capture.clips, destination: .remoteUpload, admission: admission,
                originals: capture.originals, filename: { $0.filename }
            ) { value in
                progress(
                    .init(
                        overlay: .init(value, postExportAction: .systemShare),
                        filename: value.filename))
            }
            return .init(.frameio(summary: ""))
        }
        capturedRun = accepted
        if let accepted { onStarted(accepted) }
        await accepted?.awaitEnteredCleanup()
        guard capture.action.sourceIsCurrent, let cached, cached.uncached == 0 else {
            throw MediaDeliveryError.clipNotCached(
                capture.clips.first?.filename ?? "Selected clips")
        }
    }
    func cancel() { withAnimation(.spring(duration: 0.32)) { lifetime.cancel() } }
    /// The app root owns this lifetime; temporary gallery covers do not close it.
    func close() { lifetime.close() }
    func clearSharePresentation(id: UUID? = nil) { lifetime.clearSharePresentation(id: id) }
    @discardableResult func completeSharePresentation(id: UUID) -> Bool {
        lifetime.completeSharePresentation(id: id)
    }
}

private struct MediaDeliveryOwnedProgress: Sendable {
    let overlay: MediaDeliveryOverlayState
    let filename: String?
}
private struct MediaDeliveryShareResources: Sendable {
    let urls: [URL]
    let metadataText: String?
    let cleanupURL: URL?
}

/// Pins delivery chrome below the top safe area (notch / Dynamic Island in landscape).
struct MediaDeliveryTopAnchor<Content: View>: View {
    var horizontalPadding: CGFloat = 20
    var topPadding: CGFloat = 8
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack {
            content()
                .padding(.horizontal, horizontalPadding)
                .padding(.top, topPadding)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .safeAreaPadding(.top)
    }
}

/// Persistent delivery progress anchored at the app root when media views are not on screen.
struct MediaDeliveryGlobalOverlay: View {
    @Environment(MediaDeliveryCoordinator.self) private var coordinator

    var body: some View {
        ZStack {
            if coordinator.showsGlobalChrome, let state = coordinator.overlayState {
                MediaDeliveryTopAnchor {
                    Group {
                        if coordinator.isExpanded {
                            expandedPanel(state: state)
                        } else {
                            compactPill(state: state)
                        }
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(200)
            }

            if let toast = coordinator.completionToast, !coordinator.showsLocalOverlay {
                VStack {
                    Spacer()
                    Text(toast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LiveDesign.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .liquidGlass(in: Capsule(), interactive: false)
                        .padding(.bottom, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(199)
            }
        }
        .animation(.spring(duration: 0.32), value: coordinator.showsGlobalChrome)
        .animation(.spring(duration: 0.28), value: coordinator.isExpanded)
        .allowsHitTesting(coordinator.showsGlobalChrome || coordinator.completionToast != nil)
    }

    private func compactPill(state: MediaDeliveryOverlayState) -> some View {
        MonitorMediaDeliveryProgress(
            value: state.monitorProgressValue,
            onCancel: { coordinator.cancel() },
            onExpand: {
                withAnimation(.spring(duration: 0.28)) { coordinator.isExpanded = true }
            },
            destinationIcon: {
                Image(systemName: state.destination.systemImage)
                    .font(.system(size: 13, weight: .semibold))
            }
        )
        .frame(maxWidth: 420)
    }

    private func expandedPanel(state: MediaDeliveryOverlayState) -> some View {
        MonitorMediaDeliveryProgressPanel(
            value: state.monitorProgressValue,
            details: .init(
                filename: coordinator.currentClipFilename, destination: state.destination.title),
            onCancel: { coordinator.cancel() },
            onCollapse: {
                withAnimation(.spring(duration: 0.28)) { coordinator.isExpanded = false }
            },
            destinationIcon: { EmptyView() }
        )
        .frame(maxWidth: 420)
    }
}

/// Projects source-owned progress into the common expanded chrome on media surfaces.
struct MediaDeliveryOverlay: View {
    let state: MediaDeliveryOverlayState
    var onCancel: (() -> Void)?

    var body: some View {
        MonitorMediaDeliveryProgressPanel(
            value: state.monitorProgressValue,
            onCancel: onCancel,
            destinationIcon: { EmptyView() }
        )
        .frame(maxWidth: 420)
    }
}

/// Only the native file/account/route recipe. Shared batch owns ordering, progress and cleanup.
private struct NikonDeliveryArtifact: Sendable {
    let clip: MediaClip
    let export: MediaLUT.ExportResult
}

extension MediaDeliveryOverlayState {
    init(_ value: MonitorDeliveryBatchProgress, postExportAction: MediaDeliveryPostExportAction) {
        self.init(
            destination: value.destination == .nativeShare ? .nativeShare : .frameio,
            totalClips: value.totalClips, clipIndex: value.clipIndex,
            clipFraction: value.clipFraction,
            isCaching: value.isCaching, isSwitchingNetworks: value.isSwitchingNetworks,
            postExportAction: postExportAction,
            phase: value.stage == .awaitingPhotosAccess
                ? .awaitingPhotosAccess : value.stage == .saving ? .savingToPhotos : .working)
    }
}

@MainActor enum MediaDeliveryRunner {
    static func execute(
        request: MediaDeliveryBeginRequest, model: NativeAppModel,
        onProgress: @escaping (MediaDeliveryOverlayState) -> Void
    ) async -> MediaDeliveryRunOutcome {
        guard
            let capture = request.capture
                ?? NikonMediaDeliveryCapture(model: model, clips: request.clips)
        else {
            return .failed(message: "Cancelled.")
        }
        let run = request.runAdmission ?? .init { true }
        let remote = request.destination == .frameio
        let admission = MonitorDeliveryAdmission {
            run.isCurrent() && capture.isCurrent && run.isCurrent() && capture.isCurrent
                && (!remote || capture.account.isCurrent)
        }
        let internet: MonitorDeliveryInternetService<FrameioInternetHop.Token?> = .init(
            needsHop: { model.isOnCameraAccessPoint },
            begin: {
                let token = model.beginInternetHopCaptured(admission: {
                    run.isCurrent() && capture.action.sourceIsCurrent
                })
                capture.internetLease = token
                return token
            }, owns: { $0.map(model.ownsInternetHop) == true },
            wait: { token in
                guard let token else { return false }
                return await model.waitForInternetPath(captured: token, timeoutSeconds: 30)
            },
            restoreEntered: { token in
                if let token { await model.restoreInternetHop(token) }
            }, restore: { token in if let token { _ = model.endInternetHopCaptured(token) } })
        let exporter: MonitorDeliveryExportService<MediaClip, NikonDeliveryArtifact> = .init {
            clip, progress in
            let status =
                capture.store.list(cameraID: clip.cameraID).first { $0.id == clip.id }?
                .frameioStatus ?? clip.frameioStatus
            if remote, status == .uploaded, !request.configuration.forceFrameioReupload {
                return nil
            }
            do {
                let exported = try await capture.prepare(
                    clip, configuration: request.configuration,
                    admission: admission, progress: progress)
                return .init(clip: clip, export: exported)
            } catch {
                if admission.isCurrent() {
                    let ns = error as NSError
                    let detail = "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
                    Logger(subsystem: "OpenZCine", category: "media-export").error(
                        "clip failed \(clip.filename, privacy: .public): \(detail, privacy: .public)"
                    )
                }
                throw error
            }
        }
        let upload: MonitorDeliveryUploadService<NikonDeliveryArtifact> = .init(
            progressCaption: "Uploading to Frame.io"
        ) { artifact, progress in
            try await model.uploadCapturedFrameio(
                artifact.clip, source: artifact.export.videoURL,
                metadata: capture.metadata(artifact.clip, configuration: request.configuration),
                capture: capture, admission: admission, progress: progress)
        }
        let policy = MonitorDeliveryBatchPolicy(
            behavior: .init(
                nativeFailures: .continueItems, photosFailures: .continueItems,
                emptyUploadSucceeds: true, singleUploadFailureUsesDetail: false),
            nativeSummary: { counts in
                var parts: [String] = []
                if counts.failed > 0 {
                    parts.append("Prepared \(counts.prepared); \(counts.failed) failed.")
                }
                if counts.uncached > 0 {
                    parts.append("\(counts.uncached) clip(s) couldn't be cached from the camera.")
                }
                return parts.isEmpty ? nil : parts.joined(separator: " ")
            },
            photosFailure: { saved, failed in
                if saved == 0 || failed > 0 {
                    return MediaPhotosSaver.SaveError.partialFailure(saved: saved, failed: failed)
                        .localizedDescription
                }
                return nil
            },
            cacheFailure: {
                "Couldn't cache \($0) clip(s) from the camera - check the connection and try again."
            })
        let outcome = await MonitorDeliveryModel<
            MediaDeliveryOwnedProgress, MediaDeliveryRunOutcome, MediaDeliveryShareResources
        >.runBatch(
            records: capture.clips, destination: remote ? .remoteUpload : .nativeShare,
            action: request.postExportAction == .saveToPhotos ? .saveToPhotos : .systemShare,
            admission: admission, originals: capture.originals, exporter: exporter,
            share: { artifacts in
                let prepared = try MediaShareStaging.prepareForShare(
                    videoURLs: artifacts.map { $0.export.videoURL })
                return .init(
                    urls: prepared.urls.enumerated().map { index, url in
                        .init(
                            clip: artifacts[index].clip,
                            export: .init(videoURL: url, metadataURL: nil))
                    },
                    cleanup: prepared.stagingCleanupURL.map {
                        .init(
                            clip: artifacts[0].clip, export: .init(videoURL: $0, metadataURL: nil))
                    })
            },
            photos: .perItem { artifact in
                try MediaShareStaging.validateReadableFile(at: artifact.export.videoURL)
                try await MediaPhotosSaver.saveVideo(at: artifact.export.videoURL)
                return true
            },
            photosAuthorization: .init(
                isPending: { MediaPhotosSaver.addOnlyStatus == .notDetermined },
                authorize: { try await MediaPhotosSaver.ensureAuthorized() }),
            upload: remote ? upload : nil,
            internet: remote || capture.internetLease != nil ? internet : nil,
            lease: capture.internetLease.map { Optional($0) }, filename: { $0.filename },
            artifactFilename: { $0.export.videoURL.lastPathComponent },
            metadata: {
                request.configuration.includeMetadata ? model.metadataSummary(for: $0) : nil
            },
            noPrepared: { _ in "Nothing to share." }, policy: policy,
            progress: { value in
                onProgress(.init(value, postExportAction: request.postExportAction))
            })
        switch outcome {
        case .share(let urls, let text, let cleanup):
            return .share(
                urls: urls.map { $0.export.videoURL }, metadataText: text,
                stagingCleanupURL: cleanup?.export.videoURL)
        case .savedToPhotos(let count): return .savedToPhotos(count: count)
        case .uploaded(let summary): return .frameio(summary: summary)
        case .failed(let message): return .failed(message: message)
        }
    }
}

// MARK: - Share staging

/// Source directories and native content types over the shared file staging owner.
typealias PreparedMediaShare = MonitorMediaPreparedShare

enum MediaShareStaging {
    static let shareableVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]
    typealias StagingError = MonitorMediaShareStaging.StagingError

    static func isShareableVideo(_ url: URL) -> Bool {
        MonitorMediaShareStaging.isShareableVideo(url, extensions: shareableVideoExtensions)
    }

    static func filterShareableVideos(_ urls: [URL]) -> [URL] {
        MonitorMediaShareStaging.filterShareableVideos(urls, extensions: shareableVideoExtensions)
    }

    /// Maps export extensions to the native Launch Services content type.
    static func videoUTType(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "mov": .quickTimeMovie
        case "mp4", "m4v": .mpeg4Movie
        default: .movie
        }
    }

    static func validateReadableFile(at url: URL) throws {
        try MonitorMediaShareStaging.validateShareableFile(at: url)
    }

    static func validateShareableFile(at url: URL) throws {
        try MonitorMediaShareStaging.validateShareableFile(at: url)
    }

    static func prepareForShare(videoURLs: [URL]) throws -> PreparedMediaShare {
        try MonitorMediaShareStaging.prepare(
            videoURLs: videoURLs,
            exportsDirectory: FileManager.default.urls(
                for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("exports", isDirectory: true),
            stagingDirectory: stagingDirectory,
            shareableExtensions: shareableVideoExtensions, copyBufferBytes: 64 * 1024,
            checkCancellation: { try Task.checkCancellation() }
        )
    }

    static func cleanupStaging(at url: URL?) {
        MonitorMediaShareStaging.releaseReturnedLease(url)
    }

    private static var stagingDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenZCineShare", isDirectory: true)
    }
}

// MARK: - Save to Photos

/// Saves exported `.mp4` / `.mov` clips into the user's photo library.
enum MediaPhotosSaver {
    enum SaveError: LocalizedError {
        case permissionDenied
        case noVideos
        case saveFailed(String)
        case partialFailure(saved: Int, failed: Int)

        var errorDescription: String? {
            switch self {
            case .permissionDenied:
                "Photo library access is required to save clips. Enable it in Settings."
            case .noVideos:
                "No video files are ready to save."
            case .saveFailed(let name):
                "Couldn't save \(name) to Photos."
            case .partialFailure(let saved, let failed):
                "Saved \(saved); \(failed) couldn't be saved to Photos."
            }
        }
    }

    static var addOnlyStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func ensureAuthorized() async throws {
        switch addOnlyStatus {
        case .authorized, .limited:
            return
        case .notDetermined:
            let granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard granted == .authorized || granted == .limited else {
                throw SaveError.permissionDenied
            }
        default:
            throw SaveError.permissionDenied
        }
    }

    @MainActor static func saveVideos(at urls: [URL]) async throws -> Int {
        let videos = MediaShareStaging.filterShareableVideos(urls)
        guard !videos.isEmpty else { throw SaveError.noVideos }

        for url in videos {
            try MediaShareStaging.validateReadableFile(at: url)
        }

        try await ensureAuthorized()

        var saved = 0
        var failed = 0
        typealias Batch = MonitorDeliveryModel<
            MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<URL>, URL
        >
        let outcome = await Batch.runBatch(
            records: videos, destination: .nativeShare, action: .saveToPhotos,
            admission: .init { true },
            originals: .init(available: { _ in true }, acquire: { _ in }, progress: { _ in nil }),
            exporter: .init { url, _ in url }, share: nil,
            photos: .perItem { url in
                do {
                    try await saveVideo(at: url)
                    saved += 1
                    return true
                } catch {
                    failed += 1
                    throw error
                }
            },
            internet: Optional<MonitorDeliveryInternetService<FrameioInternetHop.Token>>.none,
            filename: { $0.lastPathComponent },
            policy: .init(
                behavior: .init(photosFailures: .continueItems),
                photosFailure: { saved, failed in
                    saved == 0 || failed > 0
                        ? SaveError.partialFailure(
                            saved: saved, failed: max(failed, saved == 0 ? videos.count : 0)
                        )
                        .localizedDescription : nil
                }),
            progress: { _ in })
        if case .savedToPhotos(let count) = outcome { return count }
        if Task.isCancelled { throw CancellationError() }
        throw SaveError.partialFailure(
            saved: saved, failed: max(failed, saved == 0 ? videos.count : 0))
    }

    static func saveVideo(at url: URL) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges(
                {
                    PHAssetCreationRequest.forAsset().addResource(
                        with: .video, fileURL: url, options: nil)
                },
                completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(throwing: SaveError.saveFailed(url.lastPathComponent))
                    }
                })
        }
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Share sheet

struct MediaSharePayload: Identifiable {
    let id: UUID
    let urls: [URL]
    let metadataText: String?
    init(id: UUID = UUID(), urls: [URL], metadataText: String?) {
        self.id = id
        self.urls = urls
        self.metadataText = metadataText
    }
}

/// Supplies a typed video file via `NSItemProvider` so Launch Services can resolve share targets.
///
/// Do not pass sandbox `file://` URLs as placeholder items or `LPLinkMetadata.originalURL` —
/// ShareSheet probes those paths and logs benign `NSOSStatusErrorDomain -10814` / `NSCocoaErrorDomain
/// 256` noise even when sharing succeeds.
private final class ShareableFileItem: NSObject, UIActivityItemSource {
    let fileURL: URL
    private let contentType: UTType
    private let displayName: String

    init(fileURL: URL) {
        self.fileURL = fileURL
        self.contentType = MediaShareStaging.videoUTType(for: fileURL)
        self.displayName = fileURL.lastPathComponent
    }

    private func makeItemProvider() -> NSItemProvider {
        let url = fileURL
        let type = contentType
        let provider = NSItemProvider()
        provider.suggestedName = displayName
        provider.registerFileRepresentation(
            forTypeIdentifier: type.identifier,
            fileOptions: [.openInPlace],
            visibility: .all
        ) { completion in
            completion(url, true, nil)
            return nil
        }
        return provider
    }

    func activityViewControllerPlaceholderItem(
        _ activityViewController: UIActivityViewController
    ) -> Any {
        makeItemProvider()
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        itemForActivityType activityType: UIActivity.ActivityType?
    ) -> Any? {
        makeItemProvider()
    }

    func activityViewController(
        _ activityViewController: UIActivityViewController,
        dataTypeIdentifierForActivityType activityType: UIActivity.ActivityType?
    ) -> String {
        contentType.identifier
    }

    func activityViewControllerLinkMetadata(
        _ activityViewController: UIActivityViewController
    ) -> LPLinkMetadata? {
        let metadata = LPLinkMetadata()
        metadata.title = displayName
        return metadata
    }
}

/// Hosts `UIActivityViewController` modally instead of embedding it as the SwiftUI sheet root.
///
/// Console noise such as `[ShareSheet] Failed to request default share mode … Code=-10814`,
/// `Only support loading options for CKShare and SWY types`, and `Failed to locate container app
/// bundle record` is emitted by iOS ShareSheet / Launch Services for sandboxed files and is benign
/// when the sheet presents and destinations work.
final class ShareActivityHostViewController: UIViewController {
    var shareURLs: [URL] = []
    var metadataText: String?
    var onFinished: (() -> Void)?

    private var didPresentShareSheet = false

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !didPresentShareSheet else { return }
        didPresentShareSheet = true

        for url in shareURLs {
            do {
                try MediaShareStaging.validateShareableFile(at: url)
            } catch {
                finishSharing()
                return
            }
        }

        var items: [Any] = shareURLs.map { ShareableFileItem(fileURL: $0) }
        if let metadataText, !metadataText.isEmpty {
            items.append(metadataText)
        }

        let controller = UIActivityViewController(
            activityItems: items, applicationActivities: nil)
        controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
            self?.finishSharing()
        }
        if let popover = controller.popoverPresentationController {
            popover.sourceView = view
            popover.sourceRect = CGRect(
                x: view.bounds.midX, y: view.bounds.midY, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        present(controller, animated: true)
    }

    private func finishSharing() {
        onFinished?()
    }
}

struct MultiShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let metadataText: String?
    var onFinished: () -> Void

    func makeUIViewController(context: Context) -> ShareActivityHostViewController {
        let host = ShareActivityHostViewController()
        host.shareURLs = urls
        host.metadataText = metadataText
        host.onFinished = onFinished
        host.view.backgroundColor = .clear
        return host
    }

    func updateUIViewController(_ controller: ShareActivityHostViewController, context: Context) {}
}

/// Presents the system share sheet from the current view hierarchy (not behind a `fullScreenCover`).
struct MediaDeliveryShareSheetModifier: ViewModifier {
    var enabled: Bool = true
    var onDismiss: (() -> Void)?

    @Environment(MediaDeliveryCoordinator.self) private var coordinator

    func body(content: Content) -> some View {
        if enabled {
            let delivery = coordinator
            let presentedID = delivery.sharePayload?.id
            content
                .sheet(
                    item: delivery.sharePresentation,
                    onDismiss: {
                        if let presentedID, delivery.completeSharePresentation(id: presentedID) {
                            onDismiss?()
                        }
                    },
                    content: { payload in
                        MultiShareSheet(
                            urls: payload.urls,
                            metadataText: payload.metadataText,
                            onFinished: {
                                if delivery.completeSharePresentation(id: payload.id) {
                                    onDismiss?()
                                }
                            }
                        )
                    }
                )
        } else {
            content
        }
    }
}

extension View {
    /// Binds the delivery coordinator's share payload to a `UIActivityViewController` sheet.
    func mediaDeliveryShareSheet(
        enabled: Bool = true,
        onDismiss: (() -> Void)? = nil
    ) -> some View {
        modifier(MediaDeliveryShareSheetModifier(enabled: enabled, onDismiss: onDismiss))
    }
}
