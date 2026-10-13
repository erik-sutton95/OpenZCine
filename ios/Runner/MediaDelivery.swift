import AVFoundation
import Foundation
import OpenCineAppKit
import OpenCineCameraVocabulary
import OpenCineFrameIO
import OpenZCineCore
import os

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

/// Whether native share / save (and Frame.io after a cache pre-pass) can start.
///
/// The player used to require a complete local file, which greyed Share out for every on-camera
/// clip even though `MediaDeliveryRunner` already pulls those files before export. Cached clips
/// stay deliverable offline; uncached clips need the camera.
enum MediaDeliveryEligibility {
    /// One clip, as the playback transport Share button sees it.
    static func canDeliver(clipIsLocal: Bool, cameraConnected: Bool) -> Bool {
        clipIsLocal || cameraConnected
    }

    /// A selection of clips, as the destination popup sees it.
    static func canDeliver(localCount: Int, totalCount: Int, cameraConnected: Bool) -> Bool {
        totalCount > 0 && (localCount > 0 || cameraConnected)
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

    /// Compatibility entry points retain their result and callbacks; ordering is shared.
    func deliverClipsForShare(
        _ clips: [MediaClip], configuration: MediaDeliveryConfiguration,
        onProgress: @escaping @MainActor (Int, Int, Double) -> Void
    ) async -> MediaDeliveryBatchResult {
        await deliverCompatibilityBatch(
            clips, configuration: configuration, remote: false, onProgress: onProgress)
    }
    func uploadClipsToFrameio(
        _ clips: [MediaClip], configuration: MediaDeliveryConfiguration,
        onProgress: @escaping @MainActor (Int, Int, Double) -> Void
    ) async -> MediaDeliveryBatchResult {
        await deliverCompatibilityBatch(
            clips, configuration: configuration, remote: true, onProgress: onProgress)
    }
    private func deliverCompatibilityBatch(
        _ clips: [MediaClip], configuration: MediaDeliveryConfiguration,
        remote: Bool, onProgress: @escaping @MainActor (Int, Int, Double) -> Void
    ) async -> MediaDeliveryBatchResult {
        var result = MediaDeliveryBatchResult()
        guard !clips.isEmpty, let capture = NikonMediaDeliveryCapture(model: self, clips: clips)
        else { return result }
        let admission = MonitorDeliveryAdmission { capture.isCurrent }
        var remoteCapture: NikonMediaDeliveryCapture?
        let records = clips.enumerated().map { (index: $0.offset, clip: $0.element) }
        typealias Batch = MonitorDeliveryModel<
            MonitorDeliveryBatchProgress, MonitorDeliveryBatchOutcome<URL>, URL
        >
        _ = await Batch.runBatch(
            records: records, destination: remote ? .remoteUpload : .nativeShare,
            action: .systemShare, admission: admission,
            originals: .init(available: { _ in true }, acquire: { _ in }, progress: { _ in nil }),
            exporter: .init {
                record, progress -> (clip: MediaClip, export: MediaLUT.ExportResult)? in
                let clip = record.clip
                let status =
                    capture.store.list(cameraID: clip.cameraID).first { $0.id == clip.id }?
                    .frameioStatus ?? clip.frameioStatus
                if remote, status == .uploaded, !configuration.forceFrameioReupload {
                    result.skippedCount += 1
                    onProgress(record.index + 1, clips.count, 1)
                    return nil
                }
                do {
                    let exported = try await capture.prepare(
                        clip, configuration: configuration, admission: admission, progress: progress
                    )
                    if !remote {
                        result.exportedURLs.append(exported.videoURL)
                        if let metadata = exported.metadataURL {
                            result.metadataURLs.append(metadata)
                        }
                    }
                    return (clip: clip, export: exported)
                } catch {
                    result.failedClips.append((clip, error.localizedDescription))
                    if admission.isCurrent() {
                        let ns = error as NSError
                        let detail = "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
                        Logger(subsystem: "OpenZCine", category: "media-export").error(
                            "clip failed \(clip.filename, privacy: .public): \(detail, privacy: .public)"
                        )
                    }
                    throw error
                }
            }, share: { .init(urls: $0) }, photos: nil,
            upload: remote
                ? .init { artifact, progress in
                    do {
                        if remoteCapture == nil {
                            if !self.isFrameioConnected { try await self.connectFrameio() }
                            guard admission.isCurrent() else { throw CancellationError() }
                            remoteCapture = NikonMediaDeliveryCapture(
                                model: self, clips: clips,
                                action: capture.action)
                        }
                        guard let remoteCapture, admission.isCurrent(),
                            remoteCapture.account.isCurrent
                        else { throw CancellationError() }
                        if self.frameioUser == nil {
                            let user = try? await remoteCapture.frameioClient(admission: admission)
                                .currentUser()
                            guard admission.isCurrent(), remoteCapture.account.isCurrent
                            else { throw CancellationError() }
                            self.frameioUser = user
                        }
                        try await self.uploadCapturedFrameio(
                            artifact.clip, source: artifact.export.videoURL,
                            metadata: capture.metadata(artifact.clip, configuration: configuration),
                            capture: remoteCapture, admission: admission, progress: progress)
                        result.uploadedCount += 1
                    } catch {
                        result.failedClips.append((artifact.clip, error.localizedDescription))
                        throw error
                    }
                } : nil,
            internet: Optional<MonitorDeliveryInternetService<FrameioInternetHop.Token>>.none,
            filename: { $0.clip.filename },
            policy: .init(
                behavior: .init(
                    nativeFailures: .continueItems,
                    emptyUploadSucceeds: true, singleUploadFailureUsesDetail: false)),
            progress: { value in
                onProgress(value.clipIndex, value.totalClips, value.clipFraction)
            })
        return result
    }

    /// Plain-text metadata summary for share sheets when the operator enables metadata.
    func metadataSummary(for clips: [MediaClip]) -> String {
        clips.map { clip in
            let size =
                clip.sizeBytes > 0
                ? MediaClipFormatting.byteLabel(clip.sizeBytes)
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
