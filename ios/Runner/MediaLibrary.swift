import Foundation
import MonitorPresentation
import OpenCineAppKit
import OpenCineMedia
import OpenZCineCore
import os

import class OpenCineCameraVocabulary.CustomLUTStore

/// Media library diagnostics (Media page cache). Filter Console for subsystem `OpenZCine`, category
/// `media-store`.
let mediaLibraryLogger = Logger(subsystem: "OpenZCine", category: "media-store")

/// A file's identity, size and modification time from one `stat(2)` call.
/// `FileManager.attributesOfItem` also reads every extended attribute (getattrlist, lstat,
/// listxattr, getxattr per call), and playback reads these facts several times a second: build
/// 317 spent most of its remaining main-thread file time there.
enum MediaFileFacts {
    struct Facts: Equatable, Sendable {
        let fileNumber: UInt64
        let size: UInt64
        let modified: Date
    }

    /// `followingLinks: false` describes a final symbolic link itself, as `attributesOfItem` does.
    static func read(_ path: String, followingLinks: Bool) -> Facts? {
        var info = stat()
        let status = followingLinks ? stat(path, &info) : lstat(path, &info)
        guard status == 0 else { return nil }
        let time = info.st_mtimespec
        return .init(
            fileNumber: UInt64(info.st_ino), size: UInt64(max(0, info.st_size)),
            modified: Date(
                timeIntervalSince1970: TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1e9)
        )
    }
}

/// Operation counts for the large-card performance tests (Debug only): each counted call is a
/// whole-catalog cost, so a test can prove an operation's cost follows its own size. Counts land
/// in the task-local scope a test installs, so concurrently running tests never mix.
enum MediaPerformanceProbe {
    enum Counter: Hashable, Sendable {
        case indexDecode, directoryListing, recordMapping, projectionPass, fileStamp
        /// Microseconds spent in the codec's per-page work (captureCatalog, prepareCatalog,
        /// encodeForPersistence), so a test can split app time from shared-library time.
        case captureMicros, prepareMicros, persistMicros
    }
    #if DEBUG
        final class Scope: @unchecked Sendable {
            private let lock = NSLock()
            private var counts: [Counter: Int] = [:]
            init() {}
            func add(_ counter: Counter, _ amount: Int = 1) {
                lock.lock()
                counts[counter, default: 0] += amount
                lock.unlock()
            }
            subscript(_ counter: Counter) -> Int {
                lock.lock()
                defer { lock.unlock() }
                return counts[counter, default: 0]
            }
        }
        @TaskLocal static var scope: Scope?
        static func count(_ counter: Counter) { scope?.add(counter) }
        static func timed<T>(_ counter: Counter, _ work: () throws -> T) rethrows -> T {
            guard let scope else { return try work() }
            let start = ContinuousClock.now
            defer {
                let elapsed = ContinuousClock.now - start
                scope.add(
                    counter,
                    Int(elapsed.components.seconds) * 1_000_000
                        + Int(elapsed.components.attoseconds / 1_000_000_000_000))
            }
            return try work()
        }
    #else
        @inline(__always) static func count(_ counter: Counter) {}
        @inline(__always) static func timed<T>(_ counter: Counter, _ work: () throws -> T)
            rethrows -> T
        { try work() }
    #endif
}

/// Reserved Frame.io upload state for a clip (the Frame.io button is a placeholder for now — see
/// `MediaPlayerView`). Persisted so a future upload flow can resume/show status.
enum FrameioStatus: String, Codable, Sendable {
    case notUploaded, uploading, uploaded, failed
}

/// LUT-baked export state for a clip (Phase 3). Persisted so the browser can badge exported clips.
enum ExportStatus: String, Codable, Sendable {
    case none, exporting, exported, failed
}

/// One clip in the Media library. Persisted in the per-camera `index.json`; SwiftUI binds to it.
/// `isDownloaded` / local URL are derived at runtime from `MediaClipStore`, never persisted.
struct MediaClip: Codable, Equatable, Identifiable, Sendable {
    /// Filesystem bucket the clip belongs to (`MediaClipStore.bucketID(for:)`).
    var cameraID: String
    /// On-card filename, e.g. `C0001.MOV`.
    var filename: String
    /// Primary object handle on the camera — present when discovered on the card, nil for
    /// local-only clips. When the shot lives on both cards this is the lowest-slot copy.
    var handle: UInt32?
    /// Storage volume of the primary handle (nil for local-only clips).
    var storageID: UInt32?
    /// Every card location this shot occupies: backup mode writes the same filename to both
    /// cards as two distinct objects, and the index keeps ONE row per filename — so the row
    /// carries all its locations. Additive/Codable; nil on rows indexed before this field
    /// existed (`allLocations` falls back to the primary pair).
    var storageLocations: [MediaObjectHandle]? = nil
    /// On-card size in bytes (PTP `ObjectCompressedSize`; 0 when unknown).
    var sizeBytes: UInt64
    /// PTP capture date string (`YYYYMMDDThhmmss`) or empty.
    var captureDate: String
    /// Full-frame width from `GetObjectInfo` when the camera reports it (nil for local-only clips).
    var pixelWidth: UInt32? = nil
    /// Full-frame height from `GetObjectInfo` when the camera reports it (nil for local-only clips).
    var pixelHeight: UInt32? = nil
    /// Full-frame width from a sibling `.R3D` master when this clip is a proxy MP4/MOV.
    var sourcePixelWidth: UInt32? = nil
    /// Full-frame height from a sibling `.R3D` master when this clip is a proxy MP4/MOV.
    var sourcePixelHeight: UInt32? = nil
    /// On-card R3D filename paired with this proxy by stem (nil when unlinked).
    var linkedR3DFilename: String? = nil
    var isFavorite: Bool = false
    /// EXIF orientation (1–8) of the full still, learned from the full file's header. Camera
    /// thumbnails arrive tagged with it already; grid/filmstrip decodes use this as the fallback
    /// for a thumbnail that carries none. Additive/Codable — nil until resolved.
    var exifOrientation: Int? = nil
    /// Cached camera star rating (0–5), mirrored from the body on every rating write so the
    /// Favorites filter agrees with the shots starred during a shoot. Additive/Codable —
    /// decodes nil on index rows written before this field existed. Camera is source of truth.
    var starRating: Int? = nil
    var frameioStatus: FrameioStatus = .notUploaded
    /// Remote Frame.io file id after a successful upload (prevents duplicate uploads).
    var frameioFileID: String?
    var exportStatus: ExportStatus = .none

