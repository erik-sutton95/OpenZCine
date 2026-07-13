import AVFoundation
import Foundation

/// Container format for baked media exports.
enum MediaExportFormat: String, Sendable, CaseIterable, Identifiable {
    case mov
    case mp4

    var id: String { rawValue }

    var avFileType: AVFileType {
        switch self {
        case .mov: .mov
        case .mp4: .mp4
        }
    }

    var label: String { rawValue.uppercased() }
}

/// Best-effort clip metadata written beside exports when the operator enables metadata.
struct MediaClipDeliveryMetadata: Codable, Sendable {
    let filename: String
    let captureDate: String
    let sizeBytes: UInt64
    let cameraName: String?
    let cameraModel: String?
    let cameraSerial: String?
    let lutName: String?
    let exportedAt: Date

    static func from(
        _ clip: MediaClip, camera: NativeCameraIdentity? = nil, lutName: String? = nil
    ) -> MediaClipDeliveryMetadata {
        MediaClipDeliveryMetadata(
            filename: clip.filename,
            captureDate: clip.captureDate,
            sizeBytes: clip.sizeBytes,
            cameraName: camera?.displayName,
            cameraModel: camera?.model.nilIfEmpty,
            cameraSerial: camera?.serialNumber.nilIfEmpty,
            lutName: lutName,
            exportedAt: Date()
        )
    }
}

extension String {
    fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Where a delivery run sends prepared clips.
enum MediaDeliveryDestination: String, CaseIterable, Identifiable, Sendable {
    case nativeShare
    case frameio

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nativeShare: "Share"
        case .frameio: "Frame.io"
        }
    }

    var subtitle: String {
        switch self {
        case .nativeShare: "AirDrop, Files, and other apps"
        case .frameio: "Upload to your Frame.io project"
        }
    }

    var systemImage: String {
        switch self {
        case .nativeShare: "square.and.arrow.up"
        case .frameio: "arrow.up.circle"
        }
    }

    var actionTitle: String {
        switch self {
        case .nativeShare: "Share"
        case .frameio: "Upload"
        }
    }
}

/// Options shared by native share and Frame.io delivery.
struct MediaDeliveryConfiguration: Sendable {
    var bakeLUT: Bool = true
    var exportFormat: MediaExportFormat = .mov
    var includeMetadata: Bool = true
    var forceFrameioReupload: Bool = false
}

/// Result of a batch delivery run.
struct MediaDeliveryBatchResult: Sendable {
    var exportedURLs: [URL] = []
    var metadataURLs: [URL] = []
    var uploadedCount: Int = 0
    var skippedCount: Int = 0
    var failedClips: [(MediaClip, String)] = []
}

extension NativeAppModel {
    /// Output filename for delivery — always the camera original name, with the export format
    /// extension only when LUT baking transcodes the clip.
    func deliveryFilename(
        for clip: MediaClip, configuration: MediaDeliveryConfiguration
    ) -> String {
        guard configuration.bakeLUT else { return clip.filename }
        let stem = (clip.filename as NSString).deletingPathExtension
        return "\(stem).\(configuration.exportFormat.rawValue)"
    }

    func deliveryMetadata(
        for clip: MediaClip, configuration: MediaDeliveryConfiguration
    ) -> MediaClipDeliveryMetadata? {
        guard configuration.includeMetadata else { return nil }
        let lutName: String? =
            configuration.bakeLUT
            ? {
                switch assistConfiguration.selectedLUT {
                case .builtIn(let look): look.rawValue
                case .stored(_, let name): (name as NSString).deletingPathExtension
                }
            }() : nil
        return .from(clip, camera: connectedIdentity, lutName: lutName)
    }

