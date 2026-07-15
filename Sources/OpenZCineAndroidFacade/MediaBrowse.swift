// Media browsing for the Android facade — the browse half of the Media page
// (Kaneo OPE-34 / issue #77 v1 slice; playback via partial-object reads is a
// separate slice).
//
// Mirrors the iOS shell's PTP media path (`NativeCameraSession`): usable
// storage IDs (`GetVendorStorageIDs` 0x9209 plus `GetStorageIDs` 0x1004) →
// `GetObjectHandles` 0x1007 → per-object `GetObjectInfo` 0x1008,
// decoded by the core's `PTPObjectInfo`, plus `GetThumb` 0x100A for the
// embedded thumbnail JPEGs. Like the zone-map wire, this file compiles on
// every platform so `swift test` exercises it against the fake ZR; only the
// `@_cdecl` shims in SwiftCoreJNI.swift are Android-only.

import Foundation
import OpenZCineCore

/// One browsable media object (clip or still) flattened for the JNI seam.
public struct FacadeMediaClip: Equatable, Sendable {
    public let handle: UInt32
    public let storageID: UInt32
    /// Resolved on-card size in bytes, including Nikon's 64-bit size path.
    public let sizeBytes: UInt64
    /// PTP date-time string (`YYYYMMDDThhmmss`); empty when the camera omits it.
    public let captureDate: String
    /// Full-image pixel size (0 when the camera omits it).
    public let pixelWidth: UInt32
    public let pixelHeight: UInt32
    /// Pixel size of a same-stem R3D master represented by this playable proxy.
    /// Nil for unpaired proxies and non-proxy objects.
    public let sourcePixelWidth: UInt32?
    public let sourcePixelHeight: UInt32?
    /// Sanitized on-card filename (`MediaClipFilename.safeCameraBasename`).
    public let filename: String
    /// Shared-core browser action and still-preview policy for this object.
    public let contentClassification: MediaContentClassification
    /// True only for the proxy formats Android can stream (MOV/MP4/M4V).
    public let isPlayableProxy: Bool

    /// Creates a facade record with the shared-core media classification.
    ///
    /// The facade never lets an Android caller supply a local filename policy:
    /// the portable core derives both this record's action and its still-preview
    /// strategy from the sanitized camera filename.
    public init(
        handle: UInt32,
        storageID: UInt32,
        sizeBytes: UInt64,
        captureDate: String,
        pixelWidth: UInt32,
        pixelHeight: UInt32,
        sourcePixelWidth: UInt32? = nil,
        sourcePixelHeight: UInt32? = nil,
        filename: String
    ) {
        let contentClassification = MediaClipFilename.mediaClassification(for: filename)
        self.handle = handle
        self.storageID = storageID
        self.sizeBytes = sizeBytes
        self.captureDate = captureDate
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.sourcePixelWidth = sourcePixelWidth
        self.sourcePixelHeight = sourcePixelHeight
        self.filename = filename
        self.contentClassification = contentClassification
        isPlayableProxy = contentClassification.kind == .playableProxy
    }
}

extension FacadeMediaClip {
    fileprivate func withSourceDimensions(width: UInt32, height: UInt32) -> FacadeMediaClip {
        FacadeMediaClip(
            handle: handle,
            storageID: storageID,
            sizeBytes: sizeBytes,
            captureDate: captureDate,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            sourcePixelWidth: width,
            sourcePixelHeight: height,
            filename: filename)
    }
}

/// Stable persisted identity for one media clip removed by a later page.
public struct FacadeMediaClipIdentity: Equatable, Sendable {
    public let handle: UInt32
    public let storageID: UInt32
    public let captureDate: String
    public let filename: String

    /// Captures the fields Android uses to distinguish reused PTP handles.
    public init(_ clip: FacadeMediaClip) {
        handle = clip.handle
        storageID = clip.storageID
        captureDate = clip.captureDate
        filename = clip.filename
    }
}

