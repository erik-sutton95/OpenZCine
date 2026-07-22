import AVFoundation
import ImageIO
import SwiftUI
import UIKit

/// Decodes cell images downsampled to a bounded pixel size, off the main actor (same pattern as
/// `FrameDecoder`). Cells must never decode a full-resolution still — a 45 MP HEIF is ~180 MB
/// decoded, a screenful is a jetsam kill — and one actor also serializes decodes during fast scroll.
actor MediaCellImageLoader {
    static let shared = MediaCellImageLoader()

    /// The downsampled image at `url` (long edge ≤ `maxPixelSize`), or `nil` if unreadable.
    /// `kCGImageSourceCreateThumbnailWithTransform` bakes in EXIF orientation, so the cell shows
    /// exactly the picture a full decode would have.
    func downsampled(at url: URL, maxPixelSize: Int) -> sending UIImage? {
        autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else {
                return nil
            }
            let thumbnailOptions =
                [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceShouldCacheImmediately: true,
                    kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                ] as [CFString: Any] as CFDictionary
            guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions)
            else { return nil }
            return UIImage(cgImage: cgImage)
        }
    }
}

// MARK: - Browser

/// Grid density for the Media browser — smaller cells show more clips per row.
enum MediaThumbnailSize: String, CaseIterable, Codable, Sendable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    /// Adaptive `GridItem` minimum cell width for this preset.
    var gridMinimum: CGFloat {
        switch self {
        case .small: 148
        case .medium: 210
        case .large: 280
        }
    }

    /// Adaptive `GridItem` maximum cell width for this preset.
    var gridMaximum: CGFloat {
        switch self {
        case .small: 200
        case .medium: 300
        case .large: 380
        }
    }

    var segmentLabel: String {
        switch self {
        case .small: "S"
        case .medium: "M"
        case .large: "L"
        }
    }

    /// Square icon size for the sidebar density control — visual hierarchy without text labels.
    var gridIconSize: CGFloat {
        switch self {
        case .small: 9
        case .medium: 12
        case .large: 15
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .small: "Small thumbnails"
        case .medium: "Medium thumbnails"
        case .large: "Large thumbnails"
        }
    }
}

/// Full-screen Media page: sidebar navigation, filter popup, and a clip grid with progressive
/// on-camera playback when a clip is opened.
struct MediaBrowserView: View {
    var safeArea: MonitorEdgeInsets = .zero
    @Environment(NativeAppModel.self) private var model
    @Environment(MediaDeliveryCoordinator.self) private var deliveryCoordinator
    @State private var playingClip: MediaClip?
    @State private var viewingPhoto: MediaClip?
    @State private var isSelecting = false
    @State private var selectedClipIDs: Set<String> = []
    /// Realised grid cells' frames in ``MediaGridSpace`` — the sweep-select hit-test registry.
    @State private var cellFrames: [String: CGRect] = [:]
    /// Set by the post-hop share resume: the player opens with its share popup already on this
    /// destination. Cleared when the player dismisses.
    @State private var resumeShareDestination: MediaDeliveryDestination?
    @State private var deliveryRequest: MediaDeliveryRequest?
    @State private var deliveryAnchorFrame: CGRect = .zero
    @State private var isFilterPopupPresented = false
    @State private var filterButtonFrame: CGRect = .zero

    private let sidebarWidth: CGFloat = 172

