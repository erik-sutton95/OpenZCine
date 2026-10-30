import AVFoundation
import ImageIO
import MonitorPresentation
import MonitorUI
import OSLog
import OpenCineAppKit
import OpenCineAppKitApple
import OpenCineApple
import OpenCineCameraControls
import OpenCineCameraVocabulary
import OpenCineMedia
import OpenZCineCore
import SwiftUI
import UIKit

/// Decodes cell images downsampled to a bounded pixel size, off the main actor (same pattern as
/// `FrameDecoder`). Cells must never decode a full-resolution still — a 45 MP HEIF is ~180 MB
/// decoded, a screenful is a jetsam kill — and one actor also serializes decodes during fast scroll.
actor MediaCellImageLoader {
    static let shared = MediaCellImageLoader()

    /// The downsampled image at `url` (long edge ≤ `maxPixelSize`), or `nil` if unreadable.
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes in EXIF orientation, so the cell shows
    /// exactly the picture a full decode would have. `fallbackOrientation` covers EXIF-stripped
    /// camera thumbnails whose real orientation was learned from the full file.
    func downsampled(
        at url: URL, maxPixelSize: Int, fallbackOrientation: Int? = nil
    ) -> sending UIImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }
            return Self.downsampled(
                source: source, maxPixelSize: maxPixelSize,
                fallbackOrientation: fallbackOrientation)
        }
    }

    /// A cached thumbnail file, read and decoded on this actor: a cell never reads a file on the
    /// main actor. `unreadable` (no file) and `undecodable` (bytes ImageIO refuses) stay distinct,
    /// because only an undecodable cached thumb is removed by the cell's self-heal.
    enum FileDecode: Sendable {
        case image(UIImage)
        case unreadable
        case undecodable
    }
    func downsampled(
        fileAt url: URL, maxPixelSize: Int, fallbackOrientation: Int? = nil
    ) -> sending FileDecode {
        guard let data = try? Data(contentsOf: url) else { return .unreadable }
        guard
            let image = downsampled(
                data: data, maxPixelSize: maxPixelSize, fallbackOrientation: fallbackOrientation)
        else { return .undecodable }
        return .image(image)
    }

    /// In-memory variant for bytes that never touch disk (the instant-playback stream).
    func downsampled(
        data: Data, maxPixelSize: Int, fallbackOrientation: Int? = nil
    ) -> sending UIImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                return nil
            }
            return Self.downsampled(
                source: source, maxPixelSize: maxPixelSize,
                fallbackOrientation: fallbackOrientation)
        }
    }

    /// The EXIF orientation (1–8) recorded in the image bytes; nil when the file carries none
    /// (the discriminator between "already upright" and "needs the cached fallback").
    nonisolated static func exifOrientation(in data: Data) -> Int? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return exifOrientation(source: source)
    }

    /// File variant, used to learn a still's orientation from its streamed full bytes.
    nonisolated static func exifOrientation(atFile url: URL) -> Int? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return exifOrientation(source: source)
    }

    private nonisolated static func exifOrientation(source: CGImageSource) -> Int? {
        guard
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any]
        else { return nil }
        return (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue
    }

    private static func downsampled(
        source: CGImageSource, maxPixelSize: Int, fallbackOrientation: Int?
    ) -> UIImage? {
        let thumbnailOptions =
            [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            ] as [CFString: Any] as CFDictionary
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
        else { return nil }
        // The transform option only rotates when the bytes carry the tag — apply the caller's
        // learned orientation exactly when the source has none of its own.
        if let fallbackOrientation, fallbackOrientation != 1,
            exifOrientation(source: source) == nil,
            let exif = CGImagePropertyOrientation(rawValue: UInt32(fallbackOrientation))
        {
            return UIImage(cgImage: cgImage, scale: 1, orientation: UIImage.Orientation(exif))
        }
        return UIImage(cgImage: cgImage)
    }
}

/// Decoded cell thumbnails shared by the grid and list cells, keyed by clip id + cell variant
/// (grid and list decode video frames at different pixel sizes). A cell scrolling back into view
/// reuses the decoded image instead of re-reading + re-decoding from disk; `NSCache` evicts on
/// memory pressure by itself.
@MainActor
enum MediaCellThumbnailCache {
    static let shared: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 150
        return cache
    }()
}

// MARK: - Browser

/// Source composition for the complete shared catalog; card, RAW and delivery facts stay typed.
struct MediaBrowserView: View {
    var safeArea: MonitorEdgeInsets? = nil
    @Environment(NativeAppModel.self) private var model
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    @Environment(MonitorDeliveryCoordinator.self) private var deliveryCoordinator
    @State private var playing: MonitorMediaGalleryOpen<MediaClip>?
    @State private var photo: MonitorMediaGalleryOpen<MediaClip>?
    @State private var series: MonitorMediaGalleryOpen<MediaClip>?
    @State private var deliveryRequest: NikonDeliveryRequest?

