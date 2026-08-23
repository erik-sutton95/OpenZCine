import AVFoundation
import CoreMedia
import Foundation
import os

/// Copies a source clip's QuickTime timecode (`tmcd`) track into a finished export.
///
/// `AVAssetExportSession` only carries video and audio, so LUT-baked deliveries lose the start
/// timecode Frame.io and NLEs use to align a proxy with its R3D NE / N-RAW master. The camera
/// stamps master and proxy from the same generator, so the proxy's own track IS the master's
/// timecode — copying it byte-for-byte (format description + frame-number sample) preserves
/// frame quanta and drop-frame flags with no re-encode.
enum MediaTimecode {
    private static let logger = Logger(subsystem: "OpenZCine", category: "media-timecode")

    /// Best-effort: appends `sourceURL`'s timecode track to the finished export at `outputURL`
    /// in place (sample data + rewritten moov appended to the file). No-ops when the source has
    /// no timecode track; never throws — a missing timecode must not fail a delivery.
    static func copySourceTimecodeTrack(
        from sourceURL: URL, to outputURL: URL, as fileType: AVFileType
    ) async {
        // Precise timing is required for cross-asset track inserts (AVFoundation -11838 / -11880).
        let source = AVURLAsset(
            url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let stagedURL = outputURL.deletingLastPathComponent()
            .appendingPathComponent(
                ".\(outputURL.deletingPathExtension().lastPathComponent).tmcd"
            )
            .appendingPathExtension(outputURL.pathExtension)
        do {
            if MediaLUT.mediaDataExtendsPastEndOfFile(at: sourceURL) {
                logger.info("timecode embed skipped: source mdat is truncated")
                return
            }
            guard let sourceTrack = try await source.loadTracks(withMediaType: .timecode).first
            else {
                logger.info("timecode embed skipped: source has no tmcd track")
                return
            }
            let sourceRange = try await sourceTrack.load(.timeRange)
            let destDuration = try await AVURLAsset(
                url: outputURL,
                options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
            ).load(.duration)
            let timeRange: CMTimeRange
            if destDuration.isNumeric, destDuration < sourceRange.duration {
                timeRange = CMTimeRange(start: sourceRange.start, duration: destDuration)
            } else {
                timeRange = sourceRange
            }

            try? FileManager.default.removeItem(at: stagedURL)
            try FileManager.default.copyItem(at: outputURL, to: stagedURL)
            defer { try? FileManager.default.removeItem(at: stagedURL) }

            let movie = AVMutableMovie(url: stagedURL, options: nil)
            movie.defaultMediaDataStorage = AVMediaDataStorage(url: stagedURL, options: nil)
            guard
                let timecodeTrack = movie.addMutableTrack(
                    withMediaType: .timecode, copySettingsFrom: nil)
            else {
                logger.error("timecode embed: cannot add tmcd track to export")
                return
            }
            try timecodeTrack.insertTimeRange(
                timeRange, of: sourceTrack, at: .zero, copySampleData: true)
            if let video = try await movie.loadTracks(withMediaType: .video).first {
                video.addTrackAssociation(to: timecodeTrack, type: .timecode)
            }
            try movie.writeHeader(
                to: stagedURL, fileType: fileType, options: .addMovieHeaderToDestination)
            guard MediaLUT.movieHasFinishedHeader(at: stagedURL) else {
                logger.error("timecode embed produced a file without moov; keeping the export")
                return
            }
            try FileManager.default.removeItem(at: outputURL)
            try FileManager.default.copyItem(at: stagedURL, to: outputURL)
            logger.info("timecode embed succeeded")
        } catch {
            let ns = error as NSError
            logger.error(
                "timecode embed failed: \(ns.domain, privacy: .public) code=\(ns.code) \(ns.localizedDescription, privacy: .public)"
            )
        }
    }

    /// True when the file still has a video track AVFoundation can cursor — a failed tmcd rewrite
    /// must not replace a good export with a Photos-rejected file.
    private static func hasReadableVideoTrack(at url: URL) async -> Bool {
        let asset = AVURLAsset(
            url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard let track = try await asset.loadTracks(withMediaType: .video).first else {
                return false
            }
            return try await track.load(.isPlayable)
        } catch {
            return false
        }
    }
}
