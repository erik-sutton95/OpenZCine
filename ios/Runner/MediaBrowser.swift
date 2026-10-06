import AVFoundation
import ImageIO
import MonitorPresentation
import MonitorUI
import OSLog
import OpenCineAppKit
import OpenCineApple
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

/// Geometry for a media popup panel anchored to its trigger button.
///
/// The preferred width is a *preference, not a promise*: a 400pt panel cannot fit a 393pt phone,
/// and no clamp rescues a width that does not fit — a trailing-aligned `min(max(…))` silently
/// inverts and shoves the panel off the leading edge. So the width is bounded by the safe
/// viewport first, which is precisely what makes the two-edge clamp well-formed afterwards.
///
/// Pure and host-local (the values feed straight into `.offset`/`.frame`) so the phone-width
/// matrix is covered by unit tests instead of twenty screenshots.
struct MediaPopupPlacement: Equatable {
    /// Leading edge relative to the host origin.
    let x: CGFloat
    /// Top edge relative to the host origin.
    let y: CGFloat
    let width: CGFloat
    let maxHeight: CGFloat

    /// Gap kept between the panel and every safe-area edge.
    static let margin: CGFloat = 12

    /// Width and leading edge — the rule every anchored media popup shares. Only the vertical
    /// rule differs between the below-anchor and above-anchor panels.
    static func fitted(
        anchor: CGRect,
        host: CGRect,
        safeArea: MonitorEdgeInsets,
        preferredWidth: CGFloat
    ) -> (x: CGFloat, width: CGFloat) {
        let minX = host.minX + max(0, CGFloat(safeArea.leading))
        let maxX = host.maxX - max(0, CGFloat(safeArea.trailing))
        let width = max(0, min(preferredWidth, maxX - minX - margin * 2))
        // Trailing-align to the trigger, then clamp inside BOTH margins. With the width already
        // bounded, `minX + margin <= maxX - width - margin`, so the outer `min` can no longer
        // overrule the inner `max`.
        let trailing = anchor.width > 1 ? anchor.maxX : maxX - margin
        let x = min(max(trailing - width, minX + margin), maxX - width - margin)
        return (x - host.minX, width)
    }

    /// Panel hanging below its trigger, kept clear of every safe-area edge. A stale anchor (one
    /// frame behind a rotation or an iPad window resize) can shift the panel but can no longer
    /// push it off-screen: both axes are clamped into the live safe viewport every layout pass.
    static func below(
        anchor: CGRect,
        host: CGRect,
        safeArea: MonitorEdgeInsets,
        preferredWidth: CGFloat,
        minimumHeight: CGFloat
    ) -> MediaPopupPlacement {
        let (x, width) = fitted(
            anchor: anchor, host: host, safeArea: safeArea, preferredWidth: preferredWidth)
        let minY = host.minY + max(0, CGFloat(safeArea.top))
        let maxY = host.maxY - max(0, CGFloat(safeArea.bottom))
        let desiredTop = anchor.width > 1 ? anchor.maxY + 8 : minY + 120
        let top = max(minY + margin, min(desiredTop, maxY - margin - minimumHeight))
        return MediaPopupPlacement(
            x: x,
            y: top - host.minY,
            width: width,
            maxHeight: max(0, maxY - margin - top)
        )
    }
}

/// Full-screen Media page on the shared `MonitorMediaCatalog`. Nikon supplies the clip facts,
/// thumbnails, card-slot cards and caching bar; opening, sharing, caching and deleting stay here.
struct MediaBrowserView: View {
    var safeArea: MonitorEdgeInsets = .zero
    @Environment(NativeAppModel.self) private var model
    @Environment(\.monitorWindowGeometry) private var windowGeometry
    @Environment(MediaDeliveryCoordinator.self) private var deliveryCoordinator
    @State private var playingClip: MediaClip?
    @State private var viewingPhoto: MediaClip?
    /// The representative of a burst series whose members are being browsed (Manage series view).
    @State private var seriesRepresentative: MediaClip?
    /// Transient explanation shown when a proxy-less R3D master is tapped.
    @State private var masterNotice: String?
    @State private var masterNoticeDismissTask: Task<Void, Never>?
    private var isSelecting: Bool {
        get { model.mediaSelectionIsSelecting }
        nonmutating set { model.mediaSelectionIsSelecting = newValue }
    }
    private var selectedClipIDs: Set<String> {
        get { model.mediaSelectedClipIDs }
        nonmutating set { model.mediaSelectedClipIDs = newValue }
    }
    @State private var isBatchDeleteConfirmPresented = false
    /// Set by the post-hop share resume: the player opens with its share popup already on this
    /// destination. Cleared when the player dismisses.
    @State private var resumeShareDestination: MediaDeliveryDestination?
    @State private var deliveryRequest: MediaDeliveryRequest?
    @State private var isFilterPopupPresented = false
    @State private var filterButtonFrame: CGRect = .zero
    /// Durations read from cached files; each thumbnail reports its clip's once the asset loads.
    @State private var resolvedDurations: [String: String] = [:]

    private var displayedClips: [MediaClip] { model.filteredMediaClips }

    private var selectedClips: [MediaClip] {
        // A selected burst cell stands for its whole series, so delete, share and cache act on
        // every frame, not just the representative (Erik: "delete only removed 1 of the burst").
        model.burstExpanded(displayedClips.filter { selectedClipIDs.contains($0.id) })
    }

    private var libraryStatus: String {
        if model.mediaFetchInProgress {
            return model.mediaFetchListedCount == 0
                ? "Scanning…"
                : "Listing… \(model.mediaFetchListedCount) found"
        }
        return model.isConnected && model.mediaBrowserSource == .camera
            ? "Camera + local cache" : "Available on this phone"
    }

