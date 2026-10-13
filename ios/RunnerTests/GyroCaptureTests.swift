import Foundation
import OpenZCineCore
import Testing

@testable import Runner

@MainActor @Suite("Phone gyro capture")
struct GyroCaptureTests {
    @Test("Mount selection defaults unconfigured and persists across launches")
    func mountPreference() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        #expect(coordinator.mountPreset == .unconfigured)
        coordinator.mountPreset = .rearLeft
        #expect(
            fixture.defaults.string(forKey: GyroCaptureCoordinator.mountPreferenceKey) == "rearLeft"
        )
        let reopened = fixture.coordinator()
        await reopened.waitUntilLoaded()
        #expect(reopened.mountPreset == .rearLeft)
        fixture.defaults.set(
            "unknown future mount", forKey: GyroCaptureCoordinator.mountPreferenceKey)
        let unknown = fixture.coordinator()
        await unknown.waitUntilLoaded()
        #expect(unknown.mountPreset == .unconfigured)
    }

    @Test("Queued REC snapshots its mount and changes apply only to the next take")
    func mountSnapshot() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.mountPreset = .rearLeft
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        coordinator.observeRecording(true)
        coordinator.mountPreset = .frontDown
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        let first = try #require(coordinator.logs.first)
        #expect(first.descriptor.mount == .rearLeft)
        coordinator.observeRecording(false)
        await coordinator.processPending()
        coordinator.mountPreset = .rearRight
        fixture.feed(from: 10.11, through: 10.2)
        coordinator.observeRecording(true)
        await coordinator.processPending()
        #expect(coordinator.logs.first { $0.id == first.id }?.descriptor.mount == .rearLeft)
        let second = try #require(coordinator.logs.first { $0.id != first.id })
        #expect(second.descriptor.mount == .rearRight)
        coordinator.enabled = false
        await coordinator.processPending()
        let exported = try #require(await coordinator.share(first))
        defer { try? FileManager.default.removeItem(at: exported.deletingLastPathComponent()) }
        #expect(
            try String(contentsOf: exported, encoding: .utf8).contains(
                "orientation,\(GyroMountPreset.rearLeft.orientation)\n"))
    }

    @Test("A REC report during recovery keeps its selected mount")
    func mountBeforeLoad() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.mountPreset = .frontUp
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        coordinator.mountPreset = .rearDown
        await coordinator.waitUntilLoaded()
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.descriptor.mount == .frontUp)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Opt-in defaults off and is persisted")
    func optIn() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        #expect(!coordinator.enabled)
        #expect(fixture.driver.starts == 0)
        coordinator.enabled = true
        #expect(fixture.driver.starts == 1)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
        coordinator.enabled = true
        #expect(fixture.defaults.bool(forKey: GyroCaptureCoordinator.preferenceKey))
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Only reported REC opens a take; repeated states do not duplicate it")
    func cameraTake() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        fixture.feed(from: 10, through: 11.99)
        await coordinator.processPending()
        #expect(coordinator.logs.isEmpty)
        fixture.clock.time = 12
        coordinator.observeRecording(true)
        coordinator.observeRecording(true)
        await coordinator.processPending()
        #expect(coordinator.logs.count == 1)
        #expect(coordinator.logs.first?.active == true)
        fixture.feed(from: 12, through: 12.99)
        fixture.clock.time = 13
        coordinator.observeRecording(false)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        fixture.feed(from: 13, through: 15)
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == .normal)
        #expect(summary.sampleCount > 490)
        #expect(coordinator.logs.count == 1)
        #expect(coordinator.motionRunning)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("A delayed callback batch does not prune pre-roll before the REC event")
    func delayedStartBatch() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        fixture.feed(from: 10, through: 11.99)
        await coordinator.processPending()
        fixture.clock.time = 12
        coordinator.observeRecording(true)
        fixture.feed(from: 12, through: 12.1)
        await coordinator.processPending()
        coordinator.enabled = false
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.sampleCount == 211)
        #expect(abs(summary.duration - 2.1) < 0.0001)
    }

    @Test(
        "Interruption retains queued samples and releases the sensor",
        arguments: [
            GyroLogTermination.backgrounded, .disconnected, .disabled,
        ])
    func interruption(reason: GyroLogTermination) async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.2)
        if reason == .disabled {
            coordinator.enabled = false
        } else {
            coordinator.stop(reason: reason)
        }
        await coordinator.processPending()
        let summary = try #require(coordinator.logs.first?.summary)
        #expect(summary.termination == reason)
        #expect(summary.sampleCount == 21)
        #expect(summary.isPartial)
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.buffer == nil)
    }

    @Test("Rapid disable and enable finishes the prior take before rearming")
    func rapidRearm() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.mountPreset = .rearLeft
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        coordinator.enabled = false
        coordinator.mountPreset = .frontRight
        coordinator.enabled = true
        #expect(fixture.driver.starts == 1)
        await coordinator.processPending()
        #expect(fixture.driver.starts == 2)
        #expect(coordinator.logs.first?.summary?.termination == .disabled)
        await coordinator.processPending()
        #expect(coordinator.logs.first { $0.active }?.descriptor.mount == .frontRight)
        coordinator.enabled = false
        await coordinator.processPending()
        #expect(!coordinator.motionRunning)
    }

    @Test("Ineligible sources cannot start motion, including a recording report")
    func ineligible() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.enabled = true
        coordinator.configure(eligible: false, cameraLabel: "Relay", recording: true)
        await coordinator.waitUntilLoaded()
        #expect(!coordinator.motionRunning)
        #expect(fixture.driver.starts == 0)
        #expect(coordinator.logs.isEmpty)
    }

    @Test("A REC report during asynchronous recovery is retained")
    func reportBeforeLoad() async throws {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        await coordinator.waitUntilLoaded()
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.logs.first?.active == true)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Unavailable sensors and lost callbacks produce a visible failure")
    func sensorFailures() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        fixture.driver.unavailable = true
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: false)
        #expect(coordinator.statusIsFailure)
        #expect(!coordinator.motionRunning)
        fixture.driver.unavailable = false
        coordinator.enabled = false
        coordinator.enabled = true
        fixture.clock.time = 13
        await coordinator.processPending()
        #expect(coordinator.statusIsFailure)
        #expect(!coordinator.motionRunning)
    }

    @Test("A nonterminal sensor gap stays visible while the take continues")
    func liveGapWarning() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let coordinator = fixture.coordinator()
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.01)
        await coordinator.processPending()
        fixture.feed(from: 10.2, through: 10.21)
        await coordinator.processPending()
        #expect(coordinator.hasGapWarning)
        #expect(coordinator.statusText == "GYRO GAP")
        #expect(coordinator.motionRunning)
        coordinator.enabled = false
        await coordinator.processPending()
    }

    @Test("Disk failures abort file ownership and remain visible")
    func writeFailure() async {
        let fixture = GyroFixture()
        defer { fixture.cleanup() }
        let failing = FailingGyroStore()
        let coordinator = fixture.coordinator(store: failing)
        await coordinator.waitUntilLoaded()
        coordinator.enabled = true
        coordinator.configure(eligible: true, cameraLabel: "Nikon test camera", recording: true)
        fixture.feed(from: 10, through: 10.1)
        await coordinator.processPending()
        #expect(coordinator.statusIsFailure)
        #expect(!coordinator.motionRunning)
        #expect(await failing.aborted)
    }

    @Test("The raw callback handoff retains at most 512 samples")
    func boundedQueue() {
        let buffer = GyroSampleBuffer()
        for index in 0..<600 {
            buffer.append(GyroSample(timestamp: Double(index) / 100, x: 1, y: 2, z: 3))
        }
        let batch = buffer.drain()
        #expect(batch.samples.count == 512)
        #expect(batch.failure == .bufferOverflow)
        #expect(buffer.drain().samples.isEmpty)
    }
}

