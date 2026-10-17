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
        updates += session.finish(reason: .disabled)
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
        let summary = try #require(recovered.entries.first?.summary)
        #expect(summary.sampleCount == 2)
        #expect(summary.termination == .recovered)
        #expect(summary.isPartial)
        #expect(!FileManager.default.fileExists(atPath: part.path))
        let reopened = try await GyroLogStore(directory: directory).load()
        #expect(reopened.entries.first?.summary?.sampleCount == 2)
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
        #expect(recovered.entries.count == 1)
        #expect(recovered.entries.first?.summary == nil)
        #expect(recovered.entries.first?.active == false)
        #expect(try await store.delete(descriptor.id).isEmpty)
    }

    @MainActor
    @Test("A recovery metadata failure leaves saved logs usable and shows a storage warning")
    func recoveryWriteFailureIsIsolated() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = GyroLogStore(directory: directory)
        _ = try await store.load()
        var session = GyroTakeSession()
        var updates = session.observeRecording(
            true, at: 10, date: Date(), cameraLabel: "Saved camera")
        updates += session.ingest([GyroSample(timestamp: 10, x: 1, y: 2, z: 3)])
        updates += session.finish(reason: .disabled)
        let saved = try #require(try await store.apply(updates, at: 10.1).first)

        let interrupted = GyroLogDescriptor(
            cameraLabel: "Interrupted camera", startDate: Date(), approximateStartOffset: 2,
            isPartial: true)
        _ = try await store.apply(
            [
                .opened(interrupted),
                .appended(
                    id: interrupted.id,
                    data: GyroGCSVEncoder.header(descriptor: interrupted)),
            ], at: 11)
        // An occupied metadata directory deterministically rejects the atomic completion write.
        let metadata = directory.appendingPathComponent(interrupted.id.uuidString)
            .appendingPathComponent("summary.json", isDirectory: true)
        try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        try Data("occupied".utf8).write(to: metadata.appendingPathComponent("fixture"))
        let aborted = await store.abort()
        #expect(aborted.entries.count == 2)
        #expect(aborted.warning != nil)

        let coordinator = GyroCaptureCoordinator(
            defaults: defaults, store: GyroLogStore(directory: directory),
            automaticProcessing: false)
        await coordinator.waitUntilLoaded()
        #expect(coordinator.logs.count == 2)
        #expect(coordinator.storageWarning?.contains("Saved logs remain available") == true)
        #expect(coordinator.failure == nil)
        let healthy = try #require(coordinator.logs.first { $0.id == saved.id })
        #expect(healthy.summary != nil)
        let exported = try #require(await coordinator.share(healthy))
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        #expect(try String(contentsOf: exported, encoding: .utf8).hasPrefix("GYROFLOW IMU LOG"))
        await coordinator.delete(healthy)
        #expect(coordinator.logs.map(\.id) == [interrupted.id])
        #expect(coordinator.failure == nil)
        let incomplete = try #require(coordinator.logs.first)
        #expect(incomplete.summary == nil)
        await coordinator.delete(incomplete)
        #expect(coordinator.logs.isEmpty)
    }
}
