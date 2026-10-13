import Foundation
import OpenZCineCore
import Testing

@testable import Runner

@Suite("Durable gyro logs")
struct GyroLogStoreTests {
    @Test("The native share bridge preserves GCSV as a data file")
    func shareType() {
        #expect(MediaShareStaging.videoUTType(for: URL(fileURLWithPath: "/take.gcsv")) == .data)
    }

    @Test("An active take cannot be shared or deleted; a completed take exports GCSV")
    func activeGuardsAndExport() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession()
        let opened = session.observeRecording(
            true, at: 10, date: Date(), cameraLabel: "Nikon test camera")
        let entries = try await store.apply(opened, at: 10)
        let id = try #require(entries.first?.id)
        await #expect(throws: GyroStoreError.active) { try await store.share(id) }
        await #expect(throws: GyroStoreError.active) { try await store.delete(id) }
        var updates = session.ingest([GyroSample(timestamp: 10, x: 1, y: 2, z: 3)])
        updates += session.finish(reason: .disabled, at: 10.1)
        _ = try await store.apply(updates, at: 10.1)
        let url = try await store.share(id)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let contents = try String(contentsOf: url, encoding: .utf8)
        #expect(contents.hasPrefix("GYROFLOW IMU LOG"))
        #expect(url.pathExtension == "gcsv")
        #expect(try await store.delete(id).isEmpty)
    }

    @Test("Crash recovery keeps the monotonic complete-row prefix and marks it partial")
    func recoverPrefix() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession()
        var updates = session.observeRecording(
            true, at: 10, date: Date(), cameraLabel: "Nikon test camera")
        updates += session.ingest([
            GyroSample(timestamp: 10, x: 1, y: 2, z: 3),
            GyroSample(timestamp: 10.01, x: 4, y: 5, z: 6),
        ])
        let entries = try await store.apply(updates, at: 10.01)
        let entry = try #require(entries.first)
        let part = directory.appendingPathComponent(entry.id.uuidString).appendingPathComponent(
            "capture.gcsv.part")
        // Simulate termination midway through a row, then release file ownership as after a crash.
        _ = try await store.apply([.appended(id: entry.id, data: Data("9.5,1".utf8))], at: 11)
        let recovered = await store.abort()
        let summary = try #require(recovered.first?.summary)
        #expect(summary.sampleCount == 2)
        #expect(summary.termination == .recovered)
        #expect(summary.isPartial)
        #expect(!FileManager.default.fileExists(atPath: part.path))
        let reopened = try await GyroLogStore(directory: directory).load()
        #expect(reopened.first?.summary?.sampleCount == 2)
    }

    @Test("A damaged header stays visible without blocking other recovered logs")
    func damagedHeader() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        let descriptor = GyroLogDescriptor(
            cameraLabel: "Nikon test camera", startDate: Date(), approximateStartOffset: 2,
            isPartial: true)
        _ = try await store.apply(
            [
                .opened(descriptor), .appended(id: descriptor.id, data: Data("invalid\n".utf8)),
            ], at: 10)
        _ = await store.abort()
        let recovered = try await GyroLogStore(directory: directory).load()
        #expect(recovered.count == 1)
        #expect(recovered.first?.summary == nil)
        #expect(recovered.first?.active == false)
        #expect(try await store.delete(descriptor.id).isEmpty)
    }
}
