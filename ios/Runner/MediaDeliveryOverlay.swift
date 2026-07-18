import LinkPresentation
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

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
}

/// Outcome of a delivery run started from the overlay flow.
enum MediaDeliveryRunOutcome: Sendable {
    case share(urls: [URL], metadataText: String?, stagingCleanupURL: URL?)
    case savedToPhotos(count: Int)
    case frameio(summary: String)
    case failed(message: String)
}

/// Live progress for the on-clip delivery overlay.
struct MediaDeliveryOverlayState: Equatable {
    let destination: MediaDeliveryDestination
    let totalClips: Int
    var clipIndex: Int
    var clipFraction: Double
    /// True while on-camera clips are being pulled into the local cache before delivery.
    var isCaching = false
    /// True while the phone hops off the camera's Wi‑Fi to reach the internet (Frame.io on AP).
    var isSwitchingNetworks = false

    var overallFraction: Double {
        guard totalClips > 0 else { return 0 }
        let completed = Double(max(0, clipIndex - 1))
        return min(1, (completed + clipFraction) / Double(totalClips))
    }

    var isPreparingClip: Bool { clipFraction <= 0 }

    var percentText: String {
        guard !isPreparingClip else { return "" }
        return "\(Int((overallFraction * 100).rounded()))%"
    }