    var id: String { "\(cameraID)/\(filename)" }

    /// All card locations of this shot, falling back to the primary pair for legacy rows.
    var allLocations: [MediaObjectHandle] {
        if let storageLocations, !storageLocations.isEmpty { return storageLocations }
        if let handle, let storageID {
            return [MediaObjectHandle(storageID: storageID, handle: handle)]
        }
        return []
    }

    /// Whether any copy of this shot lives on the given storage volume (slot filter).
    func isOn(storageID target: UInt32) -> Bool {
        if allLocations.contains(where: { $0.storageID == target }) { return true }
        return storageID == target
    }

    /// Lowercased file extension without the dot, e.g. `mov`.
    var fileExtension: String {
        (filename as NSString).pathExtension.lowercased()
    }
}

// MARK: - Browser filters & formatting

/// Clips shown from the connected camera bucket vs the on-device `local` bucket.
enum MediaBrowserSource: String, CaseIterable, Sendable {
    case camera = "CAMERA"
    case iPhone = "IPHONE"
}

/// Video vs still classification for grid filtering and the photo viewer.
enum MediaKind: String, Codable, Sendable {
    case video
    case photo
}

/// Primary library tabs for the Media browser sidebar.
enum MediaCategoryTab: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case videos = "Videos"
    case photos = "Photos"
    case favorites = "Favorites"

    var id: String { rawValue }
}

/// Persisted clip ordering for the Media browser grid.
enum MediaSortOrder: String, CaseIterable, Codable, Sendable {
    case newest
    case oldest
    case name
    /// Highest camera star first — clusters favorited/rated shots at the top for culling.
    case rating

    var next: MediaSortOrder {
        switch self {
        case .newest: .oldest
        case .oldest: .name
        case .name: .rating
        case .rating: .newest
        }
    }
}

extension MediaFormatChip {
    /// True when the clip belongs to this FORMAT chip. The extension-to-chip rule is the shared
    /// core's, so both shells and the JNI listing wire agree on what a `.HIF` or `.NEF` is.
    func matches(_ clip: MediaClip) -> Bool {
        MediaClipFilename.formatChip(for: clip.filename) == self
    }
}

extension MediaClip {

    /// Inferred from filename — videos are playable proxies; stills use `MediaClipFilename.isPhoto`.
    var mediaKind: MediaKind {
        MediaClipFilename.isPhoto(filename) ? .photo : .video
    }

    /// Best-effort resolution bucket: R3D source dimensions when linked, else proxy pixels, then filename.
    var resolutionBucket: NikonMediaResolutionBucket? {
        NikonMediaResolutionBucket.classify(
            filename: filename,
            pixelWidth: pixelWidth,
            sourcePixelWidth: sourcePixelWidth)
    }

    /// True for Nikon RAW stills (`.NEF` / `.NRW` / `.DNG`) — the tag-along side of a RAW+JPEG pair.
    ///
    /// Asks the core rather than carrying its own extension list: the shell held a duplicate of
    /// the same set, and a duplicate only stays correct until one copy learns a new extension.
    /// That is not hypothetical here — `.HIF` was missing from the core's HEIF set while two other
    /// places already special-cased it, and every Nikon HEIF went unlisted as a result.
    var isRawPhoto: Bool {
        MediaClipFilename.formatChip(for: filename) == .nef
    }

    /// Favorited for the Media page: the local heart OR any camera star (≥1). Rating writes
    /// (viewer + instant playback) mirror the body's star into `starRating`, so a shot starred
    /// during the shoot lands under the Favorites tab without a per-cell camera round-trip.
    var isFavorited: Bool {
        isFavorite || (starRating ?? 0) >= 1
    }

    /// Width over height as the grid shows it: the listed pixel size, turned for a still whose
    /// orientation the row has learned (from its tagged thumbnail or its full file).
    var uprightAspectRatio: Double? {
        MonitorMediaMasonry.uprightAspect(
            width: pixelWidth.map(Int.init), height: pixelHeight.map(Int.init),
            exifOrientation: exifOrientation)
    }

    /// This clip as a burst-detection frame: capture identity plus a format/dimensions signature
    /// (RAW and JPEG of one shot share the stem so a burst of pairs counts once).
    var burstFrame: BurstFrame {
        BurstFrame(
            id: id,
            storageID: storageID,
            handle: handle,
            captureDate: captureDate,
            stem: MediaClipFilename.stem(of: filename).lowercased(),
            isRaw: isRawPhoto,
            formatKey:
                "\(fileExtension)|\(pixelWidth.map(String.init) ?? "?")x\(pixelHeight.map(String.init) ?? "?")"
        )
    }
}

