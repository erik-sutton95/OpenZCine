import AVFoundation
import CoreMedia
import XCTest

@testable import Runner

/// Roundtrip proof that `MediaLUT.export`'s transcode branch keeps the source's `tmcd` track:
/// synthesizes a movie with a known start timecode, exports it through the same path the
/// delivery sheet uses, and reads the timecode back out of the result.
final class MediaTimecodeTests: XCTestCase {

    /// Frame 330702 @ 25 fps == 03:40:28:02 — the start TC of the reference ZR proxy sample.
    private static let startFrame: UInt32 = 330_702
    private static let fps: Int32 = 25

    func testTranscodeExportKeepsSourceTimecodeTrack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mov")
        try await Self.writeMovieWithTimecode(to: sourceURL)

        let sourceStart = try await Self.readStartTimecode(of: sourceURL)
        XCTAssertEqual(sourceStart?.frame, Self.startFrame, "synthesized source lost its tmcd")

        // mov → mp4 forces the transcode branch (the one that drops tmcd) without a LUT cube.
        let result = try await MediaLUT.export(
            sourceURL: sourceURL,
            outputFilename: "tc-roundtrip-\(UUID().uuidString).mp4",
            format: .mp4,
            cube: nil,
            metadata: nil
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: result.videoURL) }

        let start = try await Self.readStartTimecode(of: result.videoURL)
        XCTAssertEqual(start?.frame, Self.startFrame)
        XCTAssertEqual(start?.frameQuanta, UInt32(Self.fps))
    }

    func testCompositionExportSessionCompletes() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mov")
        try await Self.writeMovieWithTimecode(to: sourceURL)
        let source = AVURLAsset(
            url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let exportable = try await MediaLUT.audioVisualExportAsset(from: source)
        let output = dir.appendingPathComponent("out.mp4")
        guard
            let session = AVAssetExportSession(
                asset: exportable, presetName: AVAssetExportPresetHighestQuality)
        else {
            XCTFail("no export session")
            return
        }
        session.outputURL = output
        session.outputFileType = .mp4
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            nonisolated(unsafe) let exportSession = session
            exportSession.exportAsynchronously {
                if exportSession.status == .completed {
                    cont.resume()
                } else {
                    cont.resume(
                        throwing: exportSession.error ?? NSError(domain: "export", code: -1))
                }
            }
        }
        let size =
            (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? UInt64) ?? 0
        XCTAssertGreaterThan(size, 0)
    }

    func testExportCompositionDropsTimecodeTrack() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mov")
        try await Self.writeMovieWithTimecode(to: sourceURL)
        let source = AVURLAsset(
            url: sourceURL, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let sourceTimecode = try await source.loadTracks(withMediaType: .timecode)
        XCTAssertFalse(sourceTimecode.isEmpty)

        let exportable = try await MediaLUT.audioVisualExportAsset(from: source)
        let exportTimecode = try await exportable.loadTracks(withMediaType: .timecode)
        let exportVideo = try await exportable.loadTracks(withMediaType: .video)
        XCTAssertTrue(exportTimecode.isEmpty)
        XCTAssertFalse(exportVideo.isEmpty)
    }

    func testLUTBakeExportSucceedsForTimecodeSource() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mov")
        try await Self.writeMovieWithTimecode(to: sourceURL)

        let result = try await MediaLUT.export(
            sourceURL: sourceURL,
            outputFilename: "lut-bake-\(UUID().uuidString).mov",
            format: .mov,
            cube: Self.identityCube(),
            metadata: nil
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: result.videoURL) }

        let size =
            (try FileManager.default.attributesOfItem(atPath: result.videoURL.path)[.size]
                as? UInt64) ?? 0
        XCTAssertGreaterThan(size, 0)
        let start = try await Self.readStartTimecode(of: result.videoURL)
        XCTAssertEqual(start?.frame, Self.startFrame)
    }

    func testCompleteMovieIsNotFlaggedTruncated() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mov")
        try await Self.writeMovieWithTimecode(to: sourceURL)
        XCTAssertFalse(MediaLUT.mediaDataExtendsPastEndOfFile(at: sourceURL))
        XCTAssertTrue(MediaLUT.movieHasFinishedHeader(at: sourceURL))
        XCTAssertNil(MediaLUT.mdatAvailableFraction(at: sourceURL))
    }

    func testTruncatedFastStartProxyExportWritesPlayableFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceURL = dir.appendingPathComponent("source.mov")
        try await Self.writeMovieWithTimecode(
            to: sourceURL, frameCount: 60, optimizeForNetworkUse: true)
        let truncatedURL = dir.appendingPathComponent("truncated.mov")
        try Self.truncateMdatPayload(from: sourceURL, to: truncatedURL, keepFraction: 0.35)
        try XCTSkipUnless(
            MediaLUT.mediaDataExtendsPastEndOfFile(at: truncatedURL),
            "fast-start rewrite did not leave moov before a declared-oversize mdat")
        let fraction = try XCTUnwrap(MediaLUT.mdatAvailableFraction(at: truncatedURL))
        XCTAssertGreaterThan(fraction, 0.1)
        XCTAssertLessThan(fraction, 0.9)
        let header = CMTime(seconds: 10, preferredTimescale: 25_000)
        let scaled = MediaLUT.scaledProgressDuration(for: truncatedURL, headerDuration: header)
        XCTAssertLessThan(scaled.seconds, header.seconds)

        let result = try await MediaLUT.export(
            sourceURL: truncatedURL,
            outputFilename: "truncated-export-\(UUID().uuidString).mov",
            format: .mov,
            cube: Self.identityCube(),
            metadata: nil
        ) { _ in }
        defer { try? FileManager.default.removeItem(at: result.videoURL) }

        let size =
            (try FileManager.default.attributesOfItem(atPath: result.videoURL.path)[.size]
                as? UInt64) ?? 0
        XCTAssertGreaterThan(size, 0)
        XCTAssertTrue(MediaLUT.movieHasFinishedHeader(at: result.videoURL))
        XCTAssertFalse(MediaLUT.mediaDataExtendsPastEndOfFile(at: result.videoURL))
    }

    func testExportReferenceProxyIfPresent() async throws {
        let sample = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("samples")
            .appendingPathComponent("A002_C057_0704BT.MP4")
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: sample.path),
            "reference proxy sample is not on this machine")

        let source = AVURLAsset(
            url: sample, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let exportable = try await MediaLUT.audioVisualExportAsset(from: source)
        let exportTimecode = try await exportable.loadTracks(withMediaType: .timecode)
        let exportVideo = try await exportable.loadTracks(withMediaType: .video)
        XCTAssertTrue(exportTimecode.isEmpty)
        XCTAssertFalse(exportVideo.isEmpty)
    }

    // MARK: - Synthesis

    /// Writes a tiny H.264 movie with a `tmcd` track starting at `startFrame`.
    private static func writeMovieWithTimecode(
        to url: URL, frameCount: Int = 5, optimizeForNetworkUse: Bool = false
    ) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = optimizeForNetworkUse

        let videoInput = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 320,
                AVVideoHeightKey: 240,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320,
                kCVPixelBufferHeightKey as String: 240,
            ])

        var formatDescription: CMTimeCodeFormatDescription?
        let status = CMTimeCodeFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            timeCodeFormatType: kCMTimeCodeFormatType_TimeCode32,
            frameDuration: CMTime(value: 1, timescale: fps),
            frameQuanta: UInt32(fps),
            flags: kCMTimeCodeFlag_24HourMax,
            extensions: nil,
            formatDescriptionOut: &formatDescription)
        guard status == noErr, let formatDescription else {
            throw NSError(domain: "MediaTimecodeTests", code: Int(status))
        }
        let timecodeInput = AVAssetWriterInput(
            mediaType: .timecode, outputSettings: nil, sourceFormatHint: formatDescription)

        writer.add(videoInput)
        writer.add(timecodeInput)
        videoInput.addTrackAssociation(
            withTrackOf: timecodeInput, type: AVAssetTrack.AssociationType.timecode.rawValue)

        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "MediaTimecodeTests", code: -1)
        }
        writer.startSession(atSourceTime: .zero)

        for frame in 0..<frameCount {
            while !videoInput.isReadyForMoreMediaData {
                try await Task.sleep(for: .milliseconds(10))
            }
            let buffer = try makePixelBuffer(from: adaptor)
            guard
                adaptor.append(
                    buffer,
                    withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: fps))
            else {
                throw writer.error ?? NSError(domain: "MediaTimecodeTests", code: -2)
            }
        }
        videoInput.markAsFinished()

        while !timecodeInput.isReadyForMoreMediaData {
            try await Task.sleep(for: .milliseconds(10))
        }
        let sample = try makeTimecodeSample(
            formatDescription: formatDescription,
            duration: CMTime(value: CMTimeValue(frameCount), timescale: fps))
        guard timecodeInput.append(sample) else {
            throw writer.error ?? NSError(domain: "MediaTimecodeTests", code: -3)
        }
        timecodeInput.markAsFinished()

        await writer.finishWriting()
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "MediaTimecodeTests", code: -4)
        }
    }

    private static func identityCube(size: Int = 2) -> CubeLUT {
        var rgb: [Float] = []
        rgb.reserveCapacity(size * size * size * 3)
        let denominator = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    rgb.append(Float(r) / denominator)
                    rgb.append(Float(g) / denominator)
                    rgb.append(Float(b) / denominator)
                }
            }
        }
        return CubeLUT(size: size, rgb: rgb)
    }

    private static func makePixelBuffer(
        from adaptor: AVAssetWriterInputPixelBufferAdaptor
    ) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        }
        if buffer == nil {
            CVPixelBufferCreate(
                kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer)
        }
        guard let buffer else {
            throw NSError(domain: "MediaTimecodeTests", code: -5)
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func makeTimecodeSample(
        formatDescription: CMTimeCodeFormatDescription, duration: CMTime
    ) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 4,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: 4,
            flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &blockBuffer)
        guard status == noErr, let blockBuffer else {
            throw NSError(domain: "MediaTimecodeTests", code: Int(status))
        }
        var frameNumber = startFrame.bigEndian
        status = withUnsafeBytes(of: &frameNumber) { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!, blockBuffer: blockBuffer,
                offsetIntoDestination: 0, dataLength: 4)
        }
        guard status == noErr else {
            throw NSError(domain: "MediaTimecodeTests", code: Int(status))
        }

        var timing = CMSampleTimingInfo(
            duration: duration, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: formatDescription,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
        guard status == noErr, let sample else {
            throw NSError(domain: "MediaTimecodeTests", code: Int(status))
        }
        return sample
    }

    // MARK: - Readback

    private struct StartTimecode {
        let frame: UInt32
        let frameQuanta: UInt32
    }

    /// Reads the first data-carrying `tmcd` sample (skipping empty priming buffers).
    private static func readStartTimecode(of url: URL) async throws -> StartTimecode? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .timecode).first else {
            return nil
        }
        guard let formatDescription = try await track.load(.formatDescriptions).first else {
            return nil
        }
        let quanta = CMTimeCodeFormatDescriptionGetFrameQuanta(formatDescription)

        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        reader.add(output)
        guard reader.startReading() else { return nil }

        var blockBuffer: CMBlockBuffer?
        while blockBuffer == nil, let sample = output.copyNextSampleBuffer() {
            blockBuffer = CMSampleBufferGetDataBuffer(sample)
        }
        guard let blockBuffer else { return nil }

        var length = 0
        var pointer: UnsafeMutablePointer<CChar>?
        CMBlockBufferGetDataPointer(
            blockBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length,
            dataPointerOut: &pointer)
        guard let pointer, length >= 4 else { return nil }
        let raw = pointer.withMemoryRebound(to: UInt32.self, capacity: 1) { $0.pointee }
        return StartTimecode(frame: UInt32(bigEndian: raw), frameQuanta: quanta)
    }

    /// Copies `from` up through the `mdat` header plus `keepFraction` of its payload, leaving
    /// the declared atom size intact so the file looks like a Nikon proxy whose media was cut off.
    private static func truncateMdatPayload(from: URL, to: URL, keepFraction: Double) throws {
        let data = try Data(contentsOf: from)
        var offset = 0
        var output = Data()
        while offset + 8 <= data.count {
            var atomSize = data.subdata(in: offset..<(offset + 4)).reduce(0) {
                ($0 << 8) | Int($1)
            }
            let type =
                String(data: data.subdata(in: (offset + 4)..<(offset + 8)), encoding: .ascii) ?? ""
            var header = 8
            if atomSize == 1, offset + 16 <= data.count {
                atomSize = data.subdata(in: (offset + 8)..<(offset + 16)).reduce(0) {
                    ($0 << 8) | Int($1)
                }
                header = 16
            }
            guard atomSize >= header else { break }
            if type == "mdat" {
                let payload = max(0, atomSize - header)
                let keepPayload = min(payload, max(1, Int(Double(payload) * keepFraction)))
                let end = min(data.count, offset + header + keepPayload)
                output.append(data.subdata(in: offset..<end))
                try output.write(to: to)
                return
            }
            let end = min(data.count, offset + atomSize)
            output.append(data.subdata(in: offset..<end))
            offset += atomSize
        }
        throw NSError(domain: "MediaTimecodeTests", code: -6)
    }
}