    var body: some View {
        // Read first: the projection pass it runs also feeds the category counts and bursts.
        let clips = displayedClips
        let clipsByID = Dictionary(
            clips.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        ZStack(alignment: .topLeading) {
            LiveDesign.background

            MonitorMediaCatalog(
                brand: "OpenZCine", safeArea: resolvedSafeArea, items: catalogItems(clips),
                categories: MediaCategoryTab.allCases.map {
                    MonitorMediaCategory(
                        id: $0.id, title: $0.rawValue, count: model.mediaCategoryCount($0))
                },
                category: model.mediaCategoryTab.id, layout: model.mediaBrowserLayout,
                thumbnailSize: model.mediaThumbnailSize,
                sortTitle: model.mediaSortOrder.rawValue.capitalized, status: libraryStatus,
                selectedIDs: selectedClipIDs, selecting: isSelecting,
                refreshing: model.mediaFetchInProgress,
                canRefresh: model.mediaBrowserSource == .camera,
                tablet: UIDevice.current.userInterfaceIdiom == .pad,
                action: { handle($0, clips: clipsByID) }
            ) { item in
                if let clip = clipsByID[item.id] {
                    MediaClipThumbnail(
                        clip: clip, list: model.mediaBrowserLayout == .list,
                        isDownloaded: model.isClipDownloaded(clip),
                        localURL: model.clipLocalURL(clip),
                        thumbnailURL: model.clipThumbnailURL(clip),
                        needsDuration: resolvedDurations[clip.id] == nil,
                        onDuration: { resolvedDurations[clip.id] = $0 })
                }
            } empty: {
                if model.mediaFetchInProgress { listingState } else { emptyState }
            } filters: {
                MonitorCatalogFilterButton(
                    activeCount: model.mediaActiveFilterCount, open: isFilterPopupPresented
                ) { isFilterPopupPresented.toggle() }
                .background {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear { filterButtonFrame = proxy.frame(in: .global) }
                            .onChange(of: proxy.frame(in: .global)) { _, frame in
                                filterButtonFrame = frame
                            }
                    }
                }
            } sidebar: {
                if model.mediaBrowserSource == .camera, !model.mediaStorageSlots.isEmpty {
                    storageCards
                }
            } accessory: {
                if !isSelecting, let streaming = clips.first(where: { model.isClipStreaming($0) }),
                    let progress = model.mediaDownloadProgress[streaming.id]
                {
                    clipCacheHeaderBar(filename: streaming.filename, progress: progress)
                }
            }

            if let deliveryToast = deliveryCoordinator.completionToast,
                deliveryCoordinator.showsLocalOverlay
            {
                VStack {
                    Spacer()
                    Text(deliveryToast)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(LiveDesign.text)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .liquidGlass(in: Capsule(), interactive: false)
                        .padding(.bottom, max(CGFloat(safeArea.bottom) + 80, 96))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
                .zIndex(5)
            }

            if isFilterPopupPresented {
                filterPopupOverlay
            }

            if let progress = model.mediaDeletionProgress {
                MediaDeletionProgressOverlay(progress: progress)
                    .transition(.opacity)
                    .zIndex(6)
            }

            if let deliveryRequest {
                deliveryPopupOverlay(clips: deliveryRequest.clips)
            }

            if deliveryCoordinator.showsLocalOverlay,
                let deliveryOverlay = deliveryCoordinator.overlayState
            {
                MediaDeliveryTopAnchor(horizontalPadding: 24) {
                    MediaDeliveryOverlay(state: deliveryOverlay) {
                        deliveryCoordinator.cancel()
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(50)
            }

        }
        .ignoresSafeArea()
        .observeMonitorWindowGeometry()
        .overlay(alignment: .bottom) {
            if let masterNotice {
                Text(masterNotice)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(LiveDesign.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .liquidGlass(in: Capsule())
                    .padding(.bottom, 24)
                    .transition(.opacity)
            }
        }
        .confirmationDialog(
            // Context-aware: pair/master/backup notes appear only when this selection
            // actually pulls those companions in (videos never see stills wording).
            isBatchDeleteConfirmPresented ? model.deletionConfirmMessage(for: selectedClips) : "",
            isPresented: $isBatchDeleteConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let clips = selectedClips
                Task {
                    _ = await model.deleteMediaClips(clips)
                    exitSelectionMode()
                }
            }
        }
        .onAppear {
            model.refreshMediaClips()
            if let resumeClips = model.pendingHopShareResumeClips {
                // Resume where the Frame.io setup hop interrupted: one cached clip reopens in the
                // player with the share popup on the Frame.io step; anything else reopens the
                // share popup over the grid. Continuation, not a restart.
                model.pendingHopShareResumeClips = nil
                if resumeClips.count == 1, let clip = resumeClips.first,
                    model.isClipDownloaded(clip)
                {
                    resumeShareDestination = .frameio
                    open(clip)
                } else if !resumeClips.isEmpty {
                    deliveryRequest = MediaDeliveryRequest(
                        clips: resumeClips, preferredDestination: .frameio)
                }
            }
            if !model.isStandaloneMediaLibraryPresented,
                model.mediaBrowserSource == .iPhone, !model.hasLocalMediaClips
            {
                model.mediaBrowserSource = .camera
            }
            Task { await model.refreshMediaStorageSlots() }
            if model.isConnected, model.mediaBrowserSource == .camera {
                model.scheduleFetchClipsFromCamera()
            }
            if DemoHarness.openMediaAction == "play" {
                playingClip = displayedClips.first { model.isClipDownloaded($0) }
            }
        }
        .fullScreenCover(item: $playingClip, onDismiss: { resumeShareDestination = nil }) { clip in
            MediaPlayerView(
                clips: displayedClips,
                startingAt: clip,
                initialShareDestination: resumeShareDestination
            )
            .environment(model)
            .environment(deliveryCoordinator)
        }
        .fullScreenCover(item: $viewingPhoto) { clip in
            MediaPhotoViewer(clip: clip).environment(model)
        }
        .fullScreenCover(item: $seriesRepresentative) { clip in
            MediaBurstSeriesView(representative: clip).environment(model)
        }
        .animation(.spring(duration: 0.32), value: deliveryCoordinator.isActive)
        .animation(.easeInOut(duration: 0.2), value: model.mediaThumbnailSize)
        .animation(.easeInOut(duration: 0.2), value: model.mediaBrowserLayout)
        .onAppear { deliveryCoordinator.enterLocalOverlayContext() }
        .onDisappear { deliveryCoordinator.exitLocalOverlayContext() }
        .mediaDeliveryShareSheet(enabled: playingClip == nil)
    }

    private func catalogItems(_ clips: [MediaClip]) -> [MonitorMediaItem] {
        let list = model.mediaBrowserLayout == .list
        let paired = model.rawPairedClipIDs(clips)
        // ponytail: two cache stats per clip per render; memoize per clip if large cards stutter.
        return clips.map { clip in
            let downloaded = model.isClipDownloaded(clip)
            let hasRaw = paired.contains(clip.id)
            let duration = resolvedDurations[clip.id]
            var permissions: MonitorMediaPermissions = [.favorite, .share, .delete]
            if canCache(clip, downloaded: downloaded) { permissions.insert(.cache) }
            return MediaClipCellPresentation.item(
                clip: clip,
                detail: list
                    ? MediaClipCellPresentation.metadataLine(
                        clip, hasRawSibling: hasRaw, duration: duration, isDownloaded: downloaded)
                    : "",
                isDownloaded: downloaded,
                cacheProgress: model.mediaDownloadProgress[clip.id]
                    ?? model.clipBufferedFraction(clip),
                isStreaming: model.isClipStreaming(clip), hasRawSibling: hasRaw,
                burstCount: model.burstSeries(for: clip)?.count, duration: duration,
                list: list, selecting: isSelecting, permissions: permissions)
        }
    }

    private func canCache(_ clip: MediaClip, downloaded: Bool) -> Bool {
        model.isConnected && clip.handle != nil && !downloaded
    }

    private func handle(_ action: MonitorMediaAction, clips: [String: MediaClip]) {
        switch action {
        case .back: model.dismissMediaLibrary()
        // Authoritative re-enumeration on demand (#296): the camera's inventory is the truth.
        case .refresh: model.refreshCameraMediaInventory()
        case .cycleSort: model.cycleMediaSortOrder()
        case .category(let id):
            if let tab = MediaCategoryTab(rawValue: id) { model.mediaCategoryTab = tab }
        case .layout(let layout): model.mediaBrowserLayout = layout
        case .thumbnailSize(let size): model.mediaThumbnailSize = size
        case .open(let id):
            if let clip = clips[id] { open(clip) }
        case .select(let id):
            guard let clip = clips[id] else { return }
            if isSelecting { toggleSelection(clip) } else { beginSelection(with: clip) }
        case .selection(let ids):
            if !isSelecting { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
            isSelecting = true
            selectedClipIDs = ids
        case .favorite(let id):
            if let clip = clips[id] { model.toggleClipFavorite(clip) }
        case .selectAll: selectedClipIDs = Set(clips.keys)
        case .clearSelection: exitSelectionMode()
        case .shareSelection:
            let selected = selectedClips
            if !selected.isEmpty { deliveryRequest = MediaDeliveryRequest(clips: selected) }
        case .cacheSelection:
            let selected = selectedClips.filter {
                canCache($0, downloaded: model.isClipDownloaded($0))
            }
            Task { for clip in selected { _ = await model.cacheClipFromCamera(clip) } }
        case .favoriteSelection:
            for clip in clips.values where selectedClipIDs.contains(clip.id) && !clip.isFavorite {
                model.toggleClipFavorite(clip)
            }
        case .deleteSelection:
            if !selectedClipIDs.isEmpty { isBatchDeleteConfirmPresented = true }
        }
    }

    /// Preferred, not guaranteed; see ``MediaPopupPlacement``.
    private let filterPopupWidth: CGFloat = 400

    private var filterPopupOverlay: some View {
        GeometryReader { proxy in
            // Recomputed every layout pass, so rotation and iPad window resizes re-place the
            // panel instead of reusing the geometry it opened with.
            let place = MediaPopupPlacement.below(
                anchor: filterButtonFrame,
                host: proxy.frame(in: .global),
                safeArea: safeArea,
                preferredWidth: filterPopupWidth,
                minimumHeight: 180
            )

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { isFilterPopupPresented = false }

                MediaFilterPopup {
                    isFilterPopupPresented = false
                }
                .environment(model)
                .frame(width: place.width)
                .frame(maxHeight: place.maxHeight, alignment: .top)
                .offset(x: place.x, y: place.y)
            }
        }
        .ignoresSafeArea()
    }

    /// The share chip lives in the shared selection tray, so the popup hangs above the tray.
    private func deliveryPopupOverlay(clips: [MediaClip]) -> some View {
        MediaDeliveryPopupOverlay(
            clips: clips,
            anchorFrame: .zero,
            placement: .aboveAnchor,
            preferredDestination: deliveryRequest?.preferredDestination,
            safeArea: safeArea,
            onBeginDelivery: { request in
                deliveryRequest = nil
                deliveryCoordinator.begin(request, model: model)
            }
        ) {
            deliveryRequest = nil
        }
        .environment(model)
    }

    private var resolvedSafeArea: EdgeInsets {
        if windowGeometry.validSize != nil { return windowGeometry.safeArea }
        return EdgeInsets(
            top: CGFloat(safeArea.top), leading: CGFloat(safeArea.leading),
            bottom: CGFloat(safeArea.bottom), trailing: CGFloat(safeArea.trailing))
    }

    private var storageCards: some View {
        VStack(spacing: 8) {
            ForEach(model.mediaStorageSlots) { slot in
                let active = model.mediaStorageSlotFilter == slot.storageID
                Button {
                    if active {
                        model.mediaStorageSlotFilter = nil
                    } else {
                        model.mediaStorageSlotFilter = slot.storageID
                    }
                } label: {
                    MediaStorageCard(slot: slot, isActive: active, compact: true)
                }
                .buttonStyle(.monitorTapTarget)
            }
        }
    }

    private func clipCacheHeaderBar(filename: String, progress: Double) -> some View {
        HStack(spacing: 10) {
            ProgressView(value: progress)
                .tint(LiveDesign.accent)
                .frame(maxWidth: 120)
            Text("CACHING \(filename) \(Int(progress * 100))%")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(LiveDesign.muted)
                .lineLimit(1)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .liquidGlass(in: Capsule(), interactive: false)
    }

    private func exitSelectionMode() {
        isSelecting = false
        selectedClipIDs.removeAll()
    }

    private func beginSelection(with clip: MediaClip) {
        guard !isSelecting else { return }
        isSelecting = true
        selectedClipIDs = [clip.id]
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func toggleSelection(_ clip: MediaClip) {
        if selectedClipIDs.contains(clip.id) {
            selectedClipIDs.remove(clip.id)
        } else {
            selectedClipIDs.insert(clip.id)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "film.stack")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(LiveDesign.faint)
            Text(emptyStateTitle)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveDesign.muted)
            if let subtitle = emptyStateSubtitle {
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(LiveDesign.faint)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyStateTitle: String {
        if !model.isConnected {
            return model.hasCachedMediaClips
                ? "No clips match these filters"
                : "No downloaded clips"
        }
        return "No clips yet"
    }

    private var emptyStateSubtitle: String? {
        if !model.isConnected {
            return model.hasCachedMediaClips
                ? "Try clearing filters or switching tabs."
                : "Download clips while connected to watch them offline."
        }
        return "Clips appear here as they're discovered on the card."
    }

    private var listingState: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.large)
                .tint(LiveDesign.muted)
            Text("Listing clips on camera…")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(LiveDesign.muted)
            Text(
                model.mediaFetchListedCount == 0
                    ? "Querying card storage…"
                    : "\(model.mediaFetchListedCount) clip\(model.mediaFetchListedCount == 1 ? "" : "s") found so far"
            )
            .font(.system(size: 12))
            .foregroundStyle(LiveDesign.faint)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func open(_ clip: MediaClip) {
        if isSelecting {
            toggleSelection(clip)
            return
        }
        // A burst representative opens the series view (its other frames are hidden in the grid).
        if model.burstSeries(for: clip) != nil {
            seriesRepresentative = clip
            return
        }
        if clip.mediaKind == .photo {
            viewingPhoto = clip
            return
        }
        // An R3D master only reaches the grid when no same-stem proxy was found on the
        // card; the player cannot decode it, so explain instead of opening a dead player.
        if MediaClipFilename.isR3D(clip.filename) {
            showMasterNotice("R3D master — no playable proxy was found for this clip.")
            return
        }
        playingClip = clip
    }

    private func showMasterNotice(_ message: String) {
        withAnimation { masterNotice = message }
        masterNoticeDismissTask?.cancel()
        masterNoticeDismissTask = Task {
            try? await Task.sleep(for: .seconds(2.6))
            guard !Task.isCancelled else { return }
            withAnimation { masterNotice = nil }
        }
    }
}

// MARK: - Browser chrome

/// Compact glass filter panel — mirrors live-view `AssistPanel` styling, anchored near the
/// header Filter button instead of a full-screen sheet.
struct MediaFilterPopup: View {
    @Environment(NativeAppModel.self) private var model
    let onClose: () -> Void

    var body: some View {
        GlassPanel(padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text("Filters")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .bold))
                    .kerning(1)
                    .textCase(.uppercase)
                    .foregroundStyle(LiveDesign.text)
                    Spacer()
                    CloseButton(action: onClose, size: 26)
                }
                ScrollView {
                    nikonMediaFilterForm(model: model)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }

}

@MainActor
func nikonMediaFilterForm(model: NativeAppModel) -> MonitorMediaFilterForm {
    let options = model.mediaFilterOptions
    let storageChoices: MonitorMediaStorageChoices?
    if model.mediaBrowserSource == .camera, !model.mediaStorageSlots.isEmpty {
        let slots = model.mediaStorageSlots
        storageChoices = MonitorMediaStorageChoices(
            options: slots.map {
                MonitorMediaFilterChoice(id: String($0.storageID), label: "SLOT \($0.slotNumber)")
            },
            selectedId: model.mediaStorageSlotFilter.map(String.init),
            onToggle: { id in
                guard let slot = slots.first(where: { String($0.storageID) == id }) else { return }
                model.mediaStorageSlotFilter =
                    model.mediaStorageSlotFilter == slot.storageID ? nil : slot.storageID
            })
    } else {
        storageChoices = nil
    }
    return MonitorMediaFilterForm(
        formats: options.formats.map(\.rawValue),
        resolutions: options.resolutions.map(\.rawValue),
        colors: [],
        formatSelection: Set(model.mediaFormatFilters.map(\.rawValue)),
        resolutionSelection: Set(model.mediaResolutionFilters.map(\.rawValue)),
        colorSelection: [], dateStartLabel: nil, dateEndLabel: nil,
        hasDates: false,
        onToggleFormat: { id in
            guard let value = options.formats.first(where: { $0.rawValue == id }) else { return }
            model.toggleMediaFormatFilter(value)
        },
        onToggleResolution: { id in
            guard let value = options.resolutions.first(where: { $0.rawValue == id }) else {
                return
            }
            model.toggleMediaResolutionFilter(value)
        },
        onToggleColor: { _ in }, onPickStart: {}, onPickEnd: {},
        onClear: model.clearMediaFilters,
        photoSizes: options.photoSizes.isEmpty
            ? nil
            : MonitorMediaPhotoSizeChoices(
                options: options.photoSizes.map {
                    MonitorMediaFilterChoice(id: $0.rawValue, label: $0.rawValue)
                },
                selectedIds: Set(model.mediaPhotoSizeFilters.map(\.rawValue)),
                onToggle: { id in
                    guard let value = options.photoSizes.first(where: { $0.rawValue == id }) else {
                        return
                    }
                    model.toggleMediaPhotoSizeFilter(value)
                }),
        dateWindows: options.dateWindows.isEmpty
            ? nil
            : MonitorMediaDateWindowChoices(
                options: options.dateWindows.map {
                    MonitorMediaFilterChoice(id: $0.rawValue, label: $0.rawValue)
                },
                selectedId: model.mediaDateWindow?.rawValue,
                onToggle: { id in
                    guard let value = options.dateWindows.first(where: { $0.rawValue == id }) else {
                        return
                    }
                    model.toggleMediaDateWindow(value)
                }),
        storage: storageChoices,
        hasActiveFilters: model.mediaActiveFilterCount > 0
    )
}

private struct MediaStorageCard: View {
    let slot: MediaStorageSlotDisplay
    var isActive: Bool
    var compact: Bool = false

    var body: some View {
        HStack(spacing: compact ? 8 : 10) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: compact ? 14 : 18, weight: .semibold))
                .foregroundStyle(LiveDesign.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(
                    compact
                        ? "Slot \(slot.slotNumber)" : "\(slot.cameraName) [Slot \(slot.slotNumber)]"
                )
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(LiveDesign.text)
                .lineLimit(1)
                Text(slot.summaryLine)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, compact ? 10 : 14)
        .padding(.vertical, compact ? 10 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isActive ? LiveDesign.accentDim : LiveDesign.surface.opacity(0.55),
            in: RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MonitorTheme.radius, style: .continuous)
                .stroke(
                    isActive ? LiveDesign.accent.opacity(0.5) : LiveDesign.hairline, lineWidth: 1)
        )
    }
}

/// Source-derived catalog facts. The shared catalog never inspects camera handles or cache URLs.
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
    let onDuration: (String) -> Void