/// One bounded increment from an Android camera-media enumeration cursor.
public struct FacadeMediaBrowsePage: Equatable, Sendable {
    /// Newly discovered records. A record is emitted exactly once per cursor.
    public let clips: [FacadeMediaClip]
    /// Previously emitted R3D masters hidden by a proxy discovered on this page.
    public let removedObjects: [FacadeMediaClipIdentity]
    /// Number of `GetObjectInfo` round trips consumed by this page.
    public let inspectedObjectCount: Int
    /// True while another bounded page is available.
    public let hasMore: Bool

    /// Creates one page after a bounded cursor advance.
    public init(
        clips: [FacadeMediaClip],
        removedObjects: [FacadeMediaClipIdentity] = [],
        inspectedObjectCount: Int,
        hasMore: Bool
    ) {
        self.clips = clips
        self.removedObjects = removedObjects
        self.inspectedObjectCount = inspectedObjectCount
        self.hasMore = hasMore
    }
}

/// Typed failures from one Android camera-media enumeration cursor.
public enum FacadeMediaBrowseCursorError: LocalizedError, Equatable {
    case cancelled
    case invalidPageSize(Int)

    /// Operator-safe description of the rejected cursor operation.
    public var errorDescription: String? {
        switch self {
        case .cancelled:
            "The camera media listing was cancelled."
        case .invalidPageSize(let size):
            "Camera media page size \(size) is outside the supported range."
        }
    }
}

/// One card's stable handle snapshot, retained only for the lifetime of a browse cursor.
struct MediaBrowseStorageSnapshot: Sendable {
    let storageID: UInt32
    let handles: [UInt32]
}

/// Cancellation-aware incremental enumeration over every usable camera card.
///
/// Handle arrays are snapshotted once, then consumed newest-first and round-robin
/// across cards. Every call is capped to `supportedPageSizes`, which gives the
/// Android collector a cancellation and UI-update point without letting a packed
/// first card hide newer media on a second card. Page deltas preserve the shared
/// core's R3D pairing policy when a matching proxy arrives on a later page or
/// another card, while still publishing unpaired masters incrementally like iOS.
public final class FacadeMediaBrowseCursor: @unchecked Sendable {
    /// Hard safety bound for a single cursor advance.
    public static let supportedPageSizes: ClosedRange<Int> = 1...128

    typealias ClipFetcher = (MediaObjectHandle) -> FacadeMediaClip?

    private let pageLock = NSLock()
    private let cancellationLock = NSLock()
    private let snapshots: [MediaBrowseStorageSnapshot]
    private let fetchClip: ClipFetcher
    private var positions: [Int]
    private var nextStorageIndex = 0
    private var discoveredProxyStems: Set<String> = []
    private struct VisibleR3DMaster {
        let identity: FacadeMediaClipIdentity
        let width: UInt32
        let height: UInt32
    }

    private var visibleMastersByStem: [String: [VisibleR3DMaster]] = [:]
    private var visibleProxiesByStem: [String: FacadeMediaClip] = [:]
    private var pendingChanges: [MediaBrowseChange] = []
    private var nextPendingChangeIndex = 0
    private var cancelled = false
    private var finished = false

    private enum MediaBrowseChange {
        case add(FacadeMediaClip)
        case remove(FacadeMediaClipIdentity)
    }

    init(
        snapshots: [MediaBrowseStorageSnapshot],
        fetchClip: @escaping ClipFetcher
    ) {
        self.snapshots = snapshots
        self.fetchClip = fetchClip
        positions = snapshots.map { $0.handles.count - 1 }
    }

    /// Stops this cursor. An in-flight object transaction finishes, then the
    /// next cancellation check prevents any further camera command or result.
    public func cancel() {
        cancellationLock.lock()
        cancelled = true
        cancellationLock.unlock()
    }