    var body: some View {
        ZStack {
            if let library = model.mediaLibrary {
                let projection = model.mediaGalleryProjection
                MonitorOperatorCatalogScreen(
                    library: library, brand: model.connectedIdentity?.displayName ?? "OpenZCine",
                    safeArea: resolvedSafeArea,
                    sourceAvailable: model.isConnected, operations: operations,
                    presentation: model.mediaGalleryPresentation(projection), navigation: navigate,
                    sourceFilter: model.applyMediaGalleryFilter,
                    managesVisibility: false,
                    deletionDetail: nikonDeletionDetail,
                    facts: { record in
                        .init(
                            resolution: record.payload.resolutionBucket?.rawValue,
                            byteCount: record.payload.sizeBytes > 0
                                ? record.payload.sizeBytes : nil,
                            durationSeconds: nil, dateKey: nil, colorLabel: nil,
                            progress: model.isClipStreaming(record.payload)
                                ? model.mediaDownloadProgress[record.payload.id] : nil,
                            transferRate: model.isClipStreaming(record.payload)
                                ? model.mediaDownloadRates.rate(record.payload.id) : nil)
                    },
                    cell: { record, context in
                        model.mediaCellItem(
                            record.payload, list: context.list, selecting: context.selecting,
                            duration: context.duration, projection: projection)
                    }, begin: begin, refresh: model.refreshCameraMediaInventory,
                    close: model.dismissMediaLibrary, open: open,
                    share: { records, token in
                        guard library.isCurrent(token),
                            let admission = model.captureMediaLibraryAction(records.map(\.payload)),
                            admission.isCurrent
                        else { return }
                        guard
                            let capture = NikonMediaDeliveryCapture(
                                model: model, clips: records.map(\.payload), action: admission),
                            library.isCurrent(token), capture.isCurrent
                        else { return }
                        deliveryRequest = .init(capture: capture)
                    },
                    // The caching header scans cell facts only while a clip streams.
                    cachingActive: { !model.mediaDownloadProgress.isEmpty }
                ) { request in
                    let clip = request.record.payload
                    MediaClipThumbnail(
                        clip: clip, list: request.list,
                        isDownloaded: model.isClipDownloaded(clip),
                        localURL: model.clipLocalURL(clip),
                        thumbnailURL: model.clipThumbnailURL(clip),
                        needsDuration: request.resolvedDuration == nil,
                        isCurrent: request.isCurrent,
                        onDuration: { if request.isCurrent() { request.duration($0) } })
                }
            } else {
                ProgressView().tint(MonitorTheme.muted).frame(
                    maxWidth: .infinity, maxHeight: .infinity
                )
                .background(MonitorTheme.canvas).onAppear { model.refreshMediaClips() }
            }
            deliveryOverlays
        }
        .ignoresSafeArea().observeMonitorWindowGeometry()
        .overlay {
            MonitorOperatorDeliveryChrome(
                model: deliveryCoordinator.lifetime, scope: .surface, remoteDisplayName: "Frame.io")
        }
        .fullScreenCover(item: $playing) { request in
            MediaPlayerView(
                clips: request.playlist.map(\.payload), startingAt: request.record.payload,
                opening: request
            )
            .environment(model).environment(deliveryCoordinator)
        }
        .fullScreenCover(item: $photo) { request in
            MediaPhotoViewer(clip: request.record.payload, opening: request)
                .environment(model).environment(deliveryCoordinator)
        }
        .fullScreenCover(item: $series) { request in
            MediaBurstSeriesView(opening: request)
                .environment(model).environment(deliveryCoordinator)
        }
        .animation(.spring(duration: 0.32), value: deliveryCoordinator.isActive)
    }