    @Environment(NativeAppModel.self) private var model
    @State private var thumbnail: UIImage?

    private var isPhoto: Bool { clip.mediaKind == .photo }

    var body: some View {
        ZStack {
            LiveDesign.surface
            if let thumbnail {
                Image(uiImage: thumbnail).resizable().aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isPhoto ? "photo" : "film")
                    .font(.system(size: list ? 20 : 28, weight: .light))
                    .foregroundStyle(LiveDesign.faint)
            }
        }
        // Orientation joins the trigger: a row that learns its rotation re-decodes upright.
        .task(id: "\(localURL?.absoluteString ?? "")#o\(clip.exifOrientation ?? 0)") {
            await loadThumbnail()
            await loadDuration()
        }
    }

    private func loadThumbnail() async {
        // Keyed by resolved orientation so a row learning its rotation re-decodes upright.
        let variant = list ? "list" : "grid"
        let cacheKey = "\(clip.id)#\(variant)#o\(clip.exifOrientation ?? 0)" as NSString
        if let cached = MediaCellThumbnailCache.shared.object(forKey: cacheKey) {
            thumbnail = cached
            return
        }
        func present(_ image: UIImage) {
            MediaCellThumbnailCache.shared.setObject(image, forKey: cacheKey)
            thumbnail = image
        }
        let thumbPixels = list ? 480 : 640
        if let thumbnailURL, let data = try? Data(contentsOf: thumbnailURL) {
            // The camera's PTP thumbs can be EXIF-stripped — the row's learned orientation
            // stands in so portrait shots render upright.
            if let image = await MediaCellImageLoader.shared.downsampled(
                data: data, maxPixelSize: thumbPixels, fallbackOrientation: clip.exifOrientation)
            {
                present(image)
                return
            }
            // Self-heal: a cached thumb that doesn't decode would re-fail (and spam ImageIO
            // errors) on every cell realisation. Deletes only the cached thumb, never the media.
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        if isPhoto, isDownloaded, let localURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: localURL, maxPixelSize: 640, fallbackOrientation: clip.exifOrientation)
        {
            present(image)
            return
        }
        if !isDownloaded, clip.handle != nil {
            await model.ensureThumbnail(for: clip)
            if let cachedURL = model.clipThumbnailURL(clip),
                let data = try? Data(contentsOf: cachedURL),
                let image = await MediaCellImageLoader.shared.downsampled(
                    data: data, maxPixelSize: thumbPixels,
                    fallbackOrientation: clip.exifOrientation)
            {
                present(image)
                return
            }
        }
        guard isDownloaded, !isPhoto, let localURL else { return }
        let asset = AVURLAsset(url: localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let framePixels: CGFloat = list ? 320 : 600
        generator.maximumSize = CGSize(width: framePixels, height: framePixels)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: time).image {
            present(UIImage(cgImage: cgImage))
        }
    }

    private func loadDuration() async {
        guard !isPhoto, needsDuration, isDownloaded, let localURL else { return }
        let asset = AVURLAsset(url: localURL)
        if let duration = try? await asset.load(.duration), duration.isValid, duration.seconds > 0 {
            onDuration(MediaClipFormatting.durationLabel(seconds: duration.seconds))
        }
    }
}