    /// Advances by at most `maxObjects` metadata commands and records.
    public func nextPage(maxObjects: Int) throws -> FacadeMediaBrowsePage {
        guard Self.supportedPageSizes.contains(maxObjects) else {
            throw FacadeMediaBrowseCursorError.invalidPageSize(maxObjects)
        }

        pageLock.lock()
        defer { pageLock.unlock() }
        try checkCancellation()
        guard !finished else {
            return FacadeMediaBrowsePage(
                clips: [], removedObjects: [], inspectedObjectCount: 0, hasMore: false)
        }

        var clips: [FacadeMediaClip] = []
        var removedObjects: [FacadeMediaClipIdentity] = []
        var inspectedObjectCount = 0
        while clips.count + removedObjects.count < maxObjects {
            drainPendingChanges(
                clips: &clips, removedObjects: &removedObjects, limit: maxObjects)
            guard clips.count + removedObjects.count < maxObjects,
                inspectedObjectCount < maxObjects,
                let object = nextObject()
            else { break }

            try checkCancellation()
            inspectedObjectCount += 1
            let clip = fetchClip(object)
            try checkCancellation()
            guard let clip else { continue }

            switch clip.contentClassification.kind {
            case .r3dMaster:
                let stem = MediaClipFilename.stem(of: clip.filename)
                if let proxy = visibleProxiesByStem[stem], clip.pixelWidth > 0,
                    clip.pixelHeight > 0
                {
                    let linked = proxy.withSourceDimensions(
                        width: clip.pixelWidth, height: clip.pixelHeight)
                    visibleProxiesByStem[stem] = linked
                    pendingChanges.append(.add(linked))
                } else if !discoveredProxyStems.contains(stem) {
                    visibleMastersByStem[stem, default: []].append(
                        VisibleR3DMaster(
                            identity: FacadeMediaClipIdentity(clip),
                            width: clip.pixelWidth,
                            height: clip.pixelHeight))
                    pendingChanges.append(.add(clip))
                }
            case .playableProxy:
                let stem = MediaClipFilename.stem(of: clip.filename)
                discoveredProxyStems.insert(stem)
                let pairedMasters = visibleMastersByStem.removeValue(forKey: stem) ?? []
                let source = pairedMasters.first { $0.width > 0 && $0.height > 0 }
                let linked =
                    source.map {
                        clip.withSourceDimensions(width: $0.width, height: $0.height)
                    } ?? clip
                visibleProxiesByStem[stem] = linked
                pendingChanges.append(
                    contentsOf: pairedMasters.map {
                        .remove($0.identity)
                    })
                pendingChanges.append(.add(linked))
            case .stillPhoto:
                pendingChanges.append(.add(clip))
            case .unsupported:
                continue
            }
        }

        let hasMore = hasRemainingObjects || hasPendingChanges
        if !hasMore {
            finished = true
            visibleMastersByStem.removeAll(keepingCapacity: false)
            visibleProxiesByStem.removeAll(keepingCapacity: false)
        }
        return FacadeMediaBrowsePage(
            clips: clips,
            removedObjects: removedObjects,
            inspectedObjectCount: inspectedObjectCount,
            hasMore: hasMore)
    }

    private var hasRemainingObjects: Bool {
        positions.contains(where: { $0 >= 0 })
    }

    private var hasPendingChanges: Bool {
        nextPendingChangeIndex < pendingChanges.count
    }

    private func nextObject() -> MediaObjectHandle? {
        guard !snapshots.isEmpty else { return nil }
        for _ in snapshots.indices {
            let index = nextStorageIndex
            nextStorageIndex = (nextStorageIndex + 1) % snapshots.count
            guard positions[index] >= 0 else { continue }
            let handle = snapshots[index].handles[positions[index]]
            positions[index] -= 1
            return MediaObjectHandle(storageID: snapshots[index].storageID, handle: handle)
        }
        return nil
    }