    private var operations: MonitorMediaGalleryOperations<MediaClip> {
        .init(
            download: { record in
                guard let action = model.captureMediaLibraryAction([record.payload]),
                    action.isCurrent
                else { return }
                _ = await model.cacheClipFromCamera(record.payload)
            }, favorite: { record in model.toggleClipFavorite(record.payload) },
            acceptedDeletion: .init(
                capture: { records in model.captureMediaDeletionAuthority(records.map(\.payload)) },
                perform: { records, authority in
                    _ = await model.deleteMediaClips(
                        records.map(\.payload), deleteLocation: nil, admitted: authority)
                }),
            access: { record in
                .init(
                    download: model.isConnected && record.payload.handle != nil
                        && !model.isClipDownloaded(record.payload),
                    share: true, delete: model.canDeleteMedia([record.payload]))
            }, deletionMessage: { model.deletionConfirmMessage(for: $0.map(\.payload)) },
            openNotice: { record in
                MediaClipFilename.isR3D(record.payload.filename)
                    ? "R3D master - no playable proxy was found for this clip." : nil
            })
    }
    private func navigate(_ action: MonitorMediaGalleryNavigation) {
        switch action {
        case .category(let id):
            if let tab = MediaCategoryTab(rawValue: id) { model.mediaCategoryTab = tab }
        case .layout(let value): model.mediaBrowserLayout = value
        case .thumbnailSize(let value): model.mediaThumbnailSize = value
        case .cycleSort: model.cycleMediaSortOrder()
        }
    }
    private func open(_ request: MonitorMediaGalleryOpen<MediaClip>) {
        guard model.mediaLibrary?.isCurrent(request.admission) == true else { return }
        let clip = request.record.payload
        if model.burstSeries(for: clip) != nil {
            series = request
        } else if clip.mediaKind == .photo {
            photo = request
        } else {
            playing = request
        }
    }
    private func begin() {
        model.refreshMediaClips()
        if !model.isConnected || model.mediaBrowserSource != .camera {
            model.mediaLibrary?.begin()
        }
        if !model.isStandaloneMediaLibraryPresented, model.mediaBrowserSource == .iPhone,
            !model.hasLocalMediaClips
        {
            model.mediaBrowserSource = .camera
        }
        Task { await model.refreshMediaStorageSlots() }
        if model.isConnected, model.mediaBrowserSource == .camera {
            model.scheduleFetchClipsFromCamera()
        }
        if DemoHarness.openMediaAction == "play", let library = model.mediaLibrary,
            let record = library.records.first(where: { model.isClipDownloaded($0.payload) })
        {
            open(.init(record: record, playlist: library.records, admission: library.actionToken))
        }
        if DemoHarness.openMediaAction == "share", let library = model.mediaLibrary,
            let record = library.records.first(where: { model.isClipDownloaded($0.payload) }),
            let capture = NikonMediaDeliveryCapture(model: model, clips: [record.payload])
        {
            deliveryRequest = .init(capture: capture)
        }
    }
    @ViewBuilder private var deliveryOverlays: some View {
        if let request = deliveryRequest {
            request.popup(model, coordinator: deliveryCoordinator) {
                if deliveryRequest?.id == request.id { deliveryRequest = nil }
            }
        }
    }
    private var resolvedSafeArea: EdgeInsets {
        if let safeArea {
            return .init(
                top: CGFloat(safeArea.top), leading: CGFloat(safeArea.leading),
                bottom: CGFloat(safeArea.bottom), trailing: CGFloat(safeArea.trailing))
        }
        return windowGeometry.validSize == nil ? EdgeInsets() : windowGeometry.safeArea
    }
}

/// Source-derived catalog facts. The shared catalog never inspects camera handles or cache URLs.
extension NativeAppModel {
    /// One gallery cell. The catalog screen calls this for every record on each render, so it reads
    /// the render's one projection pass and never rebuilds a library-wide index per cell.
    func mediaCellItem(
        _ clip: MediaClip, list: Bool, selecting: Bool, duration: String?,
        projection: NikonAppGalleryProjection
    ) -> MonitorMediaItem {
        let downloaded = isClipDownloaded(clip)
        let raw = projection.rawSibling(of: clip) != nil
        return MediaClipCellPresentation.item(
            clip: clip,
            detail: list
                ? MediaClipCellPresentation.metadataLine(
                    clip, hasRawSibling: raw, duration: duration, isDownloaded: downloaded) : "",
            isDownloaded: downloaded,
            cacheProgress: mediaDownloadProgress[clip.id] ?? clipBufferedFraction(clip),
            isStreaming: isClipStreaming(clip), hasRawSibling: raw,
            burstCount: projection.series(for: clip)?.count,
            duration: duration, list: list, selecting: selecting)
    }
}

enum MediaClipCellPresentation {
    static func item(
        clip: MediaClip, detail: String, isDownloaded: Bool, cacheProgress: Double?,
        isStreaming: Bool, hasRawSibling: Bool, burstCount: Int? = nil, duration: String?,
        list: Bool, selecting: Bool, permissions: MonitorMediaPermissions = []
    ) -> MonitorMediaItem {
        let photo = clip.mediaKind == .photo
        let caption = cacheProgress.map { progress in
            let percent = "\(Int(progress * 100))%"
            return !list && isStreaming ? "CACHING \(percent)" : percent
        }
        let shownDuration = list || photo || selecting || cacheProgress != nil ? nil : duration
        return MonitorMediaItem(
            id: clip.id, filename: clip.filename, metadata: detail, duration: shownDuration ?? "",
            availability: isDownloaded ? .original : .camera, progress: cacheProgress,
            favorite: clip.isFavorite, photo: photo, permissions: permissions,
            burstCount: list || selecting ? nil : burstCount,
            mediaBadge: !list && photo && hasRawSibling && !selecting && cacheProgress == nil
                ? "RAW+J" : nil,
            completionBadge: !list && !photo && isDownloaded && cacheProgress == nil
                && clip.exportStatus == .exported ? "EXPORTED" : nil,
            transferCaption: caption)
    }

