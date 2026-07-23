import Foundation
import os

/// Media library diagnostics (Media page cache). Filter Console for subsystem `OpenZCine`, category
/// `media-store`.
let mediaLibraryLogger = Logger(subsystem: "OpenZCine", category: "media-store")

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
    /// Object handle on the camera — present when discovered on the card, nil for local-only clips.
    var handle: UInt32?
    /// Owning storage volume on the camera (nil for local-only clips).
    var storageID: UInt32?
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
    var frameioStatus: FrameioStatus = .notUploaded
    /// Remote Frame.io file id after a successful upload (prevents duplicate uploads).
    var frameioFileID: String?
    var exportStatus: ExportStatus = .none

    var id: String { "\(cameraID)/\(filename)" }

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

    var systemImage: String {
        switch self {
        case .all: "square.grid.2x2"
        case .videos: "film.stack"
        case .photos: "photo.on.rectangle.angled"
        case .favorites: "star"
        }
    }
}

/// Primary layout for the Media browser main column.
enum MediaBrowserLayout: String, CaseIterable, Codable, Sendable, Identifiable {
    case grid
    case list

    var id: String { rawValue }

    var toggleIcon: String {
        switch self {
        case .grid: "list.bullet"
        case .list: "square.grid.2x2"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .grid: "List view"
        case .list: "Grid view"
        }
    }
}

/// Persisted clip ordering for the Media browser grid.
enum MediaSortOrder: String, CaseIterable, Codable, Sendable {
    case newest
    case oldest
    case name

    var menuLabel: String {
        switch self {
        case .newest: "Newest"
        case .oldest: "Oldest"
        case .name: "Name"
        }
    }

    var pillLabel: String { "SORT" }

    var next: MediaSortOrder {
        switch self {
        case .newest: .oldest
        case .oldest: .name
        case .name: .newest
        }
    }
}

/// File-type chip filters (MOV / MP4).
enum MediaFormatFilter: String, CaseIterable, Sendable {
    case mov = "MOV"
    case mp4 = "MP4"

    func matches(_ clip: MediaClip) -> Bool {
        switch self {
        case .mov: ["mov", "m4v"].contains(clip.fileExtension)
        case .mp4: clip.fileExtension == "mp4"
        }
    }
}

extension MediaClip {
    /// Inferred from filename — videos are playable proxies; stills use `MediaClipFilename.isPhoto`.
    var mediaKind: MediaKind {
        MediaClipFilename.isPhoto(filename) ? .photo : .video
    }

    /// Best-effort resolution bucket: R3D source dimensions when linked, else proxy pixels, then filename.
    var resolutionBucket: MediaResolutionBucket? {
        MediaResolutionBucket.classify(
            filename: filename,
            pixelWidth: pixelWidth,
            sourcePixelWidth: sourcePixelWidth)
    }

    /// Whether the PTP capture date falls on the device's current calendar day.
    var isCapturedToday: Bool {
        MediaClipFormatting.isCapturedToday(captureDate)
    }

    /// True for Nikon RAW stills (`.NEF` / `.NRW` / `.DNG`) — the tag-along side of a RAW+JPEG pair.
    var isRawPhoto: Bool {
        ["nef", "nrw", "dng"].contains(fileExtension)
    }

    /// True for JPEG stills — the display side of a RAW+JPEG pair (NEF has no quicklook-decodable
    /// full preview, so the JPEG carries the grid cell and opens the viewer).
    var isJPEGPhoto: Bool {
        ["jpg", "jpeg", "jpe"].contains(fileExtension)
    }

    /// Same-shot pair identity: bucket + storage slot + case-insensitive stem. The slot is part of
    /// the key on purpose — split recording writes RAW and JPEG to different cards, and those must
    /// stay separate items.
    var rawPairKey: String {
        "\(cameraID)/\(storageID.map(String.init) ?? "-")/\(MediaClipFilename.stem(of: filename))"
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

enum MediaClipFormatting {
    private static let ptpDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        return formatter
    }()

    static func isCapturedToday(_ captureDate: String) -> Bool {
        guard captureDate.count >= 8 else { return false }
        let dayToken = String(captureDate.prefix(8))
        guard let date = ptpDayFormatter.date(from: dayToken) else { return false }
        return Calendar.current.isDateInToday(date)
    }

    static func byteLabel(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "0 B" }
        let mb = Double(bytes) / 1_000_000
        if mb < 1_000 { return String(format: "%.0fMB", mb) }
        return String(format: "%.1fGB", mb / 1_000)
    }