    private func drainPendingChanges(
        clips: inout [FacadeMediaClip],
        removedObjects: inout [FacadeMediaClipIdentity],
        limit: Int
    ) {
        while clips.count + removedObjects.count < limit,
            nextPendingChangeIndex < pendingChanges.count
        {
            switch pendingChanges[nextPendingChangeIndex] {
            case .add(let clip):
                clips.append(clip)
            case .remove(let object):
                removedObjects.append(object)
            }
            nextPendingChangeIndex += 1
        }
        if nextPendingChangeIndex == pendingChanges.count {
            pendingChanges.removeAll(keepingCapacity: true)
            nextPendingChangeIndex = 0
        }
    }

    private func checkCancellation() throws {
        cancellationLock.lock()
        let isCancelled = cancelled
        cancellationLock.unlock()
        if isCancelled { throw FacadeMediaBrowseCursorError.cancelled }
    }
}

extension PTPIPClientSession {
    /// Reads the first camera storage slot that reports valid capacity data.
    ///
    /// This mirrors the iOS monitor policy: Nikon's standard storage-ID list
    /// may contain placeholder slot values, so valid IDs are gathered through
    /// the vendor operation first and each candidate is probed with
    /// `GetStorageInfo`. `nil` means no card answered, not a fabricated empty
    /// storage value.
    public func readStorageInfo() throws -> PTPStorageInfo? {
        for storageID in try usableStorageIDs() {
            let result = try executeTransaction(
                .getStorageInfo, parameters: [storageID], dataPhase: .dataIn)
            guard result.operationResponse.responseCode == .ok,
                let info = PTPStorageInfo(Array(result.data))
            else {
                continue
            }
            return info
        }
        return nil
    }

    /// Starts a stable, incremental media enumeration across every usable card.
    ///
    /// Each card's handle list is captured in one command, matching iOS's
    /// discovery snapshot, while per-object metadata remains deferred to
    /// bounded cursor pages. A card rejecting `GetObjectHandles` is skipped so
    /// another installed card can still be browsed.
    public func beginMediaBrowse() throws -> FacadeMediaBrowseCursor {
        var snapshots: [MediaBrowseStorageSnapshot] = []
        for storageID in try usableStorageIDs() {
            let handles: [UInt32]
            do {
                handles = try objectHandles(storageID: storageID)
            } catch let error as PTPIPClientSessionError {
                guard case .operationRejected(.getObjectHandles, _) = error else { throw error }
                handles = []
            }
            snapshots.append(MediaBrowseStorageSnapshot(storageID: storageID, handles: handles))
        }
        return FacadeMediaBrowseCursor(snapshots: snapshots) { [weak self] object in
            self?.mediaClip(object)
        }
    }

    /// Reads the camera's embedded thumbnail for one object — `GetThumb`
    /// (0x100A). Returns nil when the camera reports no thumbnail.
    public func thumbnail(handle: UInt32) throws -> Data? {
        let result = try executeTransaction(
            .getThumb, parameters: [handle], dataPhase: .dataIn)
        guard result.operationResponse.responseCode == .ok else { return nil }
        return result.data.isEmpty ? nil : result.data
    }

    /// The candidate card IDs from both Nikon's vendor list and standard PTP
    /// list, de-duplicated and stripped of known placeholder values. Querying
    /// both matches iOS and keeps a vendor-list omission from hiding card 2;
    /// later per-card commands harmlessly skip any remaining absent-slot ID.
    private func usableStorageIDs() throws -> [UInt32] {
        let vendorResult = Result { try storageIDList(via: .getVendorStorageIDs) }
        let standardResult = Result { try storageIDList(via: .getStorageIDs) }
        if case .failure(let error) = vendorResult,
            case .failure = standardResult
        {
            throw error
        }
        var candidates = (try? vendorResult.get()) ?? []
        candidates += (try? standardResult.get()) ?? []
        var seen = Set<UInt32>()
        return candidates.filter { $0 != 0 && $0 != 0xFFFF_FFFF && seen.insert($0).inserted }
    }

    private func storageIDList(via operationCode: PTPOperationCode) throws -> [UInt32] {
        let result = try executeTransaction(operationCode, dataPhase: .dataIn)
        guard result.operationResponse.responseCode == .ok else { return [] }
        return PTPStorageIDs.parse(Array(result.data))
    }