    /// The list row's detail: resolution, RAW pairing, size and duration, or where it lives.
    static func metadataLine(
        _ clip: MediaClip, hasRawSibling: Bool, duration: String?, isDownloaded: Bool
    ) -> String {
        var parts: [String] = []
        if let bucket = clip.resolutionBucket {
            parts.append(bucket.rawValue)
        }
        if hasRawSibling {
            parts.append("RAW+J")
        }
        if clip.sizeBytes > 0 {
            parts.append(MediaClipFormatting.byteLabel(clip.sizeBytes))
        }
        if let duration, clip.mediaKind != .photo {
            parts.append(duration)
        }
        if parts.isEmpty {
            return isDownloaded ? "Cached" : "On camera"
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Source artwork

/// A catalog cell's artwork. Thumbnail and duration loading stay app-owned; the duration goes
/// back to the browser, which hands it to the shared cell.
private struct MediaClipThumbnail: View {
    let clip: MediaClip
    let list: Bool
    let isDownloaded: Bool
    let localURL: URL?
    let thumbnailURL: URL?
    let needsDuration: Bool
    let isCurrent: () -> Bool
    let onDuration: (String) -> Void

    @Environment(NativeAppModel.self) private var model

    private var isPhoto: Bool { clip.mediaKind == .photo }

    var body: some View {
        // Orientation joins the trigger: a row that learns its rotation re-decodes upright.
        MonitorMediaCatalogArtwork(
            identity: "\(clip.id)#\(list ? "list" : "grid")",
            reload: "\(localURL?.absoluteString ?? "")#o\(clip.exifOrientation ?? 0)",
            isCurrent: isCurrent, load: loadThumbnail, afterLoad: loadDuration
        ) {
            Image(systemName: isPhoto ? "photo" : "film")
                .font(.system(size: list ? 20 : 28, weight: .light))
                .foregroundStyle(LiveDesign.faint)
        }
    }

    private func loadThumbnail() async -> UIImage? {
        guard isCurrent(), !Task.isCancelled else { return nil }
        // Keyed by resolved orientation so a row learning its rotation re-decodes upright.
        let variant = list ? "list" : "grid"
        let cacheKey = "\(clip.id)#\(variant)#o\(clip.exifOrientation ?? 0)" as NSString
        if let cached = MediaCellThumbnailCache.shared.object(forKey: cacheKey) {
            return cached
        }
        func present(_ image: UIImage) -> UIImage? {
            guard isCurrent(), !Task.isCancelled else { return nil }
            MediaCellThumbnailCache.shared.setObject(image, forKey: cacheKey)
            return image
        }
        let thumbPixels = list ? 480 : 640
        if let thumbnailURL {
            // The camera's PTP thumbs can be EXIF-stripped — the row's learned orientation
            // stands in so portrait shots render upright.
            switch await MediaCellImageLoader.shared.downsampled(
                fileAt: thumbnailURL, maxPixelSize: thumbPixels,
                fallbackOrientation: clip.exifOrientation)
            {
            case .image(let image): return present(image)
            case .undecodable:
                // Self-heal: a cached thumb that doesn't decode would re-fail (and spam ImageIO
                // errors) on every cell realisation. Deletes only the cached thumb, never the media.
                guard isCurrent(), !Task.isCancelled else { return nil }
                try? FileManager.default.removeItem(at: thumbnailURL)
            case .unreadable: break
            }
        }
        if isPhoto, isDownloaded, let localURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: localURL, maxPixelSize: 640, fallbackOrientation: clip.exifOrientation)
        {
            return present(image)
        }
        guard isCurrent(), !Task.isCancelled else { return nil }
        if !isDownloaded, clip.handle != nil {
            await model.ensureThumbnail(for: clip)
            guard isCurrent(), !Task.isCancelled else { return nil }
            if let cachedURL = model.clipThumbnailURL(clip),
                case .image(let image) = await MediaCellImageLoader.shared.downsampled(
                    fileAt: cachedURL, maxPixelSize: thumbPixels,
                    fallbackOrientation: clip.exifOrientation)
            {
                return present(image)
            }
        }
        guard isCurrent(), !Task.isCancelled, isDownloaded, !isPhoto, let localURL else {
            return nil
        }
        let asset = AVURLAsset(url: localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let framePixels: CGFloat = list ? 320 : 600
        generator.maximumSize = CGSize(width: framePixels, height: framePixels)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: time).image {
            return present(UIImage(cgImage: cgImage))
        }
        return nil
    }

    private func loadDuration() async {
        guard isCurrent(), !Task.isCancelled, !isPhoto, needsDuration, isDownloaded,
            let localURL
        else { return }
        let asset = AVURLAsset(url: localURL)
        if let duration = try? await asset.load(.duration), isCurrent(), !Task.isCancelled,
            duration.isValid, duration.seconds > 0
        {
            onDuration(MediaClipFormatting.durationLabel(seconds: Int(duration.seconds)))
        }
    }
}

/// Names the companion files (RAW+JPEG pairs, masters, backup copies) that inflate the file count
/// above the operator's picks, so the shared deletion overlay reads e.g. "3 of 6 files".
private func nikonDeletionDetail(_ progress: MonitorMediaDeletionProgress) -> String? {
    progress.total > progress.selectedCount
        ? "\(progress.completed) of \(progress.total) files · incl. RAW + copies" : nil
}

/// "Manage series" view: the frames of one burst series in a grid, with per-frame open (rate /
/// share / single-frame delete via the photo viewer) and a destructive "delete the whole set"
/// action. A series that loses frames until one remains degrades back to a normal grid cell.
private struct MediaBurstSeriesView: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let opening: MonitorMediaGalleryOpen<MediaClip>
    private var representative: MediaClip { opening.record.payload }
    @State private var members: [MediaClip] = []
    @State private var records: [MonitorMediaRecord<MediaClip>] = []
    @State private var selectedID: String?
    @State private var library: MonitorMediaLibraryModel<MediaClip>?
    @State private var returnAdmission: MonitorMediaLibraryActionToken?
    @State private var pageRevision = UUID()

    private var selected: MediaClip? {
        members.first { $0.id == selectedID } ?? members.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let selected, let record = records.first(where: { $0.payload.id == selected.id }) {
                // The selected frame reuses the full photo viewer — streaming decode, zoom,
                // rating, RAW toggle, share, and single-frame delete all keep working.
                // Recreated per frame (`.id`) so its per-clip state and stream reset cleanly.
                MediaPhotoViewer(
                    clip: selected,
                    opening: .init(
                        record: record, playlist: records,
                        admission: returnAdmission ?? opening.admission),
                    collection: members,
                    onSelected: { selectedID = $0.id },
                    onDeletedReturning: { advanceAfterDeletion(of: selected, admission: $0) }
                )
                .id("\(selected.id)#\(pageRevision.uuidString)")
            }
            // Delete-all runs over this fullScreenCover, so the progress bar mounts here too
            // (the browser-level overlay is behind the cover).
            if let progress = model.mediaDeletionProgress {
                MonitorMediaDeletionOverlay(
                    progress: progress, detail: nikonDeletionDetail(progress)
                )
                .animation(.easeInOut(duration: 0.2), value: progress)
                .transition(.opacity)
                .zIndex(6)
            }
        }
        .statusBarHidden()
        .onAppear {
            guard let library = model.mediaLibrary, library.isCurrent(opening.admission) else {
                dismiss()
                return
            }
            self.library = library
            members = model.burstMembers(of: representative)
            records = members.compactMap { member in
                library.records.first { $0.payload.id == member.id }
            }
            selectedID = members.first?.id
        }
    }