/// One camera card slot surfaced in the Media browser storage row.
struct MediaStorageSlotDisplay: Identifiable, Equatable, Sendable {
    let storageID: UInt32
    let slotNumber: Int
    let cameraName: String
    let usedGigabytes: Int
    let freeGigabytes: Int
    let totalGigabytes: Int

    var id: UInt32 { storageID }

    /// Mockup style: free space first, total capacity second (`242GB / 954GB free`).
    var summaryLine: String {
        if totalGigabytes > 0 {
            return "\(freeGigabytes)GB / \(totalGigabytes)GB free"
        }
        return "\(freeGigabytes)GB free"
    }
}

/// Counts active chip/sheet filters for the Media browser badge (excludes category tabs).
enum MediaBrowserFilterMetrics {
    static func activeCount(
        formatFilters: Set<MediaFormatChip>,
        resolutionFilters: Set<NikonMediaResolutionBucket>,
        photoSizeFilters: Set<NikonMediaPhotoSizeClass>,
        dateWindow: NikonMediaDateWindow?,
        storageSlotFilter: UInt32?
    ) -> Int {
        formatFilters.count + resolutionFilters.count + photoSizeFilters.count
            + (dateWindow != nil ? 1 : 0) + (storageSlotFilter != nil ? 1 : 0)
    }
}

enum MediaClipSorting {
    static func sort(_ clips: [MediaClip], order: MediaSortOrder) -> [MediaClip] {
        NikonAppGalleryProjection.sorted(clips, order: order)
    }
}

enum MediaClipStorePathError: LocalizedError, Equatable {
    case unsafeFilename
    case containmentViolation

    var errorDescription: String? {
        switch self {
        case .unsafeFilename:
            "The camera supplied an unsafe media filename."
        case .containmentViolation:
            "The media path escaped its cache directory."
        }
    }
}

/// Cached files a clear could not remove. Only bytes actually removed are counted, so Settings
/// never reports a clear that did not happen.
struct MediaClipCacheClearError: LocalizedError, Equatable {
    var removedBytes: UInt64
    var remainingFiles: [String]

    var errorDescription: String? {
        remainingFiles.count == 1
            ? "1 cached file could not be removed."
            : "\(remainingFiles.count) cached files could not be removed."
    }
}

/// On-disk cache for camera clips, mirroring `CustomLUTStore`. Files live under
/// `Documents/media/{cameraID}/`; a sibling `index.json` holds metadata not derivable from the
/// files (favorites, camera handles, upload/export status). Clip bytes are streamed to a
/// `FileHandle` during download — never buffered whole.
// Immutable paths and FileManager access cross into the shared filesystem worker. No delegate or
// FileManager configuration changes after construction; catalog mutation stays with its native owner.
struct MediaClipStore: @unchecked Sendable {
    /// Root of the per-camera bucket directories, `<documents>/media`.
    let root: URL
    let fileManager: FileManager

    init(root: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let root {
            self.root = root
        } else {
            let documents =
                FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.root = documents.appendingPathComponent("media", isDirectory: true)
        }
    }

    /// Bucket name for clips stored only on the iPhone (simulator samples, side-loaded files).
    static let localBucketID = "local"

    /// Sanitises a camera identity into a filesystem-safe bucket name; `local` when no camera (so the
    /// browser still works offline / in the simulator).
    static func bucketID(for identity: NativeCameraIdentity?) -> String {
        let raw = (identity?.serialNumber ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return localBucketID }
        return safeBucketID(raw)
    }