@MainActor private final class GyroTestClock {
    var time: Double = 10
}

@MainActor private final class FakeGyroDriver: GyroMotionDriving {
    var buffer: GyroSampleBuffer?
    var starts = 0
    var unavailable = false
    func startGyro(into buffer: GyroSampleBuffer) throws {
        if unavailable { throw PhoneMotionError.unavailable }
        starts += 1
        self.buffer = buffer
    }
    func stopGyro() { buffer = nil }
}

@MainActor private struct GyroFixture {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let suite = UUID().uuidString
    let driver = FakeGyroDriver()
    let clock = GyroTestClock()
    let defaults: UserDefaults
    init() {
        // SAFETY: a syntactically valid, unique suite always creates a defaults domain.
        defaults = UserDefaults(suiteName: suite)!
    }
    func coordinator(store: (any GyroLogStoring)? = nil) -> GyroCaptureCoordinator {
        GyroCaptureCoordinator(
            defaults: defaults, driver: driver, store: store ?? GyroLogStore(directory: directory),
            now: { clock.time }, automaticProcessing: false)
    }
    func feed(from start: Double, through end: Double) {
        for index in 0...Int(((end - start) * 100).rounded()) {
            driver.buffer?.append(
                GyroSample(timestamp: start + Double(index) / 100, x: 1, y: 2, z: 3))
        }
        clock.time = end
    }
    func cleanup() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor FailingGyroStore: GyroLogStoring {
    var aborted = false
    func load() -> GyroLogRecoveryResult { .init(entries: [], warning: nil) }
    func apply(_ updates: [GyroLogUpdate], at time: Double) throws -> [GyroLogEntry] {
        throw CocoaError(.fileWriteOutOfSpace)
    }
    func abort() -> GyroLogRecoveryResult {
        aborted = true
        return .init(entries: [], warning: nil)
    }
    func share(_ id: UUID) throws -> URL { throw GyroStoreError.missing }
    func delete(_ id: UUID) -> [GyroLogEntry] { [] }
}