    /// Drops the deleted frame from the strip and shows its neighbour; a series that empties
    /// (or degrades to nothing worth paging) closes back to the grid.
    private func advanceAfterDeletion(of clip: MediaClip, admission: MonitorMediaLibraryActionToken)
    {
        guard let library, model.mediaLibrary === library, library.isCurrent(admission) else {
            return
        }
        let index = members.firstIndex { $0.id == clip.id } ?? 0
        let survivors = model.burstMembers(of: representative)
        guard model.mediaLibrary === library, library.isCurrent(admission) else { return }
        returnAdmission = admission
        members = survivors
        records = survivors.compactMap { member in
            library.records.first { $0.payload.id == member.id }
        }
        guard !members.isEmpty else {
            dismiss()
            return
        }
        selectedID = members[min(index, members.count - 1)].id
        pageRevision = UUID()
    }
}

/// One scrubber thumb — the camera thumbnail at strip size, widened when selected (Photos
/// style). Fetches the thumb from the body when it isn't cached yet.
private struct NikonStripThumbnail: View {
    let request: MonitorMediaPictureRequest<MediaClip>
    @Environment(NativeAppModel.self) private var model
    @State private var image: UIImage?
    private var clip: MediaClip { request.record.payload }
    var body: some View {
        ZStack {
            Rectangle().fill(MonitorTheme.surface)
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: .fill) }
        }.task(id: clip.id) { await load() }
    }
    private func load() async {
        guard request.isCurrent() else { return }
        let cacheKey = "\(clip.id)#strip#o\(clip.exifOrientation ?? 0)" as NSString
        if let cached = MediaCellThumbnailCache.shared.object(forKey: cacheKey) {
            if request.isCurrent() { image = cached }
            return
        }
        func decodeCachedThumb() async -> UIImage? {
            guard request.isCurrent(), let url = model.clipThumbnailURL(clip) else { return nil }
            return await MediaCellImageLoader.shared.downsampled(
                at: url, maxPixelSize: 120,
                fallbackOrientation: clip.exifOrientation)
        }
        var loaded = await decodeCachedThumb()
        guard request.isCurrent() else { return }
        if loaded == nil, clip.handle != nil {
            await model.ensureThumbnail(for: clip)
            guard request.isCurrent() else { return }
            loaded = await decodeCachedThumb()
        }
        guard request.isCurrent() else { return }
        if let loaded {
            MediaCellThumbnailCache.shared.setObject(loaded, forKey: cacheKey)
            image = loaded
        }
    }
}