    private var gridColumns: [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: model.mediaThumbnailSize.gridMinimum,
                    maximum: model.mediaThumbnailSize.gridMaximum
                ),
                spacing: 16
            )
        ]
    }

    private var displayedClips: [MediaClip] { model.filteredMediaClips }

    private var selectedClips: [MediaClip] {
        displayedClips.filter { selectedClipIDs.contains($0.id) }
    }

    private var headerTitle: String {
        switch model.mediaCategoryTab {
        case .all: return "All clips"
        case .videos: return "Videos"
        case .photos: return "Photos"
        case .favorites: return "Favorites"
        }
    }

    private var headerItemCountLabel: String {
        if model.mediaFetchInProgress {
            return model.mediaFetchListedCount == 0
                ? "Scanning…"
                : "Listing… \(model.mediaFetchListedCount) found"
        }
        let count = displayedClips.count
        return "\(count) item\(count == 1 ? "" : "s")"
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            LiveDesign.background

            GeometryReader { proxy in
                let portrait = proxy.size.height > proxy.size.width

                Group {
                    if portrait {
                        VStack(alignment: .leading, spacing: 8) {
                            categoryStrip
                            mainHeader
                            gridContent
                                // Band lives in the bottom safe area: rows scroll under it
                                // (visible through the fade) and the last row can always clear it.
                                .safeAreaInset(edge: .bottom, spacing: 0) {
                                    portraitGridControlsBand
                                }
                        }
                    } else {
                        HStack(alignment: .top, spacing: 16) {
                            sidebar
                                .frame(width: sidebarWidth)

                            VStack(alignment: .leading, spacing: 6) {
                                mainHeader
                                gridContent
                            }
                            .frame(
                                maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(.top, max(CGFloat(safeArea.top) + 6, 16))
                .padding(.leading, max(CGFloat(safeArea.leading) + 6, portrait ? 16 : 64))
                .padding(.trailing, max(CGFloat(safeArea.trailing) + 6, 20))
                .padding(.bottom, max(CGFloat(safeArea.bottom) + 4, 14))
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

            CloseButton(size: 37)
                .padding(.leading, 16)
                .padding(.top, max(CGFloat(safeArea.top) + 6, 22))
        }
        .ignoresSafeArea()
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
        .animation(.spring(duration: 0.32), value: deliveryCoordinator.isActive)
        .animation(.easeInOut(duration: 0.2), value: model.mediaThumbnailSize)
        .animation(.easeInOut(duration: 0.2), value: model.mediaBrowserLayout)
        .animation(.easeInOut(duration: 0.2), value: showsThumbnailSizeControl)
        .onAppear { deliveryCoordinator.enterLocalOverlayContext() }
        .onDisappear { deliveryCoordinator.exitLocalOverlayContext() }
        .mediaDeliveryShareSheet(enabled: playingClip == nil)
    }

    private let filterPopupWidth: CGFloat = 400

    private var filterPopupOverlay: some View {
        GeometryReader { proxy in
            let host = proxy.frame(in: .global)
            let button = filterButtonFrame
            let hasButton = button.width > 1
            let trailing = hasButton ? button.maxX : host.maxX - 24
            let leading = min(
                max(trailing - filterPopupWidth, host.minX + 12),
                host.maxX - filterPopupWidth - 12
            )
            let top = hasButton ? button.maxY + 8 : host.minY + 120
            let maxHeight = max(180, host.maxY - top - 24)

            ZStack(alignment: .topLeading) {
                Color.black.opacity(0.18)
                    .ignoresSafeArea()
                    .onTapGesture { isFilterPopupPresented = false }

                MediaFilterPopup {
                    isFilterPopupPresented = false
                }
                .environment(model)
                .frame(width: filterPopupWidth)
                .frame(maxHeight: maxHeight, alignment: .top)
                .offset(x: leading - host.minX, y: top - host.minY)
            }
        }
        .ignoresSafeArea()
    }

    private func deliveryPopupOverlay(clips: [MediaClip]) -> some View {
        MediaDeliveryPopupOverlay(
            clips: clips,
            anchorFrame: deliveryAnchorFrame,
            placement: .belowAnchor,
            preferredDestination: deliveryRequest?.preferredDestination,
            onBeginDelivery: { request in
                deliveryRequest = nil
                startDelivery(request)
            }
        ) {
            deliveryRequest = nil
        }
        .environment(model)
    }

    private func startDelivery(_ request: MediaDeliveryBeginRequest) {
        deliveryCoordinator.begin(request, model: model)
    }

    private var showsThumbnailSizeControl: Bool {
        !deliveryCoordinator.isActive && deliveryRequest == nil && !isSelecting
    }

    /// Layout metrics for sidebar grid controls — sized to fit the 172pt sidebar without clipping.
    private enum SidebarGridControlMetrics {
        static let buttonSize: CGFloat = 37
        static let buttonSpacing: CGFloat = 4
        static let capsuleHorizontalPadding: CGFloat = 6
        static let capsuleVerticalPadding: CGFloat = 6
        static let buttonCornerRadius = DesignTokens.cornerRadius
        static let toggleIconSize: CGFloat = 14
    }

    /// Portrait's bottom band: the same layout-toggle + thumbnail-size capsule the landscape
    /// sidebar carries, floating on a fade so grid rows visibly scroll away beneath it.
    private var portraitGridControlsBand: some View {
        ZStack(alignment: .bottom) {
            LinearGradient(
                colors: [LiveDesign.background.opacity(0), LiveDesign.background.opacity(0.94)],
                startPoint: .top, endPoint: .bottom
            )
            .allowsHitTesting(false)
            sidebarGridControls
                .padding(.bottom, 4)
        }
        .frame(height: 84)
        .frame(maxWidth: .infinity)
    }

    private var sidebarGridControls: some View {
        HStack(spacing: SidebarGridControlMetrics.buttonSpacing) {
            layoutToggleButton

            ForEach(MediaThumbnailSize.allCases) { size in
                thumbnailSizeButton(size)
            }
        }
        .padding(.horizontal, SidebarGridControlMetrics.capsuleHorizontalPadding)
        .padding(.vertical, SidebarGridControlMetrics.capsuleVerticalPadding)
        .liquidGlass(in: Capsule(), interactive: false)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Media layout and thumbnail size")
    }

    private var layoutToggleButton: some View {
        Button {
            model.mediaBrowserLayout = model.mediaBrowserLayout == .grid ? .list : .grid
        } label: {
            Image(systemName: model.mediaBrowserLayout.toggleIcon)
                .font(.system(size: SidebarGridControlMetrics.toggleIconSize, weight: .semibold))
                .foregroundStyle(LiveDesign.muted)
                .frame(
                    width: SidebarGridControlMetrics.buttonSize,
                    height: SidebarGridControlMetrics.buttonSize
                )
                .background(
                    LiveDesign.glassBright,
                    in: RoundedRectangle(
                        cornerRadius: SidebarGridControlMetrics.buttonCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel(model.mediaBrowserLayout.accessibilityLabel)
    }

    private func thumbnailSizeButton(_ size: MediaThumbnailSize) -> some View {
        let active = model.mediaThumbnailSize == size
        return Button {
            model.mediaThumbnailSize = size
        } label: {
            Image(systemName: "square.fill")
                .font(.system(size: size.gridIconSize, weight: .bold))
                .foregroundStyle(active ? LiveDesign.accent : LiveDesign.muted)
                .frame(
                    width: SidebarGridControlMetrics.buttonSize,
                    height: SidebarGridControlMetrics.buttonSize
                )
                .background(
                    active ? LiveDesign.accentDim : Color.clear,
                    in: RoundedRectangle(
                        cornerRadius: SidebarGridControlMetrics.buttonCornerRadius,
                        style: .continuous
                    )
                )
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel(size.accessibilityLabel)
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 14) {
            categoryTabs

            if model.mediaBrowserSource == .camera, !model.mediaStorageSlots.isEmpty {
                storageCards
            }

            Spacer(minLength: 0)

            if showsThumbnailSizeControl {
                sidebarGridControls
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
        .onTapGesture {
            if isSelecting {
                exitSelectionMode()
            }
        }
    }

    private var categoryTabs: some View {
        VStack(spacing: 4) {
            ForEach(MediaCategoryTab.allCases) { tab in
                categoryTabButton(tab)
            }
        }
        .padding(4)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous),
            interactive: false)
    }

    /// Horizontal category strip for portrait: the same tab buttons the sidebar's ``categoryTabs``
    /// renders, laid out in a scrollable row above the header instead of a vertical rail.
    private var categoryStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(MediaCategoryTab.allCases) { tab in
                    // The strip scrolls — never let a pill truncate its label ("Vide…").
                    categoryTabButton(tab)
                        .fixedSize()
                }
            }
            .padding(4)
        }
        // Glass on the SCROLL VIEW, not its content: glass-on-content made the bar as wide as
        // every pill and it ran dead off the trailing edge.
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous),
            interactive: false
        )
        // Inset past the root's floating CloseButton, which overlays this corner in portrait
        // (landscape clears it via the 64pt sidebar leading floor instead).
        .padding(.leading, 45)
    }

    /// A single category tab button — shared by the vertical sidebar (``categoryTabs``) and the
    /// horizontal portrait strip (``categoryStrip``).
    private func categoryTabButton(_ tab: MediaCategoryTab) -> some View {
        let active = model.mediaCategoryTab == tab
        return Button {
            model.mediaCategoryTab = tab
        } label: {
            HStack(spacing: 8) {
                Image(systemName: tab.systemImage)
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 16)
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: active ? .semibold : .medium))
                Spacer(minLength: 0)
            }
            .foregroundStyle(active ? LiveDesign.accent : LiveDesign.muted)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                active ? LiveDesign.accentDim : Color.clear,
                in: RoundedRectangle(
                    cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
        }
        .buttonStyle(.zcTapTarget)
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
                .buttonStyle(.zcTapTarget)
            }
        }
    }

    // MARK: - Main column

    private var mainHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            if isSelecting {
                selectionHeader
            } else {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("MULTIMEDIA")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .kerning(0.8)
                            .foregroundStyle(LiveDesign.muted)
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(headerTitle)
                                .font(.system(size: 26, weight: .semibold))
                                .foregroundStyle(LiveDesign.text)
                            Text("·")
                                .font(.system(size: 18, weight: .medium))
                                .foregroundStyle(LiveDesign.faint)
                            if model.mediaFetchInProgress {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small).tint(LiveDesign.muted)
                                    Text(headerItemCountLabel)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(LiveDesign.muted)
                                }
                            } else {
                                Text(headerItemCountLabel)
                                    .font(.system(size: 14, weight: .medium))
                                    .foregroundStyle(LiveDesign.muted)
                            }
                        }
                    }

                    Spacer(minLength: 8)

                    HStack(alignment: .center, spacing: 8) {
                        filterButton
                        sortButton
                    }
                }

                if let streamingClip = displayedClips.first(where: { model.isClipStreaming($0) }),
                    let progress = model.mediaDownloadProgress[streamingClip.id]
                {
                    clipCacheHeaderBar(filename: streamingClip.filename, progress: progress)
                }
            }
        }
    }

    private var selectionHeader: some View {
        HStack(spacing: 12) {
            CloseButton(action: { exitSelectionMode() }, size: 37)
            Text("\(selectedClipIDs.count) selected")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Spacer(minLength: 8)
            Button {
                deliveryRequest = MediaDeliveryRequest(clips: selectedClips)
            } label: {
                Label("Share", systemImage: "square.and.arrow.up")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        selectedClipIDs.isEmpty ? LiveDesign.faint : LiveDesign.accent
                    )
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(
                        selectedClipIDs.isEmpty ? Color.clear : LiveDesign.accentDim,
                        in: Capsule()
                    )
                    .overlay(Capsule().stroke(LiveDesign.hairline, lineWidth: 1))
            }
            .buttonStyle(.zcTapTarget)
            .disabled(selectedClipIDs.isEmpty)
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { deliveryAnchorFrame = proxy.frame(in: .global) }
                        .onChange(of: proxy.frame(in: .global)) { _, frame in
                            deliveryAnchorFrame = frame
                        }
                }
            }
        }
    }

    @ViewBuilder
    private var gridContent: some View {
        if displayedClips.isEmpty {
            if model.mediaFetchInProgress {
                listingState
            } else {
                emptyState
            }
        } else if model.mediaBrowserLayout == .list {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(displayedClips) { clip in
                        MediaClipListRow(
                            clip: clip,
                            isDownloaded: model.isClipDownloaded(clip),
                            localURL: model.clipLocalURL(clip),
                            thumbnailURL: model.clipThumbnailURL(clip),
                            cacheProgress: model.mediaDownloadProgress[clip.id]
                                ?? model.clipBufferedFraction(clip),
                            isStreaming: model.isClipStreaming(clip),
                            isSelecting: isSelecting,
                            isSelected: selectedClipIDs.contains(clip.id),
                            onOpen: { open(clip) },
                            onBeginSelection: { beginSelection(with: clip) },
                            onToggleSelection: { toggleSelection(clip) },
                            onToggleFavorite: { model.toggleClipFavorite(clip) }
                        )
                        .environment(model)
                    }
                }
                .padding(.bottom, 24)
            }
        } else {
            // PLAIN ScrollView on purpose: a `.scrollPosition`-tracked host re-rendered the grid
            // every frame mid-gesture. Sweep edge auto-scroll instead drives `contentOffset`
            // directly via `MediaSweepSelectGesture` (UIKit recogniser + CADisplayLink).
            ScrollView { gridCells }
        }
    }

    private var gridCells: some View {
        LazyVGrid(columns: gridColumns, alignment: .leading, spacing: 16) {
            ForEach(displayedClips) { clip in
                MediaClipCell(
                    clip: clip,
                    isDownloaded: model.isClipDownloaded(clip),
                    localURL: model.clipLocalURL(clip),
                    thumbnailURL: model.clipThumbnailURL(clip),
                    cacheProgress: model.mediaDownloadProgress[clip.id]
                        ?? model.clipBufferedFraction(clip),
                    isStreaming: model.isClipStreaming(clip),
                    isSelecting: isSelecting,
                    isSelected: selectedClipIDs.contains(clip.id),
                    onOpen: { open(clip) },
                    onBeginSelection: { beginSelection(with: clip) },
                    onToggleSelection: { toggleSelection(clip) },
                    onToggleFavorite: { model.toggleClipFavorite(clip) }
                )
                .background(
                    GeometryReader { geo in
                        // Emit only while selecting: during plain browsing each lazily-realised
                        // cell would churn the preference tree. Cells re-render when `isSelecting`
                        // flips, so entering selection re-emits every frame.
                        Color.clear.preference(
                            key: MediaCellFramesKey.self,
                            value: isSelecting
                                ? [clip.id: geo.frame(in: .named(MediaGridSpace.name))] : [:]
                        )
                    }
                )
            }
        }
        .padding(.bottom, 24)
        // Named space on the grid CONTENT, not the ScrollView: content-space cell frames are
        // static while scrolling, so the preference only fires on real layout changes — measuring
        // in scroll space re-rendered the whole browser every scrolled frame.
        .coordinateSpace(name: MediaGridSpace.name)
        // Photos-style sweep multi-select with edge auto-scroll; see `MediaSweepSelectGesture`.
        // Inert outside selection mode.
        .background(
            MediaSweepSelectGesture(
                orderedIDs: displayedClips.map(\.id),
                cellFrames: cellFrames,
                isActive: isSelecting,
                selectedIDs: $selectedClipIDs
            )
        )
        // Track cell frames only while selecting: otherwise each lazy cell realisation would
        // write state and re-render the browser mid-scroll. Entering selection mode re-renders
        // the cells, which re-emits the preference and fills the registry on the spot.
        .onPreferenceChange(MediaCellFramesKey.self) { frames in
            if isSelecting { cellFrames = frames }
        }
    }

    private var sortButton: some View {
        MediaActionPill(
            icon: "arrow.up.arrow.down",
            title: model.mediaSortOrder.pillLabel,
            isActive: false
        ) {
            model.cycleMediaSortOrder()
        }
    }

    private var filterButton: some View {
        Button {
            isFilterPopupPresented.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 10, weight: .semibold))
                Text("FILTER")
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                if model.mediaActiveFilterCount > 0 {
                    Text("\(model.mediaActiveFilterCount)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(LiveDesign.background)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(LiveDesign.accent, in: Capsule())
                }
            }
            .foregroundStyle(
                model.mediaActiveFilterCount > 0 ? LiveDesign.accent : LiveDesign.muted
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                model.mediaActiveFilterCount > 0 ? LiveDesign.accentDim : Color.clear,
                in: Capsule()
            )
            .overlay(Capsule().stroke(LiveDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.zcTapTarget)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { filterButtonFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        filterButtonFrame = frame
                    }
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
        if clip.mediaKind == .photo {
            viewingPhoto = clip
        } else {
            playingClip = clip
        }
    }
}

// MARK: - Browser chrome

/// Compact glass filter panel — mirrors live-view `AssistPanel` styling, anchored near the
/// header Filter button instead of a full-screen sheet.
private struct MediaFilterPopup: View {
    @Environment(NativeAppModel.self) private var model
    let onClose: () -> Void

    private let filterChipColumns = [
        GridItem(.flexible(), spacing: 5),
        GridItem(.flexible(), spacing: 5),
    ]