    /// Object handles on one volume — `GetObjectHandles` (0x1007), all formats,
    /// all folders. The dataset is a PTP UINT32 array, byte-identical to a
    /// StorageID array.
    private func objectHandles(storageID: UInt32) throws -> [UInt32] {
        let result = try transactExpectingOK(
            .getObjectHandles, parameters: [storageID, 0, 0], dataPhase: .dataIn)
        return PTPStorageIDs.parse(Array(result.data))
    }

    /// One object's metadata — `GetObjectInfo` (0x1008), decoded by the core.
    private func objectInfo(handle: UInt32) throws -> PTPObjectInfo {
        let result = try transactExpectingOK(
            .getObjectInfo, parameters: [handle], dataPhase: .dataIn)
        return try PTPObjectInfo(result.data)
    }

    private func mediaClip(_ object: MediaObjectHandle) -> FacadeMediaClip? {
        guard let info = try? objectInfo(handle: object.handle),
            info.isMediaLibraryObject,
            let filename = MediaClipFilename.safeCameraBasename(info.filename)
        else { return nil }
        let resolvedSize =
            (try? resolvedObjectSize(
                handle: object.handle, reportedSize: UInt64(info.compressedSize)))
            ?? UInt64(info.compressedSize)
        return FacadeMediaClip(
            handle: object.handle,
            storageID: object.storageID,
            sizeBytes: resolvedSize,
            captureDate: info.captureDate,
            pixelWidth: info.imagePixWidth,
            pixelHeight: info.imagePixHeight,
            filename: filename)
    }
}

/// Flat wire format for the media listing crossing the JNI seam — one clip
/// per line, tab-separated fields with the (sanitized, tab/newline-free)
/// filename last:
/// `handle \t storageID \t sizeBytes \t captureDate \t width \t height \t sourceWidth \t sourceHeight \t playable \t kind \t strategy \t formatLabel \t filename`.
/// The Kotlin mirror lives in
/// `Apps/Android/app/src/main/kotlin/com/opencapture/openzcine/media/MediaClips.kt`.
public enum MediaListWire {
    public static func encode(_ clips: [FacadeMediaClip]) -> String {
        clips.map(encode).joined(separator: "\n")
    }

    private static func encode(_ clip: FacadeMediaClip) -> String {
        let fields: [String] = [
            String(clip.handle),
            String(clip.storageID),
            String(clip.sizeBytes),
            clip.captureDate,
            String(clip.pixelWidth),
            String(clip.pixelHeight),
            String(clip.sourcePixelWidth ?? 0),
            String(clip.sourcePixelHeight ?? 0),
            clip.isPlayableProxy ? "1" : "0",
            clip.contentClassification.kind.rawValue,
            clip.contentClassification.stillPreview?.strategy.rawValue ?? "",
            clip.contentClassification.stillPreview?.formatLabel ?? "",
            clip.filename,
        ]
        return fields.joined(separator: "\t")
    }
}

/// Versioned JNI wire for one bounded media cursor page.
public enum MediaBrowsePageWire {
    /// Stable header token mirrored by Android's `MediaBrowsePages` parser.
    public static let version = "OZCMEDIA2"