    var statusLine: String {
        if isSwitchingNetworks { return "Switching networks…" }
        let verb: String
        if isCaching {
            verb = isPreparingClip ? "Caching from camera…" : "Caching from camera"
        } else {
            switch destination {
            case .nativeShare:
                verb = isPreparingClip ? "Preparing…" : "Preparing to share"
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

/// App-scoped delivery orchestration — survives navigation; drives global and on-clip overlays.
@MainActor
@Observable
final class MediaDeliveryCoordinator {
    private(set) var overlayState: MediaDeliveryOverlayState?
    var isExpanded = false
    var sharePayload: MediaSharePayload?
    /// Staging directory removed after the share sheet finishes (idempotent cleanup).
    private(set) var shareStagingCleanupURL: URL?
    private(set) var completionToast: String?

    private var deliveryTask: Task<Void, Never>?
    private var activeRequest: MediaDeliveryBeginRequest?
    private var cancelHandler: (() -> Void)?
    private var localOverlayDepth = 0
    /// Guards against stale progress callbacks re-showing the bar after a run finishes.
    private var activeDeliveryToken = UUID()

    var isActive: Bool { overlayState != nil }

    /// When a media view is visible, it claims the on-clip overlay; otherwise the global pill shows.
    var showsLocalOverlay: Bool { localOverlayDepth > 0 }

    var showsGlobalChrome: Bool { isActive && !showsLocalOverlay }

    var currentClipFilename: String? {
        guard let state = overlayState, let request = activeRequest else { return nil }
        let index = min(max(state.clipIndex, 1), request.clips.count) - 1
        guard request.clips.indices.contains(index) else { return nil }
        return request.clips[index].filename
    }

    func enterLocalOverlayContext() {
        localOverlayDepth += 1
    }

    func exitLocalOverlayContext() {
        localOverlayDepth = max(0, localOverlayDepth - 1)
    }

    /// Starts export/upload work detached from the presenting view's lifecycle.
    func begin(
        _ request: MediaDeliveryBeginRequest,
        model: NativeAppModel,
        onCancel: (() -> Void)? = nil,
        onComplete: ((MediaDeliveryRunOutcome) -> Void)? = nil
    ) {
        deliveryTask?.cancel()
        let token = UUID()
        activeDeliveryToken = token
        activeRequest = request
        cancelHandler = onCancel
        isExpanded = false

        deliveryTask = Task { @MainActor in
            let outcome = await MediaDeliveryRunner.execute(
                request: request,
                model: model
            ) { [weak self] state in
                guard let self, self.activeDeliveryToken == token else { return }
                self.overlayState = state
            }
            guard activeDeliveryToken == token else { return }
            finishDeliveryRun(
                token: token,
                outcome: outcome,
                onComplete: onComplete
            )
        }
    }

    func cancel() {
        activeDeliveryToken = UUID()
        deliveryTask?.cancel()
        deliveryTask = nil
        cancelHandler?()
        cancelHandler = nil
        withAnimation(.spring(duration: 0.32)) {
            overlayState = nil
            activeRequest = nil
            isExpanded = false
        }
    }

    private func finishDeliveryRun(
        token: UUID,
        outcome: MediaDeliveryRunOutcome,
        onComplete: ((MediaDeliveryRunOutcome) -> Void)?
    ) {
        guard activeDeliveryToken == token else { return }
        activeDeliveryToken = UUID()
        deliveryTask = nil
        withAnimation(.spring(duration: 0.32)) {
            overlayState = nil
            activeRequest = nil
            cancelHandler = nil
            isExpanded = false
        }
        onComplete?(outcome)
        handleOutcome(outcome)
    }

    func dismissCompletionToast() {
        completionToast = nil
    }

    /// Dismisses the share sheet and deletes any cache staging directory.
    func clearSharePresentation() {
        let cleanup = shareStagingCleanupURL
        shareStagingCleanupURL = nil
        sharePayload = nil
        MediaShareStaging.cleanupStaging(at: cleanup)
    }

    private func handleOutcome(_ outcome: MediaDeliveryRunOutcome) {
        switch outcome {
        case .share(let urls, let metadataText, let stagingCleanupURL):
            shareStagingCleanupURL = stagingCleanupURL
            sharePayload = MediaSharePayload(urls: urls, metadataText: metadataText)
        case .savedToPhotos(let count):
            let noun = count == 1 ? "clip" : "clips"
            showCompletionToast("Saved \(count) \(noun) to Photos")
        case .frameio(let summary):
            showCompletionToast(summary)
        case .failed(let message):
            showCompletionToast(message)
        }
    }

    private func showCompletionToast(_ message: String) {
        withAnimation { completionToast = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            if completionToast == message {
                withAnimation { completionToast = nil }
            }
        }
    }
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
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(duration: 0.28)) { coordinator.isExpanded = true }
            } label: {
                HStack(spacing: 10) {
                    if state.isPreparingClip {
                        ProgressView()
                            .controlSize(.small)
                            .tint(LiveDesign.accent)
                    } else {
                        Image(systemName: state.destination.systemImage)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(LiveDesign.accent)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.statusLine)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(LiveDesign.text)
                            .lineLimit(1)
                        if let batchLine = state.batchLine {
                            Text(batchLine)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(LiveDesign.muted)
                        }
                    }

                    Spacer(minLength: 4)

                    if !state.isPreparingClip {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule()
                                    .fill(LiveDesign.hairline.opacity(0.55))
                                Capsule()
                                    .fill(LiveDesign.accent)
                                    .frame(width: max(4, geo.size.width * state.overallFraction))
                            }
                        }
                        .frame(width: 44, height: 4)
                    }
                }
            }
            .buttonStyle(.zcTapTarget)

            Button("Cancel") { coordinator.cancel() }
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(LiveDesign.muted)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: 420)
        .liquidGlass(in: Capsule())
    }

    private func expandedPanel(state: MediaDeliveryOverlayState) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MediaDeliveryOverlay(state: state) { coordinator.cancel() }

            if let filename = coordinator.currentClipFilename {
                HStack(spacing: 6) {
                    Text("File")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(LiveDesign.muted)
                    Text(filename)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(LiveDesign.text)
                        .lineLimit(1)
                }
            }

            Text("Destination: \(state.destination.title)")
                .font(.system(size: 11))
                .foregroundStyle(LiveDesign.muted)

            Button("Collapse") {
                withAnimation(.spring(duration: 0.28)) { coordinator.isExpanded = false }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(LiveDesign.accent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(maxWidth: 420)
    }
}