    static func durationLabel(seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        if total >= 3_600 {
            return String(format: "%d:%02d:%02d", total / 3_600, (total % 3_600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Counts active chip/sheet filters for the Media browser badge (excludes category tabs).
enum MediaBrowserFilterMetrics {
    static func activeCount(
        formatFilters: Set<MediaFormatFilter>,
        resolutionFilters: Set<MediaResolutionBucket>,
        todayOnly: Bool,
        storageSlotFilter: UInt32?
    ) -> Int {
        formatFilters.count + resolutionFilters.count + (todayOnly ? 1 : 0)
            + (storageSlotFilter != nil ? 1 : 0)
    }
}

enum MediaClipSorting {
    static func sort(_ clips: [MediaClip], order: MediaSortOrder) -> [MediaClip] {
        switch order {
        case .newest:
            return clips.sorted { lhs, rhs in
                let lk = sortKey(lhs)
                let rk = sortKey(rhs)
                if lk != rk { return lk > rk }
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
                    == .orderedDescending
            }
        case .oldest:
            return clips.sorted { lhs, rhs in
                let lk = sortKey(lhs)
                let rk = sortKey(rhs)
                if lk != rk { return lk < rk }
                return lhs.filename.localizedCaseInsensitiveCompare(rhs.filename)
                    == .orderedAscending
            }
        case .name:
            return clips.sorted {
                $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
            }
        }
    }

    private static func sortKey(_ clip: MediaClip) -> String {
        clip.captureDate.isEmpty ? clip.filename : clip.captureDate
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

/// On-disk cache for camera clips, mirroring `LUTFileStore`. Files live under
/// `Documents/media/{cameraID}/`; a sibling `index.json` holds metadata not derivable from the
/// files (favorites, camera handles, upload/export status). Clip bytes are streamed to a
/// `FileHandle` during download — never buffered whole.
struct MediaClipStore {
    /// Root of the per-camera bucket directories, `<documents>/media`.
    let root: URL

    init(root: URL? = nil) {
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
        var byName: [String: MediaClip] = [:]
        for clip in loadIndex(cameraID: cameraID) { byName[clip.filename] = clip }

        let dir = directory(for: cameraID)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where Self.isBrowsableMediaFile(name) && byName[name] == nil {
            let size = fileSize(at: dir.appendingPathComponent(name))
            byName[name] = MediaClip(
                cameraID: cameraID, filename: name, handle: nil, storageID: nil,
                sizeBytes: size, captureDate: "")
        }
        return byName.values.sorted {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }
    }

    private func fileSize(at url: URL) -> UInt64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // MARK: - Download (streaming)

    /// Opens a clip file for streaming download. Resumes at the end of a partial cache when present;
    /// otherwise creates an empty file at offset zero.
    func openForStreaming(cameraID: String, filename: String) throws -> (
        handle: FileHandle, offset: UInt32
    ) {
        let dir = directory(for: cameraID)
        let url = try localURL(cameraID: cameraID, filename: filename)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            let size = fileSize(at: url)
            let fileHandle = try FileHandle(forUpdating: url)
            try fileHandle.seekToEnd()
            let offset = UInt32(min(size, UInt64(UInt32.max)))
            return (fileHandle, offset)
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

    /// Removes cached clip bytes (video files and thumbnails) for one bucket while preserving
    /// `index.json` metadata so favorites, camera handles, and delivery flags survive for re-fetch.
    ///
    /// - Returns: Bytes removed from disk (partial caches count at their written size).
    @discardableResult
    func clearCache(cameraID: String) -> UInt64 {
        let dir = directory(for: cameraID)
        let fm = FileManager.default
        var removedBytes: UInt64 = 0

        let names = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        for name in names where Self.isBrowsableMediaFile(name) {
            let url = dir.appendingPathComponent(name)
            removedBytes += fileSize(at: url)
            try? fm.removeItem(at: url)
        }

        let thumbsDir = dir.appendingPathComponent("thumbs", isDirectory: true)
        let thumbNames = (try? fm.contentsOfDirectory(atPath: thumbsDir.path)) ?? []
        for name in thumbNames {
            let url = thumbsDir.appendingPathComponent(name)
            removedBytes += fileSize(at: url)
            try? fm.removeItem(at: url)
        }

        mediaLibraryLogger.info(
            "cleared media cache for \(cameraID, privacy: .private(mask: .hash)) (\(removedBytes, privacy: .public) bytes removed)"
        )
        return removedBytes
    }

    // MARK: - Index persistence

    /// Merges camera-discovered fields into an existing index entry, preserving operator flags.
    static func mergeCameraDiscovery(existing: MediaClip, incoming: MediaClip) -> MediaClip {
        var merged = existing
        merged.handle = incoming.handle
        merged.storageID = incoming.storageID
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

    private func loadIndex(cameraID: String) -> [MediaClip] {
        guard let data = try? Data(contentsOf: indexURL(cameraID: cameraID)),
            let clips = try? JSONDecoder().decode([MediaClip].self, from: data)
        else { return [] }
        return clips.filter { MediaClipFilename.safeCameraBasename($0.filename) != nil }
    }

    private func saveIndex(_ clips: [MediaClip], cameraID: String) {
        let dir = directory(for: cameraID)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(clips) else {
            mediaLibraryLogger.error(
                "failed to encode media index for \(cameraID, privacy: .private(mask: .hash))")
            return
        }
        try? data.write(to: indexURL(cameraID: cameraID), options: .atomic)
    }

    /// Applies delta-sync removals: drops camera-only index rows whose handles disappeared, and
    /// clears handle references for clips that remain downloaded on disk.
    ///
    /// - Returns: Filenames removed entirely from the index.
    func applyCameraRemoval(
        cameraID: String,
        removedHandles: Set<UInt32>,
        hasLocalFile: (MediaClip) -> Bool
    ) -> Set<String> {
        guard !removedHandles.isEmpty else { return [] }
        var clips = loadIndex(cameraID: cameraID)
        var removedFilenames = Set<String>()
        clips = clips.compactMap { clip in
            guard let handle = clip.handle, removedHandles.contains(handle) else { return clip }
            if hasLocalFile(clip) {
                var updated = clip
                updated.handle = nil
                updated.storageID = nil
                return updated
            }
            removedFilenames.insert(clip.filename)
            return nil
        }
        saveIndex(clips, cameraID: cameraID)
        mediaLibraryLogger.info(
            "delta sync removed \(removedFilenames.count, privacy: .public) index row(s), cleared \(removedHandles.count - removedFilenames.count, privacy: .public) local handle(s) for \(cameraID, privacy: .private(mask: .hash))"
        )
        return removedFilenames
    }
}