    /// Encodes a header, typed removal records, then zero or more
    /// `MediaListWire` additions. Android applies additions before removals so
    /// an R3D and its later proxy may share one incremental page safely.
    public static func encode(_ page: FacadeMediaBrowsePage) -> String {
        let header = [
            version,
            page.hasMore ? "1" : "0",
            String(page.inspectedObjectCount),
            String(page.removedObjects.count),
        ].joined(separator: "\t")
        let removals = page.removedObjects.map { object in
            "-\t\(object.storageID)\t\(object.handle)\t\(object.captureDate)\t\(object.filename)"
        }.joined(separator: "\n")
        let records = MediaListWire.encode(page.clips)
        return [header, removals, records].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Process-local opaque cursor handles used only by the Android JNI seam.
final class MediaBrowseCursorRegistry: @unchecked Sendable {
    static let shared = MediaBrowseCursorRegistry()

    private struct Entry {
        let sessionID: ObjectIdentifier
        let cursor: FacadeMediaBrowseCursor
    }

    private let lock = NSLock()
    private var nextHandle: Int64 = 1
    private var entries: [Int64: Entry] = [:]
    private var latestHandleBySession: [ObjectIdentifier: Int64] = [:]

    /// Starts the latest cursor for `session`. A concurrently superseded
    /// snapshot is discarded rather than publishing a stale handle.
    func begin(session: PTPIPClientSession) throws -> Int64? {
        let sessionID = ObjectIdentifier(session)
        let reservation: Int64
        let staleCursors: [FacadeMediaBrowseCursor]
        lock.lock()
        reservation = reserveHandleLocked()
        staleCursors = entries.values.compactMap { entry in
            entry.sessionID == sessionID ? entry.cursor : nil
        }
        entries = entries.filter { $0.value.sessionID != sessionID }
        latestHandleBySession[sessionID] = reservation
        lock.unlock()
        for cursor in staleCursors {
            cursor.cancel()
        }

        let cursor: FacadeMediaBrowseCursor
        do {
            cursor = try session.beginMediaBrowse()
        } catch {
            clearReservation(reservation, sessionID: sessionID)
            throw error
        }

        lock.lock()
        guard latestHandleBySession[sessionID] == reservation else {
            lock.unlock()
            cursor.cancel()
            return nil
        }
        entries[reservation] = Entry(sessionID: sessionID, cursor: cursor)
        lock.unlock()
        return reservation
    }

    func next(handle: Int64, maxObjects: Int) throws -> FacadeMediaBrowsePage? {
        lock.lock()
        let entry = entries[handle]
        lock.unlock()
        guard let entry else { return nil }

        let page = try entry.cursor.nextPage(maxObjects: maxObjects)
        if !page.hasMore {
            remove(handle: handle, matching: entry)
        }
        return page
    }

    func cancel(handle: Int64) {
        guard handle > 0 else { return }
        lock.lock()
        let entry = entries.removeValue(forKey: handle)
        if let entry, latestHandleBySession[entry.sessionID] == handle {
            latestHandleBySession.removeValue(forKey: entry.sessionID)
        }
        lock.unlock()
        entry?.cursor.cancel()
    }

    func cancel(session: PTPIPClientSession) {
        let sessionID = ObjectIdentifier(session)
        lock.lock()
        latestHandleBySession.removeValue(forKey: sessionID)
        let cursors = entries.values.compactMap { entry in
            entry.sessionID == sessionID ? entry.cursor : nil
        }
        entries = entries.filter { $0.value.sessionID != sessionID }
        lock.unlock()
        for cursor in cursors {
            cursor.cancel()
        }
    }

    private func reserveHandleLocked() -> Int64 {
        while entries[nextHandle] != nil || latestHandleBySession.values.contains(nextHandle) {
            nextHandle = nextHandle == Int64.max ? 1 : nextHandle + 1
        }
        let reserved = nextHandle
        nextHandle = nextHandle == Int64.max ? 1 : nextHandle + 1
        return reserved
    }

    private func clearReservation(_ handle: Int64, sessionID: ObjectIdentifier) {
        lock.lock()
        if latestHandleBySession[sessionID] == handle {
            latestHandleBySession.removeValue(forKey: sessionID)
        }
        lock.unlock()
    }

    private func remove(handle: Int64, matching entry: Entry) {
        lock.lock()
        if entries[handle]?.cursor === entry.cursor {
            entries.removeValue(forKey: handle)
            if latestHandleBySession[entry.sessionID] == handle {
                latestHandleBySession.removeValue(forKey: entry.sessionID)
            }
        }
        lock.unlock()
    }
}