/// Semi-transparent progress pill anchored over video or the media grid.
struct MediaDeliveryOverlay: View {
    let state: MediaDeliveryOverlayState
    var onCancel: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                if state.isPreparingClip {
                    ProgressView()
                        .controlSize(.small)
                        .tint(LiveDesign.accent)
                }

                VStack(alignment: .leading, spacing: 3) {
                    if let batchLine = state.batchLine {
                        Text(batchLine)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LiveDesign.muted)
                    }
                    Text(state.statusLine)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }

                Spacer(minLength: 8)

                if let onCancel {
                    Button("Cancel", action: onCancel)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(LiveDesign.muted)
                }
            }

            if !state.isPreparingClip {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(LiveDesign.hairline.opacity(0.55))
                        Capsule()
                            .fill(LiveDesign.accent)
                            .frame(width: max(4, geo.size.width * state.overallFraction))
                    }
                }
                .frame(height: 4)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
    }
}

/// Runs delivery after the options popup dismisses; reports progress for overlay binding.
@MainActor
enum MediaDeliveryRunner {
    static func execute(
        request: MediaDeliveryBeginRequest,
        model: NativeAppModel,
        onProgress: @escaping (MediaDeliveryOverlayState) -> Void
    ) async -> MediaDeliveryRunOutcome {
        // Cache on-camera clips first, sequentially (one PTP data channel); clips that still
        // can't cache (disconnected, no handle) are reported, not silently dropped.
        let toCache = request.clips.filter { !model.isClipDownloaded($0) }
        var uncachedCount = 0
        if !toCache.isEmpty {
            var caching = MediaDeliveryOverlayState(
                destination: request.destination,
                totalClips: toCache.count,
                clipIndex: 1,
                clipFraction: 0,
                isCaching: true
            )
            onProgress(caching)
            for (index, clip) in toCache.enumerated() {
                if Task.isCancelled {
                    return .failed(message: "Cancelled.")
                }
                caching.clipIndex = index + 1
                caching.clipFraction = 0
                onProgress(caching)
                // streamClip publishes per-clip progress on the model; mirror it onto the
                // delivery overlay while the download runs.
                let progressMirror = Task { @MainActor in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        if let fraction = model.mediaDownloadProgress[clip.id] {
                            caching.clipFraction = fraction
                            onProgress(caching)
                        }
                    }
                }
                let cached = await model.cacheClipFromCamera(clip)
                progressMirror.cancel()
                if !cached { uncachedCount += 1 }
            }
        }

        let downloadableClips = request.clips.filter { model.isClipDownloaded($0) }
        let total = downloadableClips.count
        guard total > 0 else {
            return .failed(
                message: uncachedCount > 0
                    ? "Couldn't cache \(uncachedCount) clip(s) from the camera — check the connection and try again."
                    : MediaDeliveryError.emptySelection.localizedDescription)
        }

        var overlay = MediaDeliveryOverlayState(
            destination: request.destination,
            totalClips: total,
            clipIndex: 1,
            clipFraction: 0
        )
        onProgress(overlay)