    var body: some View {
        GlassPanel(
            padding: EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10)
        ) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label {
                        Text("Filters")
                    } icon: {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .font(.system(size: 12, weight: .bold, design: .default))
                    .kerning(1)
                    .textCase(.uppercase)
                    .foregroundStyle(LiveDesign.text)
                    Spacer()
                    CloseButton(action: onClose, size: 26)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        filterSection(title: "FORMAT") {
                            LazyVGrid(columns: filterChipColumns, spacing: 5) {
                                ForEach(MediaFormatFilter.allCases, id: \.self) { format in
                                    MediaFilterChip(
                                        title: format.rawValue,
                                        expands: true,
                                        isActive: model.mediaFormatFilters.contains(format)
                                    ) {
                                        model.toggleMediaFormatFilter(format)
                                    }
                                }
                            }
                        }

                        filterSection(title: "RESOLUTION") {
                            LazyVGrid(columns: filterChipColumns, spacing: 5) {
                                ForEach(MediaResolutionBucket.allCases, id: \.self) { bucket in
                                    MediaFilterChip(
                                        title: bucket.rawValue,
                                        expands: true,
                                        isActive: model.mediaResolutionFilters.contains(bucket)
                                    ) {
                                        model.toggleMediaResolutionFilter(bucket)
                                    }
                                }
                            }
                        }

                        filterSection(title: "DATE") {
                            LazyVGrid(columns: filterChipColumns, spacing: 5) {
                                MediaFilterChip(
                                    title: "TODAY",
                                    expands: true,
                                    isActive: model.mediaTodayOnly
                                ) {
                                    model.mediaTodayOnly.toggle()
                                }
                            }
                        }

                        if model.mediaBrowserSource == .camera, !model.mediaStorageSlots.isEmpty {
                            filterSection(title: "STORAGE") {
                                LazyVGrid(columns: filterChipColumns, spacing: 5) {
                                    ForEach(model.mediaStorageSlots) { slot in
                                        let active = model.mediaStorageSlotFilter == slot.storageID
                                        MediaFilterChip(
                                            title: "SLOT \(slot.slotNumber)",
                                            icon: "sdcard.fill",
                                            expands: true,
                                            isActive: active
                                        ) {
                                            if active {
                                                model.mediaStorageSlotFilter = nil
                                            } else {
                                                model.mediaStorageSlotFilter = slot.storageID
                                            }
                                        }
                                    }
                                }
                            }
                        }

                        if model.mediaActiveFilterCount > 0 {
                            Button("Clear all filters") {
                                model.clearMediaFilters()
                            }
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(LiveDesign.accent)
                            .padding(.top, 2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .contentShape(Rectangle())
        .onTapGesture {}
    }

    private func filterSection<Content: View>(
        title: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(LiveDesign.muted)
            content()
        }
    }
}

private struct MediaActionPill: View {
    let icon: String
    let title: String
    var isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
            .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                isActive ? LiveDesign.accentDim : Color.clear,
                in: Capsule()
            )
            .overlay(Capsule().stroke(LiveDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.zcTapTarget)
    }
}

private struct MediaFilterChip: View {
    let title: String
    var icon: String? = nil
    var expands = false
    let isActive: Bool
    let action: () -> Void

    private let minHeight: CGFloat = 30
    private let horizontalPadding: CGFloat = 8
    private let verticalPadding: CGFloat = 5

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }
            .foregroundStyle(isActive ? LiveDesign.accent : LiveDesign.muted)
            .frame(maxWidth: expands ? .infinity : nil)
            .frame(minHeight: minHeight)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                isActive ? LiveDesign.accentDim : LiveDesign.glassBright,
                in: Capsule()
            )
            .overlay(
                Capsule().stroke(
                    isActive ? LiveDesign.accent.opacity(0.45) : LiveDesign.hairline, lineWidth: 1))
        }
        .buttonStyle(.zcTapTarget)
    }
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
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .stroke(
                    isActive ? LiveDesign.accent.opacity(0.5) : LiveDesign.hairline, lineWidth: 1)
        )
    }
}

// MARK: - Clip chrome

/// Favorite control with a 44pt hit target so edge taps register reliably inside scroll rows/cells.
private struct MediaClipFavoriteButton: View {
    let isFavorite: Bool
    var iconSize: CGFloat = 13
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: iconSize))
                .foregroundStyle(isFavorite ? LiveDesign.accent : LiveDesign.faint)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.zcTapTarget)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        .zIndex(1)
    }
}

// MARK: - Grid cell

/// Compact list row for the Media browser — thumbnail, filename, and metadata in one line.
private struct MediaClipListRow: View {
    let clip: MediaClip
    let isDownloaded: Bool
    let localURL: URL?
    let thumbnailURL: URL?
    let cacheProgress: Double?
    let isStreaming: Bool
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    var onBeginSelection: (() -> Void)?
    var onToggleSelection: (() -> Void)?
    let onToggleFavorite: () -> Void

    @Environment(NativeAppModel.self) private var model
    @State private var thumbnail: UIImage?
    @State private var durationLabel: String?

    private var isPhoto: Bool { clip.mediaKind == .photo }

    private var metadataLine: String {
        var parts: [String] = []
        if let bucket = clip.resolutionBucket {
            parts.append(bucket.rawValue)
        }
        if clip.sizeBytes > 0 {
            parts.append(MediaClipFormatting.byteLabel(clip.sizeBytes))
        }
        if let durationLabel, !isPhoto {
            parts.append(durationLabel)
        }
        if parts.isEmpty {
            return isDownloaded ? "Cached" : "On camera"
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 12) {
                listThumbnail
                    .frame(width: 96, height: 54)
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    )
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: DesignTokens.cornerRadius, style: .continuous
                        )
                        .strokeBorder(LiveDesign.hairline, lineWidth: 1)
                    )

                VStack(alignment: .leading, spacing: 4) {
                    Text(clip.filename)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .lineLimit(1)
                    Text(metadataLine)
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(LiveDesign.muted)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? Color.white : Color.white.opacity(0.92),
                            isSelected ? LiveDesign.accent : Color.black.opacity(0.45)
                        )
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
            .onTapGesture {
                if isSelecting {
                    onToggleSelection?()
                } else {
                    onOpen()
                }
            }

            if !isSelecting {
                MediaClipFavoriteButton(
                    isFavorite: clip.isFavorite,
                    iconSize: 14,
                    action: onToggleFavorite
                )
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .padding(.vertical, 8)
        .background(
            isSelected ? LiveDesign.accentDim.opacity(0.55) : LiveDesign.surface.opacity(0.45),
            in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                .stroke(
                    isSelected ? LiveDesign.accent.opacity(0.45) : LiveDesign.hairline, lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous))
        .onLongPressGesture(minimumDuration: 0.4) {
            guard !isSelecting else { return }
            onBeginSelection?()
        }
        .task(id: localURL) {
            await loadThumbnail()
            await loadDuration()
        }
        .onDisappear {
            thumbnail = nil
            durationLabel = nil
        }
    }

    @ViewBuilder private var listThumbnail: some View {
        ZStack {
            LiveDesign.surface
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Image(systemName: isPhoto ? "photo" : "film")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(LiveDesign.faint)
            }
            if let cacheProgress {
                ZStack {
                    Color.black.opacity(0.45)
                    Text("\(Int(cacheProgress * 100))%")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(LiveDesign.text)
                }
            } else if !isDownloaded {
                ZStack {
                    Color.black.opacity(0.35)
                    Image(systemName: isPhoto ? "photo.circle.fill" : "play.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(LiveDesign.text.opacity(0.9))
                }
            }
        }
    }

    private func loadThumbnail() async {
        if thumbnail != nil { return }
        if let thumbnailURL, let data = try? Data(contentsOf: thumbnailURL) {
            if let image = UIImage(data: data) {
                thumbnail = image
                return
            }
            // Self-heal: a cached thumb that doesn't decode would re-fail (and spam ImageIO
            // errors) on every cell realisation. Deletes only the cached thumb, never the media.
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        if isPhoto, isDownloaded, let localURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: localURL, maxPixelSize: 640)
        {
            thumbnail = image
            return
        }
        if !isDownloaded, clip.handle != nil {
            await model.ensureThumbnail(for: clip)
            if let cachedURL = model.clipThumbnailURL(clip),
                let data = try? Data(contentsOf: cachedURL),
                let image = UIImage(data: data)
            {
                thumbnail = image
            }
        }
        guard isDownloaded, !isPhoto, let localURL else { return }
        let asset = AVURLAsset(url: localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: time).image {
            thumbnail = UIImage(cgImage: cgImage)
        }
    }

    private func loadDuration() async {
        guard !isPhoto else { return }
        guard durationLabel == nil else { return }
        guard isDownloaded, let localURL else { return }
        let asset = AVURLAsset(url: localURL)
        if let duration = try? await asset.load(.duration), duration.isValid, duration.seconds > 0 {
            durationLabel = MediaClipFormatting.durationLabel(seconds: duration.seconds)
        }
    }
}

/// Named coordinate space for the media grid — cell frames and sweep-drag locations must share
/// one space for hit-testing.
enum MediaGridSpace {
    static let name = "mediaGrid"
}

extension UIView {
    /// Nearest ancestor `UIScrollView` (the one SwiftUI creates for the enclosing `ScrollView`).
    fileprivate var mediaEnclosingScrollView: UIScrollView? {
        var candidate = superview
        while let view = candidate {
            if let scrollView = view as? UIScrollView { return scrollView }
            candidate = view.superview
        }
        return nil
    }
}

/// Photos-style one-finger sweep multi-select with edge auto-scroll. iOS 17 has no
/// `UIGestureRecognizerRepresentable`, so a zero-size `UIViewRepresentable` probe walks up to the
/// enclosing `UIScrollView` and attaches a short-press `UILongPressGestureRecognizer`:
///
/// - The hold disambiguates sweep from scroll — a quick drag never trips it, so scrolling stays
///   native; only a deliberate press-then-drag arms selection.
/// - `.began` locks scrolling and anchors on the pressed cell, whose state fixes the paint mode.
/// - `.changed` range-paints `[anchor…current]` over the pre-sweep snapshot, so dragging back
///   un-paints.
/// - A `CADisplayLink` auto-scrolls in the top/bottom edge band (speed ramps with depth),
///   re-hit-testing the finger each frame; rounded offset steps avoid sub-pixel shimmer.
/// - Every terminal state restores scrolling and stops the loop.
///
/// Enabled only in selection mode — completely inert during plain browse.
private struct MediaSweepSelectGesture: UIViewRepresentable {
    /// Clip ids in display order — the range paint works on indices, not geometry.
    let orderedIDs: [String]
    /// Cell hit-test registry (``MediaGridSpace`` == the scroll view's content coordinate space).
    let cellFrames: [String: CGRect]
    /// Selection mode gate; the recognizer is disabled otherwise.
    let isActive: Bool
    @Binding var selectedIDs: Set<String>

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        let coordinator = context.coordinator
        coordinator.orderedIDs = orderedIDs
        coordinator.cellFrames = cellFrames
        coordinator.readSelection = { selectedIDs }
        coordinator.writeSelection = { selectedIDs = $0 }
        coordinator.isActive = isActive
        // The enclosing UIScrollView isn't in the hierarchy during the first layout pass — defer
        // the superview walk one run-loop cycle (the SwiftUI-Introspect technique).
        DispatchQueue.main.async { coordinator.attachIfNeeded(probe: uiView) }
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var orderedIDs: [String] = []
        var cellFrames: [String: CGRect] = [:]
        var readSelection: () -> Set<String> = { [] }
        var writeSelection: (Set<String>) -> Void = { _ in }
        var isActive = false {
            didSet { recognizer?.isEnabled = isActive }
        }

