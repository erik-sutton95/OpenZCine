// Progressive object-transfer tests against the scripted fake ZR. The core's
// planner tests own pure range math; these cover bytes on the socket, facade
// pump sequencing, resumable offsets, and the Nikon extended operations.

import Foundation
import OpenZCineCore
import Testing

@testable import OpenZCineAndroidFacade

struct MediaTransferPumpTests {
    private func connect(to server: FakeZRServer) throws -> PTPIPClientSession {
        try PTPIPClientSession.connect(
            host: "127.0.0.1", port: server.port, timeoutMilliseconds: 2_000)
    }

    @Test func streamsStandardObjectIntoOrderedChunks() throws {
        let chunkSize = Int(PTPObjectTransferCursor.defaultChunkSize)
        let payload = Data((0..<(chunkSize * 2 + 37)).map { UInt8(truncatingIfNeeded: $0) })
        let object = mediaObject(handle: 0x2001, payload: payload)
        var options = FakeZRServer.Options()
        options.mediaObjects = [object]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        session.enterMediaMode()

        let collector = TransferCollector()
        try session.startMediaTransfer(
            handle: object.handle,
            reportedSize: UInt64(object.sizeBytes),
            onStarted: collector.started,
            onChunk: collector.chunk,
            onCompleted: collector.completed,
            onStopped: collector.stopped,
            onFailed: collector.failed)
        try collector.waitForTerminal()

        #expect(collector.totalBytes == UInt64(payload.count))
        #expect(collector.completedBytes == UInt64(payload.count))
        #expect(collector.failure == nil)
        #expect(collector.combinedData == payload)
        #expect(collector.offsets == [0, UInt64(chunkSize), UInt64(chunkSize * 2)])
        let requests = server.receivedRequests().filter { $0.operation == .getPartialObject }
        #expect(requests.count == 3)
        #expect(!server.receivedOperations().contains(.getPartialObjectEx))
    }

    @Test func resolvesAndResumesLargeObjectWithNikonExtendedRead() throws {
        let totalBytes = UInt64(UInt32.max) + 1_024
        let resumeOffset = totalBytes - 1_024
        let object = FakeZRMediaObject(
            handle: 0x2002,
            filename: "LARGE.MOV",
            objectFormat: 0x300D,
            sizeBytes: UInt32.max,
            captureDate: "20260714T120000",
            pixelWidth: 3840,
            pixelHeight: 2160,
            thumbnail: [],
            objectSizeBytes: totalBytes)
        var options = FakeZRServer.Options()
        options.mediaObjects = [object]
        let server = try FakeZRServer(options: options)
        defer { server.stop() }
        let session = try connect(to: server)
        defer { session.disconnect() }
        session.enterMediaMode()

        let collector = TransferCollector()
        try session.startMediaTransfer(
            handle: object.handle,
            reportedSize: UInt64(UInt32.max),
            resumeOffset: resumeOffset,
            onStarted: collector.started,
            onChunk: collector.chunk,
            onCompleted: collector.completed,
            onStopped: collector.stopped,
            onFailed: collector.failed)
        try collector.waitForTerminal()

        #expect(collector.failure == nil)
        #expect(collector.totalBytes == totalBytes)
        #expect(collector.offsets == [resumeOffset])
        #expect(collector.combinedData.count == 1_024)
        let requests = server.receivedRequests()
        #expect(requests.contains(FakeZRRequest(operation: .getObjectSize, parameters: [0x2002])))
        let extended = try #require(requests.first { $0.operation == .getPartialObjectEx })
        #expect(
            extended.parameters == [
                0x2002,
                UInt32(truncatingIfNeeded: resumeOffset),
                UInt32(truncatingIfNeeded: resumeOffset >> 32),
                1_024,
                0,
            ])
    }

    private func mediaObject(handle: UInt32, payload: Data) -> FakeZRMediaObject {
        FakeZRMediaObject(
            handle: handle,
            filename: "TEST.MOV",
            objectFormat: 0x300D,
            sizeBytes: UInt32(payload.count),
            captureDate: "20260714T120000",
            pixelWidth: 1920,
            pixelHeight: 1080,
            thumbnail: [],
            payload: payload)
    }
}

// SAFETY: mutable collector state is protected by `condition`.
private final class TransferCollector: @unchecked Sendable {
    private struct TimedOut: Error {}

    private let condition = NSCondition()
    private var chunks: [(offset: UInt64, data: Data)] = []
    private var terminal = false
    private var total: UInt64?
    private var completed: UInt64?
    private var failureMessage: String?

    func started(_ totalBytes: UInt64) {
        condition.lock()
        total = totalBytes
        condition.unlock()
    }

    func chunk(offset: UInt64, data: Data) -> Bool {
        condition.lock()
        chunks.append((offset, data))
        condition.unlock()
        return true
    }

    func completed(_ totalBytes: UInt64) {
        markTerminal { completed = totalBytes }
    }

    func stopped(_ cachedBytes: UInt64) {
        markTerminal { completed = cachedBytes }
    }

    func failed(_ message: String) {
        markTerminal { failureMessage = message }
    }

    var totalBytes: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return total
    }

    var completedBytes: UInt64? {
        condition.lock()
        defer { condition.unlock() }
        return completed
    }

    var failure: String? {
        condition.lock()
        defer { condition.unlock() }
        return failureMessage
    }

    var offsets: [UInt64] {
        condition.lock()
        defer { condition.unlock() }
        return chunks.map(\.offset)
    }

    var combinedData: Data {
        condition.lock()
        defer { condition.unlock() }
        return chunks.sorted { $0.offset < $1.offset }.reduce(into: Data()) { result, chunk in
            result.append(chunk.data)
        }
    }

    func waitForTerminal(timeoutSeconds: TimeInterval = 5) throws {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while !terminal {
            guard condition.wait(until: deadline) else { throw TimedOut() }
        }
    }

    private func markTerminal(_ update: () -> Void) {
        condition.lock()
        update()
        terminal = true
        condition.broadcast()
        condition.unlock()
    }
}