        switch request.destination {
        case .nativeShare:
            let result = await model.deliverClipsForShare(
                downloadableClips, configuration: request.configuration
            ) { index, _, fraction in
                overlay.clipIndex = index
                overlay.clipFraction = fraction
                onProgress(overlay)
            }
            if result.exportedURLs.isEmpty {
                return .failed(
                    message: result.failedClips.first?.1 ?? "Nothing to share."
                )
            }
            let metadata =
                request.configuration.includeMetadata
                ? model.metadataSummary(for: downloadableClips) : nil
            var partialParts: [String] = []
            if !result.failedClips.isEmpty {
                partialParts.append(
                    "Prepared \(result.exportedURLs.count); \(result.failedClips.count) failed.")
            }
            if uncachedCount > 0 {
                partialParts.append("\(uncachedCount) clip(s) couldn't be cached from the camera.")
            }
            let partialNote: String? =
                partialParts.isEmpty ? nil : partialParts.joined(separator: " ")
            let metadataText: String? = [partialNote, metadata].compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
                .nilIfEmpty

            switch request.postExportAction {
            case .saveToPhotos:
                do {
                    let count = try await MediaPhotosSaver.saveVideos(at: result.exportedURLs)
                    return .savedToPhotos(count: count)
                } catch {
                    return .failed(message: error.localizedDescription)
                }
            case .systemShare:
                do {
                    let prepared = try MediaShareStaging.prepareForShare(
                        videoURLs: result.exportedURLs)
                    return .share(
                        urls: prepared.urls,
                        metadataText: metadataText,
                        stagingCleanupURL: prepared.stagingCleanupURL)
                } catch {
                    return .failed(message: error.localizedDescription)
                }
            }

        case .frameio:
            // Camera-AP mode has no internet route: clips are already local (pre-pass above), so
            // hop off the camera network, upload, and rejoin — same beat as the RED LUT download.
            // Sign-in and project resolution happen inside the upload path once online.
            var hopped = false
            if model.isOnCameraAccessPoint {
                model.beginInternetHop()
                hopped = true
                overlay.isSwitchingNetworks = true
                onProgress(overlay)
                let online = await model.waitForInternetPath(timeoutSeconds: 30)
                overlay.isSwitchingNetworks = false
                onProgress(overlay)
                if !online {
                    model.endInternetHop()
                    return .failed(
                        message:
                            "Couldn't reach the internet after leaving the camera's Wi‑Fi. Check cellular or home Wi‑Fi and try again."
                    )
                }
            }
            defer {
                // Rejoin the camera network once the upload finishes or fails — whether the hop
                // started here or was handed over by the popup's sign-in/project setup flow.
                if hopped || model.internetHopActive { model.endInternetHop() }
            }
            let result = await model.uploadClipsToFrameio(
                downloadableClips, configuration: request.configuration
            ) { index, _, fraction in
                overlay.clipIndex = index
                overlay.clipFraction = fraction
                onProgress(overlay)
            }
            var parts: [String] = []
            if result.uploadedCount > 0 { parts.append("\(result.uploadedCount) uploaded") }
            if result.skippedCount > 0 { parts.append("\(result.skippedCount) skipped") }
            if uncachedCount > 0 { parts.append("\(uncachedCount) not cached") }
            if result.failedClips.isEmpty {
                let summary = parts.isEmpty ? "Nothing to upload." : parts.joined(separator: ", ")
                return .frameio(summary: summary)
            }
            let summary = (parts + ["\(result.failedClips.count) failed"]).joined(separator: ", ")
            return .failed(message: summary)
        }
    }
}

// MARK: - Share staging

/// Result of validating and optionally copying exports before handing them to the share sheet.
struct PreparedMediaShare: Sendable {
    let urls: [URL]
    /// Non-nil when videos were copied into a cache folder that must be deleted after sharing.
    let stagingCleanupURL: URL?
}

/// Validates exported videos and, when needed, copies them into a cache folder for sharing.
enum MediaShareStaging {
    static let shareableVideoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    enum StagingError: LocalizedError {
        case fileMissing(String)
        case fileEmpty(String)
        case fileUnreadable(String)
        case noVideos
        case copyFailed(String, Error)

        var errorDescription: String? {
            switch self {
            case .fileMissing(let name): "Couldn't find \(name) to share."
            case .fileEmpty(let name): "\(name) is empty."
            case .fileUnreadable(let name): "\(name) isn't readable."
            case .noVideos: "No video files are ready to share."
            case .copyFailed(let name, let error):
                "Couldn't prepare \(name): \(error.localizedDescription)"
            }
        }
    }

    static func isShareableVideo(_ url: URL) -> Bool {
        shareableVideoExtensions.contains(url.pathExtension.lowercased())
    }

    static func filterShareableVideos(_ urls: [URL]) -> [URL] {
        urls.filter(isShareableVideo)
    }