        private weak var scrollView: UIScrollView?
        private var recognizer: UILongPressGestureRecognizer?
        private var displayLink: CADisplayLink?
        private var autoScrollSpeed: CGFloat = 0

        private var anchorIndex: Int?
        private var paintSelect = true
        private var snapshot: Set<String> = []
        private var lastRange: ClosedRange<Int>?

        private let edgeBand: CGFloat = 90
        private let maxScrollSpeed: CGFloat = 620  // points/sec at the very edge

        func attachIfNeeded(probe: UIView) {
            guard recognizer == nil, let scrollView = probe.mediaEnclosingScrollView else { return }
            self.scrollView = scrollView
            let press = UILongPressGestureRecognizer(target: self, action: #selector(handle(_:)))
            press.minimumPressDuration = 0.18
            press.allowableMovement = 40
            press.cancelsTouchesInView = false
            press.delegate = self
            press.isEnabled = isActive
            scrollView.addGestureRecognizer(press)
            recognizer = press
        }

        func detach() {
            stopAutoScroll()
            if let recognizer, let scrollView { scrollView.removeGestureRecognizer(recognizer) }
            recognizer = nil
        }

        @objc private func handle(_ gesture: UILongPressGestureRecognizer) {
            guard isActive, let scrollView else { return }
            switch gesture.state {
            case .began:
                scrollView.isScrollEnabled = false
                snapshot = readSelection()
                lastRange = nil
                if let index = index(atContentPoint: gesture.location(in: scrollView)) {
                    anchorIndex = index
                    paintSelect = !snapshot.contains(orderedIDs[index])
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    paint(to: index)
                } else {
                    anchorIndex = nil
                }
            case .changed:
                let content = gesture.location(in: scrollView)
                if let index = index(atContentPoint: content) { paint(to: index) }
                updateAutoScroll(viewportY: content.y - scrollView.contentOffset.y)
            case .ended, .cancelled, .failed:
                stopAutoScroll()
                scrollView.isScrollEnabled = true
                anchorIndex = nil
                lastRange = nil
            default:
                break
            }
        }

        private func index(atContentPoint point: CGPoint) -> Int? {
            guard let id = cellFrames.first(where: { $0.value.contains(point) })?.key else {
                return nil
            }
            return orderedIDs.firstIndex(of: id)
        }

        /// Selection = snapshot with the contiguous `[anchor…current]` range painted, so shrinking
        /// the range reverts the trailing cells to their pre-sweep state (Photos "swipe back").
        private func paint(to currentIndex: Int) {
            guard let anchor = anchorIndex else { return }
            let range = min(anchor, currentIndex)...max(anchor, currentIndex)
            guard range != lastRange else { return }
            lastRange = range
            var selection = snapshot
            for index in range where index < orderedIDs.count {
                if paintSelect {
                    selection.insert(orderedIDs[index])
                } else {
                    selection.remove(orderedIDs[index])
                }
            }
            writeSelection(selection)
            UISelectionFeedbackGenerator().selectionChanged()
        }

        private func updateAutoScroll(viewportY: CGFloat) {
            guard let scrollView else { return }
            let height = scrollView.bounds.height
            if viewportY < edgeBand {
                autoScrollSpeed = -maxScrollSpeed * min(1, (edgeBand - viewportY) / edgeBand)
                startAutoScroll()
            } else if viewportY > height - edgeBand {
                autoScrollSpeed =
                    maxScrollSpeed * min(1, (viewportY - (height - edgeBand)) / edgeBand)
                startAutoScroll()
            } else {
                stopAutoScroll()
            }
        }

        private func startAutoScroll() {
            guard displayLink == nil else { return }
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }

        private func stopAutoScroll() {
            displayLink?.invalidate()
            displayLink = nil
        }

        @objc private func step(_ link: CADisplayLink) {
            guard let scrollView, let recognizer else {
                stopAutoScroll()
                return
            }
            var offset = scrollView.contentOffset
            let minY = -scrollView.adjustedContentInset.top
            let maxY =
                max(scrollView.contentSize.height, scrollView.bounds.height)
                - scrollView.bounds.height + scrollView.adjustedContentInset.bottom
            // Frame-rate independent + rounded so integer offset steps don't shimmer the tracked cell.
            let delta = (autoScrollSpeed * CGFloat(link.duration)).rounded()
            let target = min(max(offset.y + delta, minY), maxY)
            guard target != offset.y else {
                stopAutoScroll()
                return
            }
            offset.y = target
            scrollView.setContentOffset(offset, animated: false)
            // The finger is fixed but content moved — its location in content space is now a new cell.
            if let index = index(atContentPoint: recognizer.location(in: scrollView)) {
                paint(to: index)
            }
        }

        // Coexist with the scroll pan; the hold + `isScrollEnabled` toggle do the real arbitration.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
        ) -> Bool { true }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            isActive
        }
    }
}

/// Realised grid cells' frames, keyed by clip id, in ``MediaGridSpace``.
private struct MediaCellFramesKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

private struct MediaClipCell: View {
    let clip: MediaClip
    let isDownloaded: Bool
    let localURL: URL?
    let thumbnailURL: URL?
    /// Live stream or partial on-disk cache fraction (0…1); primary download progress display.
    let cacheProgress: Double?
    let isStreaming: Bool
    var isSelecting: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void
    var onBeginSelection: (() -> Void)?
    var onToggleSelection: (() -> Void)?
    let onToggleFavorite: () -> Void

    @Environment(NativeAppModel.self) private var model
    @State private var thumbnail: UIImage?
    @State private var durationLabel: String?

    private var isPhoto: Bool { clip.mediaKind == .photo }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    .fill(LiveDesign.surface)
                if let thumbnail {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: isPhoto ? "photo" : "film")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(LiveDesign.faint)
                }
                overlay
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                    .strokeBorder(LiveDesign.hairline, lineWidth: 1)
            )
            .overlay(alignment: .bottomTrailing) {
                if !isPhoto, let durationLabel, cacheProgress == nil, !isSelecting {
                    Text(durationLabel)
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(LiveDesign.text)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(
                            Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 4)
                        )
                        .padding(8)
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelecting {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            isSelected ? Color.white : Color.white.opacity(0.92),
                            isSelected ? LiveDesign.accent : Color.black.opacity(0.45)
                        )
                        .padding(8)
                        .shadow(color: .black.opacity(0.4), radius: 4, x: 0, y: 1)
                }
            }
            .contentShape(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
            .onTapGesture {
                if isSelecting {
                    onToggleSelection?()
                } else {
                    onOpen()
                }
            }
            // Plain long-press ENTERS selection mode (and picks this cell). Once selecting, the
            // press-and-drag sweep + edge auto-scroll is owned by the grid-level UIKit recogniser
            // (`MediaSweepSelectGesture`), which only arms in selection mode — keeping cell touches
            // scroll-safe during plain browsing.
            .onLongPressGesture(minimumDuration: 0.4) {
                guard !isSelecting else { return }
                onBeginSelection?()
            }

            HStack(spacing: 6) {
                Text(clip.filename)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(LiveDesign.text)
                    .lineLimit(1)
                Spacer(minLength: 4)
                MediaClipFavoriteButton(
                    isFavorite: clip.isFavorite,
                    action: onToggleFavorite
                )
            }
        }
        .task(id: localURL) {
            await loadThumbnail()
            await loadDuration()
        }
        .onDisappear {
            thumbnail = nil
            durationLabel = nil
        }
    }

    @ViewBuilder private var overlay: some View {
        if let cacheProgress {
            ZStack {
                Color.black.opacity(0.45)
                VStack(spacing: 6) {
                    if isStreaming {
                        Text("CACHING \(Int(cacheProgress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(LiveDesign.text)
                    } else {
                        Text("\(Int(cacheProgress * 100))%")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(LiveDesign.text)
                    }
                    ProgressView(value: cacheProgress)
                        .tint(LiveDesign.accent)
                        .frame(width: 120)
                }
            }
            .overlay(alignment: .bottom) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(LiveDesign.accent.opacity(0.25))
                        Capsule()
                            .fill(LiveDesign.accent)
                            .frame(width: max(4, geo.size.width * cacheProgress))
                    }
                }
                .frame(height: 3)
            }
        } else if isPhoto {
            if !isDownloaded {
                ZStack {
                    Color.black.opacity(0.35)
                    VStack(spacing: 4) {
                        Image(systemName: "photo.circle.fill").font(.system(size: 26))
                        Text("On camera").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(LiveDesign.text)
                }
            }
        } else if !isDownloaded {
            ZStack {
                Color.black.opacity(0.35)
                VStack(spacing: 4) {
                    Image(systemName: "play.circle.fill").font(.system(size: 26))
                    Text("On camera").font(.system(size: 10, weight: .semibold))
                }
                .foregroundStyle(LiveDesign.text)
            }
        } else {
            VStack {
                Spacer()
                HStack {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(LiveDesign.text.opacity(0.9))
                        .padding(8)
                    Spacer()
                    if clip.exportStatus == .exported {
                        Image(systemName: "square.and.arrow.up.circle.fill")
                            .font(.system(size: 18))
                            .foregroundStyle(LiveDesign.good)
                            .padding(8)
                    }
                }
            }
        }
    }

    private func loadThumbnail() async {
        if thumbnail != nil { return }
        if let thumbnailURL, let data = try? Data(contentsOf: thumbnailURL) {
            if let image = UIImage(data: data) {
                thumbnail = image
                return
            }
            // Self-heal: a cached thumb that doesn't decode would re-fail (and spam ImageIO
            // errors) on every cell realisation. Deletes only the cached thumb, never the media.
            try? FileManager.default.removeItem(at: thumbnailURL)
        }
        if isPhoto, isDownloaded, let localURL,
            let image = await MediaCellImageLoader.shared.downsampled(
                at: localURL, maxPixelSize: 640)
        {
            thumbnail = image
            return
        }
        if !isDownloaded, clip.handle != nil {
            await model.ensureThumbnail(for: clip)
            if let cachedURL = model.clipThumbnailURL(clip),
                let data = try? Data(contentsOf: cachedURL),
                let image = UIImage(data: data)
            {
                thumbnail = image
                return
            }
        }
        guard isDownloaded, !isPhoto, let localURL else { return }
        let asset = AVURLAsset(url: localURL)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 600, height: 600)
        let time = CMTime(seconds: 0.2, preferredTimescale: 600)
        if let cgImage = try? await generator.image(at: time).image {
            thumbnail = UIImage(cgImage: cgImage)
        }
    }

    private func loadDuration() async {
        guard !isPhoto else { return }
        guard durationLabel == nil else { return }
        guard isDownloaded, let localURL else { return }
        let asset = AVURLAsset(url: localURL)
        if let duration = try? await asset.load(.duration), duration.isValid, duration.seconds > 0 {
            durationLabel = MediaClipFormatting.durationLabel(seconds: duration.seconds)
        }
    }
}

