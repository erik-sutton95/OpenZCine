import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import XCTest
import os

@testable import Runner

/// SIMULATED native file operation through the actual delivery exporter adapter.
final class MediaLUTExportAdapterTests: XCTestCase {
    func testActualAdapterPreservesDestinationAndMetadataPolicy() async throws {
        let files = FileManager.default
        let documents = try XCTUnwrap(
            files.urls(for: .documentDirectory, in: .userDomainMask).first)
        let exports = documents.appendingPathComponent("exports", isDirectory: true)
        let exportsExisted = files.fileExists(atPath: exports.path)
        let originalNames =
            exportsExisted ? try files.contentsOfDirectory(atPath: exports.path) : []
        let identifier = UUID().uuidString
        let stem = "SIMULATED-adapter-\(identifier)"
        let nilStem = "SIMULATED-adapter-nil-\(identifier)"
        let videoURL = exports.appendingPathComponent("\(stem).mov")
        let metadataURL = exports.appendingPathComponent("\(stem).meta.json")
        let nilVideoURL = exports.appendingPathComponent("\(nilStem).mov")
        let nilMetadataURL = exports.appendingPathComponent("\(nilStem).meta.json")
        let outputs = [videoURL, metadataURL, nilVideoURL, nilMetadataURL]
        for url in outputs {
            guard (try? files.attributesOfItem(atPath: url.path)) == nil else {
                throw NSError(domain: "MediaLUTExportAdapterTests", code: 1)
            }
        }
        let temporary = files.temporaryDirectory.appendingPathComponent(
            "SIMULATED-adapter-\(identifier)", isDirectory: true)
        guard (try? files.attributesOfItem(atPath: temporary.path)) == nil else {
            throw NSError(domain: "MediaLUTExportAdapterTests", code: 2)
        }
        // Register exact unique paths before any export can create an output.
        defer {
            for url in outputs + [temporary] {
                if files.fileExists(atPath: url.path) {
                    do { try files.removeItem(at: url) } catch {
                        XCTFail("SIMULATED adapter cleanup failed: \(error)")
                    }
                }
            }
            if !exportsExisted, files.fileExists(atPath: exports.path) {
                do {
                    let names = try files.contentsOfDirectory(atPath: exports.path)
                    XCTAssertTrue(names.isEmpty, "Preserve unexpected export entries")
                    if names.isEmpty { try files.removeItem(at: exports) }
                } catch {
                    XCTFail("SIMULATED exports absence restoration failed: \(error)")
                }
            } else if exportsExisted {
                do {
                    XCTAssertEqual(
                        Set(try files.contentsOfDirectory(atPath: exports.path)),
                        Set(originalNames))
                } catch {
                    XCTFail("SIMULATED original exports verification failed: \(error)")
                }
            }
        }
        try files.createDirectory(at: temporary, withIntermediateDirectories: true)
        let sourceURL = temporary.appendingPathComponent("SIMULATED.MOV")
        try await Self.writeSupportedMovie(to: sourceURL)
        let originalMovie = try Data(contentsOf: sourceURL)
        let metadata = MediaClipDeliveryMetadata(
            filename: "SIMULATED.MOV", captureDate: "20261004T120000", sizeBytes: 123,
            cameraName: "SIMULATED", cameraModel: nil, cameraSerial: nil, lutName: nil,
            exportedAt: Date(timeIntervalSince1970: 0))
        let progress = ProgressValues()
        let result = try await MediaLUT.export(
            sourceURL: sourceURL, outputFilename: "  \(stem)  ", format: .mov,
            cube: nil, metadata: metadata
        ) { progress.record($0) }
        XCTAssertEqual(result.videoURL, videoURL)
        XCTAssertEqual(result.metadataURL, metadataURL)
        XCTAssertEqual(try Data(contentsOf: result.videoURL), originalMovie)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalMovie)
        let expectedJSON = """
            {
              "cameraName" : "SIMULATED",
              "captureDate" : "20261004T120000",
              "exportedAt" : "1970-01-01T00:00:00Z",
              "filename" : "SIMULATED.MOV",
              "sizeBytes" : 123
            }
            """
        XCTAssertEqual(try Data(contentsOf: metadataURL), Data(expectedJSON.utf8))
        XCTAssertEqual(progress.values, [0.02, 0.9, 1.0])

        let nilProgress = ProgressValues()
        let noMetadata = try await MediaLUT.export(
            sourceURL: sourceURL, outputFilename: nilStem, format: .mov,
            cube: nil, metadata: nil
        ) { nilProgress.record($0) }
        XCTAssertEqual(noMetadata.videoURL, nilVideoURL)
        XCTAssertNil(noMetadata.metadataURL)
        XCTAssertFalse(files.fileExists(atPath: nilMetadataURL.path))
        XCTAssertEqual(try Data(contentsOf: noMetadata.videoURL), originalMovie)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalMovie)
        XCTAssertEqual(nilProgress.values, [0.02, 0.9, 1.0])

        let beforeRefusal = Set(try files.contentsOfDirectory(atPath: exports.path))
        let refusedProgress = ProgressValues()
        do {
            _ = try await MediaLUT.export(
                sourceURL: sourceURL, outputFilename: " \n\t ", format: .mov,
                cube: nil, metadata: metadata
            ) { refusedProgress.record($0) }
            XCTFail("Whitespace output must preserve invalidFilename refusal")
        } catch let error as MediaLUT.ExportError {
            guard case .invalidFilename = error else {
                XCTFail("Unexpected adapter error: \(error)")
                throw error
            }
            XCTAssertEqual(error.localizedDescription, "Enter a valid filename.")
        }
        XCTAssertTrue(refusedProgress.values.isEmpty)
        XCTAssertEqual(Set(try files.contentsOfDirectory(atPath: exports.path)), beforeRefusal)
        XCTAssertEqual(try Data(contentsOf: sourceURL), originalMovie)
    }

    private final class ProgressValues: Sendable {
        private let state = OSAllocatedUnfairLock(initialState: [Double]())
        func record(_ value: Double) { state.withLock { $0.append(value) } }
        var values: [Double] { state.withLock { $0 } }
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
            throw NSError(domain: "MediaLUTExportAdapterTests", code: 3)
        }
        writer.add(input)
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "MediaLUTExportAdapterTests", code: 4)
        }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        var buffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA, nil, &buffer)
        guard status == kCVReturnSuccess, let pixel = buffer else {
            throw NSError(domain: "MediaLUTExportAdapterTests", code: Int(status))
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
                throw NSError(domain: "MediaLUTExportAdapterTests", code: 5)
            }
            guard
                adaptor.append(
                    pixel, withPresentationTime: CMTime(value: Int64(frame), timescale: 25))
            else {
                throw writer.error ?? NSError(domain: "MediaLUTExportAdapterTests", code: 6)
            }
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 25))
        input.markAsFinished()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? NSError(domain: "MediaLUTExportAdapterTests", code: 7)
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
