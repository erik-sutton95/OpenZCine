import Foundation
import OpenCineCore
import OpenCineMedia
import OpenCineNikon
import OpenZCineCore

/// Captured data mapping only. Projection/filter/sort/expansion loops belong to the neutral owner.
struct NikonAppGalleryProjection {
    let result: MonitorMediaProjectionResult
    let policy: NikonAppleGalleryProjectionPolicy
    private let rowsByID: [MediaAssetID: MediaClip]
    private let idsByLegacy: [String: MediaAssetID]
    init(
        clips: [MediaClip], actualIDs: [String: MediaAssetID], category: MediaCategoryTab,
        sort: MediaSortOrder, formats: Set<MediaFormatChip>,
        resolutions: Set<MediaResolutionBucket>,
        photoSizes: Set<MediaPhotoSizeClass>, dateWindow: MediaDateWindow?, storage: UInt32?,
        requireLocal: Bool, downloaded: (MediaClip) -> Bool,
        now: Date = Date(), calendar: Calendar = .current
    ) {
        let input = clips.map {
            Self.input(
                $0, actualID: actualIDs[$0.id],
                localEligible: requireLocal ? downloaded($0) : nil)
        }
        policy = .init(items: input, now: now, calendar: calendar)
        rowsByID = Dictionary(zip(input.map(\.id), clips), uniquingKeysWith: { first, _ in first })
        idsByLegacy = Dictionary(
            input.map { ($0.legacyID, $0.id) }, uniquingKeysWith: { first, _ in first })
        result = MonitorMediaProjection.project(
            input.map(\.id),
            request: .init(
                category: Self.category(category), sort: Self.sort(sort),
                formats: Set(formats.map(\.rawValue)),
                resolutions: Set(resolutions.map(\.rawValue)),
                photoSizes: Set(photoSizes.map(\.rawValue)), dateWindow: dateWindow?.rawValue,
                storage: storage.map(String.init), requireLocal: requireLocal), policy: policy)
    }
    var gridClips: [MediaClip] { result.gridIDs.compactMap { rowsByID[$0] } }
    var filterOptions: MediaFilterOptions {
        .init(
            formats: result.offered.formats.compactMap(MediaFormatChip.init(rawValue:)),
            resolutions: result.offered.resolutions.compactMap(
                MediaResolutionBucket.init(rawValue:)),
            photoSizes: result.offered.photoSizes.compactMap(MediaPhotoSizeClass.init(rawValue:)),
            dateWindows: result.offered.dateWindows.compactMap(MediaDateWindow.init(rawValue:)))
    }
    func series(for clip: MediaClip) -> BurstSeries? {
        guard let id = idsByLegacy[clip.id], let group = result.group(for: id) else { return nil }
        return .init(memberIDs: group.members.compactMap { rowsByID[$0]?.id })
    }
    func members(of clip: MediaClip, current: [MediaClip]) -> [MediaClip] {
        guard let id = idsByLegacy[clip.id], let group = result.group(for: id) else { return [] }
        let byLegacy = Dictionary(
            current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return group.members.compactMap { rowsByID[$0]?.id }.compactMap { byLegacy[$0] }
    }
    func expanded(_ clips: [MediaClip], current: [MediaClip]) -> [MediaClip] {
        let byLegacy = Dictionary(
            current.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let supplied = Dictionary(
            clips.map { (idsByLegacy[$0.id] ?? Self.sourceID($0), $0) },
            uniquingKeysWith: { first, _ in first })
        let available = Set(rowsByID.compactMap { byLegacy[$0.value.id] == nil ? nil : $0.key })
        return result.expansion(
            clips.map { idsByLegacy[$0.id] ?? Self.sourceID($0) },
            availableMemberIDs: available
        ).compactMap { entry in
            switch entry {
            case .supplied(let id): supplied[id]
            case .member(let id): rowsByID[id].flatMap { byLegacy[$0.id] }
            }
        }
    }
    static func ungroupedExpanded(_ clips: [MediaClip]) -> [MediaClip] {
        Self(
            clips: [], actualIDs: [:], category: .all, sort: .newest,
            formats: [], resolutions: [], photoSizes: [], dateWindow: nil, storage: nil,
            requireLocal: false, downloaded: { _ in false }
        ).expanded(clips, current: [])
    }
    func rawSibling(of clip: MediaClip) -> MediaClip? {
        guard let id = idsByLegacy[clip.id], let sibling = policy.rawCompanion(of: id) else {
            return nil
        }
        return rowsByID[sibling]
    }
    static func sorted(_ clips: [MediaClip], order: MediaSortOrder) -> [MediaClip] {
        // Preserve duplicates accepted by the legacy sort API; only the source comparator moves.
        clips.sorted {
            NikonAppleGalleryProjectionPolicy.compare(
                input($0), input($1),
                sort: sort(order)) == .orderedAscending
        }
    }
    static func rawSibling(of clip: MediaClip, in clips: [MediaClip]) -> MediaClip? {
        let items = clips.map { input($0) }
        let policy = NikonAppleGalleryProjectionPolicy(
            items: items, now: Date(), calendar: .current)
        guard let sibling = policy.rawCompanion(of: sourceID(clip)) else { return nil }
        return zip(items, clips).first { $0.0.id == sibling }?.1
    }
    private static func input(
        _ clip: MediaClip, actualID: MediaAssetID? = nil,
        localEligible: Bool? = nil
    ) -> NikonGallerySourceItem {
        var memberships = Set(clip.allLocations.map(\.storageID))
        if let primary = clip.storageID { memberships.insert(primary) }
        return .init(
            id: actualID ?? sourceID(clip), legacyID: clip.id, namespace: clip.cameraID,
            filename: clip.filename, captureDate: clip.captureDate, pixelWidth: clip.pixelWidth,
            pixelHeight: clip.pixelHeight, sourcePixelWidth: clip.sourcePixelWidth,
            storageID: clip.storageID, storageMembership: memberships.isEmpty ? nil : memberships,
            handle: clip.handle, favorite: clip.isFavorited, rating: clip.starRating,
            localEligible: localEligible)
    }
    static func sourceID(_ clip: MediaClip) -> MediaAssetID {
        NikonMediaLibraryAssets.asset(
            namespace: clip.cameraID, identity: clip.id,
            filename: clip.filename, captureDate: clip.captureDate, sizeBytes: clip.sizeBytes,
            pixelWidth: clip.pixelWidth, pixelHeight: clip.pixelHeight
        ).id
    }
    private static func category(_ value: MediaCategoryTab) -> MonitorMediaProjectionCategory {
        switch value {
        case .all: .all
        case .videos: .videos
        case .photos: .photos
        case .favorites: .favorites
        }
    }
    private static func sort(_ value: MediaSortOrder) -> MonitorMediaProjectionSort {
        switch value {
        case .newest: .newest
        case .oldest: .oldest
        case .name: .name
        case .rating: .rating
        }
    }
}

extension NativeAppModel {
    var mediaProjectionPass: NikonAppGalleryProjection {
        let actualIDs = Dictionary(
            (mediaLibrary?.records ?? []).map { ($0.payload.id, $0.asset.id) },
            uniquingKeysWith: { first, _ in first })
        return .init(
            clips: mediaClips, actualIDs: actualIDs, category: mediaCategoryTab,
            sort: mediaSortOrder, formats: mediaFormatFilters, resolutions: mediaResolutionFilters,
            photoSizes: mediaPhotoSizeFilters, dateWindow: mediaDateWindow,
            storage: mediaStorageSlotFilter,
            requireLocal: !isConnected, downloaded: isClipDownloaded)
    }
}