    /// Maps common export extensions to explicit UTTypes for Launch Services.
    static func videoUTType(for url: URL) -> UTType {
        switch url.pathExtension.lowercased() {
        case "mov": .quickTimeMovie
        case "mp4": .mpeg4Movie
        case "m4v": .mpeg4Movie
        default: .movie
        }
    }

    static func validateReadableFile(at url: URL) throws {
        try validateShareableFile(at: url)
    }

    /// Confirms the file exists, is a regular readable file, and has non-zero size.
    static func validateShareableFile(at url: URL) throws {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else {
            throw StagingError.fileMissing(url.lastPathComponent)
        }
        let values = try url.resourceValues(forKeys: [
            .fileSizeKey, .isReadableKey, .isRegularFileKey,
        ])
        guard values.isRegularFile != false else {
            throw StagingError.fileMissing(url.lastPathComponent)
        }
        if values.isReadable == false {
            throw StagingError.fileUnreadable(url.lastPathComponent)
        }
        let size = values.fileSize ?? 0
        guard size > 0 else { throw StagingError.fileEmpty(url.lastPathComponent) }
    }

    /// Shares stable `Documents/exports` files in place; otherwise copies into a cache staging folder.
    static func prepareForShare(videoURLs: [URL]) throws -> PreparedMediaShare {
        let videos = filterShareableVideos(videoURLs)
        guard !videos.isEmpty else { throw StagingError.noVideos }

        if videos.allSatisfy(isStableExportURL) {
            for url in videos { try validateShareableFile(at: url) }
            return PreparedMediaShare(urls: videos, stagingCleanupURL: nil)
        }
        return try copyToStagingDirectory(videos)
    }

    static func cleanupStaging(at url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func exportsDirectoryURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("exports", isDirectory: true)
    }

    private static func isStableExportURL(_ url: URL) -> Bool {
        let exportsPath = exportsDirectoryURL().standardizedFileURL.path
        let candidatePath = url.standardizedFileURL.path
        return candidatePath.hasPrefix(exportsPath + "/")
    }

    private static func copyToStagingDirectory(_ videos: [URL]) throws -> PreparedMediaShare {
        let stagingRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenZCineShare", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        var staged: [URL] = []
        for source in videos {
            try validateShareableFile(at: source)
            let destination = stagingRoot.appendingPathComponent(source.lastPathComponent)
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            do {
                try FileManager.default.copyItem(at: source, to: destination)
            } catch {
                throw StagingError.copyFailed(source.lastPathComponent, error)
            }
            try validateShareableFile(at: destination)
            staged.append(destination)
        }
        return PreparedMediaShare(urls: staged, stagingCleanupURL: stagingRoot)
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

    static func saveVideos(at urls: [URL]) async throws -> Int {
        let videos = MediaShareStaging.filterShareableVideos(urls)
        guard !videos.isEmpty else { throw SaveError.noVideos }

        for url in videos {
            try MediaShareStaging.validateReadableFile(at: url)
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw SaveError.permissionDenied
        }

        var saved = 0
        var failed = 0
        for url in videos {
            do {
                try await saveVideo(at: url)
                saved += 1
            } catch {
                failed += 1
            }
        }

        if saved == 0 {
            throw SaveError.partialFailure(saved: 0, failed: max(failed, videos.count))
        }
        if failed > 0 {
            throw SaveError.partialFailure(saved: saved, failed: failed)
        }
        return saved
    }

    private static func saveVideo(at url: URL) async throws {
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
    let id = UUID()
    let urls: [URL]
    let metadataText: String?
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
            @Bindable var delivery = coordinator
            content
                .sheet(
                    item: $delivery.sharePayload,
                    onDismiss: {
                        delivery.clearSharePresentation()
                        onDismiss?()
                    },
                    content: { payload in
                        MultiShareSheet(
                            urls: payload.urls,
                            metadataText: payload.metadataText,
                            onFinished: { delivery.clearSharePresentation() }
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