    private static func safeBucketID(_ raw: String) -> String {
        let safe = String(
            raw.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "_" })
        return safe.isEmpty ? localBucketID : safe
    }

    /// Sum of on-disk clip bytes in one bucket (partial caches count at their written size).
    func cachedByteCount(cameraID: String) -> UInt64 {
        list(cameraID: cameraID).reduce(0) { total, clip in
            total + cachedByteCount(cameraID: clip.cameraID, filename: clip.filename)
        }
    }

    func directory(for cameraID: String) -> URL {
        root.standardizedFileURL.appendingPathComponent(
            Self.safeBucketID(cameraID), isDirectory: true)
    }

    /// Every bucket directory currently on disk (camera serials + `local`).
    func allBucketIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { name in
            var isDirectory: ObjCBool = false
            let path = root.appendingPathComponent(name).path
            return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
                && isDirectory.boolValue
        }
    }

    func localURL(cameraID: String, filename: String) throws -> URL {
        try containedURL(in: directory(for: cameraID), basename: filename)
    }

    func thumbURL(cameraID: String, filename: String) throws -> URL {
        guard let basename = MediaClipFilename.safeCameraBasename(filename) else {
            throw MediaClipStorePathError.unsafeFilename
        }
        let stem = (basename as NSString).deletingPathExtension
        let directory = directory(for: cameraID)
            .appendingPathComponent("thumbs", isDirectory: true)
        return try containedURL(in: directory, basename: "\(stem).jpg")
    }

    private func containedURL(in directory: URL, basename: String) throws -> URL {
        guard let basename = MediaClipFilename.safeCameraBasename(basename) else {
            throw MediaClipStorePathError.unsafeFilename
        }
        let parent = directory.standardizedFileURL
        let candidate = parent.appendingPathComponent(basename).standardizedFileURL
        guard candidate.deletingLastPathComponent().path == parent.path else {
            throw MediaClipStorePathError.containmentViolation
        }
        return candidate
    }

    func hasThumbnail(cameraID: String, filename: String) -> Bool {
        guard let url = try? thumbURL(cameraID: cameraID, filename: filename) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func saveThumbnail(cameraID: String, filename: String, data: Data) throws {
        let url = try thumbURL(cameraID: cameraID, filename: filename)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    /// Camera thumbnails cached before thumbnails carried their still's orientation draw
    /// portrait stills sideways. Once per library, removes the cached thumbnail of every camera
    /// still whose row has not learned its orientation (a learned row still turns its old
    /// thumbnail upright), so the grid fetches it again through the orientation-tagging read.
    /// The library is marked done only after a complete pass: a bucket whose index cannot be read
    /// or a thumbnail that could not be removed is tried again on the next launch.
    func retireUnorientedStillThumbnails() {
        let marker = root.appendingPathComponent(Self.orientedThumbnailsMarker)
        guard !fileManager.fileExists(atPath: marker.path) else { return }
        var complete = true
        for bucket in allBucketIDs() where bucket != Self.localBucketID {
            let indexed: [MediaClip]
            do {
                indexed = try observedIndex(cameraID: bucket)
            } catch {
                complete = false
                continue
            }
            let names =
                (try? fileManager.contentsOfDirectory(atPath: directory(for: bucket).path)) ?? []
            for clip in reconciledRows(cameraID: bucket, indexed: indexed, diskNames: names).values
            where clip.mediaKind == .photo && clip.exifOrientation == nil {
                guard let thumb = try? thumbURL(cameraID: bucket, filename: clip.filename),
                    fileManager.fileExists(atPath: thumb.path)
                else { continue }
                do {
                    try fileManager.removeItem(at: thumb)
                } catch {
                    if fileManager.fileExists(atPath: thumb.path) { complete = false }
                }
            }
        }
        guard complete else { return }
        try? fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        _ = fileManager.createFile(atPath: marker.path, contents: Data())
    }

    /// Present once a library's cached thumbnails all carry their still's orientation.
    static let orientedThumbnailsMarker = ".thumbnails-oriented-v1"

    func isDownloaded(cameraID: String, filename: String) -> Bool {
        guard let url = try? localURL(cameraID: cameraID, filename: filename) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// Bytes written to the local cache for this clip (zero when not present).
    func cachedByteCount(cameraID: String, filename: String) -> UInt64 {
        guard let url = try? localURL(cameraID: cameraID, filename: filename) else { return 0 }
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        return fileSize(at: url)
    }

    /// True for playable video containers.
    static func isMediaFile(_ name: String) -> Bool {
        MediaClipFilename.isPlayableProxy(name)
    }

    /// True for still-image files cached on disk.
    static func isPhotoFile(_ name: String) -> Bool {
        MediaClipFilename.isPhoto(name)
    }

    /// True for any video or still the browser can list from disk.
    static func isBrowsableMediaFile(_ name: String) -> Bool {
        MediaClipFilename.safeCameraBasename(name) != nil
            && (isMediaFile(name) || isPhotoFile(name))
    }

    // MARK: - Listing

    /// Bucket directory names under the media root (one per camera serial or `local`).
    func listAllBucketIDs() -> [String] {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { return nil }
            return url.lastPathComponent
        }.sorted()
    }

    /// Every indexed clip across all on-device buckets — used for offline cached browsing.
    func listAllCachedClips() -> [MediaClip] {
        listAllBucketIDs().flatMap { list(cameraID: $0) }
    }

    /// All known clips for a bucket: the persisted index reconciled with the files actually on disk.
    /// Files present but not in the index are adopted as local clips (so a clip dropped into the
    /// container — e.g. a simulator sample — shows up); index entries are kept even when not yet
    /// downloaded (camera clips awaiting fetch). Sorted by filename.
    func list(cameraID: String) -> [MediaClip] {
        let listing = reconciledListing(cameraID: cameraID)
        if let sorted = listing.sorted { return sorted }
        MediaPerformanceProbe.count(.directoryListing)
        let sorted = listing.byName.values.sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
        MediaClipIndexMemo.shared.storeSorted(
            sorted, at: directory(for: cameraID).path, stamp: listing.stamp)
        return sorted
    }

    /// `list(cameraID:)` keyed by filename, without its localized sort (catalog preparation and
    /// action checks only look rows up).
    func listByName(cameraID: String) -> [String: MediaClip] {
        reconciledListing(cameraID: cameraID).byName
    }

    private func reconciledListing(cameraID: String) -> MediaClipIndexMemo.Listing {
        let dir = directory(for: cameraID)
        let stamp = indexStamp(cameraID: cameraID)
        if let cached = MediaClipIndexMemo.shared.listing(at: dir.path, stamp: stamp),
            cached.unindexed.allSatisfy({
                fileSize(at: dir.appendingPathComponent($0.key)) == $0.value
            })
        {
            return cached
        }
        let indexed = loadIndex(cameraID: cameraID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let byName = reconciledRows(cameraID: cameraID, indexed: indexed, diskNames: names)
        let indexedNames = Set(indexed.map(\.filename))
        var unindexed: [String: UInt64] = [:]
        for clip in byName.values where !indexedNames.contains(clip.filename) {
            unindexed[clip.filename] = clip.sizeBytes
        }
        let listing = MediaClipIndexMemo.Listing(
            stamp: stamp, unindexed: unindexed, byName: byName, sorted: nil)
        MediaClipIndexMemo.shared.storeListing(listing, at: dir.path)
        return listing
    }

    /// Identity of this bucket's listing inputs: the index file and the bucket directory entries.
    /// Equal stamps mean `list(cameraID:)` would read the same index and the same file names.
    func indexStamp(cameraID: String) -> MediaClipIndexStamp {
        .init(
            index: MediaClipIndexMemo.fileStamp(indexURL(cameraID: cameraID).path),
            directory: MediaClipIndexMemo.fileStamp(directory(for: cameraID).path))
    }

    private func reconciledClips(cameraID: String, indexed: [MediaClip], diskNames: [String])
        -> [MediaClip]
    {
        reconciledRows(cameraID: cameraID, indexed: indexed, diskNames: diskNames).values.sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
    }

    private func reconciledRows(cameraID: String, indexed: [MediaClip], diskNames: [String])
        -> [String: MediaClip]
    {
        var byName: [String: MediaClip] = [:]
        for clip in indexed { byName[clip.filename] = clip }

        let dir = directory(for: cameraID)
        for name in diskNames where Self.isBrowsableMediaFile(name) && byName[name] == nil {
            let size = fileSize(at: dir.appendingPathComponent(name))
            byName[name] = MediaClip(
                cameraID: cameraID, filename: name, handle: nil, storageID: nil,
                sizeBytes: size, captureDate: "")
        }
        return byName
    }

    private func fileSize(at url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Download (streaming)

    /// Opens a clip file for streaming download. Resumes at the end of a partial cache when present;
    /// otherwise creates an empty file at offset zero.
    func openForStreaming(cameraID: String, filename: String) throws -> (
        handle: FileHandle, offset: UInt64
    ) {
        let dir = directory(for: cameraID)
        let url = try localURL(cameraID: cameraID, filename: filename)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let fileHandle = try FileHandle(forUpdating: url)
            do {
                let offset = try fileHandle.seekToEnd()
                return (fileHandle, offset)
            } catch {
                try? fileHandle.close()
                throw error
            }
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return (try FileHandle(forWritingTo: url), 0)
    }

    func removeLocalFile(cameraID: String, filename: String) throws {
        try FileManager.default.removeItem(at: localURL(cameraID: cameraID, filename: filename))
    }

    /// Drops one clip row from the index entirely (deliberate deletion — unlike
    /// `applyCameraRemoval`, downloaded copies don't keep a row alive).
    func removeEntry(cameraID: String, filename: String) {
        var clips = loadIndex(cameraID: cameraID)
        clips.removeAll { $0.filename == filename }
        saveIndex(clips, cameraID: cameraID)
    }

    /// Full purge for a deliberately deleted clip: cached bytes, thumbnail, and index row.
    /// Everything `list(cameraID:)`'s disk scan could resurrect an item from goes with it.
    func purgeClip(cameraID: String, filename: String) {
        try? removeLocalFile(cameraID: cameraID, filename: filename)
        if let thumb = try? thumbURL(cameraID: cameraID, filename: filename) {
            try? FileManager.default.removeItem(at: thumb)
        }
        removeEntry(cameraID: cameraID, filename: filename)
    }

    /// Removes cached clip bytes (video files and thumbnails) for one bucket.
    ///
    /// `preservingIndex` keeps `index.json` (favorites, handles, delivery flags) for buckets
    /// whose index IS the source of truth — the local library has no camera to re-enumerate.
    /// CAMERA buckets must clear the index too (#296): preserved handles of a formatted card
    /// are exactly the thumbnail-less, unopenable ghost rows that survived every cache clear —
    /// the camera re-enumerates the truth on the next connected pass.
    ///
    /// - Returns: Bytes removed from disk (partial caches count at their written size).
    /// - Throws: `MediaClipCacheClearError` naming every file that stayed on disk, after all of
    ///   them were tried. Its byte count covers only what was actually removed.
    @MainActor @discardableResult
    func clearCache(
        cameraID: String, preservingIndex: Bool = true,
        directory: MonitorMediaCacheDirectory? = nil
    ) throws -> UInt64 {
        try Task.checkCancellation()
        let addresses = try cacheFileAddresses(
            cameraID: cameraID, includingMetadata: true,
            preservingIndex: preservingIndex)
        let cache = directory ?? MonitorMediaCacheDirectory(root: root, fileManager: fileManager)
        let result = try cache.removeFiles(addresses)
        mediaLibraryLogger.info(
            "cleared media cache for \(cameraID, privacy: .private(mask: .hash)) (\(result.removedBytes, privacy: .public) bytes removed, \(result.remainingFiles.count, privacy: .public) files remain, index \(preservingIndex ? "kept" : "cleared", privacy: .public))"
        )
        guard result.remainingFiles.isEmpty else {
            let prefix = Self.safeBucketID(cameraID) + "/"
            throw MediaClipCacheClearError(
                removedBytes: result.removedBytes,
                remainingFiles: result.remainingFiles.map { String($0.dropFirst(prefix.count)) })
        }
        return result.removedBytes
    }

    /// Only real camera buckets are cache. Local recordings and symbolic links are never selected.
    func cacheBucketIDs() throws -> [String] {
        let names: [String]
        do {
            let type =
                try fileManager.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType
            guard type == .typeDirectory else { throw MonitorMediaCacheError.invalidAddress }
            names = try fileManager.contentsOfDirectory(atPath: root.path)
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        { return [] }
        return try names.sorted().filter { name in
            try Task.checkCancellation()
            guard name != Self.localBucketID, !name.hasPrefix("."), Self.safeBucketID(name) == name
            else { return false }
            do {
                return try fileManager.attributesOfItem(
                    atPath: root.appendingPathComponent(name).path)[.type]
                    as? FileAttributeType == .typeDirectory
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
            { return false }
        }
    }

    /// Select the legacy clip readout, or the exact clip/thumbnail/index set Clear owns.
    private func cacheFileAddresses(
        cameraID: String, includingMetadata: Bool,
        preservingIndex: Bool = true
    ) throws -> [String] {
        let bucket = Self.safeBucketID(cameraID)
        let dir = directory(for: cameraID)
        let names: [String]
        do { names = try fileManager.contentsOfDirectory(atPath: dir.path) } catch let error
            as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        { return [] }
        if !includingMetadata {
            // Preserve the existing indexed-plus-disk readout, including indexed masters that
            // Clear has never owned. An index removal still makes those non-browsable files
            // absent from the legacy readout; this adoption does not expand deletion.
            let indexed = try observedIndex(cameraID: cameraID)
            return reconciledClips(cameraID: cameraID, indexed: indexed, diskNames: names)
                .compactMap { clip in
                    guard let filename = MediaClipFilename.safeCameraBasename(clip.filename) else {
                        return nil
                    }
                    return Self.safeBucketID(clip.cameraID) + "/" + filename
                }.sorted()
        }
        var selected = names.filter(Self.isBrowsableMediaFile).map { bucket + "/" + $0 }
        if includingMetadata {
            let thumbs = dir.appendingPathComponent("thumbs", isDirectory: true)
            do {
                let names = try fileManager.contentsOfDirectory(atPath: thumbs.path)
                selected += names.map { bucket + "/thumbs/" + $0 }
            } catch let error as CocoaError
                where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
            {}
            if !preservingIndex { selected.append(bucket + "/index.json") }
        }
        return selected.sorted()
    }

    /// Enumeration and the shared file-stat read run off the main actor; caller cancellation owns both.
    func cameraCacheReadAddresses() async throws -> [String] {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .utility) {
            var addresses: [String] = []
            for bucket in try cacheBucketIDs() {
                try Task.checkCancellation()
                addresses += try cacheFileAddresses(cameraID: bucket, includingMetadata: false)
            }
            return addresses
        }
        return try await withTaskCancellationHandler {
            let addresses = try await worker.value
            try Task.checkCancellation()
            return addresses
        } onCancel: {
            worker.cancel()
        }
    }

    // MARK: - Index persistence

    /// Sort rank for choosing a row's primary location: real slot words first, slot 1 before
    /// slot 2, stable on ties.
    static func locationRank(_ location: MediaObjectHandle) -> (UInt32, UInt32) {
        let slot = (location.storageID >> 16) & 0xFF
        return (slot > 0 ? slot : 0xFF, location.storageID)
    }

    /// Merges camera-discovered fields into an existing index entry, preserving operator flags.
    /// Backup mode surfaces one shot as an object per card sharing the filename — the
    /// locations union instead of the newest discovery clobbering the row's identity.
    static func mergeCameraDiscovery(existing: MediaClip, incoming: MediaClip) -> MediaClip {
        var merged = existing
        var locations = existing.allLocations
        for location in incoming.allLocations where !locations.contains(location) {
            locations.append(location)
        }
        if let primary = locations.min(by: { locationRank($0) < locationRank($1) }) {
            merged.handle = primary.handle
            merged.storageID = primary.storageID
            merged.storageLocations = locations
        } else {
            merged.handle = incoming.handle
            merged.storageID = incoming.storageID
        }
        merged.sizeBytes = incoming.sizeBytes
        merged.captureDate = incoming.captureDate
        merged.pixelWidth = incoming.pixelWidth
        merged.pixelHeight = incoming.pixelHeight
        if incoming.sourcePixelWidth != nil {
            merged.sourcePixelWidth = incoming.sourcePixelWidth
        }
        if incoming.sourcePixelHeight != nil {
            merged.sourcePixelHeight = incoming.sourcePixelHeight
        }
        if incoming.linkedR3DFilename != nil {
            merged.linkedR3DFilename = incoming.linkedR3DFilename
        }
        return merged
    }

    /// Merges camera-discovered records into the index, preserving existing per-clip flags
    /// (favorite / upload / export) by only overwriting the camera-sourced fields.
    func upsert(_ clips: [MediaClip], cameraID: String) {
        upsertBatch(clips, cameraID: cameraID)
    }

    /// Batch variant of `upsert` — reads and writes `index.json` once for the whole batch.
    func upsertBatch(_ clips: [MediaClip], cameraID: String) {
        let clips = clips.filter { MediaClipFilename.safeCameraBasename($0.filename) != nil }
        guard !clips.isEmpty else { return }
        var byName: [String: MediaClip] = [:]
        for clip in loadIndex(cameraID: cameraID) { byName[clip.filename] = clip }
        for incoming in clips {
            if let existing = byName[incoming.filename] {
                byName[incoming.filename] = Self.mergeCameraDiscovery(
                    existing: existing, incoming: incoming)
            } else {
                byName[incoming.filename] = incoming
            }
        }
        saveIndex(Array(byName.values), cameraID: cameraID)
    }

    /// Mutates one clip's metadata in the index, adopting it from disk first if it isn't indexed yet.
    func update(cameraID: String, filename: String, _ mutate: (inout MediaClip) -> Void) {
        guard MediaClipFilename.safeCameraBasename(filename) != nil else { return }
        var clips = loadIndex(cameraID: cameraID)
        if let idx = clips.firstIndex(where: { $0.filename == filename }) {
            mutate(&clips[idx])
        } else {
            var clip =
                list(cameraID: cameraID).first { $0.filename == filename }
                ?? MediaClip(
                    cameraID: cameraID, filename: filename, handle: nil, storageID: nil,
                    sizeBytes: 0, captureDate: "")
            mutate(&clip)
            clips.append(clip)
        }
        saveIndex(clips, cameraID: cameraID)
    }

    private func indexURL(cameraID: String) -> URL {
        directory(for: cameraID).appendingPathComponent("index.json")
    }

    /// Exact catalog-byte access for the shared library owner. Paths and JSON schema stay local.
    func catalogBytes(cameraID: String) throws -> Data? {
        let url = indexURL(cameraID: cameraID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeCatalogBytes(_ bytes: Data, cameraID: String, ifCurrent: () -> Bool) throws {
        let dir = directory(for: cameraID)
        guard ifCurrent() else { throw MediaServiceError.retired }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard ifCurrent() else { throw MediaServiceError.retired }
        try bytes.write(to: indexURL(cameraID: cameraID), options: .atomic)
        MediaClipIndexMemo.shared.invalidate(directory: dir.path)
    }

    static func decodeCatalogBytes(_ bytes: Data) throws -> [MediaClip] {
        if let decoded = MediaClipIndexMemo.shared.decoded(bytes) { return decoded }
        MediaPerformanceProbe.count(.indexDecode)
        let clips = try JSONDecoder().decode([MediaClip].self, from: bytes).filter {
            MediaClipFilename.safeCameraBasename($0.filename) != nil
        }
        MediaClipIndexMemo.shared.rememberDecoded(clips, for: bytes)
        return clips
    }

    static func encodeCatalogBytes(_ clips: [MediaClip]) throws -> Data {
        let bytes = try JSONEncoder().encode(clips)
        // MediaClip's Codable form round-trips exactly, so the next read of these bytes (the
        // following checkpoint's current index) needs no decode.
        MediaClipIndexMemo.shared.rememberDecoded(
            clips.filter { MediaClipFilename.safeCameraBasename($0.filename) != nil }, for: bytes)
        return bytes
    }

    private func loadIndex(cameraID: String) -> [MediaClip] {
        let url = indexURL(cameraID: cameraID)
        // The stamp is read before the bytes: a replacement in between only costs a later decode.
        guard let stamp = MediaClipIndexMemo.fileStamp(url.path) else { return [] }
        if let cached = MediaClipIndexMemo.shared.index(at: url.path, stamp: stamp) {
            return cached
        }
        guard let data = try? Data(contentsOf: url) else { return [] }
        guard let clips = try? Self.decodeCatalogBytes(data) else { return [] }
        MediaClipIndexMemo.shared.storeIndex(clips, at: url.path, stamp: stamp)
        return clips
    }

    /// Settings observes the same catalog as listing, but an unreadable or malformed index is unknown.
    /// A missing index alone permits the existing browsable-disk fallback.
    private func observedIndex(cameraID: String) throws -> [MediaClip] {
        let location = indexURL(cameraID: cameraID)
        do {
            guard
                try fileManager.attributesOfItem(atPath: location.path)[.type] as? FileAttributeType
                    == .typeRegular
            else {
                throw MonitorMediaCacheError.invalidAddress
            }
            return try Self.decodeCatalogBytes(Data(contentsOf: location))
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile
        { return [] }
    }

    private func saveIndex(_ clips: [MediaClip], cameraID: String) {
        let dir = directory(for: cameraID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? Self.encodeCatalogBytes(clips) else {
            mediaLibraryLogger.error(
                "failed to encode media index for \(cameraID, privacy: .private(mask: .hash))")
            return
        }
        try? data.write(to: indexURL(cameraID: cameraID), options: .atomic)
        MediaClipIndexMemo.shared.invalidate(directory: dir.path)
    }

    /// Applies delta-sync removals: drops camera-only index rows whose handles disappeared, and
    /// clears handle references for clips that remain downloaded on disk.
    ///
    /// - Returns: Filenames removed entirely from the index.
    func applyCameraRemoval(
        cameraID: String,
        removedHandles: Set<MediaObjectHandle>,
        hasLocalFile: (MediaClip) -> Bool
    ) -> Set<String> {
        guard !removedHandles.isEmpty else { return [] }
        var clips = loadIndex(cameraID: cameraID)
        var removedFilenames = Set<String>()
        var shrunkCount = 0
        clips = clips.compactMap { clip in
            let locations = clip.allLocations
            let survivors: [MediaObjectHandle]
            if locations.isEmpty {
                // Legacy row (handle without a storage) — match by bare handle.
                guard let bare = clip.handle,
                    removedHandles.contains(where: { $0.handle == bare })
                else { return clip }
                survivors = []
            } else {
                survivors = locations.filter { !removedHandles.contains($0) }
                if survivors.count == locations.count { return clip }
            }
            if let primary = survivors.min(by: { Self.locationRank($0) < Self.locationRank($1) }) {
                // One card's copy vanished (e.g. deleted in-camera) — the row lives on the rest.
                var updated = clip
                updated.handle = primary.handle
                updated.storageID = primary.storageID
                updated.storageLocations = survivors
                shrunkCount += 1
                return updated
            }
            if hasLocalFile(clip) {
                var updated = clip
                updated.handle = nil
                updated.storageID = nil
                updated.storageLocations = nil
                shrunkCount += 1
                return updated
            }
            removedFilenames.insert(clip.filename)
            return nil
        }
        saveIndex(clips, cameraID: cameraID)
        mediaLibraryLogger.info(
            "delta sync removed \(removedFilenames.count, privacy: .public) index row(s), shrank \(shrunkCount, privacy: .public) row(s) for \(cameraID, privacy: .private(mask: .hash))"
        )
        return removedFilenames
    }
}

/// The real native-session/cache seam for one bounded progressive Nikon object transfer.
/// Range math stays in the shared cursor; the host keeps transfer ownership and cancellation.
@MainActor enum NikonMediaObjectTransfer {
    static func stream(
        session: NativeCameraSession, handle: UInt32, totalBytes: UInt64,
        store: MediaClipStore, cameraID: String, filename: String,
        onProgress: (UInt64) -> Void
    ) async throws -> UInt64 {
        guard totalBytes > 0, totalBytes != UInt64(UInt32.max) else {
            throw PTPObjectTransferError.unresolvedObjectSize(reportedBytes: totalBytes)
        }
        // Keep one Wi-Fi transaction below the live-view deadline; USB keeps the original 4 MiB.
        let chunk: UInt64 = session.transportKind == .usb ? 4 << 20 : 1 << 20
        let supportsExtended = session.operationPolicy.supports(.getPartialObjectEx)
        // Refuse unsupported large objects before creating or opening any cache file.
        _ = try PTPObjectTransferCursor(
            objectHandle: handle, totalBytes: totalBytes, chunkSize: chunk,
            supportsExtendedReads: supportsExtended)
        try Task.checkCancellation()
        let (file, resumeOffset) = try store.openForStreaming(
            cameraID: cameraID, filename: filename)
        defer { try? file.close() }
        var cursor = try PTPObjectTransferCursor(
            objectHandle: handle, totalBytes: totalBytes, resumeOffset: resumeOffset,
            chunkSize: chunk, supportsExtendedReads: supportsExtended)
        onProgress(cursor.offset)
        while let request = try cursor.nextRequest() {
            try Task.checkCancellation()
            let data = try await session.getPartialObject(request)
            try Task.checkCancellation()
            var next = cursor
            try next.advance(by: UInt64(data.count))
            try file.write(contentsOf: data)
            cursor = next
            onProgress(cursor.offset)
        }
        return cursor.offset
    }
}

/// Listing inputs of one bucket; see `MediaClipStore.indexStamp(cameraID:)`.
struct MediaClipIndexStamp: Equatable, Sendable {
    let index: MediaClipIndexMemo.FileStamp?
    let directory: MediaClipIndexMemo.FileStamp?
}

/// Process-wide memo of decoded `index.json` files and reconciled bucket listings. Every read
/// validates against the file system (file number, size and modification date of the index and
/// of the bucket directory), so a write by any store, process or test is always seen; the store's
/// own writes also drop the entry. A 3,200-row index costs a JSON decode, a directory listing and
/// a localized sort per read, and the gallery, listing, playback and delivery checks read it far
/// more often than it changes (owner report 2026-10-25, build 304).
final class MediaClipIndexMemo: @unchecked Sendable {
    struct FileStamp: Equatable, Sendable {
        let fileNumber: UInt64
        let size: UInt64
        let modified: Date
    }
    struct Listing {
        let stamp: MediaClipIndexStamp
        let unindexed: [String: UInt64]
        let byName: [String: MediaClip]
        var sorted: [MediaClip]?
    }
    static let shared = MediaClipIndexMemo()
    private let lock = NSLock()
    private var indexes: [String: (stamp: FileStamp, clips: [MediaClip])] = [:]
    private var listings: [String: Listing] = [:]
    private var recentDecodes: [(bytes: Data, clips: [MediaClip])] = []
    private var writes: UInt64 = 0
    /// Advances with every write this process makes to an index (each drops its memo entry).
    var writeGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return writes
    }

    static func fileStamp(_ path: String) -> FileStamp? {
        MediaPerformanceProbe.count(.fileStamp)
        guard let facts = MediaFileFacts.read(path, followingLinks: false) else { return nil }
        return .init(fileNumber: facts.fileNumber, size: facts.size, modified: facts.modified)
    }
    func index(at path: String, stamp: FileStamp) -> [MediaClip]? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = indexes[path], entry.stamp == stamp else { return nil }
        return entry.clips
    }
    func storeIndex(_ clips: [MediaClip], at path: String, stamp: FileStamp) {
        lock.lock()
        indexes[path] = (stamp, clips)
        lock.unlock()
    }
    func listing(at directory: String, stamp: MediaClipIndexStamp) -> Listing? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = listings[directory], entry.stamp == stamp else { return nil }
        return entry
    }
    func storeListing(_ listing: Listing, at directory: String) {
        lock.lock()
        listings[directory] = listing
        lock.unlock()
    }
    func storeSorted(_ sorted: [MediaClip], at directory: String, stamp: MediaClipIndexStamp) {
        lock.lock()
        if listings[directory]?.stamp == stamp { listings[directory]?.sorted = sorted }
        lock.unlock()
    }
    func invalidate(directory: String) {
        lock.lock()
        writes &+= 1
        listings[directory] = nil
        indexes = indexes.filter { !$0.key.hasPrefix(directory + "/") }
        lock.unlock()
    }
    /// The last few exact byte strings this process encoded or decoded.
    func decoded(_ bytes: Data) -> [MediaClip]? {
        lock.lock()
        defer { lock.unlock() }
        return recentDecodes.first { $0.bytes == bytes }?.clips
    }
    func rememberDecoded(_ clips: [MediaClip], for bytes: Data) {
        lock.lock()
        recentDecodes.removeAll { $0.bytes == bytes }
        recentDecodes.insert((bytes, clips), at: 0)
        if recentDecodes.count > 4 { recentDecodes.removeLast(recentDecodes.count - 4) }
        lock.unlock()
    }
}