    /// Resolves a clip to a shareable/uploadable file URL, optionally baking the selected LUT.
    func prepareClipForDelivery(
        _ clip: MediaClip,
        configuration: MediaDeliveryConfiguration,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> MediaLUT.ExportResult {
        guard let sourceURL = clipLocalURL(clip) else {
            throw MediaDeliveryError.unsafeMediaFilename
        }
        guard isClipDownloaded(clip) else {
            throw MediaDeliveryError.clipNotCached(clip.filename)
        }
        let filename = deliveryFilename(for: clip, configuration: configuration)
        let cube = configuration.bakeLUT ? currentLUTCube() : nil
        if configuration.bakeLUT, cube == nil {
            throw MediaDeliveryError.noLUTSelected
        }
        return try await MediaLUT.export(
            sourceURL: sourceURL,
            outputFilename: filename,
            format: configuration.exportFormat,
            cube: cube,
            metadata: deliveryMetadata(for: clip, configuration: configuration),
            progress: progress
        )
    }

    /// Exports or copies each clip, reporting combined progress across the batch.
    func deliverClipsForShare(
        _ clips: [MediaClip],
        configuration: MediaDeliveryConfiguration,
        onProgress: @escaping @MainActor (Int, Int, Double) -> Void
    ) async -> MediaDeliveryBatchResult {
        var result = MediaDeliveryBatchResult()
        let total = clips.count
        guard total > 0 else { return result }

        for (index, clip) in clips.enumerated() {
            onProgress(index + 1, total, 0)
            do {
                let export = try await prepareClipForDelivery(
                    clip, configuration: configuration
                ) {
                    fraction in
                    Task { @MainActor in onProgress(index + 1, total, fraction) }
                }
                result.exportedURLs.append(export.videoURL)
                if let metadataURL = export.metadataURL {
                    result.metadataURLs.append(metadataURL)
                }
                if configuration.bakeLUT, currentLUTCube() != nil {
                    setClipExportStatus(.exported, for: clip)
                }
            } catch {
                result.failedClips.append((clip, error.localizedDescription))
                if configuration.bakeLUT { setClipExportStatus(.failed, for: clip) }
            }
        }
        return result
    }

    /// Uploads clips to Frame.io sequentially; skips already-uploaded clips unless forced.
    func uploadClipsToFrameio(
        _ clips: [MediaClip],
        configuration: MediaDeliveryConfiguration,
        onProgress: @escaping @MainActor (Int, Int, Double) -> Void
    ) async -> MediaDeliveryBatchResult {
        var result = MediaDeliveryBatchResult()
        let total = clips.count
        guard total > 0 else { return result }

        for (index, clip) in clips.enumerated() {
            let status =
                mediaClips.first { $0.id == clip.id }?.frameioStatus ?? clip.frameioStatus
            if status == .uploaded, !configuration.forceFrameioReupload {
                result.skippedCount += 1
                onProgress(index + 1, total, 1)
                continue
            }
            if !isClipDownloaded(clip) {
                result.failedClips.append(
                    (clip, MediaDeliveryError.clipNotCached(clip.filename).localizedDescription))
                continue
            }

            onProgress(index + 1, total, 0)
            let filename = deliveryFilename(for: clip, configuration: configuration)
            let options = MediaDeliveryUploadOptions(
                filename: filename,
                bakeLUT: configuration.bakeLUT,
                cube: configuration.bakeLUT ? currentLUTCube() : nil,
                metadata: deliveryMetadata(for: clip, configuration: configuration),
                forceReupload: configuration.forceFrameioReupload
            )
            await uploadClipToFrameio(clip, options: options) { fraction in
                Task { @MainActor in onProgress(index + 1, total, fraction) }
            }
            if let error = frameioUploadError {
                frameioUploadError = nil
                result.failedClips.append((clip, error))
            } else {
                result.uploadedCount += 1
            }
            onProgress(index + 1, total, 1)
        }
        return result
    }

    /// Plain-text metadata summary for share sheets when the operator enables metadata.
    func metadataSummary(for clips: [MediaClip]) -> String {
        clips.map { clip in
            let size =
                clip.sizeBytes > 0
                ? ByteCountFormatter.string(fromByteCount: Int64(clip.sizeBytes), countStyle: .file)
                : "unknown size"
            let date = clip.captureDate.isEmpty ? "unknown date" : clip.captureDate
            return "\(clip.filename) · \(date) · \(size)"
        }.joined(separator: "\n")
    }
}

enum MediaDeliveryError: LocalizedError {
    case clipNotCached(String)
    case noLUTSelected
    case emptySelection
    case unsafeMediaFilename

    var errorDescription: String? {
        switch self {
        case .clipNotCached(let name): "\(name) isn't fully cached yet."
        case .noLUTSelected: "Select a LUT before baking grades into exports."
        case .emptySelection: "Select at least one clip."
        case .unsafeMediaFilename: "The camera supplied an unsafe media filename."
        }
    }
}