/// A centred, non-interactive progress card shown while a batch delete runs — the grid holds
/// steady behind it and refreshes once when the deletion finishes.
private struct MediaDeletionProgressOverlay: View {
    let progress: MediaDeletionProgress

    var body: some View {
        ZStack {
            Color.black.opacity(0.35).ignoresSafeArea()
            VStack(spacing: 6) {
                Text(
                    "Deleting \(progress.selectedCount) \(progress.selectedCount == 1 ? "item" : "items")…"
                )
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                if progress.hasCompanionFiles {
                    // Make the inflated file count legible: 8 picks can be 16 files once each
                    // RAW+JPEG pair (and any backup copies) are counted.
                    Text("\(progress.completed) of \(progress.total) files · incl. RAW + copies")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(LiveDesign.muted)
                } else {
                    Text("\(progress.completed) of \(progress.total)")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(LiveDesign.muted)
                }
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(LiveDesign.accent)
                    .frame(width: 220)
                    .padding(.top, 6)
                    .animation(.easeInOut(duration: 0.2), value: progress.fraction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .liquidGlass(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .allowsHitTesting(true)  // swallow taps so the grid can't be interacted with mid-delete
    }
}

/// "Manage series" view: the frames of one burst series in a grid, with per-frame open (rate /
/// share / single-frame delete via the photo viewer) and a destructive "delete the whole set"
/// action. A series that loses frames until one remains degrades back to a normal grid cell.
private struct MediaBurstSeriesView: View {
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let representative: MediaClip
    @State private var members: [MediaClip] = []
    @State private var selectedID: String?
    @State private var confirmDeleteAll = false

    private var selected: MediaClip? {
        members.first { $0.id == selectedID } ?? members.first
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let selected {
                // The selected frame reuses the full photo viewer — streaming decode, zoom,
                // rating, RAW toggle, share, and single-frame delete all keep working.
                // Recreated per frame (`.id`) so its per-clip state and stream reset cleanly.
                MediaPhotoViewer(
                    clip: selected,
                    onDeleteAll: { confirmDeleteAll = true },
                    onDeleted: { advanceAfterDeletion(of: selected) }
                )
                .id(selected.id)
            }
            // Delete-all runs over this fullScreenCover, so the progress bar mounts here too
            // (the browser-level overlay is behind the cover).
            if let progress = model.mediaDeletionProgress {
                MediaDeletionProgressOverlay(progress: progress)
                    .transition(.opacity)
                    .zIndex(6)
            }
        }
        .safeAreaInset(edge: .bottom) {
            // The scrubber sits above the home indicator via the safe-area inset; the viewer's
            // rating row stacks above it automatically (its chrome respects the inset edge).
            if let selected, members.count > 1 {
                BurstFilmstrip(
                    members: members,
                    selectedID: selected.id,
                    onSelect: { selectedID = $0 }
                )
            }
        }
        .statusBarHidden()
        .onAppear {
            members = model.burstMembers(of: representative)
            selectedID = members.first?.id
        }
        .confirmationDialog(
            "Delete this burst of \(members.count) frames?",
            isPresented: $confirmDeleteAll, titleVisibility: .visible
        ) {
            Button("Delete \(members.count) frames", role: .destructive) {
                let targets = members
                Task {
                    _ = await model.deleteMediaClips(targets)
                    dismiss()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(burstDeleteAllMessage)
        }
    }

    /// Names what delete-all actually removes — the cross-card/pair notes appear only when
    /// the plan really pulls those companions in.
    private var burstDeleteAllMessage: String {
        var message = "This removes every frame in the series from the card."
        let plan = model.deletionPlan(for: members)
        if plan.pairCount > 0 {
            message += " Both the RAW and JPEG files of each pair are removed."
        }
        if plan.backupCount > 0 {
            message += " The backup copies on the other card are removed too."
        }
        message += " This can't be undone."
        return message
    }

    /// Drops the deleted frame from the strip and shows its neighbour; a series that empties
    /// (or degrades to nothing worth paging) closes back to the grid.
    private func advanceAfterDeletion(of clip: MediaClip) {
        let index = members.firstIndex { $0.id == clip.id } ?? 0
        members.removeAll { $0.id == clip.id }
        guard !members.isEmpty else {
            dismiss()
            return
        }
        selectedID = members[min(index, members.count - 1)].id
    }
}

/// iPhone-Photos-style burst scrubber: dragging scrolls the strip with the centered thumb
/// highlighting live; the displayed frame commits when the scroll SETTLES, not on every
/// intermediate frame. The full viewer is heavy (it re-streams the frame), so committing on
/// every thumb that passes center used to recreate it dozens of times per drag — the lag and
/// "Preparing image…" storm Erik saw. Tapping a thumb jumps to it immediately.
private struct BurstFilmstrip: View {
    let members: [MediaClip]
    let selectedID: String
    let onSelect: (String) -> Void
    /// The thumb currently under the centre line — drives the live highlight only, NOT the
    /// heavy viewer (which commits when the scrub settles).
    @State private var scrolledID: String?
    /// Debounces the commit so the frame lands once the scrub stops, not on every thumb that
    /// crosses centre. Cancelled on each intermediate move.
    @State private var commitTask: Task<Void, Never>?

    /// Widest a thumb gets (selected). Half of it is subtracted from the side inset so the
    /// first/last frame can sit dead-centre.
    private static let maxThumbWidth: CGFloat = 46

    var body: some View {
        GeometryReader { proxy in
            // Enough leading/trailing space that ANY thumb — including the first and last —
            // can scroll to the centre anchor (was a fixed 130, far too little on a wide
            // landscape screen, so the edge frames were unreachable by scrubbing).
            let sideInset = max(0, proxy.size.width / 2 - Self.maxThumbWidth / 2)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 4) {
                    ForEach(members) { member in
                        FilmstripThumb(
                            clip: member, isSelected: member.id == (scrolledID ?? selectedID)
                        )
                        .onTapGesture { onSelect(member.id) }
                        .id(member.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollPosition(id: $scrolledID, anchor: .center)
            .scrollTargetBehavior(.viewAligned)
            .contentMargins(.horizontal, sideInset, for: .scrollContent)
        }
        .frame(height: 56)
        .onAppear { scrolledID = selectedID }
        // Commit the displayed frame only after the scrub settles (~140ms idle): the heavy
        // viewer re-streams each frame, so committing on every thumb that crosses centre was
        // the lag + "Preparing image…" storm. Each intermediate move cancels the prior commit.
        .onChange(of: scrolledID) { _, newValue in
            commitTask?.cancel()
            guard let newValue, newValue != selectedID else { return }
            commitTask = Task {
                try? await Task.sleep(for: .milliseconds(140))
                guard !Task.isCancelled else { return }
                onSelect(newValue)
            }
        }
        .onChange(of: selectedID) { _, newValue in
            // External selection (tap, deletion advance) re-centres the strip; a settle-commit
            // already has scrolledID == newValue, so this no-ops for scrubs.
            guard scrolledID != newValue else { return }
            withAnimation(.easeOut(duration: 0.2)) { scrolledID = newValue }
        }
        .padding(.vertical, 4)
    }
}

/// One scrubber thumb — the camera thumbnail at strip size, widened when selected (Photos
/// style). Fetches the thumb from the body when it isn't cached yet.
private struct FilmstripThumb: View {
    let clip: MediaClip
    let isSelected: Bool
    @Environment(NativeAppModel.self) private var model
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4, style: .continuous).fill(LiveDesign.surface)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: isSelected ? 46 : 30, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .strokeBorder(
                    isSelected ? LiveDesign.accent : Color.clear, lineWidth: 1.5)
        )
        .animation(.easeOut(duration: 0.15), value: isSelected)
        .task(id: clip.id) { await load() }
    }

    private func load() async {
        let cacheKey = "\(clip.id)#strip#o\(clip.exifOrientation ?? 0)" as NSString
        if let cached = MediaCellThumbnailCache.shared.object(forKey: cacheKey) {
            image = cached
            return
        }
        func decodeCachedThumb() async -> UIImage? {
            guard let url = model.clipThumbnailURL(clip) else { return nil }
            return await MediaCellImageLoader.shared.downsampled(
                at: url, maxPixelSize: 120, fallbackOrientation: clip.exifOrientation)
        }
        var loaded = await decodeCachedThumb()
        if loaded == nil, clip.handle != nil {
            await model.ensureThumbnail(for: clip)
            loaded = await decodeCachedThumb()
        }
        if let loaded {
            MediaCellThumbnailCache.shared.setObject(loaded, forKey: cacheKey)
            image = loaded
        }
    }
}

// MARK: - Photo viewer

/// Full-screen still viewer for camera JPEG/RAW/HEIF — streams the object from the card when
/// needed. Same-stem RAW+JPEG pairs open on the JPEG with a JPG ⇄ RAW toggle beside Share.
struct MediaPhotoViewer: View {
    let clip: MediaClip
    /// Burst-series hosting: shows a "Delete all" action for the whole set in the top bar.
    var onDeleteAll: (() -> Void)? = nil
    /// Burst-series hosting: called after a single-frame delete instead of dismissing, so the
    /// series view can advance to the neighbouring frame.
    var onDeleted: (() -> Void)? = nil
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var loadTask: Task<Void, Never>?
    @State private var zoom = MonitorPlaybackZoom()
    @State private var isSharePresented = false
    @State private var isPreparingShare = false
    @State private var isDeleteConfirmPresented = false
    /// Camera-read star rating; nil until loaded (or unreachable — row hidden).
    @State private var ratingStars: Int?
    /// Transient message shown when the body refuses a rating write (with its response code).
    @State private var ratingToast: String?
    /// RAW side of the JPG/RAW toggle is active (paired stills only).
    @State private var showingRaw = false

    /// The same-stem RAW behind this JPEG's grid item (nil for unpaired stills — no toggle).
    private var rawSibling: MediaClip? { model.rawSibling(of: clip) }

    /// The file the viewer currently loads, names, and shares — the JPEG or its RAW sibling.
    private var displayClip: MediaClip { showingRaw ? (rawSibling ?? clip) : clip }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                GeometryReader { geo in
                    Image(uiImage: image)
                        .resizable()
                        // Anamorphic stills are judged at their intended geometry; the file is
                        // never touched. `nil` (de-squeeze off) means the image's own ratio.
                        .aspectRatio(
                            desqueezedAspectRatio(image.size, model.playbackDesqueeze),
                            contentMode: .fit
                        )
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(zoom.scale)
                        .offset(zoom.offset)
                        .contentShape(Rectangle())
                        .gesture(
                            SimultaneousGesture(
                                pinchGesture(size: geo.size), panGesture(size: geo.size)))
                }
                .ignoresSafeArea()
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView().tint(LiveDesign.accent)
                    Text(loadingMessage)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(LiveDesign.muted)
                }
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        CircleIconButton(systemName: "xmark", size: 34)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.monitorTapTarget)
                    Text(displayClip.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .lineLimit(1)
                    Spacer()
                    if rawSibling != nil {
                        sideToggle
                    }
                    if let onDeleteAll {
                        Button(action: onDeleteAll) {
                            HStack(spacing: 5) {
                                Image(systemName: "trash")
                                Text("Delete all")
                            }
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .liquidGlass(in: Capsule(), interactive: true)
                        }
                        .buttonStyle(.monitorTapTarget)
                    }
                    deleteButton
                    shareButton
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                Spacer()
                VStack(spacing: 10) {
                    if let ratingToast {
                        Text(ratingToast)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(LiveDesign.text)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .liquidGlass(in: Capsule(), interactive: true)
                            .padding(.horizontal, 24)
                            .transition(.opacity)
                    }
                    if let stars = ratingStars {
                        StarRatingRow(stars: stars) { target in
                            let previous = ratingStars
                            ratingStars = target
                            Task {
                                // The camera stays source of truth (the model confirms by
                                // readback). A refusal shows the body's response code rather
                                // than silently rolling the star back.
                                switch await model.setMediaStarRating(target, for: clip) {
                                case .confirmed(let confirmed):
                                    ratingStars = confirmed
                                case .refused(_, let message):
                                    ratingStars = previous
                                    showRatingToast(message)
                                case .offline:
                                    ratingStars = previous
                                }
                            }
                        }
                    }
                }
                .padding(.bottom, 18)
            }
        }
        .statusBarHidden()
        .onAppear {
            loadTask = Task { await loadImage() }
            Task { ratingStars = await model.mediaStarRating(for: clip) }
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            model.cancelClipStream()
            image = nil
        }
        .sheet(isPresented: $isSharePresented) {
            if let url = model.clipLocalURL(displayClip) {
                MultiShareSheet(urls: [url], metadataText: nil) {
                    isSharePresented = false
                }
            }
        }
    }