// MARK: - Photo viewer

/// Full-screen still viewer for camera JPEG/RAW/HEIF — streams the object from the card when
/// needed. Same-stem RAW+JPEG pairs open on the JPEG with a JPG ⇄ RAW toggle beside Share.
@MainActor private struct NikonPhotoContext {
    let library: MonitorMediaLibraryModel<MediaClip>
    let record: MonitorMediaRecord<MediaClip>
    let admission: MonitorMediaLibraryActionToken
    let variants: [MonitorMediaPictureVariant<MediaClip>]
    let collection: [MonitorMediaRecord<MediaClip>]
    let action: NikonMediaLibraryAction?
}

struct MediaPhotoViewer: View {
    let clip: MediaClip
    var opening: MonitorMediaGalleryOpen<MediaClip>? = nil
    var collection: [MediaClip] = []
    var onDeleted: (() -> Void)? = nil
    var onSelected: ((MediaClip) -> Void)? = nil
    var onDeletedReturning: ((MonitorMediaLibraryActionToken) -> Void)? = nil
    @Environment(NativeAppModel.self) private var model
    @Environment(MonitorDeliveryCoordinator.self) private var deliveryCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var context: NikonPhotoContext?
    @State private var delivery: NikonDeliveryRequest?

    var body: some View {
        Group {
            if let context {
                MonitorOperatorPhotoScreen(
                    library: context.library, record: context.record,
                    admission: context.admission, assist: model.assist, loaders: loaders,
                    operations: operations,
                    haptics: .init(isEnabled: { [weak model] in
                        model?.preferences.hapticsEnabled == true
                    }),
                    coverPresented: delivery != nil || deliveryCoordinator.coversPlayback,
                    variants: context.variants,
                    rating: rating,
                    sharing: .init(readiness: { [weak model] request in
                        guard request.isCurrent(), let model else { return .unavailable }
                        return model.isClipDownloaded(request.record.payload) ? .ready : .waiting
                    }), collection: context.collection,
                    selectRecord: onSelected.map { selected in
                        { record in selected(record.payload) }
                    },
                    collectionThumbnail: { request in
                        AnyView(NikonStripThumbnail(request: request).environment(model))
                    },
                    sourceCurrent: { context.action?.sourceIsCurrent != false },
                    close: { dismiss() },
                    deleted: { if let onDeleted { onDeleted() } else { dismiss() } },
                    share: { request in
                        // The same delivery choices as a clip; a still travels as its original.
                        guard request.isCurrent(),
                            let capture = NikonMediaDeliveryCapture(
                                model: model, clips: [request.record.payload]),
                            capture.isCurrent
                        else { return }
                        delivery = .init(capture: capture)
                    }, deletedReturning: onDeletedReturning)
            } else {
                ProgressView().tint(MonitorTheme.accent).frame(
                    maxWidth: .infinity, maxHeight: .infinity
                )
                .background(.black)
            }
        }
        .task {
            guard context == nil else { return }
            guard let library = model.mediaLibrary else {
                dismiss()
                return
            }
            let admission = opening?.admission ?? library.actionToken
            guard library.isCurrent(admission),
                let record = opening?.record
                    ?? library.records.first(where: { $0.payload.id == clip.id })
            else {
                dismiss()
                return
            }
            let raw = model.rawSibling(of: clip).flatMap { raw in
                library.records.first { $0.payload.id == raw.id }
            }
            let variants =
                raw.map {
                    [
                        MonitorMediaPictureVariant(label: "JPG", record: record),
                        .init(label: "RAW", record: $0),
                    ]
                } ?? []
            let members = collection.compactMap { member in
                library.records.first { $0.payload.id == member.id }
            }
            context = .init(
                library: library, record: record, admission: admission,
                variants: variants, collection: members,
                action: model.captureMediaLibraryAction(
                    [clip] + (raw.map { [$0.payload] } ?? []) + collection))
        }
        .overlay {
            if let request = delivery {
                request.popup(model, coordinator: deliveryCoordinator) {
                    if delivery?.id == request.id { delivery = nil }
                }
            }
        }
        .overlay {
            MonitorOperatorDeliveryChrome(
                model: deliveryCoordinator.lifetime, scope: .surface, remoteDisplayName: "Frame.io")
        }
    }
    private var operations: MonitorMediaGalleryOperations<MediaClip> {
        .init(
            favorite: { record in model.toggleClipFavorite(record.payload) },
            acceptedDeletion: .init(
                capture: { rows in model.captureMediaDeletionAuthority(rows.map(\.payload)) },
                perform: { rows, authority in
                    _ = await model.deleteMediaClips(
                        rows.map(\.payload), deleteLocation: nil, admitted: authority)
                }),
            access: { record in
                .init(share: true, delete: model.canDeleteMedia([record.payload]))
            },
            deletionMessage: { rows in
                if rows.count > 1, !collection.isEmpty {
                    return burstDeletionMessage(rows.map(\.payload))
                }
                return model.deletionConfirmMessage(for: rows.map(\.payload))
            })
    }
    private var rating: MonitorMediaPictureRatingService<MediaClip> {
        .init(
            levels: [1, 2, 3, 4, 5],
            read: { [weak model] request in
                guard request.isCurrent(), let model else { return nil }
                return await model.mediaStarRating(for: request.record.payload)
            },
            commit: { [weak model] target, request in
                guard request.isCurrent(), let model else { return .unavailable }
                switch await model.setMediaStarRating(target, for: request.record.payload) {
                case .confirmed(let value): return .confirmed(value)
                case .refused(_, let message): return .refused(message)
                case .offline: return .unavailable
                }
            })
    }
    private var loaders: MonitorMediaPictureLoaders<MediaClip, UIImage> {
        .init(
            preview: { [weak model] request in
                guard request.isCurrent(),
                    let url = model?.clipThumbnailURL(request.record.payload),
                    let data = try? Data(contentsOf: url)
                else { return nil }
                return UIImage(data: data)
            },
            cached: { [weak model] request in
                guard request.isCurrent(), let model, model.isClipDownloaded(request.record.payload)
                else { return nil }
                return await NikonPhotoDecode.complete(request, model: model)
            },
            progressive: { [weak model] publication in
                guard publication.isCurrent, let model else { return nil }
                let ticket = model.startClipStream(publication.request.record.payload)
                let result = await NikonPhotoDecode.progressive(publication, model: model)
                if let ticket {
                    model.cancelClipStream(ticket)
                    await ticket.task.value
                }
                return publication.isCurrent ? result : nil
            })
    }
    private func burstDeletionMessage(_ targets: [MediaClip]) -> String {
        let plan = model.deletionPlan(for: targets)
        var message =
            "Delete this burst of \(targets.count) frames? This removes every frame in the series from the card."
        if plan.pairCount > 0 {
            message += " Both the RAW and JPEG files of each pair are removed."
        }
        if plan.backupCount > 0 {
            message += " The backup copies on the other card are removed too."
        }
        return message + " This can't be undone."
    }
}