// MARK: - Photo viewer

/// Full-screen still viewer for camera JPEG/RAW/HEIF — streams the object from the card when needed.
struct MediaPhotoViewer: View {
    let clip: MediaClip
    @Environment(NativeAppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var image: UIImage?
    @State private var isLoading = true
    @State private var loadTask: Task<Void, Never>?
    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                GeometryReader { geo in
                    ScrollView([.horizontal, .vertical], showsIndicators: false) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(
                                width: geo.size.width * zoomScale,
                                height: geo.size.height * zoomScale
                            )
                            .gesture(magnificationGesture)
                    }
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
                    .buttonStyle(.zcTapTarget)
                    Text(clip.filename)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(LiveDesign.text)
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                Spacer()
            }
        }
        .statusBarHidden()
        .onAppear { loadTask = Task { await loadImage() } }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
            model.cancelClipStream()
            image = nil
        }
    }

    private var loadingMessage: String {
        if model.mediaDownloadProgress[clip.id] != nil {
            return "Loading from camera…"
        }
        return "Preparing image…"
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                zoomScale = min(4, max(1, lastZoomScale * value))
            }
            .onEnded { _ in
                lastZoomScale = zoomScale
                if zoomScale < 1.05 {
                    zoomScale = 1
                    lastZoomScale = 1
                }
            }
    }

    private func loadImage() async {
        isLoading = true
        defer { isLoading = false }

        if let thumbURL = model.clipThumbnailURL(clip),
            let data = try? Data(contentsOf: thumbURL),
            let thumb = UIImage(data: data)
        {
            await MainActor.run { image = thumb }
        }

        if model.isClipDownloaded(clip) {
            await loadFromDisk()
            return
        }

        model.startClipStream(clip)
        while !Task.isCancelled {
            if model.isClipDownloaded(clip) {
                await loadFromDisk()
                return
            }
            guard let url = model.clipLocalURL(clip) else { return }
            if FileManager.default.fileExists(atPath: url.path),
                let partial = UIImage(contentsOfFile: url.path)
            {
                await MainActor.run { image = partial }
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    @MainActor
    private func loadFromDisk() async {
        guard let url = model.clipLocalURL(clip) else { return }
        guard let loaded = UIImage(contentsOfFile: url.path) else { return }
        image = loaded
    }
}

// MARK: - Player

private struct PlaybackScopeDerivationConfiguration: Equatable, Sendable {
    let trafficLightsCrushClip: AssistConfiguration.CrushClipCompensation
    let mapping: ExposureSignalMapping
    let vectorscopeCube: CubeLUT?

    func bundle(samples: ScopeSamples, previous: ScopeAssistBundle) -> ScopeAssistBundle {
        ScopeAssistSampling.bundle(
            samples: samples,
            trafficLightsCrushClip: trafficLightsCrushClip,
            mapping: mapping,
            vectorscopeCube: vectorscopeCube,
            previous: previous)
    }
}

/// Full-screen AVPlayer with LiveDesign controls: play/pause, ±15s, mute, view-assist, favorite,
/// share (native or Frame.io), side arrows for clip navigation, pinch-to-zoom on the video,
/// single-tap on the frame to play/pause (with a transient transport flash), long-press drag to
/// scrub, and restart at end-of-clip.
struct MediaPlayerView: View {
    let clips: [MediaClip]
    @State private var activeClip: MediaClip
    @Environment(NativeAppModel.self) private var model
    @Environment(MediaDeliveryCoordinator.self) private var deliveryCoordinator
    @Environment(\.dismiss) private var dismiss

    /// Convenience alias for the clip currently playing.
    private var clip: MediaClip { activeClip }

    @State private var player = AVPlayer()
    @State private var isPlaying = true
    @State private var isMuted = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var timeObserver: Any?
    @State private var endObserver: NSObjectProtocol?
    @State private var reachedEnd = false
    @State private var isScrubbing = false
    @State private var scrubTime: Double = 0
    @State private var wasPlayingBeforeScrub = false
    @State private var lastScrubSeekTime: CFAbsoluteTime = 0

    private let scrubSeekThrottle: CFAbsoluteTime = 0.075
    private let scrubSeekTolerance = CMTime(seconds: 0.1, preferredTimescale: 600)

    @State private var isClipReady = false
    @State private var streamPollTask: Task<Void, Never>?
    @State private var chromeVisible = true
    @State private var assistMode = false
    @State private var assistOptionsTool: MonitorAssistTool?
    @State private var playbackBarFrame: CGRect = .zero
    @State private var playbackAssistToolbarFrame: CGRect = .zero
    @State private var playbackAssistPanelRevealed = false

    @State private var isFavorite = false
    @State private var exportState: ExportStatus = .none
    @State private var deliveryPresentation: MediaDeliveryPresentation?
    @State private var shareButtonFrame: CGRect = .zero
    @State private var wasPlayingBeforeDelivery = false
    @State private var toastMessage: String?

    @State private var videoDisplaySize = CGSize(width: 16, height: 9)
    @State private var playbackScopeAssist: ScopeAssistBundle = .empty
    @State private var playbackScopeController = PlaybackScopeController()
    @State private var playbackAudioLevels = AudioMeterLevels.silent
    @State private var audioMeterController = PlaybackAudioMeterController()
    @State private var clipSlideEdge: Edge = .trailing
    @State private var playbackEffectsBox = MediaLUT.PlaybackEffectsBox()
    /// Bumps on each clip load so async asset probes cannot apply to a replaced clip.
    @State private var playerLoadGeneration = 0
    /// Invalidates detached scope derivations whenever polling is restarted or stopped.
    @State private var playbackScopePollingGeneration = 0
    @State private var zoomScale: CGFloat = 1
    @State private var lastZoomScale: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var lastPanOffset: CGSize = .zero
    /// Suppresses play/pause tap recognition after pinch, pan, or frame scrub so those gestures do not toggle transport.
    @State private var suppressNextPlaybackTap = false
    /// Brief play/pause symbol shown centered on the video after a frame tap toggles transport.
    @State private var playbackFlashSymbol: String?
    @State private var playbackFlashVisible = false
    @State private var playbackFlashTask: Task<Void, Never>?
    /// Long-press horizontal scrub on the letterboxed video frame (distinct from bottom-bar scrubber).
    @State private var isFrameScrubbing = false
    @State private var frameScrubOriginTime: Double = 0
    @State private var frameScrubVideoWidth: CGFloat = 0
    @State private var frameScrubPending = false

    private enum PlaybackZoom {
        static let minScale: CGFloat = 1
        static let maxScale: CGFloat = 4
    }

    private enum PlaybackFlash {
        static let fadeIn: Double = 0.12
        static let hold: Double = 0.55
        static let fadeOut: Double = 0.22
    }

    private enum FrameScrub {
        static let longPressDuration: Double = 0.35
    }

    init(
        clips: [MediaClip],
        startingAt clip: MediaClip,
        initialShareDestination: MediaDeliveryDestination? = nil
    ) {
        self.clips = clips
        _activeClip = State(initialValue: clip)
        // Post-hop resume: open with the share popup already on the given destination.
        if let initialShareDestination {
            _deliveryPresentation = State(
                initialValue: MediaDeliveryPresentation(
                    clip: clip, preferredDestination: initialShareDestination))
        }
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

    private var showsClipNavigation: Bool {
        clips.count > 1
    }

    private var playbackScopesActive: Bool {
        let visible = model.preferences.playbackVisibleAssistTools
        return visible.contains(.waveform) || visible.contains(.parade)
            || visible.contains(.histogram) || visible.contains(.trafficLights)
            || visible.contains(.vectorscope)
    }

    private var playbackAudioMetersActive: Bool {
        model.preferences.playbackVisibleAssistTools.contains(.audioMeters)
    }

    /// Playback de-squeeze uses the shared factor, gated by playback-visible tools.
    private var playbackDesqueeze: AssistConfiguration.Desqueeze {
        var config = model.assistConfiguration.desqueeze
        config.enabled = model.preferences.playbackVisibleAssistTools.contains(.desqueeze)
        return config
    }

    private var playbackScopeDerivationConfiguration: PlaybackScopeDerivationConfiguration {
        let scopes = model.assistConfiguration.scopes
        // Playback scopes measure source/log on the same anchored axis as live view; clips don't
        // persist a per-clip tone mode yet, so the mapping follows current camera state. The
        // vectorscope reads the monitor image through the look the player bakes (LUT tool + LUT).
        return PlaybackScopeDerivationConfiguration(
            trafficLightsCrushClip: scopes.crushClipCompensation,
            mapping: model.playbackExposureSignalMapping,
            vectorscopeCube: model.vectorscopeMonitorCube(
                visibleTools: model.preferences.playbackVisibleAssistTools,
                curve: model.playbackExposureSignalMapping.curve))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            GeometryReader { geo in
                let container = CGRect(origin: .zero, size: geo.size)
                let videoRect = aspectFitRect(videoSize: videoDisplaySize, in: container)

                ZStack {
                    PlayerLayerView(player: player)
                        // Match live view: de-squeeze the raster, then apply pinch zoom.
                        .scaleEffect(desqueezeScale(playbackDesqueeze), anchor: .center)
                        .scaleEffect(zoomScale)
                        .offset(panOffset)
                }
                .frame(width: videoRect.width, height: videoRect.height)
                .clipped()
                .position(x: videoRect.midX, y: videoRect.midY)
                .allowsHitTesting(false)
                .id(activeClip.id)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: clipSlideEdge),
                        removal: .move(edge: clipSlideEdge == .trailing ? .leading : .trailing)
                    )
                )

                FeedAlignedAssists(
                    clean: false, feed: videoRect, excludeTools: [.level], usePlaybackContext: true
                )
                .frame(width: geo.size.width, height: geo.size.height)

                Color.clear
                    .frame(width: videoRect.width, height: videoRect.height)
                    .position(x: videoRect.midX, y: videoRect.midY)
                    .contentShape(Rectangle())
                    .onAppear { frameScrubVideoWidth = videoRect.width }
                    .onChange(of: videoRect.width) { _, width in
                        frameScrubVideoWidth = width
                    }
                    .gesture(playbackVideoGesture)
                    .simultaneousGesture(playbackFrameTapGesture)
                    .simultaneousGesture(playbackFrameScrubGesture)

                playbackTransportFlashOverlay(in: videoRect)
                playbackFrameScrubOverlay(in: videoRect)

                if playbackScopesActive || playbackAudioMetersActive {
                    PlaybackAssistOverlayModule(
                        scopeAssist: playbackScopeAssist, videoRect: videoRect,
                        audioLevels: playbackAudioLevels
                    )
                    .frame(width: geo.size.width, height: geo.size.height)
                }

                if showsClipNavigation {
                    clipNavigationArrows(in: videoRect)
                }
            }
            .ignoresSafeArea()

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

            if !isClipReady {
                clipLoadingOverlay
            }

            VStack {
                if chromeVisible { topBar }
                Spacer()
                if chromeVisible, let toastMessage { toastView(toastMessage) }
                if chromeVisible { bottomBar }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .allowsHitTesting(true)
            .zIndex(2)
            .animation(.spring(duration: 0.32), value: chromeVisible)

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
                playbackAssistOptionsOverlay(tool: tool)
                    .zIndex(4)
            }
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
        .onChange(of: model.preferences.playbackVisibleAssistTools) { _, _ in
            updatePlaybackEffects()
            syncPlaybackScopeSampling()
            syncPlaybackAudioMetering()
        }
        .onChange(of: model.assistConfiguration) { _, _ in
            updatePlaybackEffects()
        }
        .onChange(of: model.assistConfiguration.scopes.crushClipCompensation) { _, _ in
            restartPlaybackScopeSampling()
        }
        .mediaDeliveryShareSheet(onDismiss: resumePlaybackIfNeeded)
    }

    /// Mirrors live-monitor `PanelHost.bottomAssistBody` — glass popup anchored above the playback bar.
    private func playbackAssistOptionsOverlay(tool: MonitorAssistTool) -> some View {
        PlaybackAssistOptionsOverlay(
            tool: tool,
            anchorToolbarFrame: playbackAssistToolbarFrame,
            isRevealed: playbackAssistPanelRevealed,
            onBackdropTap: dismissPlaybackAssistOptions,
            onClose: dismissPlaybackAssistOptions
        )
        .environment(model)
    }

    private func presentPlaybackAssistOptions(_ tool: MonitorAssistTool) {
        playbackAssistPanelRevealed = false
        assistOptionsTool = tool
        schedulePlaybackAssistReveal()
    }

    private func dismissPlaybackAssistOptions() {
        assistOptionsTool = nil
    }

    /// Same slide-up curve as live-monitor assist popups (`NativeAppModel.panelRevealCurve`).
    private func schedulePlaybackAssistReveal() {
        Task { @MainActor in
            await Task.yield()
            guard assistOptionsTool != nil else { return }
            withAnimation(.timingCurve(0.16, 1, 0.3, 1, duration: 0.20)) {
                playbackAssistPanelRevealed = true
            }
        }
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
        if wasPlayingBeforeDelivery {
            player.play()
            isPlaying = true
            wasPlayingBeforeDelivery = false
        }
    }

    private func closeDeliveryPopup() {
        deliveryPresentation = nil
        exportState =
            model.mediaClips.first { $0.id == activeClip.id }?.exportStatus
            ?? activeClip.exportStatus
        resumePlaybackIfNeeded()
    }

    private var playbackVideoGesture: some Gesture {
        SimultaneousGesture(
            SimultaneousGesture(playbackMagnificationGesture, playbackPanGesture),
            chromeSwipeGesture
        )
    }

    /// Single-tap on the letterboxed video frame — must be simultaneous with pinch/pan so drags still win.
    private var playbackFrameTapGesture: some Gesture {
        TapGesture()
            .onEnded {
                handlePlaybackFrameTap()
            }
    }

    /// Long-press then horizontal drag on the video frame to scrub the timeline in-place.
    private var playbackFrameScrubGesture: some Gesture {
        LongPressGesture(minimumDuration: FrameScrub.longPressDuration)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard isClipReady, deliveryPresentation == nil, assistOptionsTool == nil else {
                    return
                }
                guard zoomScale <= 1.05 else { return }

                switch value {
                case .first(true):
                    frameScrubPending = true
                case .second(true, let drag?):
                    if frameScrubPending {
                        beginFrameScrub()
                        frameScrubPending = false
                    }
                    guard isFrameScrubbing else { return }
                    updateFrameScrub(horizontalDelta: drag.translation.width)
                default:
                    break
                }
            }
            .onEnded { _ in
                frameScrubPending = false
                if isFrameScrubbing {
                    endFrameScrub()
                }
            }
    }

    @ViewBuilder
    private func playbackTransportFlashOverlay(in videoRect: CGRect) -> some View {
        if playbackFlashSymbol != nil {
            Image(systemName: playbackFlashSymbol ?? "play.fill")
                .font(.system(size: 48, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
                .shadow(color: .black.opacity(0.5), radius: 10, y: 3)
                .overlay {
                    Image(systemName: playbackFlashSymbol ?? "play.fill")
                        .font(.system(size: 48, weight: .semibold))
                        .foregroundStyle(LiveDesign.accent.opacity(0.28))
                        .blendMode(.overlay)
                }
                .opacity(playbackFlashVisible ? 1 : 0)
                .scaleEffect(playbackFlashVisible ? 1 : 0.86)
                .animation(.easeOut(duration: PlaybackFlash.fadeIn), value: playbackFlashVisible)
                .position(x: videoRect.midX, y: videoRect.midY)
                .allowsHitTesting(false)
                .zIndex(2)
        }
    }

    @ViewBuilder
    private func playbackFrameScrubOverlay(in videoRect: CGRect) -> some View {
        if isFrameScrubbing, duration > 0 {
            let fraction = min(1, max(0, scrubTime / duration))
            let barWidth = max(0, videoRect.width - 32)
            VStack(spacing: 10) {
                Text(timeLabel(scrubTime))
                    .font(.system(size: 16, weight: .semibold, design: .monospaced))
                    .foregroundStyle(LiveDesign.text)
                    .shadow(color: .black.opacity(0.55), radius: 6, y: 2)
                Text("/ \(timeLabel(duration))")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .liquidGlass(in: Capsule(), interactive: false)
            .position(x: videoRect.midX, y: videoRect.midY)
            .allowsHitTesting(false)
            .transition(.opacity.combined(with: .scale(scale: 0.94)))
            .zIndex(2)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LiveDesign.hairline)
                    .frame(width: barWidth, height: 3)
                Capsule()
                    .fill(LiveDesign.accent)
                    .frame(width: max(3, barWidth * fraction), height: 3)
            }
            .position(x: videoRect.midX, y: videoRect.maxY - 18)
            .allowsHitTesting(false)
            .zIndex(2)
        }
    }

    private var chromeSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 28)
            .onEnded { value in
                guard !isFrameScrubbing else { return }
                let dy = value.translation.height
                guard abs(dy) > abs(value.translation.width) + 8, abs(dy) > 44 else { return }
                withAnimation(.spring(duration: 0.32)) {
                    chromeVisible = dy < 0
                }
            }
    }

    private var playbackMagnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                if abs(value - 1) > 0.02 {
                    suppressNextPlaybackTap = true
                    frameScrubPending = false
                }
                let proposed = lastZoomScale * value
                zoomScale = min(PlaybackZoom.maxScale, max(PlaybackZoom.minScale, proposed))
            }
            .onEnded { _ in
                lastZoomScale = zoomScale
                if zoomScale < 1.05 {
                    resetPlaybackZoom()
                }
            }
    }

    private var playbackPanGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard zoomScale > 1 else { return }
                if hypot(value.translation.width, value.translation.height) > 8 {
                    suppressNextPlaybackTap = true
                    frameScrubPending = false
                }
                panOffset = CGSize(
                    width: lastPanOffset.width + value.translation.width,
                    height: lastPanOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard zoomScale > 1 else { return }
                lastPanOffset = panOffset
            }
    }

    @ViewBuilder
    private func clipNavigationArrows(in videoRect: CGRect) -> some View {
        if canGoToPreviousClip {
            Button {
                goToAdjacentClip(offset: -1)
            } label: {
                clipNavigationArrowButton(systemName: "chevron.left")
            }
            .buttonStyle(.zcTapTarget)
            .position(x: videoRect.minX + 22, y: videoRect.midY)
            .accessibilityLabel("Previous clip")
        }

        if canGoToNextClip {
            Button {
                goToAdjacentClip(offset: 1)
            } label: {
                clipNavigationArrowButton(systemName: "chevron.right")
            }
            .buttonStyle(.zcTapTarget)
            .position(x: videoRect.maxX - 22, y: videoRect.midY)
            .accessibilityLabel("Next clip")
        }
    }

    private func clipNavigationArrowButton(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(LiveDesign.accent)
            .frame(width: 32, height: 32)
            .liquidGlass(in: Circle(), interactive: true)
    }

    private func resetPlaybackZoom() {
        zoomScale = PlaybackZoom.minScale
        lastZoomScale = PlaybackZoom.minScale
        panOffset = .zero
        lastPanOffset = .zero
    }

    private func goToAdjacentClip(offset: Int) {
        guard let index = currentClipIndex else { return }
        let targetIndex = index + offset
        guard clips.indices.contains(targetIndex) else {
            UIImpactFeedbackGenerator(style: .rigid).impactOccurred()
            return
        }
        clipSlideEdge = offset > 0 ? .trailing : .leading
        navigateToClip(clips[targetIndex])
    }

    private func navigateToClip(_ clip: MediaClip) {
        guard clip.id != activeClip.id else { return }
        streamPollTask?.cancel()
        streamPollTask = nil
        model.cancelClipStream()
        teardownPlayer()
        resetPlaybackZoom()

        currentTime = 0
        duration = 0
        scrubTime = 0
        isScrubbing = false
        isFrameScrubbing = false
        frameScrubPending = false
        playbackFlashTask?.cancel()
        playbackFlashTask = nil
        playbackFlashSymbol = nil
        playbackFlashVisible = false
        isPlaying = true
        reachedEnd = false
        isClipReady = false

        withAnimation(.easeInOut(duration: 0.28)) {
            activeClip = clip
        }
        loadActiveClip()
    }

    private var clipLoadingOverlay: some View {
        ZStack {
            Color.black.opacity(0.72)
            VStack(spacing: 12) {
                ProgressView().tint(LiveDesign.accent)
                Text(loadingMessage)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(LiveDesign.muted)
            }
            .padding(24)
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius), interactive: false)
        }
        .ignoresSafeArea()
        .zIndex(2)
    }

    private var loadingMessage: String {
        if model.mediaDownloadProgress[activeClip.id] != nil {
            return "Buffering from camera…"
        }
        return "Preparing playback…"
    }

    // MARK: Top bar (close · name · favorite)

    private var topBar: some View {
        HStack(spacing: 10) {
            Button {
                dismiss()
            } label: {
                CircleIconButton(systemName: "chevron.left", size: 34)
            }
            .buttonStyle(.zcTapTarget)
            Text(activeClip.filename)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(LiveDesign.text)
            Spacer()
            Button {
                model.toggleClipFavorite(activeClip)
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 17))
                    .foregroundStyle(isFavorite ? LiveDesign.accent : LiveDesign.text)
                    .frame(width: 34, height: 34)
                    .liquidGlass(in: Circle(), interactive: true)
            }
            .buttonStyle(.zcTapTarget)
        }
    }

    // MARK: Bottom bar (playback transport or inline view-assist)

    /// Compact playback chrome — primary controls use 44pt hit targets via `ZCTapTargetButtonStyle`.
    private enum PlaybackChrome {
        static let barPaddingH: CGFloat = 12
        static let barPaddingV: CGFloat = 9
        static let transportRowSpacing: CGFloat = 8
        static let scrubberRowSpacing: CGFloat = 5
        static let transportButtonSize = CGSize(width: 40, height: 36)
        static let actionButtonSize = CGSize(width: 38, height: 36)
        static let transportIconSize: CGFloat = 18
        static let primaryTransportIconSize: CGFloat = 22
        static let actionIconSize: CGFloat = 16
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if assistMode {
                assistModeBar
            } else {
                playbackTransportBar
            }
        }
        .padding(.horizontal, PlaybackChrome.barPaddingH)
        .padding(.vertical, PlaybackChrome.barPaddingV)
        .liquidGlass(
            in: RoundedRectangle(cornerRadius: LiveDesign.cornerRadius, style: .continuous),
            interactive: false
        )
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { playbackBarFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        playbackBarFrame = frame
                    }
            }
        }
        .animation(.spring(duration: 0.32), value: assistMode)
    }

    private var playbackTransportBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: PlaybackChrome.scrubberRowSpacing) {
                Text(timeLabel(isScrubbing ? scrubTime : currentTime))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
                    .frame(width: 40, alignment: .leading)
                PlaybackScrubber(
                    progress: isScrubbing ? scrubTime : currentTime,
                    duration: duration,
                    bufferedFraction: model.clipBufferedFraction(activeClip),
                    onScrubbingChanged: { scrubbing in
                        if scrubbing {
                            if !isScrubbing {
                                wasPlayingBeforeScrub = isPlaying
                                scrubTime = currentTime
                                player.pause()
                            }
                            isScrubbing = true
                        } else {
                            isScrubbing = false
                        }
                    },
                    onProgressChange: { time in
                        scrubTime = time
                        clearEndStateIfSeeking(to: time)
                        let now = CFAbsoluteTimeGetCurrent()
                        if now - lastScrubSeekTime >= scrubSeekThrottle {
                            lastScrubSeekTime = now
                            player.seek(
                                to: CMTime(seconds: time, preferredTimescale: 600),
                                toleranceBefore: scrubSeekTolerance,
                                toleranceAfter: scrubSeekTolerance)
                        }
                    },
                    onSeek: { time in
                        player.seek(
                            to: CMTime(seconds: time, preferredTimescale: 600),
                            toleranceBefore: .zero, toleranceAfter: .zero)
                        currentTime = time
                        scrubTime = time
                        isScrubbing = false
                        clearEndStateIfSeeking(to: time)
                        if wasPlayingBeforeScrub {
                            player.play()
                            isPlaying = true
                        }
                    }
                )
                Text(timeLabel(duration))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(LiveDesign.muted)
                    .frame(width: 40, alignment: .trailing)
            }

            HStack(spacing: PlaybackChrome.transportRowSpacing) {
                transportButton("gobackward.15") { seek(by: -15) }
                if reachedEnd {
                    transportButton(
                        "arrow.counterclockwise", size: PlaybackChrome.primaryTransportIconSize
                    ) {
                        restartPlayback()
                    }
                } else {
                    transportButton(
                        isPlaying ? "pause.fill" : "play.fill",
                        size: PlaybackChrome.primaryTransportIconSize
                    ) {
                        togglePlay()
                    }
                }
                transportButton("goforward.15") { seek(by: 15) }

                Spacer(minLength: 12)

                actionToggle("speaker.slash.fill", "speaker.wave.2.fill", on: isMuted) {
                    toggleMute()
                }
                viewAssistButton
                shareButton
            }
        }
    }

    private var assistModeBar: some View {
        HStack(spacing: 6) {
            playbackAssistToolbar
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(0)
            viewAssistButton
                .layoutPriority(1)
        }
    }

    private var visiblePlaybackToolbarTools: [MonitorAssistTool] {
        model.preferences.assistToolbarOrder.filter {
            $0 != .level && model.preferences.isAssistToolbarButtonVisible($0)
        }
    }

    /// Same assist toolbar row as the live monitor: tap toggles, long-press opens options.
    private var playbackAssistToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(
                    Array(visiblePlaybackToolbarTools.enumerated()),
                    id: \.element.id
                ) { index, tool in
                    if index > 0 && index.isMultiple(of: 3) {
                        Rectangle()
                            .fill(LiveDesign.hairlineStrong)
                            .frame(width: 1, height: 22)
                            .padding(.horizontal, 3)
                    }
                    AssistToolButtonRow(tool: tool, context: .playback) { tool in
                        presentPlaybackAssistOptions(tool)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { playbackAssistToolbarFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        playbackAssistToolbarFrame = frame
                    }
            }
        }
    }

    private var viewAssistButton: some View {
        let anyAssistOn = !model.preferences.playbackVisibleAssistTools.isEmpty
        let highlighted = assistMode || anyAssistOn
        return Button {
            withAnimation(.spring(duration: 0.32)) {
                assistMode.toggle()
            }
        } label: {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: PlaybackChrome.actionIconSize, weight: .medium))
                .foregroundStyle(highlighted ? LiveDesign.accent : LiveDesign.text)
                .frame(
                    width: PlaybackChrome.actionButtonSize.width,
                    height: PlaybackChrome.actionButtonSize.height
                )
                .background(
                    assistMode ? LiveDesign.accentDim : Color.clear,
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
                .liquidGlass(
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous),
                    interactive: true)
        }
        .buttonStyle(.zcTapTarget)
    }

    private var shareButton: some View {
        Button {
            wasPlayingBeforeDelivery = isPlaying
            if isPlaying {
                player.pause()
                isPlaying = false
            }
            deliveryPresentation = MediaDeliveryPresentation(clip: activeClip)
        } label: {
            Image(
                systemName: exportState == .exported
                    ? "square.and.arrow.up.fill" : "square.and.arrow.up"
            )
            .font(.system(size: PlaybackChrome.actionIconSize, weight: .medium))
            .foregroundStyle(
                model.isClipDownloaded(activeClip) ? LiveDesign.text : LiveDesign.faint
            )
            .frame(
                width: PlaybackChrome.actionButtonSize.width,
                height: PlaybackChrome.actionButtonSize.height
            )
            .contentShape(
                RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
            )
            .liquidGlass(
                in: RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous),
                interactive: true)
        }
        .buttonStyle(.zcTapTarget)
        .disabled(!model.isClipDownloaded(activeClip))
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear { shareButtonFrame = proxy.frame(in: .global) }
                    .onChange(of: proxy.frame(in: .global)) { _, frame in
                        shareButtonFrame = frame
                    }
            }
        }
    }

    private func transportButton(
        _ systemName: String,
        size: CGFloat = PlaybackChrome.transportIconSize,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(LiveDesign.text)
                .frame(
                    width: PlaybackChrome.transportButtonSize.width,
                    height: PlaybackChrome.transportButtonSize.height
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
                .liquidGlass(
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous),
                    interactive: true)
        }
        .buttonStyle(.zcTapTarget)
    }

    private func actionButton(_ systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: PlaybackChrome.actionIconSize, weight: .medium))
                .foregroundStyle(LiveDesign.text)
                .frame(
                    width: PlaybackChrome.actionButtonSize.width,
                    height: PlaybackChrome.actionButtonSize.height
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
                .liquidGlass(
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous),
                    interactive: true)
        }
        .buttonStyle(.zcTapTarget)
    }

    private func actionToggle(
        _ onName: String, _ offName: String, on: Bool, enabled: Bool = true,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: on ? onName : offName)
                .font(.system(size: PlaybackChrome.actionIconSize, weight: .medium))
                .foregroundStyle(
                    enabled ? (on ? LiveDesign.accent : LiveDesign.text) : LiveDesign.faint
                )
                .frame(
                    width: PlaybackChrome.actionButtonSize.width,
                    height: PlaybackChrome.actionButtonSize.height
                )
                .contentShape(
                    RoundedRectangle(cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
                .background(
                    on ? LiveDesign.accentDim : Color.clear,
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous)
                )
                .liquidGlass(
                    in: RoundedRectangle(
                        cornerRadius: DesignTokens.cornerRadius, style: .continuous),
                    interactive: true)
        }
        .buttonStyle(.zcTapTarget)
        .disabled(!enabled)
    }

    private func toastView(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(LiveDesign.text)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16).padding(.vertical, 10)
            .liquidGlass(in: Capsule(), interactive: true)
            .padding(.bottom, 8)
            .transition(.opacity)
    }

    // MARK: Actions

    private func appear() {
        // Stop the shutter before playback changes the process-wide AVAudioSession category.
        model.setMediaPlaybackOwnsAudioSession(true)
        MediaPlaybackAudioSession.activateForPlayback()
        loadActiveClip()
    }

    private func loadActiveClip() {
        isFavorite = activeClip.isFavorite
        exportState = activeClip.exportStatus
        isClipReady = model.isClipDownloaded(activeClip)

        if isClipReady {
            loadPlayerItem()
        } else {
            model.startClipStream(activeClip)
            streamPollTask?.cancel()
            streamPollTask = Task { @MainActor in
                await pollUntilPlayable()
            }
        }
    }

    private func disappear() {
        streamPollTask?.cancel()
        streamPollTask = nil
        playbackFlashTask?.cancel()
        playbackFlashTask = nil
        model.cancelClipStream()
        teardownPlayer()
        MediaPlaybackAudioSession.deactivateAfterPlayback()
        model.setMediaPlaybackOwnsAudioSession(false)
    }

    /// Polls the growing local cache until AVFoundation can open the clip, or the download completes.
    @MainActor
    private func pollUntilPlayable() async {
        let clipID = activeClip.id
        guard let url = model.clipLocalURL(activeClip) else { return }
        let assetOptions = [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        var probeAsset: AVURLAsset?
        defer { probeAsset?.cancelLoading() }
        while !Task.isCancelled, !isClipReady {
            guard activeClip.id == clipID else { return }
            if model.isClipDownloaded(activeClip) {
                isClipReady = true
                loadPlayerItem()
                return
            }
            if FileManager.default.fileExists(atPath: url.path) {
                if probeAsset == nil {
                    probeAsset = AVURLAsset(url: url, options: assetOptions)
                }
                if let probeAsset, await isAssetPlayable(probeAsset) {
                    isClipReady = true
                    loadPlayerItem()
                    return
                }
                // A growing partial file can make the first probe on a reused asset look
                // permanently unplayable; discard and recreate on the next pass.
                probeAsset?.cancelLoading()
                probeAsset = nil
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
    }

    private func isAssetPlayable(_ asset: AVURLAsset) async -> Bool {
        // Partial cache may not expose final duration yet; isPlayable is enough to start.
        (try? await asset.load(.isPlayable)) == true
    }

    private func loadPlayerItem() {
        teardownPlayer()
        playerLoadGeneration += 1
        let generation = playerLoadGeneration
        reachedEnd = false
        guard let url = model.clipLocalURL(activeClip) else { return }
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: false]
        )
        let item = AVPlayerItem(asset: asset)
        player.replaceCurrentItem(with: item)
        observePlaybackEnd(for: item)
        player.automaticallyWaitsToMinimizeStalling = false
        player.isMuted = isMuted
        playbackScopeController.stop()
        syncPlaybackScopeSampling()
        Task {
            if let size = await loadVideoDisplaySize(from: asset) {
                guard generation == playerLoadGeneration else { return }
                videoDisplaySize = size
            }
        }
        let interval = CMTime(seconds: isScrubbing ? 0.05 : 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            Task { @MainActor in
                guard !isScrubbing else { return }
                currentTime = time.seconds
                if let dur = player.currentItem?.duration.seconds, dur.isFinite { duration = dur }
            }
        }
        if DemoHarness.mediaLUT {
            model.setAssist(.lut, visible: true)
        }
        attachPlaybackVideoComposition(to: item)
        // Tap installs per item regardless of the tool toggle (uniform lifecycle, passthrough
        // audio, negligible cost); polling below follows the toggle.
        audioMeterController.attach(to: item)
        syncPlaybackAudioMetering()
        player.play()
        isPlaying = true
    }

    private func teardownPlayer() {
        playbackScopeController.stop()
        playbackEffectsBox.invalidateScopeComposition()
        syncPlaybackScopeSampling(active: false)
        // Drop the audio mix before the item goes away — releasing an item with a live tap crashes.
        audioMeterController.stopPolling()
        audioMeterController.detach(from: player.currentItem)
        playbackAudioLevels = .silent
        removeEndObserver()
        if let observer = timeObserver {
            player.removeTimeObserver(observer)
            timeObserver = nil
        }
        player.pause()
        if let item = player.currentItem {
            item.videoComposition = nil
            (item.asset as? AVURLAsset)?.cancelLoading()
        }
        player.replaceCurrentItem(with: nil)
        playbackScopeAssist = .empty
    }

    private func observePlaybackEnd(for item: AVPlayerItem) {
        removeEndObserver()
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                reachedEnd = true
                isPlaying = false
                if let dur = player.currentItem?.duration.seconds, dur.isFinite {
                    currentTime = dur
                }
            }
        }
    }

    private func removeEndObserver() {
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
            self.endObserver = nil
        }
    }

    /// Clears end-of-clip state when the user seeks away from the tail.
    private func clearEndStateIfSeeking(to time: Double) {
        guard duration > 0 else { return }
        if time < duration - 0.25 {
            reachedEnd = false
        }
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
                let visible = model.preferences.playbackVisibleAssistTools
                return visible.contains(.waveform) || visible.contains(.parade)
                    || visible.contains(.histogram) || visible.contains(.trafficLights)
                    || visible.contains(.vectorscope)
            },
            onSamples: { samples in
                let configuration = playbackScopeDerivationConfiguration
                let clipID = activeClip.id
                let loadGeneration = playerLoadGeneration
                let previous = playbackScopeAssist
                let bundle = await Task.detached(priority: .utility) {
                    configuration.bundle(samples: samples, previous: previous)
                }.value
                guard !Task.isCancelled,
                    pollingGeneration == playbackScopePollingGeneration,
                    loadGeneration == playerLoadGeneration,
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
            playbackAudioLevels = .silent
            return
        }
        audioMeterController.startPolling { levels in
            playbackAudioLevels = levels
        }
    }

    private func togglePlay() {
        isPlaying.toggle()
        isPlaying ? player.play() : player.pause()
    }

    /// Tap on the video frame toggles transport; at end-of-clip restarts from the beginning.
    private func handlePlaybackFrameTap() {
        guard isClipReady else { return }
        guard deliveryPresentation == nil, assistOptionsTool == nil else { return }
        guard !isFrameScrubbing else { return }
        if suppressNextPlaybackTap {
            suppressNextPlaybackTap = false
            return
        }
        if reachedEnd {
            restartPlayback()
            showPlaybackFlash(symbol: "play.fill")
        } else {
            let willPlay = !isPlaying
            togglePlay()
            showPlaybackFlash(symbol: willPlay ? "play.fill" : "pause.fill")
        }
    }

    private func showPlaybackFlash(symbol: String) {
        playbackFlashTask?.cancel()
        playbackFlashSymbol = symbol
        withAnimation(.easeOut(duration: PlaybackFlash.fadeIn)) {
            playbackFlashVisible = true
        }
        playbackFlashTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(PlaybackFlash.hold))
            guard !Task.isCancelled else { return }
            withAnimation(.easeIn(duration: PlaybackFlash.fadeOut)) {
                playbackFlashVisible = false
            }
            try? await Task.sleep(for: .seconds(PlaybackFlash.fadeOut))
            guard !Task.isCancelled else { return }
            playbackFlashSymbol = nil
        }
    }

    private func beginFrameScrub() {
        wasPlayingBeforeScrub = isPlaying
        frameScrubOriginTime = currentTime
        scrubTime = currentTime
        isScrubbing = true
        isFrameScrubbing = true
        player.pause()
        isPlaying = false
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func updateFrameScrub(horizontalDelta: CGFloat) {
        guard duration > 0, frameScrubVideoWidth > 0 else { return }
        let deltaTime = Double(horizontalDelta / frameScrubVideoWidth) * duration
        let time = max(0, min(duration, frameScrubOriginTime + deltaTime))
        scrubTime = time
        clearEndStateIfSeeking(to: time)
        let now = CFAbsoluteTimeGetCurrent()
        if now - lastScrubSeekTime >= scrubSeekThrottle {
            lastScrubSeekTime = now
            player.seek(
                to: CMTime(seconds: time, preferredTimescale: 600),
                toleranceBefore: scrubSeekTolerance,
                toleranceAfter: scrubSeekTolerance)
        }
    }

    private func endFrameScrub() {
        guard isFrameScrubbing else { return }
        player.seek(
            to: CMTime(seconds: scrubTime, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero)
        currentTime = scrubTime
        isScrubbing = false
        isFrameScrubbing = false
        clearEndStateIfSeeking(to: scrubTime)
        if wasPlayingBeforeScrub {
            player.play()
            isPlaying = true
        }
        suppressNextPlaybackTap = true
    }

    private func restartPlayback() {
        reachedEnd = false
        currentTime = 0
        player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
        isPlaying = true
    }

    private func seek(by seconds: Double) {
        let target = max(0, min(duration, currentTime + seconds))
        clearEndStateIfSeeking(to: target)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
    }

    private func toggleMute() {
        isMuted.toggle()
        player.isMuted = isMuted
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

/// Draggable playback timeline — drag to scrub in real time, release for a precise seek.
private struct PlaybackScrubber: View {
    let progress: Double
    let duration: Double
    /// Cached byte fraction (0…1) mapped along clip duration; `nil` hides the buffer layer.
    let bufferedFraction: Double?
    let onScrubbingChanged: (Bool) -> Void
    let onProgressChange: (Double) -> Void
    let onSeek: (Double) -> Void

    @State private var isDragging = false

    private var fraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, progress / duration))
    }

    private var bufferFraction: Double {
        guard let bufferedFraction else { return 0 }
        return min(1, max(0, bufferedFraction))
    }

    var body: some View {
        GeometryReader { geo in
            let trackHeight: CGFloat = 3
            let thumbSize: CGFloat = 12
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LiveDesign.hairline)
                    .frame(height: trackHeight)
                if bufferFraction > 0 {
                    Capsule()
                        .fill(LiveDesign.accent.opacity(0.32))
                        .frame(
                            width: max(trackHeight, geo.size.width * bufferFraction),
                            height: trackHeight)
                }
                Capsule()
                    .fill(LiveDesign.accent)
                    .frame(width: max(trackHeight, geo.size.width * fraction), height: trackHeight)
                Circle()
                    .fill(LiveDesign.accent)
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: max(0, geo.size.width * fraction - thumbSize / 2))
            }
            .frame(maxHeight: .infinity, alignment: .center)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            onScrubbingChanged(true)
                        }
                        let f = fraction(at: value.location.x, width: geo.size.width)
                        onProgressChange(f * duration)
                    }
                    .onEnded { value in
                        let f = fraction(at: value.location.x, width: geo.size.width)
                        onSeek(f * duration)
                        isDragging = false
                        onScrubbingChanged(false)
                    }
            )
        }
        .frame(height: 22)
    }

    private func fraction(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return Double(min(1, max(0, x / width)))
    }
}

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

// MARK: - Supporting views