    /// Deletes the shot from the camera card (both sides of a RAW+JPEG pair) after a
    /// destructive confirmation, then closes the viewer.
    private var deleteButton: some View {
        Button {
            isDeleteConfirmPresented = true
        } label: {
            CircleIconButton(systemName: "trash", size: 34)
                .contentShape(Circle())
        }
        .buttonStyle(.monitorTapTarget)
        .confirmationDialog(
            model.deletionConfirmMessage(for: [clip]),
            isPresented: $isDeleteConfirmPresented,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                Task {
                    _ = await model.deleteMediaClips([clip])
                    if let onDeleted {
                        onDeleted()  // burst hosting advances to the neighbouring frame
                    } else {
                        dismiss()
                    }
                }
            }
        }
    }

    /// Shares the currently-viewed side of the still (JPEG/HEIF/NEF alike) once its camera
    /// download completes — the share sheet covers AirDrop, Files, and Save Image.
    private var shareButton: some View {
        Button {
            guard !isPreparingShare else { return }
            let target = displayClip
            if model.isClipDownloaded(target) {
                isSharePresented = true
            } else {
                isPreparingShare = true
                Task {
                    // The viewer already streams the full file; wait for it to land.
                    while !Task.isCancelled, !model.isClipDownloaded(target) {
                        try? await Task.sleep(for: .milliseconds(300))
                    }
                    isPreparingShare = false
                    if model.isClipDownloaded(target) { isSharePresented = true }
                }
            }
        } label: {
            if isPreparingShare {
                ProgressView()
                    .tint(LiveDesign.accent)
                    .frame(width: 34, height: 34)
            } else {
                CircleIconButton(systemName: "square.and.arrow.up", size: 34)
                    .contentShape(Circle())
            }
        }
        .buttonStyle(.monitorTapTarget)
        .accessibilityLabel("Share photo")
    }

    /// Compact JPG ⇄ RAW switch for a same-stem pair — mirrors the browser pill chrome.
    private var sideToggle: some View {
        HStack(spacing: 2) {
            sideSegment("JPG", isActive: !showingRaw) { showSide(raw: false) }
            sideSegment("RAW", isActive: showingRaw) { showSide(raw: true) }
        }
        .padding(2)
        .background(Color.black.opacity(0.35), in: Capsule())
        .overlay(Capsule().stroke(LiveDesign.hairline, lineWidth: 1))
        .accessibilityLabel("Photo format")
        .accessibilityValue(showingRaw ? "RAW" : "JPG")
    }

    private func sideSegment(
        _ title: String, isActive: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(isActive ? LiveDesign.accentDim : Color.clear, in: Capsule())
        }
        .buttonStyle(.monitorTapTarget)
    }

    /// Switches the viewer to the other side of the pair and loads/streams that file.
    private func showSide(raw: Bool) {
        guard showingRaw != raw else { return }
        showingRaw = raw
        loadTask?.cancel()
        model.cancelClipStream()
        loadTask = Task { await loadImage() }
    }

    /// Briefly shows a rating-write refusal (with the body's response code) above the star row.
    private func showRatingToast(_ message: String) {
        withAnimation { ratingToast = message }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation { ratingToast = nil }
        }
    }

    private var loadingMessage: String {
        if model.mediaDownloadProgress[displayClip.id] != nil {
            return "Loading from camera…"
        }
        return "Preparing image…"
    }

    private func pinchGesture(size: CGSize) -> some Gesture {
        MagnifyGesture()
            .onChanged { value in
                zoom.pinchChanged(
                    magnification: value.magnification, startAnchorX: value.startAnchor.x,
                    startAnchorY: value.startAnchor.y, size: size)
            }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.2)) { zoom.endGesture(size: size) }
            }
    }

    private func panGesture(size: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in zoom.panChanged(translation: value.translation) }
            .onEnded { _ in
                withAnimation(.easeOut(duration: 0.2)) { zoom.endGesture(size: size) }
            }
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }

        // Pair toggle keeps the current frame up while the other side streams — the pair shares
        // one stem thumbnail, and swapping it in would downgrade an already-decoded image.
        if image == nil, let thumbURL = model.clipThumbnailURL(displayClip),
            let data = try? Data(contentsOf: thumbURL),
            let thumb = UIImage(data: data)
        {
            await MainActor.run { image = thumb }
        }

        if model.isClipDownloaded(displayClip) {
            await loadFromDisk()
            return
        }

        model.startClipStream(displayClip)
        // Incremental decode of the growing file. Brute-force `UIImage(contentsOfFile:)` per
        // tick sprayed Console: format sniffing fails until the header lands ("could not find
        // plugin"), every partial decode logs a JFIF-incomplete warning, and each tick re-decoded
        // from byte zero. The incremental source keeps the parse state, and attempts are gated
        // to a meaningful chunk of fresh bytes.
        let incremental = CGImageSourceCreateIncremental(
            [kCGImageSourceShouldCache: false] as CFDictionary)
        var deliveredBytes = 0
        var lastAttemptBytes = 0
        while !Task.isCancelled {
            if model.isClipDownloaded(displayClip) {
                await loadFromDisk()
                return
            }
            guard let url = model.clipLocalURL(displayClip) else { return }
            if let data = try? Data(contentsOf: url), data.count > deliveredBytes {
                deliveredBytes = data.count
                CGImageSourceUpdateData(incremental, data as CFData, false)
                if deliveredBytes >= 262_144, deliveredBytes - lastAttemptBytes >= 1_000_000,
                    let partial = Self.partialImage(from: incremental)
                {
                    lastAttemptBytes = deliveredBytes
                    await MainActor.run { image = partial }
                }
            }
            try? await Task.sleep(for: .milliseconds(600))
        }
    }

    /// The decodable top portion of a partially streamed still, EXIF orientation applied.
    private static func partialImage(from source: CGImageSource) -> UIImage? {
        guard CGImageSourceGetCount(source) > 0,
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        var orientation = UIImage.Orientation.up
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any],
            let raw = properties[kCGImagePropertyOrientation] as? UInt32,
            let exif = CGImagePropertyOrientation(rawValue: raw)
        {
            orientation = UIImage.Orientation(exif)
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: orientation)
    }

    private func loadFromDisk() async {
        guard let url = model.clipLocalURL(displayClip) else { return }
        // Display-sized decode: a full-resolution still would allocate a decode surface far
        // beyond what any zoom shows (the IOSurface failures in Console).
        // ponytail: 4096 long edge ≈ 3× zoom headroom on phone screens; raise if deep
        // pinch-zoom ever needs more.
        guard
            let loaded = await MediaCellImageLoader.shared.downsampled(
                at: url, maxPixelSize: 4096)
        else { return }
        // The full file always carries the orientation header — learn it once so the grid's
        // (possibly EXIF-stripped) camera thumbnails render upright from here on.
        model.resolveEXIFOrientation(for: displayClip, at: url)
        await MainActor.run { image = loaded }
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

private struct PlaybackScopeDerivationConfiguration: Equatable, Sendable {
    let trafficLightsCrushClip: MonitorCrushClipCompensation
    let mapping: ExposureSignalMapping
    let vectorscopeCube: CubeLUT?

    func bundle(samples: OpenCineMedia.ScopeSamples, previous: ScopeAssistBundle)
        -> ScopeAssistBundle
    {
        ScopeAssistSampling.bundle(
            samples: samples,
            trafficLightsCrushClip: trafficLightsCrushClip,
            mapping: mapping,
            vectorscopeCube: vectorscopeCube,
            previous: previous)
    }
}

/// Five-star rating row on glass: tap a star to set the count, tap the active count to
/// clear. Optimistic — the caller writes to the camera and rolls back on failure.
struct StarRatingRow: View {
    let stars: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 10) {
            ForEach(1...5, id: \.self) { star in
                Button {
                    onSelect(star == stars ? 0 : star)
                } label: {
                    Image(systemName: star <= stars ? "star.fill" : "star")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(star <= stars ? LiveDesign.accent : LiveDesign.muted)
                }
                .buttonStyle(.monitorTapTarget)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .liquidGlass(in: Capsule())
    }
}

/// Full-screen AVPlayer with LiveDesign controls: play/pause, ±15s, mute, view-assist, favorite,
/// share (native or Frame.io), side arrows for clip navigation, pinch-to-zoom on the video,
/// single-tap on the frame to play/pause (with a transient transport flash), long-press drag to
/// scrub, and restart at end-of-clip.
struct MediaPlayerView: View {
    let clips: [MediaClip]
    private let startingClip: MediaClip
    @State private var session: NikonPlaybackSession?
    private var playback: MonitorMediaPlaybackModel<MediaClip, String>? { session?.owner }
    @State private var native = NikonPlaybackNativePort()
    private var activeClip: MediaClip { playback?.active?.payload ?? startingClip }
    @Environment(NativeAppModel.self) private var model
    @Environment(MediaDeliveryCoordinator.self) private var deliveryCoordinator
    @Environment(\.dismiss) private var dismiss

    /// Convenience alias for the clip currently playing.
    private var clip: MediaClip { activeClip }

    private var player: AVPlayer { native.player }
    private var isPlaying: Bool { playback?.reportedPlaying ?? playback?.playRequested ?? true }
    private var isMuted: Bool { playback?.muted ?? false }
    private var currentTime: Double { playback?.position ?? 0 }
    private var duration: Double { playback?.duration ?? 0 }
    private var conformSource: MonitorConformPreview.Source {
        playback?.metadata.conform ?? .init()
    }
    private var conformTarget: Double? {
        get { playback?.conformTarget }
        nonmutating set { playback?.setConformTarget(newValue) }
    }
    /// Whether the star-rating shade is open. Deliberately NOT reset per clip: the operator opened
    /// it to rate a run of shots, so it stays open across them until it is closed again.
    @State private var ratingShadeOpen = DemoHarness.ratingShade == "open"
    /// Retained 250 ms Nikon restart presentation; shared transport keeps its neutral seek rule.
    @State private var tailPresentation = NikonPlaybackTailPresentation()
    private var reachedEnd: Bool { tailPresentation.reachedEnd }
    private var isScrubbing: Bool { playback?.scrubbing ?? false }
    private var scrubTime: Double { playback?.scrubPosition ?? currentTime }
    private var isClipReady: Bool { playback?.ready ?? false }

    @State private var assistOptionsTool: MonitorAssistTool?
    @State private var playbackBarFrame: CGRect = .zero

    @State private var isFavorite = false
    @State private var exportState: ExportStatus = .none
    @State private var deliveryPresentation: MediaDeliveryPresentation?
    @State private var shareButtonFrame: CGRect = .zero
    @State private var deliveryPause: NikonPlaybackSession.DeliveryPause?
    @State private var toastMessage: String?

    private var videoDisplaySize: CGSize {
        guard let width = playback?.metadata.width, let height = playback?.metadata.height else {
            return CGSize(width: 16, height: 9)
        }
        return CGSize(width: width, height: height)
    }
    @State private var playbackScopeAssist: ScopeAssistBundle = .empty
    @State private var playbackScopeController = PlaybackScopeController()
    @State private var playbackAudioLevels: MonitorAudioMeterLevels?
    @State private var audioMeterController = MonitorPlaybackAudioMeterRuntime { status in
        Logger(subsystem: "OpenZCine", category: "media-playback-audio")
            .error("MTAudioProcessingTapCreate failed: \(status)")
    }
    @State private var playbackEffectsBox = MediaLUT.PlaybackEffectsBox()
    /// Invalidates detached scope derivations whenever polling is restarted or stopped.
    @State private var playbackScopePollingGeneration = 0
    /// Camera-read star rating for the active clip; nil until loaded (or unreachable).
    @State private var playerRatingStars: Int?

    init(
        clips: [MediaClip],
        startingAt clip: MediaClip,
        initialShareDestination: MediaDeliveryDestination? = nil
    ) {
        self.clips = clips
        startingClip = clip
        // Post-hop resume: open with the share popup already on the given destination.
        if let initialShareDestination {
            _deliveryPresentation = State(
                initialValue: MediaDeliveryPresentation(
                    clip: clip, preferredDestination: initialShareDestination))
        }
    }

    private var playbackPresentation: MonitorPlaybackPresentation {
        MonitorPlaybackPresentation(
            item: playback?.token, title: activeClip.filename, subtitle: "", source: nil,
            metadata: [], aspect: Double(videoDisplaySize.width / max(1, videoDisplaySize.height)),
            ready: isClipReady, error: playback?.error,
            progress: model.mediaDownloadProgress[activeClip.id],
            position: isScrubbing ? scrubTime : currentTime, duration: duration,
            buffered: model.clipBufferedFraction(activeClip) ?? 0,
            positionLabel: conformedLabel(isScrubbing ? scrubTime : currentTime),
            durationLabel: conformedLabel(duration), playing: isPlaying, reachedEnd: reachedEnd,
            scrubbing: isScrubbing, muted: isMuted, looping: false,
            previous: canGoToPreviousClip, next: canGoToNextClip, favorite: isFavorite,
            conform: conformSource, conformTarget: conformTarget,
            haptics: model.preferences.hapticsEnabled, toast: toastMessage,
            initialChromeVisible: !DemoHarness.playbackCleanView,
            loopAvailable: false, shareEnabled: canShareActiveClip)
    }

    private func admitted(
        _ item: MonitorPlaybackItemToken,
        _ action: (MonitorMediaPlaybackModel<MediaClip, String>) -> Void
    ) {
        guard let playback, playback.isActive, playback.token == item else { return }
        action(playback)
    }

    private var playbackActions: MonitorPlaybackActions {
        MonitorPlaybackActions(
            back: { dismiss() },
            play: { item, playing in admitted(item) { $0.setPlaying(playing) } },
            restart: { item in admitted(item) { _ in restartPlayback() } },
            seekBy: { item, seconds in admitted(item) { _ in seek(by: seconds) } },
            mute: { item, muted in admitted(item) { $0.setMuted(muted) } },
            loop: { _, _ in },
            conform: { item, target in admitted(item) { $0.setConformTarget(target) } },
            adjacent: { item, offset in admitted(item) { _ in goToAdjacentClip(offset: offset) } },
            favorite: { item in
                admitted(item) { _ in
                    model.toggleClipFavorite(activeClip)
                    isFavorite.toggle()
                }
            },
            share: { item in
                admitted(item) { _ in
                    guard canShareActiveClip else { return }
                    deliveryPause = session?.pauseForDelivery(playing: isPlaying)
                    deliveryPresentation = MediaDeliveryPresentation(clip: activeClip)
                }
            },
            beginScrub: { item in
                guard let playback, playback.isActive, playback.token == item else { return nil }
                return playback.beginScrub()
            },
            updateScrub: { edit, time in
                guard playback?.token == edit.item else { return }
                tailPresentation.seeking(to: time, duration: duration)
                playback?.updateScrub(seconds: time, admitted: edit)
            },
            updateFrameScrub: { edit, delta, width in
                guard playback?.token == edit.item else { return }
                playback?.updateFrameScrub(delta: delta, width: width, admitted: edit)
                tailPresentation.seeking(to: scrubTime, duration: duration)
            },
            commitScrub: { playback?.commitScrub(admitted: $0) },
            cancelScrub: { edit, reason in
                playback?.cancelScrub(interrupted: reason == .interrupted, admitted: edit)
            })
    }

    /// The shared assist palette in the playback slot, over the playback flags.
    private func playbackTools(_ context: MonitorPlaybackToolsContext) -> some View {
        let tools = model.playbackAssistPaletteTools
        let (metrics, frame) = MonitorAssistPaletteLayout.fieldMonitor(
            context.presentation, toolCount: tools.count, safeTop: context.safeTop)
        return NikonAssistPalette(
            tools: tools, context: .playback, layout: metrics, expanded: context.expanded,
            onOptions: { assistOptionsTool = $0 }
        )
        .position(x: frame.midX, y: frame.midY)
        .frame(
            width: context.presentation.viewport.width,
            height: context.presentation.viewport.height, alignment: .topLeading)
    }

    private var currentClipIndex: Int? {
        clips.firstIndex { $0.id == activeClip.id }
    }

    private var canGoToPreviousClip: Bool {
        guard let index = currentClipIndex else { return false }
        return index > 0
    }

    private var canGoToNextClip: Bool {
        guard let index = currentClipIndex else { return false }
        return index < clips.count - 1
    }

    private var playbackScopesActive: Bool {
        let visible = model.assist.playbackTools
        return visible.contains(.waveform) || visible.contains(.parade)
            || visible.contains(.histogram) || visible.contains(.trafficLights)
            || visible.contains(.vectorscope)
    }

    private var playbackAudioMetersActive: Bool {
        model.assist.playbackTools.contains(.audioMeters)
    }

    private var playbackScopeDerivationConfiguration: PlaybackScopeDerivationConfiguration {
        // Playback scopes measure source/log on the same anchored axis as live view; clips don't
        // persist a per-clip tone mode yet, so the mapping follows current camera state. The
        // vectorscope reads the monitor image through the look the player bakes (LUT tool + LUT).
        return PlaybackScopeDerivationConfiguration(
            trafficLightsCrushClip: model.assist.crushClipCompensation,
            mapping: model.playbackExposureSignalMapping,
            vectorscopeCube: model.vectorscopeMonitorCube(
                visibleTools: model.assist.playbackTools,
                curve: model.playbackExposureSignalMapping.curve))
    }

    var body: some View {
        ZStack {
            MonitorPlaybackScreen(
                value: playbackPresentation, actions: playbackActions,
                coverPresented: deliveryPresentation != nil,
                onBarFrame: { playbackBarFrame = $0 },
                slots: MonitorPlaybackPageSlots(
                    headerAccessory: {
                        AnyView(
                            VStack(spacing: 0) {
                                if ratingShadeMounts {
                                    ratingShadeHandle
                                    if ratingShadeOpen { ratingStarRow }
                                }
                            })
                    },
                    onShareButtonFrame: { shareButtonFrame = $0 }),
                picture: {
                    PlayerLayerView(player: player)
                        .scaleEffect(desqueezeScale(model.playbackDesqueeze), anchor: .center)
                },
                feedAssists: { rect in
                    FeedAlignedAssists(
                        clean: false, feed: rect,
                        excludeTools: [.level], usePlaybackContext: true)
                },
                canvasAssists: { size, rect in
                    if playbackScopesActive || playbackAudioMetersActive {
                        PlaybackAssistOverlayModule(
                            scopeAssist: playbackScopeAssist, videoRect: rect,
                            audioLevels: playbackAudioLevels, onOptions: { assistOptionsTool = $0 }
                        )
                        .frame(width: size.width, height: size.height)
                    }
                }, tools: { context in playbackTools(context) })
            if deliveryCoordinator.showsLocalOverlay,
                let deliveryOverlay = deliveryCoordinator.overlayState
            {
                MediaDeliveryTopAnchor(horizontalPadding: 24) {
                    MediaDeliveryOverlay(state: deliveryOverlay) {
                        deliveryCoordinator.cancel()
                    }
                }
                .transition(.move(edge: .top).combined(with: .opacity))
                .zIndex(50)
            }

            if let deliveryContext = deliveryPresentation {
                MediaDeliveryPopupOverlay(
                    clips: [deliveryContext.clip],
                    anchorFrame: shareButtonFrame,
                    placement: .aboveAnchor,
                    preferredDestination: deliveryContext.preferredDestination,
                    onBeginDelivery: { request in
                        deliveryPresentation = nil
                        startDelivery(request)
                    }
                ) {
                    closeDeliveryPopup()
                }
                .environment(model)
                .zIndex(3)
            }

            if let tool = assistOptionsTool {
                GeometryReader { proxy in
                    NikonAssistInspector(
                        tool: tool, tools: model.playbackAssistPaletteTools, viewport: proxy.size,
                        safeArea: proxy.safeAreaInsets, onSelect: { assistOptionsTool = $0 },
                        onDismiss: { assistOptionsTool = nil })
                }
                .ignoresSafeArea()
                .environment(model)
                .zIndex(4)
            }
        }
        .task(id: activeClip.id) {
            let item = playback?.token
            let captured = activeClip
            let stars = await model.mediaStarRating(for: captured)
            guard !Task.isCancelled, item == playback?.token, captured.id == activeClip.id else {
                return
            }
            playerRatingStars = stars
        }
        .animation(.easeInOut(duration: 0.28), value: activeClip.id)
        .animation(.spring(duration: 0.32), value: deliveryCoordinator.isActive)
        .statusBarHidden()
        .onAppear {
            appear()
            model.isMediaPlaybackActive = isPlaying
            deliveryCoordinator.enterLocalOverlayContext()
        }
        .onDisappear {
            disappear()
            model.isMediaPlaybackActive = false
            deliveryCoordinator.exitLocalOverlayContext()
        }
        .onChange(of: isPlaying) { _, playing in
            model.isMediaPlaybackActive = playing
        }
        .onChange(of: model.assist.playbackTools) { _, _ in
            updatePlaybackEffects()
            syncPlaybackScopeSampling()
            syncPlaybackAudioMetering()
        }
        .onChange(of: model.playbackImageEffects) { _, _ in
            updatePlaybackEffects()
        }
        .onChange(of: model.assist.crushClipCompensation) { _, _ in
            restartPlaybackScopeSampling()
        }
        .mediaDeliveryShareSheet(onDismiss: resumePlaybackIfNeeded)
    }

    private func startDelivery(_ request: MediaDeliveryBeginRequest) {
        deliveryCoordinator.begin(
            request,
            model: model,
            onCancel: { resumePlaybackIfNeeded() },
            onComplete: { outcome in
                exportState =
                    model.mediaClips.first { $0.id == activeClip.id }?.exportStatus
                    ?? activeClip.exportStatus
                switch outcome {
                case .frameio(let summary):
                    resumePlaybackIfNeeded()
                    showToast(summary)
                case .savedToPhotos:
                    resumePlaybackIfNeeded()
                case .failed(let message):
                    resumePlaybackIfNeeded()
                    showToast(message)
                case .share:
                    // Keep playback paused until the share sheet dismisses.
                    break
                }
            }
        )
    }

    private func resumePlaybackIfNeeded() {
        guard let deliveryPause else { return }
        self.deliveryPause = nil
        session?.resumeAfterDelivery(deliveryPause)
    }

    private func closeDeliveryPopup() {
        deliveryPresentation = nil
        exportState =
            model.mediaClips.first { $0.id == activeClip.id }?.exportStatus
            ?? activeClip.exportStatus
        resumePlaybackIfNeeded()
    }

    private func goToAdjacentClip(offset: Int) {
        guard let index = currentClipIndex, clips.indices.contains(index + offset) else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }
        tailPresentation.reset()
        withAnimation(.easeInOut(duration: 0.28)) {
            session?.navigate(to: clips[index + offset], clips: clips, model: model)
        }
        isFavorite = activeClip.isFavorite
        exportState = activeClip.exportStatus
    }

    // MARK: Bottom bar (playback transport or inline view-assist)

    /// Star rating, pulled down from the top edge and left there until pushed back up.
    ///
    /// It used to sit above the transport, where it cost a permanent band of picture for a control
    /// that is only wanted while actually rating. Up here it is out of the frame's way, and closed
    /// it costs a handle.
    ///
    /// The handle is not decoration. A pull-down nobody knows about is the same mistake the
    /// clean-view button exists to correct, so the shade always shows where to grab it — and the
    /// handle is a tap target too, since a tap is easier than a drag on a moving picture.
    /// The star row itself, revealed by dragging the handle down.
    @ViewBuilder
    private var ratingStarRow: some View {
        // Written to the card — the camera stays source of truth (the model confirms by readback).
        // A refusal surfaces the body's response code rather than rolling back silently.
        StarRatingRow(stars: playerRatingStars ?? 0) { target in
            let previous = playerRatingStars
            playerRatingStars = target
            let clip = activeClip
            let item = playback?.token
            Task {
                switch await model.setMediaStarRating(target, for: clip) {
                case .confirmed(let confirmed):
                    guard item == playback?.token else { return }
                    playerRatingStars = confirmed
                case .refused(_, let message):
                    guard item == playback?.token else { return }
                    playerRatingStars = previous
                    showToast(message)
                case .offline:
                    guard item == playback?.token else { return }
                    playerRatingStars = previous
                    showToast("Connect the camera to rate this clip")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .liquidGlass(in: Capsule(), interactive: false)
        .padding(.top, 4)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    /// Nothing at all without a camera-read rating: nil means the clip has no handle or there is no
    /// session, so the rating could not be written either and the handle would advertise a control
    /// that cannot work.
    private var ratingShadeMounts: Bool {
        playerRatingStars != nil || DemoHarness.ratingShade != nil
    }

    /// Tap toggles it. A bare chevron says "something is under here" without saying what; the
    /// star makes it self-describing.
    ///
    /// The drag it used to want is gone: pulling a shade down over a moving picture is fussy on a
    /// handheld rig, and the one gesture that has to stay reliable here is the scrub.
    private var ratingShadeHandle: some View {
        Button {
            withAnimation(.spring(duration: 0.28)) { ratingShadeOpen.toggle() }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "star.fill")
                    .font(.system(size: 10, weight: .semibold))
                Image(systemName: ratingShadeOpen ? "chevron.up" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
            }
            .foregroundStyle(LiveDesign.muted)
            .frame(width: 52, height: 20)
            .liquidGlass(in: Capsule(), interactive: true)
            .opacity(0.9)
        }
        .buttonStyle(.monitorTapTarget)
        .accessibilityLabel(ratingShadeOpen ? "Hide star rating" : "Show star rating")
    }

    /// Cached clips are ready now; on-camera clips are ready once the camera can cache them.
    private var canShareActiveClip: Bool {
        MediaDeliveryEligibility.canDeliver(
            clipIsLocal: model.isClipDownloaded(activeClip),
            cameraConnected: model.isConnected)
    }

    // MARK: Actions

    private func appear() {
        // Stop the shutter before playback changes the process-wide AVAudioSession category.
        model.setMediaPlaybackOwnsAudioSession(true)
        MediaPlaybackAudioSession.activateForPlayback()
        if playback?.closed == true {
            session = nil
            native = NikonPlaybackNativePort()
        }
        loadActiveClip()
    }

    private func loadActiveClip() {
        guard playback == nil, model.mediaLibrary != nil else { return }
        native.beforeItemRetirement = {
            playbackScopeController.stop()
            playbackEffectsBox.invalidateScopeComposition()
            syncPlaybackScopeSampling(active: false)
            audioMeterController.stopPolling()
            audioMeterController.detach(from: player.currentItem)
            playbackAudioLevels = nil
            playbackScopeAssist = .empty
        }
        native.afterItemInstallation = { item in
            if DemoHarness.mediaLUT { model.setAssist(.lut, visible: true) }
            attachPlaybackVideoComposition(to: item)
            audioMeterController.attach(to: item)
            syncPlaybackScopeSampling()
            syncPlaybackAudioMetering()
        }
        native.afterPlaybackEnd = { item in
            guard playback?.token == item else { return }
            tailPresentation.ended()
        }
        tailPresentation.reset()
        do {
            let session = try NikonPlaybackSession(
                clips: clips, startingAt: startingClip, model: model, native: native)
            self.session = session
            isFavorite = startingClip.isFavorite
            exportState = startingClip.exportStatus
        } catch {
            native.beforeItemRetirement = nil
            native.afterItemInstallation = nil
            native.afterPlaybackEnd = nil
        }
    }

    private func disappear() {
        playback?.close()
        MediaPlaybackAudioSession.deactivateAfterPlayback()
        model.setMediaPlaybackOwnsAudioSession(false)
    }

    private func syncPlaybackScopeSampling(active: Bool? = nil) {
        playbackScopePollingGeneration &+= 1
        let pollingGeneration = playbackScopePollingGeneration
        let scopesOn = active ?? playbackScopesActive
        playbackEffectsBox.setScopesActive(scopesOn)
        playbackScopeController.stop()
        guard scopesOn else {
            playbackScopeAssist = .empty
            return
        }
        playbackScopeController.startPolling(
            effectsBox: playbackEffectsBox,
            isActive: { [model] in
                let visible = model.assist.playbackTools
                return visible.contains(.waveform) || visible.contains(.parade)
                    || visible.contains(.histogram) || visible.contains(.trafficLights)
                    || visible.contains(.vectorscope)
            },
            onSamples: { samples in
                let configuration = playbackScopeDerivationConfiguration
                let clipID = activeClip.id
                let itemToken = playback?.token
                let previous = playbackScopeAssist
                let bundle = await Task.detached(priority: .utility) {
                    configuration.bundle(samples: samples, previous: previous)
                }.value
                guard !Task.isCancelled,
                    pollingGeneration == playbackScopePollingGeneration,
                    itemToken == playback?.token,
                    clipID == activeClip.id,
                    player.currentItem != nil,
                    configuration == playbackScopeDerivationConfiguration
                else { return }
                playbackScopeAssist = bundle
            }
        )
    }

    private func restartPlaybackScopeSampling() {
        syncPlaybackScopeSampling()
    }

    /// Starts/stops the audio-meter polling loop to match the tool toggle (the tap itself stays
    /// installed for the item's lifetime — it is passthrough and effectively free when unpolled).
    private func syncPlaybackAudioMetering() {
        guard playbackAudioMetersActive else {
            audioMeterController.stopPolling()
            playbackAudioLevels = nil
            return
        }
        audioMeterController.startPolling { levels in
            playbackAudioLevels = levels
        }
    }

    /// Real seconds shown on the conformed timeline: a 6 s clip at 40% reads 15 s.
    private func conformedLabel(_ seconds: Double) -> String {
        timeLabel(
            MonitorConformPreview.conformedDuration(sourceSeconds: seconds, speed: conformSpeed))
    }

    /// Playback rate for the active conform, or 1 in real time.
    private var conformSpeed: Double {
        guard let target = conformTarget, let rate = conformSource.captureRate else { return 1 }
        return MonitorConformPreview.speed(captureRate: rate, targetRate: target)
    }

    /// Starts playback at the conform rate. Setting a non-zero `rate` IS play, so this replaces
    /// `player.play()` everywhere — calling `play()` would snap back to 1x and silently drop the
    /// conform the operator selected.
    private func restartPlayback() {
        tailPresentation.reset()
        playback?.restart()
    }

    private func seek(by seconds: Double) {
        tailPresentation.seeking(
            to: min(max(0, currentTime + seconds), duration), duration: duration)
        playback?.seek(by: seconds)
    }

    /// Installs one `AVVideoComposition` per clip; assist toggles only mutate `playbackEffectsBox`.
    private func attachPlaybackVideoComposition(to item: AVPlayerItem) {
        updatePlaybackEffects()
        item.videoComposition = playbackEffectsBox.makeVideoComposition(for: item.asset)
    }

    /// Pushes current view-assist effects into the live composition box. While playing the next
    /// decoded frame picks them up; while paused a fresh composition instance is required to force
    /// a re-render (a zero-tolerance same-time seek is optimized away and cannot serve as a nudge).
    private func updatePlaybackEffects() {
        let changed = playbackEffectsBox.set(effects: model.resolvedPlaybackEffects())
        guard changed, player.rate == 0, let item = player.currentItem,
            item.videoComposition != nil
        else { return }
        item.videoComposition = playbackEffectsBox.makeVideoComposition(for: item.asset)
    }

    private func showToast(_ message: String) {
        withAnimation { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            withAnimation { toastMessage = nil }
        }
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00" }
        let total = Int(seconds.rounded())
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}

// MARK: - Supporting views

/// Hosts an `AVPlayerLayer` with no native transport chrome, so the LiveDesign controls are the UI.
private struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.isUserInteractionEnabled = false
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ uiView: PlayerHostView, context: Context) {
        uiView.isUserInteractionEnabled = false
        uiView.playerLayer.player = player
    }

    static func dismantleUIView(_ uiView: PlayerHostView, coordinator: ()) {
        uiView.playerLayer.player = nil
    }

    final class PlayerHostView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        // SAFETY: layerClass is AVPlayerLayer, so this cast always succeeds.
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}
