// Media browsing for the Android facade — the browse half of the Media page
// (Kaneo OPE-34 / issue #77 v1 slice; playback via partial-object reads is a
// separate slice).
//
// Mirrors the iOS shell's PTP media path (`NativeCameraSession`): usable
// storage IDs (`GetVendorStorageIDs` 0x9209 falling back to `GetStorageIDs`
// 0x1004) → `GetObjectHandles` 0x1007 → per-object `GetObjectInfo` 0x1008,
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

    /// Lists browsable media on the camera's cards, applying the iOS browse
    /// policies: media-library filtering (movies, stills, R3D masters) and the
    /// R3D-hide pairing rule (a master with a same-stem playable proxy is
    /// represented by the proxy).
    ///
    /// Enumeration is BOUNDED: at most `maxObjects` `GetObjectInfo` round
    /// trips across all cards, so a packed card can never block the session
    /// thread unboundedly (the iOS USB lesson: never gate a session on
    /// cataloging a whole card). Newest handles are inspected first — PTP
    /// object handles arrive in on-card order, so the tail of each volume's
    /// handle list is the most recent footage.
    // ponytail: cap + newest-first is the whole v1 policy; cursor-style paging
    // arrives with the playback slice if a real card overflows the cap.
    public func listMedia(maxObjects: Int = 256) throws -> [FacadeMediaClip] {
        var inspected = 0
        var clips: [FacadeMediaClip] = []
        for storageID in try usableStorageIDs() {
            let handles = try objectHandles(storageID: storageID)
            for handle in handles.reversed() {
                guard inspected < maxObjects else { break }
                inspected += 1
                guard let info = try? objectInfo(handle: handle),
                    info.isMediaLibraryObject,
                    let filename = MediaClipFilename.safeCameraBasename(info.filename)
                else { continue }
                let resolvedSize =
                    (try? resolvedObjectSize(
                        handle: handle, reportedSize: UInt64(info.compressedSize)))
                    ?? UInt64(info.compressedSize)
                clips.append(
                    FacadeMediaClip(
                        handle: handle,
                        storageID: storageID,
                        sizeBytes: resolvedSize,
                        captureDate: info.captureDate,
                        pixelWidth: info.imagePixWidth,
                        pixelHeight: info.imagePixHeight,
                        filename: filename))
            }
        }
        var r3dIndex = R3DClipIndex()
        for clip in clips {
            if MediaClipFilename.isR3D(clip.filename), clip.pixelWidth > 0, clip.pixelHeight > 0 {
                r3dIndex.registerR3D(
                    filename: clip.filename, width: clip.pixelWidth, height: clip.pixelHeight)
            } else if clip.isPlayableProxy {
                r3dIndex.noteProxy(clip.filename)
            }
        }
        let linked = clips.map { clip in
            guard clip.isPlayableProxy, let source = r3dIndex.siblingForProxy(clip.filename) else {
                return clip
            }
            return FacadeMediaClip(
                handle: clip.handle,
                storageID: clip.storageID,
                sizeBytes: clip.sizeBytes,
                captureDate: clip.captureDate,
                pixelWidth: clip.pixelWidth,
                pixelHeight: clip.pixelHeight,
                sourcePixelWidth: source.width,
                sourcePixelHeight: source.height,
                filename: clip.filename)
        }
        let proxyStems = MediaClipFilename.playableProxyStems(in: linked.map(\.filename))
        return linked.filter {
            MediaClipFilename.shouldShowInMediaBrowser(
                filename: $0.filename, playableProxyStems: proxyStems)
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

    /// The *valid* (card-present) storage IDs: `GetVendorStorageIDs` preferred
    /// (standard `GetStorageIDs` reports placeholder per-slot IDs), falling
    /// back to the standard list; de-duplicated, placeholder/empty stripped —
    /// the iOS `usableStorageIDs` policy.
    private func usableStorageIDs() throws -> [UInt32] {
        var candidates: [UInt32] = []
        candidates += (try? storageIDList(via: .getVendorStorageIDs)) ?? []
        if candidates.isEmpty {
            candidates += try storageIDList(via: .getStorageIDs)
        }
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