/// Bounded ImageIO/native-file port. The shared picture owner owns load/variant/publication lifetime.
@MainActor private enum NikonPhotoDecode {
    static func progressive(
        _ publication: MonitorMediaPicturePublication<MediaClip, UIImage>, model: NativeAppModel
    ) async -> UIImage? {
        let request = publication.request
        let target = request.record.payload
        let incremental = CGImageSourceCreateIncremental(
            [kCGImageSourceShouldCache: false] as CFDictionary)
        var deliveredBytes = 0
        var lastAttemptBytes = 0
        while !Task.isCancelled, request.isCurrent() {
            if model.isClipDownloaded(target) { return await complete(request, model: model) }
            publication.publish(
                status: .init(
                    message: model.mediaDownloadProgress[target.id] == nil
                        ? "Preparing image…" : "Loading from camera…"))
            guard let url = model.clipLocalURL(target) else { return nil }
            let data = await Task.detached(priority: .userInitiated) { try? Data(contentsOf: url) }
                .value
            guard !Task.isCancelled, request.isCurrent() else { return nil }
            if let data, data.count > deliveredBytes {
                deliveredBytes = data.count
                CGImageSourceUpdateData(incremental, data as CFData, false)
                if deliveredBytes >= 262_144, deliveredBytes - lastAttemptBytes >= 1_000_000,
                    let partial = partialImage(from: incremental)
                {
                    lastAttemptBytes = deliveredBytes
                    publication.publish(partial)
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
        return nil
    }
    static func complete(_ request: MonitorMediaPictureRequest<MediaClip>, model: NativeAppModel)
        async -> UIImage?
    {
        guard request.isCurrent(), let url = model.clipLocalURL(request.record.payload),
            let image = await MediaCellImageLoader.shared.downsampled(at: url, maxPixelSize: 4096),
            request.isCurrent()
        else { return nil }
        model.resolveEXIFOrientation(for: request.record.payload, at: url)
        return request.isCurrent() ? image : nil
    }
    private static func partialImage(from source: CGImageSource) -> UIImage? {
        guard CGImageSourceGetCount(source) > 0,
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var orientation = UIImage.Orientation.up
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
            let raw = properties[kCGImagePropertyOrientation] as? UInt32,
            let exif = CGImagePropertyOrientation(rawValue: raw)
        {
            orientation = UIImage.Orientation(exif)
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }
}

extension UIImage.Orientation {
    /// EXIF/CGImage orientation → UIKit orientation (no built-in bridge exists).
    fileprivate init(_ exif: CGImagePropertyOrientation) {
        switch exif {
        case .up: self = .up
        case .upMirrored: self = .upMirrored
        case .down: self = .down
        case .downMirrored: self = .downMirrored
        case .left: self = .left
        case .leftMirrored: self = .leftMirrored
        case .right: self = .right
        case .rightMirrored: self = .rightMirrored
        }
    }
}

// MARK: - Player

/// Composes the shared playback host with the actual gallery request and Nikon's camera source.
struct MediaPlayerView: View {
    let clips: [MediaClip]
    private let startingClip: MediaClip
    private let opening: MonitorMediaGalleryOpen<MediaClip>?
    @Environment(NativeAppModel.self) private var model
    @Environment(MonitorDeliveryCoordinator.self) private var deliveryCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var context: NikonOperatorPlaybackContext?

    init(
        clips: [MediaClip], startingAt clip: MediaClip,
        opening: MonitorMediaGalleryOpen<MediaClip>? = nil
    ) {
        self.clips = clips
        startingClip = clip
        self.opening = opening
    }

    var body: some View {
        ZStack {
            if let context {
                sharedPlayer(context)
            } else {
                Color.black.overlay { ProgressView().tint(MonitorTheme.accent) }
            }
        }
        .task {
            guard context == nil, let library = model.mediaLibrary else { return }
            let request: MonitorMediaGalleryOpen<MediaClip>
            if let opening {
                request = opening
            } else {
                guard
                    let record = library.records.first(where: { $0.payload.id == startingClip.id })
                else {
                    dismiss()
                    return
                }
                let ids = Set(clips.map(\.id))
                request = .init(
                    record: record,
                    playlist: library.records.filter { ids.contains($0.payload.id) },
                    admission: library.actionToken)
            }
            let delivery = deliveryCoordinator
            guard
                let created = NikonOperatorPlaybackContext(
                    model: model, initial: request, delivery: delivery,
                    // Playback waits only while a delivery caches from the camera, never
                    // cancelling it (A2-54).
                    cameraTransferReleased: { await delivery.cameraTransferReleased() })
            else {
                dismiss()
                return
            }
            context = created
        }
        .onDisappear { model.isMediaPlaybackActive = false }
        .onChange(of: playing) { _, value in model.isMediaPlaybackActive = value }
        // The player is a full-screen cover, so the root's download cover cannot present over
        // it: the playback LUT picker asks this mount instead.
        .redDownloadCover(model, host: .playback)
    }

    private var playing: Bool {
        let player = context?.media.playback
        return player?.reportedPlaying ?? player?.playRequested ?? false
    }

    private func sharedPlayer(_ context: NikonOperatorPlaybackContext) -> some View {
        let menus = NikonAssistMenuAdapter(model: model, compact: false, context: .playback)
        return MonitorOperatorPlaybackHost(
            opening: context.initial, host: context.host, values: .nikon(model),
            options: .init(
                signalOptions: .init(
                    falseColor: AnyView(menus.falseColor), zebra: AnyView(menus.zebra),
                    reference: menus.falseColorReference),
                availableAssistTools: Set(model.playbackAssistPaletteTools.map(\.selection)),
                initialRatingShadeOpen: DemoHarness.ratingShade == "open",
                initialChromeVisible: !DemoHarness.playbackCleanView),
            makeSource: { context }, captureSource: { context.sourceAdmission },
            preview: { NikonPlaybackInspectorPreview(tool: $0, host: context.host) },
            lookMenu: { NikonLUTPicker(downloadHost: .playback).environment(model) },
            deliveryPopup: { [model] request, dismiss in
                request.popup(model, coordinator: context.delivery, onDismiss: dismiss)
            })
    }
}
