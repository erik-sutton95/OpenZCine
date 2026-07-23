import AVFoundation
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
        // Precise timing is required for cross-asset track inserts (AVFoundation -11838).
        let source = AVURLAsset(
            url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        do {
            guard let sourceTrack = try await source.loadTracks(withMediaType: .timecode).first
            else { return }
            let timeRange = try await sourceTrack.load(.timeRange)

            let movie = AVMutableMovie(url: outputURL, options: nil)
            movie.defaultMediaDataStorage = AVMediaDataStorage(url: outputURL, options: nil)
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
                to: outputURL, fileType: fileType, options: .addMovieHeaderToDestination)
        } catch {
            logger.error(
                "timecode embed failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
