import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import OpenCineAppKit
import OpenCineCameraControls
import OpenCineMedia
import XCTest

@testable import Runner

/// SIMULATED cached movie through the actual Nikon export into the shared delivery store
/// (A2-58): the camera's name, its own directory per export, the Nikon sidecar, released by
/// the run.
@MainActor final class NikonDeliveryExportTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SIMULATED-nikon-export-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testExportsIntoTheStoreUnderTheCameraNameAndNeverOverwrites() async throws {
        let clips = MediaClipStore(root: root.appendingPathComponent("clips", isDirectory: true))
        let clip = MediaClip(
            cameraID: "SIMULATED", filename: "SIMULATED.MOV", handle: 4, storageID: 65_537,
            sizeBytes: 0, captureDate: "20261004T120000")
        let uncached = MediaClip(
            cameraID: "SIMULATED", filename: "SIMULATED-UNCACHED.MOV", handle: 5,
            storageID: 65_537, sizeBytes: 64, captureDate: "")
        clips.upsertBatch([clip, uncached], cameraID: clip.cameraID)
        let original = try clips.localURL(cameraID: clip.cameraID, filename: clip.filename)
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Self.writeSupportedMovie(to: original)
        let model = NativeAppModel(mediaClipStore: clips)
        let capture = try XCTUnwrap(
            NikonMediaDeliveryCapture(model: model, clips: [clip, uncached]))
        let exports = MonitorDeliveryExportStore(
            root: root.appendingPathComponent("delivery", isDirectory: true))
        var configuration = NikonDeliveryConfiguration(
            logTransform: "unchanged", exportFormat: .mov)
        configuration.bakeLUT = false

        let first = try await capture.export(
            clip, configuration: configuration, store: exports, admission: .init { true },
            progress: { _ in })
        let second = try await capture.export(
            clip, configuration: configuration, store: exports, admission: .init { true },
            progress: { _ in })
        XCTAssertEqual(first.lastPathComponent, "SIMULATED.MOV")
        XCTAssertEqual(second.lastPathComponent, "SIMULATED.MOV")
        XCTAssertNotEqual(first, second, "An export never overwrites another")
        XCTAssertTrue(first.path.hasPrefix(exports.exportsDirectory.standardizedFileURL.path))
        XCTAssertEqual(try Data(contentsOf: first), try Data(contentsOf: original))
        let sidecar = first.deletingPathExtension().appendingPathExtension("meta.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let metadata = try decoder.decode(
            MediaClipDeliveryMetadata.self, from: Data(contentsOf: sidecar))
        XCTAssertEqual(metadata.filename, "SIMULATED.MOV")
        XCTAssertEqual(metadata.captureDate, "20261004T120000")
        XCTAssertNil(metadata.lutName, "Nothing was baked")

        exports.release(first)
        XCTAssertFalse(FileManager.default.fileExists(atPath: first.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))

        do {
            _ = try await capture.export(
                uncached, configuration: configuration, store: exports, admission: .init { true },
                progress: { _ in })
            XCTFail("An uncached clip never exports")
        } catch {
            XCTAssertEqual(
                error.localizedDescription, "SIMULATED-UNCACHED.MOV isn't fully cached yet.")
        }
    }

    private static func writeSupportedMovie(to url: URL) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: 16, AVVideoHeightKey: 16,
            ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 16, kCVPixelBufferHeightKey as String: 16,
            ])
        guard writer.canAdd(input) else {
            throw NSError(domain: "NikonDeliveryExportTests", code: 3)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "NikonDeliveryExportTests", code: 4)
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let pixel = buffer else {
            throw NSError(domain: "NikonDeliveryExportTests", code: Int(status))
        }
        CVPixelBufferLockBaseAddress(pixel, [])
        if let address = CVPixelBufferGetBaseAddress(pixel) {
            memset(address, 0x80, CVPixelBufferGetDataSize(pixel))
        }
        CVPixelBufferUnlockBaseAddress(pixel, [])
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        for frame in 0..<2 {
            while !input.isReadyForMoreMediaData && ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard input.isReadyForMoreMediaData else {
                throw NSError(domain: "NikonDeliveryExportTests", code: 5)
            }
            guard
                adaptor.append(
                    pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 25))
            else {
                throw writer.error ?? NSError(domain: "NikonDeliveryExportTests", code: 6)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 25))
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "NikonDeliveryExportTests", code: 7)
        }
        let asset = AVURLAsset(url: url)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertFalse(videoTracks.isEmpty)
        let duration = try await asset.load(.duration)
        XCTAssertTrue(duration.seconds.isFinite && duration.seconds > 0)
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber
        ).uint64Value
        XCTAssertGreaterThan(size, 0)
        XCTAssertLessThan(size, 100_000)
    }
}
